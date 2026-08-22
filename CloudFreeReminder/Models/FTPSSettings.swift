import Foundation

// Where reminders are stored. Both locations speak FTPS, so they share the
// same transport – only the credentials and the remote path differ.
nonisolated enum StorageLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case fritzBox
    case raspberryPi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fritzBox:    return "Fritz!Box"
        case .raspberryPi: return "Raspberry Pi"
        }
    }

    var symbol: String {
        switch self {
        case .fritzBox:    return "wifi.router"
        case .raspberryPi: return "server.rack"
        }
    }

    var hostPlaceholder: String {
        switch self {
        case .fritzBox:    return "DynDNS-Adresse deiner Fritz!Box"
        case .raspberryPi: return "Hostname oder IP des Raspberry Pi"
        }
    }

    var hostHint: String {
        switch self {
        case .fritzBox:
            return "Für den Zugriff von unterwegs die DynDNS- bzw. MyFRITZ!-Adresse deiner Fritz!Box eintragen (z. B. meinbox.myfritz.net). Im Heimnetz genügt fritz.box."
        case .raspberryPi:
            return "Im Heimnetz genügt der Hostname des Pi. Der Pi nutzt ein selbstsigniertes Zertifikat – „Selbstsignierten Zertifikaten vertrauen“ muss daher aktiv bleiben."
        }
    }

    fileprivate var defaultsKey: String { "ftps_reminder_settings_\(rawValue)_v2" }
    fileprivate var keychainAccount: String { "ftps_reminder_password_\(rawValue)_v2" }

    fileprivate var defaults: FTPSSettings {
        switch self {
        case .fritzBox:
            return FTPSSettings()
        case .raspberryPi:
            // vsftpd on the Pi listens on the standard port with explicit TLS.
            var settings = FTPSSettings()
            settings.remotePath = "/Reminder/"
            return settings
        }
    }
}

// Identical FTPS access to FritzNotes – the user enters the same Frtiz!Box
// credentials here. Reminders are stored in their own remote directory
// (default "/reminder/") so they never mix with FritzNotes' note files.
//
// Each storage location keeps its own settings, so switching back and forth
// does not require retyping credentials.
nonisolated struct FTPSSettings: Codable, Sendable {
    var host: String = ""
    var port: Int = 21
    var username: String = ""
    var password: String = ""
    var remotePath: String = "/reminder/"
    var useImplicitTLS: Bool = false
    // Wird nicht mehr ausgewertet: der Datenkanal laeuft immer ueber PASV, ein
    // aktiver Modus ist gar nicht implementiert. Das Feld bleibt nur erhalten,
    // damit bereits gespeicherte Profile weiterhin dekodiert werden koennen.
    var passiveMode: Bool = true
    var trustSelfSignedCertificates: Bool = true

    // Keys used before storage locations existed. Read once, then migrated
    // into the Fritz!Box profile so nobody has to re-enter their settings.
    private static let legacyDefaultsKey = "ftps_reminder_settings_v1"
    private static let legacyKeychainAccount = "ftps_reminder_password_v1"

    private static let activeLocationKey = "ftps_reminder_active_location_v1"

    static var activeLocation: StorageLocation {
        get {
            let raw = UserDefaults.standard.string(forKey: activeLocationKey) ?? ""
            return StorageLocation(rawValue: raw) ?? .fritzBox
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: activeLocationKey) }
    }

    static func load(_ location: StorageLocation = FTPSSettings.activeLocation) -> FTPSSettings {
        if let data = UserDefaults.standard.data(forKey: location.defaultsKey),
           var settings = try? JSONDecoder().decode(FTPSSettings.self, from: data) {
            settings.password = KeychainStore.string(for: location.keychainAccount) ?? ""
            return settings
        }
        if location == .fritzBox, var migrated = legacySettings() {
            migrated.save(for: .fritzBox)
            return migrated
        }
        return location.defaults
    }

    func save(for location: StorageLocation = FTPSSettings.activeLocation) {
        KeychainStore.setString(password, for: location.keychainAccount)
        // Persist everything except the password as plaintext JSON.
        var sanitized = self
        sanitized.password = ""
        if let data = try? JSONEncoder().encode(sanitized) {
            UserDefaults.standard.set(data, forKey: location.defaultsKey)
        }
    }

    var isConfigured: Bool { !host.isEmpty && !username.isEmpty }

    /// Settings written by a version that only knew a single server.
    private static func legacySettings() -> FTPSSettings? {
        guard let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
              var settings = try? JSONDecoder().decode(FTPSSettings.self, from: data) else {
            return nil
        }
        if let stored = KeychainStore.string(for: legacyKeychainAccount) {
            settings.password = stored
        }
        return settings
    }
}
