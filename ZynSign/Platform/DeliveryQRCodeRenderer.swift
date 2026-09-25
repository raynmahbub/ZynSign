import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

/// Failures raised while rendering a delivery QR code.
enum DeliveryQRCodeError: Error, Equatable {
    /// The platform's QR generator filter was unavailable.
    case generatorUnavailable

    /// The generator produced no output for the given payload.
    case renderingFailed
}

/// Renders a QR code image for the delivery hand-off.
///
/// Uses the documented Core Image `CIQRCodeGenerator` filter entirely
/// on-device. The renderer knows nothing about what the code encodes; the
/// caller supplies the string (typically the `itms-services` install link)
/// and receives a grayscale CGImage scaled for screen display.
struct DeliveryQRCodeRenderer {

    /// The pixel scale applied to the generated matrix. 10× turns the
    /// generator's ~25–29 px output into a crisp 250–290 px image.
    let scale: CGFloat

    init(scale: CGFloat = 10) {
        self.scale = scale
    }

    /// Renders `payload` as a QR code with high error correction, so a
    /// link survives a photo-of-a-screen hand-off.
    func cgImage(for payload: String) throws -> CGImage {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw DeliveryQRCodeError.generatorUnavailable
        }
        filter.setValue(Data(payload.utf8), forKey: "message")
        filter.setValue("H", forKey: "correctionLevel")
        guard let outputImage = filter.outputImage else {
            throw DeliveryQRCodeError.renderingFailed
        }
        let transformed = outputImage.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            throw DeliveryQRCodeError.renderingFailed
        }
        return cgImage
    }
}
