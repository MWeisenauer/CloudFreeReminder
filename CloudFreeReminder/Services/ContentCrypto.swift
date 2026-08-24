import CryptoKit
import Foundation

// Inhaltsverschluesselung: Dateien werden auf dem Geraet verschluesselt und
// verlassen es nur noch als Geheimtext. Der Server sieht den Klartext nie – das
// gilt fuer die Fritz!Box genauso wie fuer den Raspberry Pi, denn hier ist
// serverseitig nichts zu konfigurieren.
//
// FTPS schuetzt die Uebertragung, diese Schicht schuetzt die Ablage. Beides
// zusammen: unterwegs verschluesselt und im Ruhezustand verschluesselt.
//
// Dateiformat
//
//     Byte 0..3     "CFE1"      Kennung samt Formatversion
//     Byte 4..15    Nonce       12 Byte, von AES-GCM erzeugt
//     Byte 16..n    Geheimtext
//     letzte 16     Tag         Authentisierung
//
// Ab Byte 4 ist das exakt `AES.GCM.SealedBox.combined`. Die vier Byte davor
// sind der Grund, warum die Umstellung ohne Stichtag auskommt: Beim Lesen
// entscheidet die Kennung, ob entschluesselt oder als Klartext geparst wird.
// Der Bestand wandert dadurch von selbst hinueber, sobald eine Datei
// geschrieben wird.
//
// Der Dateiname geht als zusaetzlich authentisierte Daten (AAD) mit ein. Wer
// eine Datei ueber eine andere kopiert, bekommt beim Lesen einen
// Authentisierungsfehler statt fremden Inhalts.
//
// WICHTIG: Entschluesseln darf niemals von der Kaufberechtigung abhaengen.
// `seal` ist das kostenpflichtige Feature, `open` nicht – sonst waeren die
// Daten des Kunden bei Erstattung, misslungener Wiederherstellung oder
// fehlendem Netz unerreichbar.
nonisolated enum ContentCrypto {

    // Vier Byte, nicht mehr. Wer das aendert, macht alle abgelegten Dateien
    // unlesbar – eine neue Formatversion bekaeme "CFE2" und muesste "CFE1"
    // weiterhin lesen koennen.
    static let magic = Data("CFE1".utf8)

    private static let nonceBytes = 12
    private static let tagBytes   = 16

    // Kleinstmoegliche verschluesselte Datei: Kennung, Nonce und Tag, kein Inhalt.
    static var overhead: Int { magic.count + nonceBytes + tagBytes }

    // Traegt die Datei unsere Kennung? Einzige Unterscheidung zwischen alten
    // Klartextdateien und neuen verschluesselten.
    static func isEncrypted(_ data: Data) -> Bool {
        data.count >= magic.count && data.prefix(magic.count) == magic
    }

    static func seal(_ plaintext: Data,
                     filename: String,
                     using key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.seal(plaintext,
                                       using: key,
                                       authenticating: Data(filename.utf8))
            guard let combined = box.combined else { throw CryptoError.sealFailed }
            return magic + combined
        } catch {
            throw CryptoError.sealFailed
        }
    }

    static func open(_ data: Data,
                     filename: String,
                     using key: SymmetricKey) throws -> Data {
        guard isEncrypted(data)   else { throw CryptoError.notEncrypted }
        guard data.count > overhead else { throw CryptoError.truncated }

        let combined = Data(data.dropFirst(magic.count))
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box,
                                    using: key,
                                    authenticating: Data(filename.utf8))
        } catch {
            // AES-GCM unterscheidet nicht zwischen falschem Schluessel und
            // veraenderten Daten – beides schlaegt bei der Tag-Pruefung fehl.
            throw CryptoError.wrongKeyOrTampered
        }
    }
}

nonisolated enum CryptoError: LocalizedError {
    case notEncrypted
    case truncated
    case wrongKeyOrTampered
    case sealFailed
    case noKey
    case invalidBackupCode

    var errorDescription: String? {
        switch self {
        case .notEncrypted:
            return "Diese Datei ist nicht verschlüsselt."
        case .truncated:
            return "Die verschlüsselte Datei ist unvollständig."
        case .wrongKeyOrTampered:
            return "Diese Datei gehört zu einem anderen Schlüssel oder wurde verändert."
        case .sealFailed:
            return "Der Inhalt konnte nicht verschlüsselt werden."
        case .noKey:
            return "Auf diesem Gerät liegt kein Schlüssel. Bitte den Sicherungscode eingeben."
        case .invalidBackupCode:
            return "Der Sicherungscode ist ungültig."
        }
    }
}
