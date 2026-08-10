import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Renders the pairing URL into a QR image with Core Image (`ios-app.md` §4).
///
/// The input string contains the root secret, so it is passed in, used, and
/// dropped — never cached, never written to a file, never logged.
enum QRCodeRenderer {

    /// Shared context: creating a `CIContext` per render is expensive and the QR
    /// is re-rendered every two minutes for as long as the screen is up.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// - Parameters:
    ///   - string: the `kidscam://pair?…` URL.
    ///   - pointSize: the on-screen size; the bitmap is generated at
    ///     `pointSize * displayScale` so it stays crisp without interpolation.
    ///   - displayScale: the screen's scale factor.
    /// - Returns: `nil` if Core Image cannot produce an image, in which case the
    ///   caller must show an error rather than an empty box.
    static func makeImage(
        from string: String,
        pointSize: CGFloat,
        displayScale: CGFloat
    ) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // "M" (~15 % recovery) keeps the module count low enough for the payload
        // to stay comfortably scannable at arm's length on a phone screen.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }

        let targetPixels = max(pointSize * displayScale, 1)
        let scale = targetPixels / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: displayScale, orientation: .up)
    }
}
