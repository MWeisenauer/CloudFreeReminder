import SwiftUI

struct SettingsView: View {
    @State private var settings = FTPSSettings.load()
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @State private var showSaveConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("FTPS-Server") {
                    TextField("Host (z.B. 192.168.1.1)", text: $settings.host)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("Port", value: $settings.port, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                    }
                    Toggle("Implizites TLS (ftps://, Port 990)", isOn: $settings.useImplicitTLS)
                        .onChange(of: settings.useImplicitTLS) { _, enabled in
                            settings.port = enabled ? 990 : 21
                        }
                }
                Section("Zugangsdaten") {
                    TextField("Benutzername", text: $settings.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Passwort", text: $settings.password)
                        .textContentType(.password)
                }
                Section {
                    TextField("Pfad (z.B. /reminder/)", text: $settings.remotePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Verzeichnis auf dem Server")
                } footer: {
                    Text("Eigener Ordner für Erinnerungen – getrennt von den FritzNotes-Notizen.")
                }
                Section("Verbindungsoptionen") {
                    Toggle("Passiver Modus (PASV)", isOn: $settings.passiveMode)
                    Toggle("Selbstsignierten Zertifikaten vertrauen", isOn: $settings.trustSelfSignedCertificates)
                }
                Section {
                    Button("Einstellungen speichern") {
                        settings.save()
                        showSaveConfirmation = true
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)

                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Spacer()
                            if isTesting { ProgressView().padding(.trailing, 6) }
                            Text(isTesting ? "Verbinde…" : "Verbindung testen")
                            Spacer()
                        }
                    }
                    .disabled(isTesting || !settings.isConfigured)
                }
                if let result = testResult {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(testSuccess ? .green : .red)
                            Text(result)
                                .font(.callout)
                        }
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .alert("Gespeichert", isPresented: $showSaveConfirmation) {
                Button("OK") {}
            } message: {
                Text("Die FTPS-Einstellungen wurden gespeichert.")
            }
        }
    }

    private func testConnection() async {
        settings.save()
        isTesting = true
        testResult = nil
        do {
            testResult = try await ReminderService(settings: settings).testConnection()
            testSuccess = true
        } catch {
            testResult = error.localizedDescription
            testSuccess = false
        }
        isTesting = false
    }
}
