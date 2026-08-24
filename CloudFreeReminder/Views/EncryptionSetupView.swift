import StoreKit
import SwiftUI

// Der Weg zur Inhaltsverschluesselung, in vier Schritten:
//
//   Anfang  →  Sicherung anzeigen  →  Sicherung nachweisen  →  aktiv
//
// Der dritte Schritt ist der, den man am liebsten weglassen wuerde, und der
// wichtigste. Der Schluessel liegt im Keychain unter
// WhenUnlockedThisDeviceOnly – er wandert in kein Backup und ueberlebt keinen
// Geraetewechsel. Wer die Sicherung nur wegtippt, merkt das erst, wenn das
// alte Geraet weg ist. Deshalb wird der Code einmal zurueckverlangt, bevor
// ueberhaupt etwas verschluesselt wird.
struct EncryptionSetupView: View {

    private enum Step {
        case anfang        // kein Schluessel vorhanden
        case sicherung     // Schluessel da, Code anzeigen
        case nachweis      // Code zurueckverlangen
        case aktiv         // fertig eingerichtet
    }

    @StateObject private var store = PurchaseManager()
    @State private var step: Step = .anfang
    @State private var backupCode = ""
    @State private var eingabe = ""
    @State private var fehler: String?
    @State private var zeigeCodeErneut = false
    @State private var wiederherstellen = false
    @State private var wiederherstellenCode = ""

