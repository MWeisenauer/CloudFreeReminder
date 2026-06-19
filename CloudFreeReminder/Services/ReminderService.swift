import Foundation

// MARK: - Error types

enum FTPSError: LocalizedError {
    case notConfigured
    case connectionFailed(String)
    case authFailed
    case tlsFailed
    case listingFailed
    case downloadFailed
    case uploadFailed(String)
    case deleteFailed(String)
    case invalidResponse(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConfigured:             return "FTPS nicht konfiguriert – bitte Einstellungen prüfen."
        case .connectionFailed(let msg): return "Verbindungsfehler: \(msg)"
        case .authFailed:                return "Anmeldung fehlgeschlagen – Benutzername oder Passwort prüfen."
        case .tlsFailed:                 return "TLS/SSL-Handshake fehlgeschlagen."
        case .listingFailed:             return "Verzeichnisliste konnte nicht geladen werden."
        case .downloadFailed:            return "Datei konnte nicht heruntergeladen werden."
        case .uploadFailed(let msg):     return "Upload fehlgeschlagen: \(msg)"
        case .deleteFailed(let msg):     return "Löschen fehlgeschlagen: \(msg)"
        case .invalidResponse(let msg):  return "Ungültige Server-Antwort: \(msg)"
        case .notConnected:              return "Nicht mit FTP-Server verbunden."
        }
    }
}

// MARK: - TLS delegate

