import UIKit
import CoreImage

enum QRCodeService {
    static func extractString(from image: UIImage) -> String? {
        let context = CIContext()
        guard let ciImage = CIImage(image: image) else { return nil }
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: context,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: ciImage) ?? []
        for feature in features {
            if let qrFeature = feature as? CIQRCodeFeature,
               let message = qrFeature.messageString,
               !message.isEmpty {
                return message
            }
        }
        return nil
    }
}
