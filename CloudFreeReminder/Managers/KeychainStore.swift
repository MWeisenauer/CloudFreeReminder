import Foundation
import Security

// Stores small secrets (the FTPS password) in the iOS Keychain instead of
// UserDefaults. Items are marked `WhenUnlockedThisDeviceOnly` so they are never
// written to iCloud/iTunes backups and only readable while the device is unlocked.
//
// Fuer den Schluessel der Inhaltsverschluesselung hat `ThisDeviceOnly` eine
// Folge, die man kennen muss: der Eintrag wandert in KEIN Backup und ueberlebt
// deshalb keinen Geraetewechsel. Beim FTPS-Passwort ist das folgenlos, das
// tippt man neu ein. Beim Schluessel waere es der Totalverlust – siehe
// `CryptoKeyStore.backupCode()`.
nonisolated enum KeychainStore {

    private static let service = "de.cloudfreereminder.ftps"

    // Gemeinsamer Dienst fuer den App-uebergreifenden Hauptschluessel.
    static let sharedService = "de.cloudfree.crypto"

    // Geteilte Keychain-Gruppe. Solange hier `nil` steht, bleibt der Schluessel
    // auf diese App beschraenkt – genau richtig, solange der Reminder die
    // einzige umgestellte App ist.
    //
    // Zum Scharfschalten spaeter: in Xcode die Capability „Keychain Sharing"
    // hinzufuegen (legt die .entitlements-Datei an und setzt
    // CODE_SIGN_ENTITLEMENTS) und hier "$(AppIdentifierPrefix)de.TimeTec.cloudfree"
    // eintragen. Ohne das Entitlement scheitert jeder Keychain-Zugriff mit
    // errSecMissingEntitlement – deshalb nicht auf Verdacht setzen.
    static let accessGroup: String? = nil

    // MARK: - Data

    static func setData(_ data: Data, for account: String, service: String = sharedService) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func data(for account: String, service: String = sharedService) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return data
    }

    // MARK: - String

    static func setString(_ value: String, for account: String) {
        guard let data = value.data(using: .utf8) else {
            removeItem(for: account)
            return
        }
        setData(data, for: account, service: service)
    }

    static func string(for account: String) -> String? {
        guard let data = data(for: account, service: service) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func removeItem(for account: String, service: String = KeychainStore.service) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        SecItemDelete(query as CFDictionary)
    }
}
