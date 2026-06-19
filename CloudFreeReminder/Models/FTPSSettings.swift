import Foundation

// Identical FTPS access to FritzNotes – the user enters the same Frtiz!Box
// credentials here. Reminders are stored in their own remote directory
// (default "/reminder/") so they never mix with FritzNotes' note files.
nonisolated struct FTPSSettings: Codable, Sendable {
    var host: String = ""
    var port: Int = 21
    var username: String = ""
    var password: String = ""
    var remotePath: String = "/reminder/"
    var useImplicitTLS: Bool = false
    var passiveMode: Bool = true
    var trustSelfSignedCertificates: Bool = true

    private static let userDefaultsKey = "ftps_reminder_settings_v1"

    static func load() -> FTPSSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let settings = try? JSONDecoder().decode(FTPSSettings.self, from: data) else {
            return FTPSSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: FTPSSettings.userDefaultsKey)
        }
    }

    var isConfigured: Bool { !host.isEmpty && !username.isEmpty }
}
