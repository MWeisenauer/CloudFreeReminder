import SwiftUI

struct SettingsView: View {
    private enum Field: Hashable {
        case host, port, username, password, remotePath
    }

    @EnvironmentObject private var store: ReminderStore
    @State private var location = FTPSSettings.activeLocation
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
                    Picker("Ablageort", selection: $location) {
                        ForEach(StorageLocation.allCases) { ort in
                            Label(ort.title, systemImage: ort.symbol).tag(ort)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: location) { alt, neu in
                        wechsleAblageort(von: alt, zu: neu)
                    }
                } header: {
                    Text("Ablageort")
                } footer: {
                    Text("Jeder Ablageort hat eigene Zugangsdaten. Beim Umschalten werden die Erinnerungen vom gewählten Server neu geladen.")
                }
                Section {
                    TextField(location.hostPlaceholder, text: $settings.host)
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
                            // Nur zwischen den beiden Standardports umschalten.
                            //
                            // Ein selbst vergebener Port (etwa eine Portfreigabe
                            // am Router) bleibt unangetastet. Ohne diese Bedingung
                            // ging er auf zwei Wegen verloren: beim Umlegen des
                            // Schalters – und vor allem beim Wechsel des
                            // Ablageorts, weil onChange nicht unterscheidet, ob
                            // der Nutzer den Schalter bewegt hat oder ob gerade
                            // ein anderes Profil geladen wurde.
                            guard settings.port == 21 || settings.port == 990 else { return }
                            settings.port = enabled ? 990 : 21
                        }
                } header: {
                    Text("FTPS-Server")
                } footer: {
                    Text(location.hostHint)
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
                Section {
                    NavigationLink {
                        EncryptionSetupView()
                    } label: {
                        HStack {
                            Label("Inhaltsverschlüsselung", systemImage: verschluesselungSymbol)
                            Spacer()
                            Text(verschluesselungZustand)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Verschlüsselung")
                } footer: {
                    Text("FTPS schützt die Leitung. Die Inhaltsverschlüsselung schützt zusätzlich die Dateien selbst – auf dem Server liegen sie dann unlesbar.")
                }
                Section {
                    Toggle("Selbstsignierten Zertifikaten vertrauen", isOn: $settings.trustSelfSignedCertificates)
                } header: {
                    Text("Verbindungsoptionen")
                } footer: {
                    Text("Der Datenkanal wird immer im passiven Modus (PASV) aufgebaut. Aktives FTP verlangt, dass der Server eine Verbindung zum iPhone aufbaut – das scheitert hinter jedem Router.")
                }
                Section {
                    Button("Einstellungen speichern") {
                        settings.save(for: location)
                        showSaveConfirmation = true
                        Task { await store.loadReminders() }
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

    // Kurzer Zustand fuer die Zeile in den Einstellungen. Bewusst drei Faelle
    // statt an/aus: „Schluessel da, aber nicht freigeschaltet" ist ein eigener
    // Zustand, den man sehen koennen muss.
    private var verschluesselungZustand: String {
        if EncryptionPolicy.mayEncrypt { return "Aktiv" }
        if CryptoKeyStore.hasMasterKey { return "Eingerichtet" }
        return "Aus"
    }

    private var verschluesselungSymbol: String {
        EncryptionPolicy.mayEncrypt ? "lock.fill" : "lock.open"
    }

    /// Speichert das bisherige Profil und laedt das neue in das Formular.
    /// Die Liste wird anschliessend vom neuen Server geholt.
    private func wechsleAblageort(von alt: StorageLocation, zu neu: StorageLocation) {
        guard alt != neu else { return }
        settings.save(for: alt)
        FTPSSettings.activeLocation = neu
        settings = FTPSSettings.load(neu)
        testResult = nil
        focusedField = nil
        Task { await store.loadReminders() }
    }

    private func testConnection() async {
        settings.save(for: location)
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
