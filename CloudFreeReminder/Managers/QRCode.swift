import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// Erzeugt den QR-Code fuer den Sicherungscode. CoreImage bringt das mit, es
// braucht keine Bibliothek von aussen.
//
// Der Code enthaelt 44 Zeichen Base64 – das passt selbst bei der hoechsten
// Fehlerkorrekturstufe muehelos hinein. "H" ist hier richtig gewaehlt: der
// Ausdruck soll auch dann noch lesbar sein, wenn er ein paar Jahre in einem
// Ordner gelegen hat.
//
// Gescannt wird er von der Kamera-App des neuen Geraets, die den Text zum
// Kopieren anbietet. Eine eigene Kamerafunktion braucht die App dafuer nicht.
nonisolated enum QRCode {

    static func image(for text: String, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