final class FTPSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let allowSelfSigned: Bool
    nonisolated(unsafe) var dataChannelMode = false

    init(allowSelfSigned: Bool) {
        self.allowSelfSigned = allowSelfSigned
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if allowSelfSigned || dataChannelMode {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Reminder service

// Uses explicit TLS (AUTH TLS) and passive mode (PASV).
// Data channel encryption is auto-detected: starts with PROT C (unencrypted).
// If the server responds 425, switches to PROT P (encrypted) and retries transparently.
actor ReminderService {
    private let settings: FTPSSettings

    private var controlTask: URLSessionStreamTask?
    private var urlSession: URLSession?
    private var ftpDelegate: FTPSDelegate?
    private var readBuffer = Data()
    private var encryptDataChannel = false  // auto-set on first 425 response

    private let commandTimeout: TimeInterval = 30
    private let readTimeout: TimeInterval    = 30
    private let dataTimeout: TimeInterval    = 120

    init(settings: FTPSSettings) {
        self.settings = settings
    }

    // MARK: - Public API

    func fetchAllReminders() async throws -> [Reminder] {
        guard settings.isConfigured else { throw FTPSError.notConfigured }
        try await connect()
        defer { disconnect() }
        let filenames = try await listFiles()
        var reminders: [Reminder] = []
        for filename in filenames {
            if let reminder = try? await fetchReminder(filename: filename) {
                reminders.append(reminder)
            }
        }
        return reminders.sorted { sortKey($0) < sortKey($1) }
    }

    func uploadReminder(_ reminder: Reminder) async throws {
        guard settings.isConfigured else { throw FTPSError.notConfigured }
        guard let data = encode(reminder).data(using: .utf8) else {
            throw FTPSError.uploadFailed("Erinnerung konnte nicht kodiert werden.")
        }
        try await connect()
        defer { disconnect() }
        try await storeFile(filename: reminder.remoteFilename, data: data)
    }

    func deleteReminder(filename: String) async throws {
        guard settings.isConfigured else { throw FTPSError.notConfigured }
        try await connect()
        defer { disconnect() }
        guard let controlTask else { throw FTPSError.notConnected }
        try await send("DELE \(filename)\r\n", to: controlTask)
        let resp = try await readResponse(from: controlTask)
        guard resp.hasPrefix("2") else {
            throw FTPSError.deleteFailed(resp)
        }
    }

    func testConnection() async throws -> String {
        guard settings.isConfigured else { throw FTPSError.notConfigured }
        try await connect()
        defer { disconnect() }
        let filenames = try await listFiles()
        return "Verbunden! \(filenames.count) Erinnerung(en) im Verzeichnis."
    }

    // Sorts open reminders by due date first, completed ones last.
    private func sortKey(_ r: Reminder) -> Date {
        if r.isCompleted { return Date.distantFuture }
        return r.dueDate ?? Date.distantFuture
    }

    // MARK: - Reminder encoding / decoding
    // Format: line 1 = title
    //         line 2 = ISO8601 modified date
    //         line 3 = ISO8601 due date (empty if none)
    //         line 4 = "1" completed / "0" open
    //         lines 5+ = body

    private func encode(_ reminder: Reminder) -> String {
        let iso = ISO8601DateFormatter()
        let modified = iso.string(from: reminder.modifiedDate)
        let due = reminder.dueDate.map { iso.string(from: $0) } ?? ""
        let completed = reminder.isCompleted ? "1" : "0"
        return [reminder.title, modified, due, completed, reminder.body].joined(separator: "\n")
    }

    private func decode(_ text: String, filename: String) -> Reminder {
        let iso = ISO8601DateFormatter()
        var reminder = Reminder()
        reminder.remoteFilename = filename
        let uuidStr = filename.hasSuffix(".txt") ? String(filename.dropLast(4)) : filename
        reminder.id = UUID(uuidString: uuidStr) ?? UUID()
        let lines = text.components(separatedBy: "\n")
        if lines.count >= 1 { reminder.title = lines[0] }
        if lines.count >= 2 { reminder.modifiedDate = iso.date(from: lines[1]) ?? Date() }
        if lines.count >= 3 { reminder.dueDate = lines[2].isEmpty ? nil : iso.date(from: lines[2]) }
        if lines.count >= 4 { reminder.isCompleted = lines[3] == "1" }
        if lines.count >= 5 { reminder.body = lines[4...].joined(separator: "\n") }
        return reminder
    }

    // MARK: - Connection lifecycle

    private func connect() async throws {
        let delegate = FTPSDelegate(allowSelfSigned: settings.trustSelfSignedCertificates)
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest  = commandTimeout
        sessionConfig.timeoutIntervalForResource = dataTimeout
        let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
        ftpDelegate = delegate
        urlSession  = session
        readBuffer  = Data()

        let task = session.streamTask(withHostName: settings.host, port: settings.port)
        task.resume()

        let banner = try await readResponse(from: task)
        guard banner.hasPrefix("220") else {
            throw FTPSError.connectionFailed("Kein FTP-Banner: \(banner)")
        }

        try await send("AUTH TLS\r\n", to: task)
        let authResp = try await readResponse(from: task)
        guard authResp.hasPrefix("234") else { throw FTPSError.tlsFailed }
        task.startSecureConnection()

        try await send("USER \(settings.username)\r\n", to: task)
        let userResp = try await readResponse(from: task)
        if userResp.hasPrefix("331") {
            try await send("PASS \(settings.password)\r\n", to: task)
            let passResp = try await readResponse(from: task)
            guard passResp.hasPrefix("230") else { throw FTPSError.authFailed }
        } else if !userResp.hasPrefix("230") {
            throw FTPSError.authFailed
        }

        try await send("PBSZ 0\r\n", to: task)
        _ = try await readResponse(from: task)
        // PROT C: unencrypted data channel. Fritz!Box built-in FTP (port 21) responds 200
        // to PROT P but does not perform TLS on the data channel → handshake deadlock.
        try await send("PROT C\r\n", to: task)
        _ = try await readResponse(from: task)

        let path = settings.remotePath.isEmpty ? "/" : settings.remotePath
        if path != "/" {
            try await send("CWD \(path)\r\n", to: task)
            let cwdResp = try await readResponse(from: task)
            guard cwdResp.hasPrefix("2") else {
                throw FTPSError.connectionFailed("Verzeichnis nicht gefunden: \(path)")
            }
        }

        controlTask = task
    }

    private func disconnect() {
        controlTask?.cancel()
        controlTask = nil
        urlSession?.invalidateAndCancel()
        urlSession  = nil
        ftpDelegate = nil
    }

    // MARK: - FTP operations

    private func listFiles() async throws -> [String] {
        guard let controlTask, let urlSession else { throw FTPSError.notConnected }
        try await send("TYPE A\r\n", to: controlTask)
        _ = try await readResponse(from: controlTask)

        var dataTask = try await openDataChannel(controlTask: controlTask, session: urlSession)
        try await send("NLST\r\n", to: controlTask)
        var reply = try await readResponse(from: controlTask)

        if reply.hasPrefix("425") {
            dataTask.cancel()
            try await upgradeToProtP(controlTask: controlTask)
            dataTask = try await openDataChannel(controlTask: controlTask, session: urlSession)
            try await send("NLST\r\n", to: controlTask)
            reply = try await readResponse(from: controlTask)
        }

        if reply.hasPrefix("226") || reply.hasPrefix("250") {
            dataTask.cancel()
            return []
        }
        guard reply.hasPrefix("125") || reply.hasPrefix("150") else {
            dataTask.cancel()
            throw FTPSError.connectionFailed("NLST fehlgeschlagen: \(reply)")
        }

        let data = try await readAll(from: dataTask)
        _ = try? await readResponse(from: controlTask) // 226

        let listing = String(data: data, encoding: .utf8)
                   ?? String(data: data, encoding: .isoLatin1) ?? ""
        return listing
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased().hasSuffix(".txt") }
    }

    private func fetchReminder(filename: String) async throws -> Reminder {
        guard let controlTask, let urlSession else { throw FTPSError.notConnected }
        try await send("TYPE I\r\n", to: controlTask)
        _ = try await readResponse(from: controlTask)

        var dataTask = try await openDataChannel(controlTask: controlTask, session: urlSession)
        try await send("RETR \(filename)\r\n", to: controlTask)
        var reply = try await readResponse(from: controlTask)

        if reply.hasPrefix("425") {
            dataTask.cancel()
            try await upgradeToProtP(controlTask: controlTask)
            dataTask = try await openDataChannel(controlTask: controlTask, session: urlSession)
            try await send("RETR \(filename)\r\n", to: controlTask)
            reply = try await readResponse(from: controlTask)
        }

        guard reply.hasPrefix("125") || reply.hasPrefix("150") else {
            dataTask.cancel()
            throw FTPSError.downloadFailed
        }

        let data = try await readAll(from: dataTask)
        _ = try? await readResponse(from: controlTask) // 226

        guard let content = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else {
            throw FTPSError.downloadFailed
        }
        return decode(content, filename: filename)
    }

    private func storeFile(filename: String, data: Data) async throws {
        guard let controlTask, let urlSession else { throw FTPSError.notConnected }
        try await send("TYPE I\r\n", to: controlTask)
        _ = try await readResponse(from: controlTask)

        var dataTask = try await openDataChannel(controlTask: controlTask, session: urlSession)
        try await send("STOR \(filename)\r\n", to: controlTask)
        var storResp = try await readResponse(from: controlTask)

        if storResp.hasPrefix("425") {
            dataTask.cancel()
            try await upgradeToProtP(controlTask: controlTask)
            dataTask = try await openDataChannel(controlTask: controlTask, session: urlSession)
            try await send("STOR \(filename)\r\n", to: controlTask)
            storResp = try await readResponse(from: controlTask)
        }

        guard storResp.hasPrefix("125") || storResp.hasPrefix("150") else {
            dataTask.cancel()
            throw FTPSError.uploadFailed("STOR abgelehnt: \(storResp)")
        }

        try await writeData(data, to: dataTask)
        dataTask.closeWrite()

        let completeResp = (try? await readResponse(from: controlTask)) ?? "226 implicit"
        if !completeResp.hasPrefix("226") && !completeResp.hasPrefix("250")
            && !completeResp.hasPrefix("4") && !completeResp.hasPrefix("5") {
            throw FTPSError.uploadFailed("Keine Transfer-Bestätigung: \(completeResp)")
        }
    }

    // Switches to encrypted data channel (PROT P) after a 425 response.
    // Subsequent openDataChannel calls will use startSecureConnection().
    private func upgradeToProtP(controlTask: URLSessionStreamTask) async throws {
        encryptDataChannel = true
        try await send("PROT P\r\n", to: controlTask)
        _ = try await readResponse(from: controlTask)
    }

    // MARK: - Passive data channel

    private func openDataChannel(
        controlTask: URLSessionStreamTask,
        session: URLSession
    ) async throws -> URLSessionStreamTask {
        try await send("PASV\r\n", to: controlTask)
        let pasvResp = try await readResponse(from: controlTask)
        guard pasvResp.hasPrefix("227") else {
            throw FTPSError.connectionFailed("PASV fehlgeschlagen: \(pasvResp)")
        }
        let (_, port) = try parsePASV(pasvResp)
        // Ignore the IP from PASV — Fritz!Box sometimes returns 0.0.0.0 or external WAN IP.
        ftpDelegate?.dataChannelMode = encryptDataChannel
        let dataTask = session.streamTask(withHostName: settings.host, port: port)
        dataTask.resume()
        if encryptDataChannel { dataTask.startSecureConnection() }
        return dataTask
    }

    // MARK: - Low-level I/O

    private func send(_ command: String, to task: URLSessionStreamTask) async throws {
        let data = Data(command.utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: commandTimeout) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private func writeData(_ data: Data, to task: URLSessionStreamTask) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: dataTimeout) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private func readResponse(from task: URLSessionStreamTask) async throws -> String {
        while true {
            let line = try await readLine(from: task)
            guard line.count >= 4 else { continue }
            if line[line.index(line.startIndex, offsetBy: 3)] == " " { return line }
        }
    }

    private func readLine(from task: URLSessionStreamTask) async throws -> String {
        while true {
            if let range = readBuffer.range(of: Data("\r\n".utf8)) {
                let line = String(data: readBuffer[..<range.lowerBound], encoding: .utf8) ?? ""
                readBuffer.removeSubrange(..<range.upperBound)
                return line
            }
            if let range = readBuffer.range(of: Data("\n".utf8)) {
                var line = String(data: readBuffer[..<range.lowerBound], encoding: .utf8) ?? ""
                if line.hasSuffix("\r") { line.removeLast() }
                readBuffer.removeSubrange(..<range.upperBound)
                return line
            }
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                task.readData(ofMinLength: 1, maxLength: 4096, timeout: readTimeout) { data, _, error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: data ?? Data()) }
                }
            }
            readBuffer.append(chunk)
        }
    }

    private func readAll(from task: URLSessionStreamTask) async throws -> Data {
        var result = Data()
        while true {
            let (chunk, eof): (Data?, Bool) = try await withCheckedThrowingContinuation { cont in
                task.readData(ofMinLength: 1, maxLength: 65536, timeout: dataTimeout) { data, atEOF, error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: (data, atEOF)) }
                }
            }
            if let chunk { result.append(chunk) }
            if eof { break }
        }
        return result
    }

    // MARK: - PASV parser

    private func parsePASV(_ response: String) throws -> (String, Int) {
        guard let open  = response.firstIndex(of: "("),
              let close = response.firstIndex(of: ")") else {
            throw FTPSError.invalidResponse("PASV-Format ungültig: \(response)")
        }
        let inner = String(response[response.index(after: open)..<close])
        let parts = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 6 else {
            throw FTPSError.invalidResponse("PASV-Parameter ungültig: \(inner)")
        }
        return ("\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3])", parts[4] * 256 + parts[5])
    }
}
