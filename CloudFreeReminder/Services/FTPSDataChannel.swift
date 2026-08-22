import Foundation
import Network

// MARK: - Verschluesselter Datenkanal

// Der FTPS-Datenkanal laeuft ueber NWConnection statt ueber URLSessionStreamTask.
//
// Warum nicht URLSessionStreamTask: dessen startSecureConnection() stoesst den
// TLS-Handschlag erst an, wenn danach geschrieben wird. Bei STOR wird
// geschrieben, deshalb liefen Uploads; NLST und RETR lesen nur, der Handschlag
// kam nie zustande und die Uebertragung lief in die Zeitueberschreitung.
//
// Warum ein frueherer NWConnection-Versuch ebenfalls scheiterte: ohne
// sec_protocol_options_set_verify_block prueft Network.framework gegen den
// System-Trust-Store. Das selbstsignierte Zertifikat des Raspberry Pi faellt
// dabei durch – TCP steht (per ss als ESTAB nachgewiesen), der Handschlag
// scheitert trotzdem. Der URLSessionDelegate der Steuerverbindung greift hier
// nicht, NWConnection kennt ihn schlicht nicht.
//
// Ausserdem wurde damals nur auf .ready gewartet. Ein .failed blieb unbemerkt,
// weshalb sich der Abbruch als Zeitueberschreitung tarnte statt als Fehler.
// Deshalb wertet start() jeden Endzustand aus.
nonisolated final class FTPSDataChannel: @unchecked Sendable {

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "de.cloudfree.reminder.datenkanal")
    private let verifyQueue: DispatchQueue
    private let timeout: TimeInterval

    /// Alle drei werden ausschliesslich auf `queue` angefasst – Zustandswechsel,
    /// Wachhund und awaitReady() laufen dort, eine Sperre eruebrigt sich damit.
    private var readyResult: Result<Void, Error>?
    private var readyWaiter: CheckedContinuation<Void, Error>?

    init(
        host: String,
        port: Int,
        useTLS: Bool,
        trustSelfSigned: Bool,
        timeout: TimeInterval
    ) throws {
        guard port > 0, port <= 65_535, let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw FTPSError.invalidResponse("Ungültiger PASV-Port: \(port)")
        }

        let verifyQueue = DispatchQueue(label: "de.cloudfree.reminder.datenkanal.zertifikat")
        self.verifyQueue = verifyQueue
        self.timeout = timeout

        let parameters: NWParameters
        if useTLS {
            let tlsOptions = NWProtocolTLS.Options()
            if trustSelfSigned {
                // Der Kern der Sache: ohne diesen Block prueft Network.framework
                // gegen den System-Trust-Store und lehnt das selbstsignierte
                // Zertifikat ab. complete(false) waere die Pruefung, die der
                // Nutzer per Einstellung bewusst abgeschaltet hat.
                sec_protocol_options_set_verify_block(
                    tlsOptions.securityProtocolOptions,
                    { _, _, complete in complete(true) },
                    verifyQueue
                )
            }
            parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        }

        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: parameters
        )
    }

    // MARK: - Lebenszyklus

    /// Stoesst Verbindungsaufbau und TLS-Handschlag an und kehrt SOFORT zurueck.
    ///
    /// Hier darf nicht auf .ready gewartet werden: vsftpd ruft SSL_accept() auf
    /// dem Datenkanal erst auf, wenn der Uebertragungsbefehl vorliegt. Wer vor
    /// dem NLST/RETR/STOR auf den Handschlag wartet, wartet ewig – der Client
    /// wartet dann auf das ServerHello, der Server auf das Kommando. Am
    /// 22.08.2026 auf dem Pi gemessen: 1496 Bytes ClientHello standen ungelesen
    /// in der Recv-Q des Servers, der Steuerkanal war leer. Genau daran ist auch
    /// der erste NWConnection-Versuch gescheitert.
    ///
    /// Deshalb: erst start(), dann das Kommando senden, dann awaitReady().
    /// curl macht es genauso – daher lief es dort von Anfang an.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.settle(.success(()))
            case .failed(let error):
                self.settle(.failure(FTPSError.dataChannelFailed(Self.describe(error))))
            case .waiting(let error):
                // Network.framework parkt eine abgelehnte Zertifikatspruefung im
                // Wartezustand statt in .failed. Wer nur auf .ready lauscht,
                // bekommt den Grund nie zu sehen und haengt still.
                self.settle(.failure(FTPSError.dataChannelFailed(Self.describe(error))))
            case .cancelled:
                self.settle(.failure(FTPSError.dataChannelFailed("Datenkanal wurde abgebrochen.")))
            default:
                break
            }
        }

        // Wachhund ueber Handschlag und Uebertragung. Der Abbruch laesst auch
        // haengende Lese- und Schreibvorgaenge mit einem Fehler enden.
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.settle(.failure(FTPSError.dataChannelFailed(
                "Zeitüberschreitung auf dem Datenkanal nach \(Int(self.timeout)) s.")))
            self.connection.cancel()
        }

        connection.start(queue: queue)
    }

    /// Wartet den TLS-Handschlag ab. Erst aufrufen, nachdem der Server den
    /// Uebertragungsbefehl mit 150 quittiert hat.
    func awaitReady() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if let result = self.readyResult {
                    cont.resume(with: result)
                } else {
                    self.readyWaiter = cont
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }

    // MARK: - Uebertragung

    /// Liest bis der Server die Verbindung schliesst – so endet ein FTP-Transfer.
    func readAll() async throws -> Data {
        var result = Data()
        while true {
            let (chunk, atEOF) = try await receiveChunk()
            if let chunk { result.append(chunk) }
            if atEOF { break }
        }
        return result
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: FTPSError.dataChannelFailed(Self.describe(error)))
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Signalisiert das Ende der Uebertragung (FIN). Ohne dies wartet der Server
    /// nach STOR weiter auf Daten und quittiert nie mit 226.
    func closeWrite() {
        connection.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .idempotent
        )
    }

    // MARK: - Intern

    private func settle(_ result: Result<Void, Error>) {
        guard readyResult == nil else { return }
        readyResult = result
        if let waiter = readyWaiter {
            readyWaiter = nil
            waiter.resume(with: result)
        }
    }

    private func receiveChunk() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data?, Bool), Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: FTPSError.dataChannelFailed(Self.describe(error)))
                } else {
                    cont.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .tls(let status):
            // Haeufig: -9807 errSSLXCertChainInvalid, -9808 errSSLBadCert,
            // -9843 errSSLHostNameMismatch. Alle drei bedeuten, dass das
            // Zertifikat nicht angenommen wurde.
            return "TLS-Handschlag fehlgeschlagen (Status \(status)). "
                 + "Bei selbstsignierten Zertifikaten muss „Selbstsignierten Zertifikaten vertrauen“ aktiv sein."
        case .posix(let code):
            return "Netzwerkfehler: \(code)"
        case .dns(let code):
            return "DNS-Fehler: \(code)"
        default:
            return String(describing: error)
        }
    }
}
