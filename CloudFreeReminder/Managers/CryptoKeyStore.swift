import CryptoKit
import Foundation

// Verwaltet den Schluessel fuer die Inhaltsverschluesselung.
//
// Aufbau
//
//   Hauptschluessel   256 Bit Zufall, einmalig erzeugt, im Keychain.
//                     Geteilt ueber alle CloudFree-Apps – deshalb genuegt ein
//                     Sicherungscode und ein Scan je Geraet statt dreizehn.
//   App-Schluessel    per HKDF aus dem Hauptschluessel abgeleitet, je App
//                     eigen. Der Schluessel des Reminders taugt nicht dazu,
//                     den Tresor von CloudFreePass zu oeffnen.
//
// Der Kauf ist davon unberuehrt: er gilt je App, der Schluessel wird geteilt.
// Wer die zweite App kauft, findet den Schluessel bereits vor – kein neuer
// Sicherungsdialog.
//
// Kein Passwort, keine Ableitung aus einer Passphrase. Ein Zufallsschluessel
// ist staerker als alles Merkbare, und CryptoKit bringt bewusst kein PBKDF2
// mit. Der Preis dafuer ist, dass die Sicherung Pflicht ist – siehe unten.
nonisolated enum CryptoKeyStore {

    // Fester Bezeichner dieser App fuer die HKDF-Ableitung.
    //
    // NIEMALS AENDERN. Aus diesem Text entsteht der App-Schluessel; ein anderer
    // Text ergibt einen anderen Schluessel und macht jede abgelegte Datei
    // unlesbar. Bewusst nicht die Bundle-ID, die kann sich aendern.
    private static let appLabel = "CloudFreeReminder"

    private static let keychainAccount = "de.cloudfree.contentkey.v1"
    private static let hkdfSalt = Data("CloudFree-Inhaltsverschluesselung-v1".utf8)

    // MARK: - Hauptschluessel

    static var hasMasterKey: Bool { masterKey() != nil }

    static func masterKey() -> SymmetricKey? {
        guard let data = KeychainStore.data(for: keychainAccount),
              data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    // Erzeugt einen neuen Hauptschluessel und legt ihn ab. Ueberschreibt einen
    // vorhandenen NICHT – das waere der stille Totalverlust aller Dateien, die
    // mit dem alten Schluessel abgelegt wurden.
    @discardableResult
    static func createMasterKeyIfNeeded() -> SymmetricKey {
        if let existing = masterKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        store(key)
        return key
    }

    private static func store(_ key: SymmetricKey) {
        let data = key.withUnsafeBytes { Data($0) }
        KeychainStore.setData(data, for: keychainAccount)
    }

    // MARK: - App-Schluessel

    // Der Schluessel, mit dem diese App tatsaechlich arbeitet.
    static func appKey() throws -> SymmetricKey {
        guard let master = masterKey() else { throw CryptoError.noKey }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: master,
                                      salt: hkdfSalt,
                                      info: Data(appLabel.utf8),
                                      outputByteCount: 32)
    }

    // MARK: - Sicherung

    // Der Sicherungscode ist der Hauptschluessel in Base64 – 44 Zeichen, passt
    // muehelos in einen QR-Code und laesst sich zur Not abschreiben.
    //
    // Ohne ihn sind die Daten bei Geraetewechsel verloren: der Keychain-Eintrag
    // steht auf `WhenUnlockedThisDeviceOnly` und wandert deshalb in KEIN
    // Backup, auch nicht in ein verschluesseltes. Die Sicherung ist damit kein
    // Komfortmerkmal, sondern tragendes Teil des Entwurfs.
    static func backupCode() -> String? {
        masterKey()?.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    // Stellt den Hauptschluessel aus einem Sicherungscode wieder her.
    // Verweigert das Ueberschreiben eines vorhandenen Schluessels, ausser der
    // Code beschreibt genau denselben – so kann ein Fehlgriff beim Scannen
    // keinen Bestand vernichten.
    static func restore(fromBackupCode code: String) throws {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: cleaned), data.count == 32 else {
            throw CryptoError.invalidBackupCode
        }
        if let existing = masterKey() {
            let same = existing.withUnsafeBytes { Data($0) } == data
            guard same else { throw CryptoError.wrongKeyOrTampered }
            return
        }
        store(SymmetricKey(data: data))
    }

    // Prueft, ob eine Eingabe zum abgelegten Schluessel passt. Fuer den
    // erzwungenen Nachweis direkt nach dem Anzeigen der Sicherung: erst wenn
    // der Code einmal zurueckgelesen wurde, wird verschluesselt. Sonst faellt
    // ein unscharfes Foto des QR-Codes erst im Ernstfall auf.
    static func backupCodeMatches(_ code: String) -> Bool {
        guard let expected = backupCode() else { return false }
        return code.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }
}
