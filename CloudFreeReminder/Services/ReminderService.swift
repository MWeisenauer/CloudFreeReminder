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
    case dataChannelFailed(String)

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
        case .dataChannelFailed(let msg): return "Datenkanal: \(msg)"
        }
    }
}

// MARK: - TLS delegate

// Gilt nur noch fuer die Steuerverbindung. Der Datenkanal laeuft ueber
// NWConnection und bringt seine eigene Zertifikatspruefung mit – siehe
// FTPSDataChannel.
final class FTPSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let allowSelfSigned: Bool

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
        if allowSelfSigned {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Reminder service

// Uses explicit TLS (AUTH TLS) and passive mode (PASV).
// Der Datenkanal ist verschluesselt (PROT P) und laeuft ueber FTPSDataChannel.
// Nur wenn ein Server das Kommando PROT P selbst zurueckweist, faellt die
// Verbindung auf PROT C zurueck.
actor ReminderService {
    private let settings: FTPSSettings

    private var controlTask: URLSessionStreamTask?
    private var urlSession: URLSession?
    private var ftpDelegate: FTPSDelegate?
    private var readBuffer = Data()
    private var encryptDataChannel = true   // PROT P; nur auf Serverwunsch abgeschaltet

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
        var failed: [String] = []
        for filename in filenames {
            do {
                reminders.append(try await fetchReminder(filename: filename))
            } catch {
                failed.append(filename)
            }
        }
        // Frueher wurden fehlgeschlagene Downloads mit try? verschluckt. Eine
        // unvollstaendige Liste sah dann aus wie eine vollstaendige – bei einer
        // App fuer Termine die denkbar schlechteste Eigenschaft.
        if !failed.isEmpty && reminders.isEmpty {
            throw FTPSError.connectionFailed(
                "\(failed.count) Erinnerung(en) konnten nicht geladen werden.")
        }
        return reminders.sorted { sortKey($0) < sortKey($1) }
    }

    func uploadReminder(_ reminder: Reminder) async throws {
        guard settings.isConfigured else { throw FTPSError.notConfigured }
        guard let plaintext = encode(reminder).data(using: .utf8) else {
            throw FTPSError.uploadFailed("Erinnerung konnte nicht kodiert werden.")
        }
        let data = try prepareForUpload(plaintext, filename: reminder.remoteFilename)
        try await connect()
        defer { disconnect() }
        try await storeFile(filename: reminder.remoteFilename, data: data)
    }

    // Verschluesselt, sofern gekauft, gesichert und ein Schluessel da ist.
    // Sonst geht der Inhalt wie bisher im Klartext hinaus. Die Umstellung
    // braucht deshalb keinen Stichtag: der Bestand wandert hinueber, sobald
    // eine Erinnerung geschrieben wird.
    private func prepareForUpload(_ plaintext: Data, filename: String) throws -> Data {
        guard EncryptionPolicy.mayEncrypt else { return plaintext }
        let key = try CryptoKeyStore.appKey()
        return try ContentCrypto.seal(plaintext, filename: filename, using: key)
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

    // Die Kennung "CFE1" entscheidet, nicht eine Einstellung: alte
    // Klartextdateien und neue verschluesselte liegen nebeneinander und werden
    // beide gelesen.
    //
    // Hier wird bewusst NICHT nach der Kaufberechtigung gefragt. Entschluesseln
    // muss immer moeglich sein – siehe EncryptionPolicy.
    private func decryptIfNeeded(_ raw: Data, filename: String) throws -> Data {
        guard ContentCrypto.isEncrypted(raw) else { return raw }
        let key = try CryptoKeyStore.appKey()
        return try ContentCrypto.open(raw, filename: filename, using: key)
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
        // PROT P: verschluesselter Datenkanal – seit dem 22.08.2026 die
        // Voreinstellung.
        //
        // Vorher stand hier PROT C, weil der Handschlag auf dem Datenkanal mit
        // keinem Weg zustande kam. Die Ursache war ein fehlender Verify-Block:
        // NWConnection prueft ohne sec_protocol_options_set_verify_block gegen
        // den System-Trust-Store und lehnt das selbstsignierte Zertifikat des
        // Raspberry Pi ab. Der URLSessionDelegate der Steuerverbindung greift
        // dort nicht. Einzelheiten in FTPSDataChannel.
        //
        // Zurueckgefallen wird nur, wenn der Server das Kommando PROT P selbst
        // zurueckweist. Scheitert spaeter der Handschlag, wird der Fehler
        // gemeldet und NICHT still auf Klartext umgeschaltet – genau dieses
        // stille Zurueckfallen hat dafuer gesorgt, dass die Dateiinhalte lange
        // offen uebertragen wurden, ohne dass es auffiel.
        try await send("PROT P\r\n", to: task)
        let protResp = try await readResponse(from: task)
        if protResp.hasPrefix("2") {
            encryptDataChannel = true
        } else {
            encryptDataChannel = false
            try await send("PROT C\r\n", to: task)
            _ = try await readResponse(from: task)
        }

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
        guard let controlTask else { throw FTPSError.notConnected }
        try await send("TYPE A\r\n", to: controlTask)
        _ = try await readResponse(from: controlTask)

        let dataChannel = try await openDataChannel(controlTask: controlTask)
        try await send("NLST\r\n", to: controlTask)
        let reply = try await readResponse(from: controlTask)

        if reply.hasPrefix("226") || reply.hasPrefix("250") {
            dataChannel.cancel()
            return []
        }
        guard reply.hasPrefix("125") || reply.hasPrefix("150") else {
            dataChannel.cancel()
            throw FTPSError.connectionFailed("NLST fehlgeschlagen: \(reply)")
        }

        // Jetzt hat vsftpd den Handschlag begonnen.
        try await dataChannel.awaitReady()
        let data = try await dataChannel.readAll()
        dataChannel.cancel()
        // Der Abschlusscode wird ausgewertet, nicht verworfen. Bleibt er aus
        // oder meldet er einen Fehler, kam die Uebertragung nicht zustande –
        // ohne diese Pruefung waere das von einem leeren Verzeichnis nicht zu
        // unterscheiden und die App zeigte stillschweigend "keine Eintraege".
        let completion = try await readResponse(from: controlTask)
        guard completion.hasPrefix("226") || completion.hasPrefix("250") else {
            throw FTPSError.connectionFailed("Verzeichnisliste unvollständig: \(completion)")
        }

        let listing = String(data: data, encoding: .utf8)
                   ?? String(data: data, encoding: .isoLatin1) ?? ""
        return listing
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased().hasSuffix(".txt") }
    }

    private func fetchReminder(filename: String) async throws -> Reminder {
        guard let controlTask else { throw FTPSError.notConnected }
        try await send("TYPE I\r\n", to: controlTask)
        _ = try await readResponse(from: controlTask)

        let dataChannel = try await openDataChannel(controlTask: controlTask)
        try await send("RETR \(filename)\r\n", to: controlTask)
        let reply = try await readResponse(from: controlTask)

        guard reply.hasPrefix("125") || reply.hasPrefix("150") else {
            dataChannel.cancel()
            throw FTPSError.downloadFailed
        }

        try await dataChannel.awaitReady()
        let raw = try await dataChannel.readAll()
        dataChannel.cancel()
        _ = try? await readResponse(from: controlTask) // 226

        let data = try decryptIfNeeded(raw, filename: filename)
        guard let content = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else {
            throw FTPSError.downloadFailed
        }
        return decode(content, filename: filename)
    }

    private func storeFile(filename: String, data: Data) async throws {
        guard let controlTask else { throw FTPSError.notConnected }
        try await send("TYPE I\r\n", to: controlTask)
        _ = try await readResponse(from: controlTask)

        let dataChannel = try await openDataChannel(controlTask: controlTask)
        try await send("STOR \(filename)\r\n", to: controlTask)
        let storResp = try await readResponse(from: controlTask)

        guard storResp.hasPrefix("125") || storResp.hasPrefix("150") else {
            dataChannel.cancel()
            throw FTPSError.uploadFailed("STOR abgelehnt: \(storResp)")
        }

        try await dataChannel.awaitReady()
        try await dataChannel.write(data)
        dataChannel.closeWrite()
        // Den Datenkanal VOR dem Warten auf 226 vollstaendig schliessen. Die
        // FRITZ!Box 7690 bestaetigt den Upload erst, wenn die TLS-Sitzung beendet
        // ist (close_notify + FIN); das halbe Schliessen allein laesst beide
        // Seiten warten, bis der Steuerkanal in die Zeitueberschreitung laeuft.
        // cancel() schliesst geordnet: bereits Geschriebenes geht noch raus.
        dataChannel.cancel()

        let completeResp = (try? await readResponse(from: controlTask)) ?? "226 implicit"
        if !completeResp.hasPrefix("226") && !completeResp.hasPrefix("250")
            && !completeResp.hasPrefix("4") && !completeResp.hasPrefix("5") {
            throw FTPSError.uploadFailed("Keine Transfer-Bestätigung: \(completeResp)")
        }
    }

    // MARK: - Passive data channel

    private func openDataChannel(
        controlTask: URLSessionStreamTask
    ) async throws -> FTPSDataChannel {
        try await send("PASV\r\n", to: controlTask)
        let pasvResp = try await readResponse(from: controlTask)
        guard pasvResp.hasPrefix("227") else {
            throw FTPSError.connectionFailed("PASV fehlgeschlagen: \(pasvResp)")
        }
        let (_, port) = try parsePASV(pasvResp)
        // Ignore the IP from PASV — Fritz!Box sometimes returns 0.0.0.0 or external WAN IP.
        let dataChannel = try FTPSDataChannel(
            host: settings.host,
            port: port,
            useTLS: encryptDataChannel,
            trustSelfSigned: settings.trustSelfSignedCertificates,
            timeout: dataTimeout
        )
        // Stoesst den Aufbau an, wartet aber NICHT auf den Handschlag: vsftpd
        // beginnt ihn erst nach dem Uebertragungsbefehl. Auf .ready wird nach
        // dem 150 gewartet – siehe FTPSDataChannel.start().
        dataChannel.start()
        return dataChannel
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
