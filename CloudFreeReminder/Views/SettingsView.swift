import SwiftUI

struct SettingsView: View {
    private enum Field: Hashable {
        case host, port, username, password, remotePath
    }

    @State private var settings = FTPSSettings.load()
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @State private var showSaveConfirmation = false
    @State private var isPasswordVisible = false
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("DynDNS-Adresse deiner Fritz!Box", text: $settings.host)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .host)
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("Port", value: $settings.port, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                            .focused($focusedField, equals: .port)
                    }
                    Toggle("Implizites TLS (ftps://, Port 990)", isOn: $settings.useImplicitTLS)
                        .onChange(of: settings.useImplicitTLS) { _, enabled in
                            settings.port = enabled ? 990 : 21
                        }
                } header: {
                    Text("FTPS-Server")
                } footer: {
                    Text("Für den Zugriff von unterwegs die DynDNS- bzw. MyFRITZ!-Adresse deiner Fritz!Box eintragen (z. B. meinbox.myfritz.net). Im Heimnetz genügt fritz.box.")
                }
                Section("Zugangsdaten") {
                    TextField("Benutzername", text: $settings.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                    HStack {
                        Group {
                            if isPasswordVisible {
                                TextField("Passwort", text: $settings.password)
                            } else {
                                SecureField("Passwort", text: $settings.password)
                            }
                        }
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .password)

                        Button {
                            // Beim Umschalten wird das Feld neu aufgebaut – Fokus
                            // danach zurückholen, sonst klappt die Tastatur zu.
                            let wasFocused = focusedField == .password
                            isPasswordVisible.toggle()
                            if wasFocused {
                                DispatchQueue.main.async { focusedField = .password }
                            }
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPasswordVisible ? "Passwort verbergen" : "Passwort anzeigen")
                    }
                }
                Section {
                    TextField("Pfad (z.B. /reminder/)", text: $settings.remotePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .remotePath)
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
            // Ohne diese Leiste liesse sich der Zahlenblock des Port-Feldes gar
            // nicht schliessen – er hat keine Return-Taste. Die Tastatur wuerde
            // dann dauerhaft die Tab-Leiste verdecken.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fertig") { focusedField = nil }
                        .fontWeight(.semibold)
                }
            }
            .scrollDismissesKeyboard(.interactively)
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