    var body: some View {
        Form {
            switch step {
            case .anfang:   anfangsSchritt
            case .sicherung: sicherungsSchritt
            case .nachweis:  nachweisSchritt
            case .aktiv:     aktivSchritt
            }
        }
        .navigationTitle("Inhaltsverschlüsselung")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: zustandBestimmen)
        .task { await store.laden() }
        .onChange(of: store.isPurchased) { _, _ in zustandBestimmen() }
    }

    // MARK: - Schritt 1: Anfang

    @ViewBuilder
    private var anfangsSchritt: some View {
        Section {
            Text("Die Erinnerungen werden auf diesem Gerät verschlüsselt, bevor sie hochgeladen werden. Auf dem Server liegen sie dann unlesbar – auf der Fritz!Box genauso wie auf dem Raspberry Pi.")
                .font(.callout)
        } header: {
            Text("Was das bedeutet")
        } footer: {
            Text("FTPS schützt heute nur die Leitung. Wer die Speicherkarte in die Hand bekommt, liest die Erinnerungen im Klartext. Mit der Inhaltsverschlüsselung ändert sich das.")
        }

        Section {
            // Die Farbe muss die Aussage tragen. Mit der Standardtoenung sieht
            // das Kreuz aus wie ein weiteres Haekchen – die Zeile behauptet
            // dann das Gegenteil dessen, was sie meint.
            punkt("Gestohlene Speicherkarte", geschuetzt: true)
            punkt("Fremder Zugriff auf die Ablage", geschuetzt: true)
            punkt("Dateinamen, Anzahl und Größe", geschuetzt: false)
        } header: {
            Text("Geschützt – und was nicht")
        } footer: {
            Text("Die Dateinamen sind reine Kennnummern und verraten nichts über den Inhalt. Sichtbar bleibt aber, wie viele Erinnerungen es gibt und wann sie zuletzt geändert wurden.")
        }

        if !store.isPurchased {
            Section {
                Button {
                    Task { await store.kaufen() }
                } label: {
                    HStack {
                        Spacer()
                        if store.isWorking { ProgressView().padding(.trailing, 6) }
                        Text(kaufBeschriftung)
                        Spacer()
                    }
                }
                .fontWeight(.semibold)
                .disabled(store.product == nil || store.isWorking)

                Button("Käufe wiederherstellen") {
                    Task { await store.wiederherstellen() }
                }
                .frame(maxWidth: .infinity)
                .disabled(store.isWorking)
            } header: {
                Text("Freischalten")
            } footer: {
                Text("Einmalig, kein Abonnement. Der Kauf gilt für diese App. „Käufe wiederherstellen“ holt ihn auf ein neues Gerät oder nach einer Neuinstallation zurück.")
            }

            if let meldung = store.fehler {
                Section {
                    Label(meldung, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }

        Section {
            Button("Verschlüsselung einrichten") {
                CryptoKeyStore.createMasterKeyIfNeeded()
                backupCode = CryptoKeyStore.backupCode() ?? ""
                step = .sicherung
            }
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
            .disabled(!store.isPurchased)

            // Bewusst NICHT hinter dem Kauf. Wer verschluesselte Dateien
            // liegen hat und auf einem neuen Geraet steht, muss an seinen
            // Schluessel kommen - sonst waeren seine Daten verloren, weil eine
            // Zahlung nicht durchging. Entschluesseln kostet nichts.
            Button("Ich habe schon einen Schlüssel") {
                wiederherstellen = true
            }
            .frame(maxWidth: .infinity)
        } footer: {
            Text(store.isPurchased
                 ? "Der zweite Weg ist der richtige, wenn du die Verschlüsselung auf einem anderen Gerät schon eingerichtet hast. Beide Geräte brauchen denselben Schlüssel, sonst liest das eine nicht, was das andere geschrieben hat."
                 : "Hast du auf einem anderen Gerät schon verschlüsselt, übernimm dort den Schlüssel – das geht auch ohne Kauf. Lesen kostet nichts, nur das Verschlüsseln neuer Erinnerungen ist die Freischaltung.")
        }
        .sheet(isPresented: $wiederherstellen) { wiederherstellenBlatt }
    }

    // Der Preis kommt immer aus dem Store, nie aus dem Code - er haengt an
    // Waehrung und Region des Kunden.
    private var kaufBeschriftung: String {
        if let preis = store.product?.displayPrice {
            return "Für \(preis) freischalten"
        }
        return "Freischalten"
    }

    private func punkt(_ text: String, geschuetzt: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: geschuetzt ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(geschuetzt ? .green : .orange)
            Text(text)
        }
    }

    // MARK: - Schritt 2: Sicherung anzeigen

    @ViewBuilder
    private var sicherungsSchritt: some View {
        // Ein leerer Code darf nie stumm durchgehen. Genau das ist passiert,
        // als der Keychain-Zugriff scheiterte: die Ansicht zeigte einen
        // gueltig aussehenden QR-Code, der nichts enthielt.
        if backupCode.isEmpty {
            Section {
                Label("Der Schlüssel konnte nicht gelesen werden.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("Erneut versuchen") { zustandBestimmen() }
            } footer: {
                Text("Ohne Schlüssel wird nicht verschlüsselt. Bereits abgelegte Erinnerungen sind davon nicht betroffen.")
            }
        } else {
        Section {
            if let bild = QRCode.image(for: backupCode) {
                HStack {
                    Spacer()
                    Image(uiImage: bild)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(12)
                        // Fester weisser Grund: ein QR-Code auf dunklem
                        // Hintergrund wird von keiner Kamera gelesen.
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Text(CryptoKeyStore.grouped(backupCode))
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)

            Button {
                UIPasteboard.general.string = backupCode
            } label: {
                Label("Code kopieren", systemImage: "doc.on.doc")
            }

            ShareLink(item: backupCode) {
                Label("Sichern oder drucken", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Dein Sicherungscode")
        } footer: {
            Text("Dies ist der Schlüssel selbst. Druck ihn aus oder leg ihn in deinen Passwortspeicher. Zum Scannen genügt später die Kamera-App des neuen Geräts.")
        }

        Section {
            Button("Weiter zur Prüfung") {
                eingabe = ""
                fehler = nil
                step = .nachweis
            }
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
        } header: {
            Text("Ohne Code sind die Daten verloren")
        } footer: {
            Text("Der Schlüssel liegt nur auf diesem Gerät und wandert in kein Backup – auch nicht in ein verschlüsseltes. Geht das Gerät verloren und fehlt der Code, kann niemand die Erinnerungen wiederherstellen. Auch ich nicht.")
        }

        geschwisterHinweis
        }
    }

    // Der Hinweis gehoert dorthin, wo der Code zu sehen ist - beim Sichern und
    // im fertigen Zustand. Wer spaeter eine zweite CloudFree-App kauft, soll
    // nicht raten muessen, ob er einen neuen Schluessel braucht.
    @ViewBuilder
    private var geschwisterHinweis: some View {
        Section {
            Label("Ein Code für alle CloudFree-Apps", systemImage: "square.stack.3d.up")
        } header: {
            Text("Die anderen CloudFree-Apps")
        } footer: {
            Text("Derselbe Sicherungscode gilt für alle CloudFree-Apps – Notizen, Passwörter, Adressen und die übrigen. Wähle dort „Ich habe schon einen Schlüssel“ und gib ihn ein; einen zweiten Code brauchst du nicht.\n\nJede App leitet daraus ihren eigenen Schlüssel ab: der Schlüssel der Erinnerungen öffnet nicht den Passworttresor. Freigeschaltet wird jede App einzeln.")
        }
    }

    // MARK: - Schritt 3: Nachweis

    @ViewBuilder
    private var nachweisSchritt: some View {
        Section {
            TextField("Sicherungscode", text: $eingabe, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(2...4)

            Button {
                if let clipboard = UIPasteboard.general.string {
                    eingabe = clipboard
                }
            } label: {
                Label("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard")
            }
        } header: {
            Text("Code zurücklesen")
        } footer: {
            Text("Gib den Code ein, so wie du ihn gesichert hast. Nicht abschreiben, was hier auf dem Bildschirm steht – der Sinn der Prüfung ist der Nachweis, dass du wirklich an deine Sicherung herankommst.")
        }

        if let fehler {
            Section {
                Label(fehler, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }

        Section {
            Button("Prüfen und aktivieren") {
                pruefen()
            }
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
            .disabled(eingabe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Zurück zum Code") {
                fehler = nil
                step = .sicherung
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Schritt 4: Aktiv

    @ViewBuilder
    private var aktivSchritt: some View {
        Section {
            if EncryptionPolicy.mayEncrypt {
                Label("Neue Erinnerungen werden verschlüsselt", systemImage: "lock.fill")
                    .foregroundStyle(.green)
            } else if !store.isPurchased {
                Label("Schlüssel eingerichtet, Feature nicht freigeschaltet",
                      systemImage: "lock.open.fill")
                    .foregroundStyle(.orange)
                Button(kaufBeschriftung) {
                    Task { await store.kaufen() }
                }
                .disabled(store.product == nil || store.isWorking)
                Button("Käufe wiederherstellen") {
                    Task { await store.wiederherstellen() }
                }
                .disabled(store.isWorking)
            }
        } header: {
            Text("Zustand")
        } footer: {
            Text(EncryptionPolicy.mayEncrypt
                 ? "Bereits abgelegte Klartextdateien wandern nach und nach mit: sobald du eine Erinnerung änderst, wird sie verschlüsselt neu geschrieben."
                 : "Der Schlüssel liegt bereit. Verschlüsselt wird erst nach dem Freischalten.")
        }

        Section {
            Button {
                backupCode = CryptoKeyStore.backupCode() ?? ""
                zeigeCodeErneut = true
            } label: {
                Label("Sicherungscode erneut anzeigen", systemImage: "qrcode")
            }
        } footer: {
            Text("Für ein zweites Gerät: dort „Ich habe schon einen Schlüssel“ wählen und diesen Code eingeben.")
        }
        .sheet(isPresented: $zeigeCodeErneut) { codeBlatt }

        geschwisterHinweis
    }

    // MARK: - Blaetter

    private var codeBlatt: some View {
        NavigationStack {
            Form { sicherungsSchrittNurAnzeige }
                .navigationTitle("Sicherungscode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { zeigeCodeErneut = false }
                    }
                }
        }
    }

    @ViewBuilder
    private var sicherungsSchrittNurAnzeige: some View {
        Section {
            if let bild = QRCode.image(for: backupCode) {
                HStack {
                    Spacer()
                    Image(uiImage: bild)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Text(CryptoKeyStore.grouped(backupCode))
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = backupCode
            } label: {
                Label("Code kopieren", systemImage: "doc.on.doc")
            }
            ShareLink(item: backupCode) {
                Label("Sichern oder drucken", systemImage: "square.and.arrow.up")
            }
        } footer: {
            Text("Behandle diesen Code wie ein Passwort. Wer ihn hat, kann die abgelegten Erinnerungen lesen.")
        }
    }

    private var wiederherstellenBlatt: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Sicherungscode", text: $wiederherstellenCode, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                    Button {
                        if let clipboard = UIPasteboard.general.string {
                            wiederherstellenCode = clipboard
                        }
                    } label: {
                        Label("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("Schlüssel vom anderen Gerät")
                } footer: {
                    Text("Den QR-Code mit der Kamera-App scannen, den Text kopieren und hier einfügen.")
                }

                if let fehler {
                    Section {
                        Label(fehler, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    Button("Schlüssel übernehmen") {
                        uebernehmen()
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .disabled(wiederherstellenCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Schlüssel übernehmen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        fehler = nil
                        wiederherstellen = false
                    }
                }
            }
        }
    }

    // MARK: - Ablauf

    private func zustandBestimmen() {
        if CryptoKeyStore.hasMasterKey {
            step = EncryptionPolicy.isBackupConfirmed ? .aktiv : .sicherung
            if step == .sicherung {
                backupCode = CryptoKeyStore.backupCode() ?? ""
            }
        } else {
            step = .anfang
        }
    }

    private func pruefen() {
        guard CryptoKeyStore.backupCodeMatches(eingabe) else {
            fehler = "Der Code passt nicht zum Schlüssel auf diesem Gerät."
            return
        }
        fehler = nil
        EncryptionPolicy.isBackupConfirmed = true
        step = .aktiv
    }

    private func uebernehmen() {
        do {
            try CryptoKeyStore.restore(fromBackupCode: wiederherstellenCode)
            // Wer den Code eingetippt hat, hat ihn offensichtlich – ein
            // zweiter Nachweis waere hier reine Schikane.
            EncryptionPolicy.isBackupConfirmed = true
            fehler = nil
            wiederherstellen = false
            zustandBestimmen()
        } catch {
            fehler = (error as? LocalizedError)?.errorDescription
                  ?? "Der Schlüssel konnte nicht übernommen werden."
        }
    }
}
