import UIKit

enum ImageTools {
    /// Downscale to ≤1600px on the long side and JPEG-encode. The API resizes anyway
    /// (≈1300×1300 budget), so sending more only costs bandwidth.
    static func prepareForUpload(_ image: UIImage, maxSide: CGFloat = 1600, quality: CGFloat = 0.82) -> Data? {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    static func thumbnail(_ data: Data, side: CGFloat = 360) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingThumbnail(of: CGSize(width: side, height: side * image.size.height / max(image.size.width, 1)))
    }
}
