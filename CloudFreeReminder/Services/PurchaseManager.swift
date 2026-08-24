import Combine
import Foundation
import StoreKit

// Der Kauf der Inhaltsverschluesselung: nicht-verbrauchbar, einmalig, je App.
//
// Zwei Regeln bestimmen den Aufbau:
//
// 1. Entschluesseln haengt nie am Kauf. Diese Klasse entscheidet ausschliesslich
//    darueber, ob NEU verschluesselt werden darf. ContentCrypto.open fragt sie
//    nie. Wer einmal verschluesselt abgelegt hat, kommt an seine Daten - auch
//    nach Erstattung oder auf einem Geraet, das den Kauf gerade nicht kennt.
//
// 2. Im Zweifel nicht sperren. Der zuletzt bekannte Stand wird lokal behalten
//    und ueberlebt einen Start ohne Netz. Zurueckgenommen wird er nur, wenn
//    StoreKit die Berechtigungen tatsaechlich durchgesehen hat und sie fehlt.
//
// "Kaeufe wiederherstellen" ist bei nicht-verbrauchbaren Produkten von Apple
// vorgeschrieben - ohne diesen Knopf gibt es eine Ablehnung im Review. Er ist
// nicht nur Formsache: auf einem neuen Geraet ist er der Weg, ueber den die
// Berechtigung ueberhaupt erst ankommt.
final class PurchaseManager: ObservableObject {

    static let productID = "de.TimeTec.CloudFreeReminder.contentencryption"

    @Published private(set) var product: Product?
    @Published private(set) var isPurchased: Bool
    @Published private(set) var isWorking = false
    @Published var fehler: String?

    // Laeuft, solange die App laeuft: faengt Kaeufe auf, die anderswo
    // abgeschlossen wurden - Familienfreigabe, ein zweites Geraet, ein
    // nachtraeglich bestaetigter Kauf ("Ask to Buy").
    private var beobachter: Task<Void, Never>?

    init() {
        // Erst der gespeicherte Stand, dann fragen. So ist die App sofort
        // arbeitsfaehig und nicht erst nach einer Netzantwort.
        self.isPurchased = EncryptionPolicy.isPurchased
        beobachter = beobachteAenderungen()
    }

    deinit { beobachter?.cancel() }

    // MARK: - Laden

    func laden() async {
        await pruefeBerechtigung()
        do {
            let treffer = try await Product.products(for: [Self.productID])
            product = treffer.first
            if treffer.isEmpty {
                fehler = "Das Produkt ist im Store nicht hinterlegt."
            }
        } catch {
            // Kein Grund, etwas zu sperren - nur der Preis fehlt.
            fehler = "Der Preis konnte nicht geladen werden."
        }
    }

    // MARK: - Kaufen

    func kaufen() async {
        guard let product else { return }
        isWorking = true
        fehler = nil
        defer { isWorking = false }

        do {
            switch try await product.purchase() {
            case .success(let ergebnis):
                if let transaktion = pruefe(ergebnis) {
                    await transaktion.finish()
                    setze(true)
                } else {
                    fehler = "Der Kauf konnte nicht bestätigt werden."
                }
            case .userCancelled:
                break                       // kein Fehler, keine Meldung
            case .pending:
                // "Ask to Buy" oder eine Zahlung, die noch bestaetigt werden
                // muss. Der Beobachter oben faengt den Abschluss auf.
                fehler = "Der Kauf wartet noch auf Bestätigung."
            @unknown default:
                break
            }
        } catch {
            fehler = "Der Kauf ist fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    // MARK: - Wiederherstellen

    func wiederherstellen() async {
        isWorking = true
        fehler = nil
        defer { isWorking = false }

        do {
            try await AppStore.sync()
        } catch {
            fehler = "Die Wiederherstellung ist fehlgeschlagen."
        }
        await pruefeBerechtigung()
        if !isPurchased && fehler == nil {
            fehler = "Für dieses Konto wurde kein Kauf gefunden."
        }
    }

    // MARK: - Berechtigung

    // Liest die Berechtigungen, die auf dem Geraet vorliegen. Das geht auch
    // ohne Netz - deshalb darf das Ergebnis den gespeicherten Stand
    // ueberschreiben, in beide Richtungen. Widerrufene Kaeufe tragen ein
    // revocationDate und zaehlen nicht mehr.
    func pruefeBerechtigung() async {
        var berechtigt = false
        for await ergebnis in Transaction.currentEntitlements {
            guard let transaktion = pruefe(ergebnis) else { continue }
            if transaktion.productID == Self.productID, transaktion.revocationDate == nil {
                berechtigt = true
            }
        }
        setze(berechtigt)
    }

    private func beobachteAenderungen() -> Task<Void, Never> {
        Task { [weak self] in
            for await ergebnis in Transaction.updates {
                guard let self, let transaktion = self.pruefe(ergebnis) else { continue }
                await transaktion.finish()
                await self.pruefeBerechtigung()
            }
        }
    }

    // Eine Transaktion, deren Signatur nicht aufgeht, wird verworfen. Sie
    // ergibt keinen Fehler nach aussen - sie zaehlt einfach nicht.
    private func pruefe(_ ergebnis: VerificationResult<Transaction>) -> Transaction? {
        switch ergebnis {
        case .verified(let transaktion):   return transaktion
        case .unverified:                  return nil
        }
    }

    private func setze(_ wert: Bool) {
        isPurchased = wert
        EncryptionPolicy.isPurchased = wert
    }
}
