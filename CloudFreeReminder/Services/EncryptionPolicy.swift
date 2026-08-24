import Foundation

// Entscheidet, ob VERSCHLUESSELT geschrieben wird. Ueber das Entschluesseln
// entscheidet diese Stelle ausdruecklich NICHT.
//
// Das ist die wichtigste Regel des ganzen Features: `ContentCrypto.open` wird
// niemals gefragt, ob gekauft wurde. Wer einmal verschluesselt abgelegt hat,
// kommt an seine Daten – auch nach Erstattung, misslungener Wiederherstellung,
// abgelaufenem Zwischenspeicher oder ohne Netz. Alles andere hiesse, die Daten
// des Kunden in Geiselhaft zu nehmen.
//
// Hier haengt spaeter StoreKit 2 dran (nicht-verbrauchbares Produkt, 3,99 EUR,
// je App). Bis dahin bleibt `isPurchased` ein schlichter Merker.
nonisolated enum EncryptionPolicy {

    private static let purchasedKey = "contentEncryption.purchased"
    private static let backupConfirmedKey = "contentEncryption.backupConfirmed"

    // Platzhalter fuer `Transaction.currentEntitlements`. Beim Ersetzen daran
    // denken: bei Netz- oder StoreKit-Fehlern grosszuegig entscheiden statt
    // sperren, und den letzten bekannten Stand lokal behalten.
    static var isPurchased: Bool {
        get { UserDefaults.standard.bool(forKey: purchasedKey) }
        set { UserDefaults.standard.set(newValue, forKey: purchasedKey) }
    }

    // Wird erst wahr, wenn der Sicherungscode angezeigt UND einmal
    // zurueckgelesen wurde. Ohne diesen Nachweis wird nicht verschluesselt:
    // der Keychain-Eintrag ueberlebt keinen Geraetewechsel, ein unscharfes Foto
    // des QR-Codes faellt sonst erst im Ernstfall auf.
    static var isBackupConfirmed: Bool {
        get { UserDefaults.standard.bool(forKey: backupConfirmedKey) }
        set { UserDefaults.standard.set(newValue, forKey: backupConfirmedKey) }
    }

    // Alle drei Bedingungen. Faellt eine weg, wird weiter im Klartext
    // geschrieben – bereits verschluesselte Dateien bleiben trotzdem lesbar.
    static var mayEncrypt: Bool {
        isPurchased && isBackupConfirmed && CryptoKeyStore.hasMasterKey
    }
}
