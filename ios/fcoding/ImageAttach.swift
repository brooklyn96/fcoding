import SwiftUI
import UIKit

/// Chat image attach (CONTRACT A12): every picked or shot image becomes a JPEG for
/// POST /api/projects/<name>/upload.
enum ImageAttach {
    /// The server's cap (10 MiB).
    static let maxBytes = 10_485_760
    static let maxSide: CGFloat = 2048

    /// Pixel size with the longest side at most `maxSide`, aspect kept, never upscaled.
    static func targetSize(_ size: CGSize, maxSide: CGFloat = ImageAttach.maxSide) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return CGSize(width: size.width.rounded(), height: size.height.rounded()) }
        let k = maxSide / longest
        return CGSize(width: max(1, (size.width * k).rounded()), height: max(1, (size.height * k).rounded()))
    }

    /// JPEG at quality 0.8, then 0.6 when still over the cap. Redrawn at scale 1 on white, so any
    /// format (HEIC, PNG with alpha) and any EXIF orientation comes out as an upright JPEG.
    /// Throws APIError code "bad_type" (unreadable) or "too_big".
    static func jpeg(_ image: UIImage) throws -> Data {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixels.width >= 1, pixels.height >= 1 else { throw APIError(status: 0, code: "bad_type") }
        let size = targetSize(pixels)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.8, 0.6] as [CGFloat] {
            guard let data = drawn.jpegData(compressionQuality: quality) else { throw APIError(status: 0, code: "bad_type") }
            if data.count <= maxBytes { return data }
        }
        throw APIError(status: 0, code: "too_big")
    }

    /// Short Vietnamese line for an upload or conversion failure (401 is handled by the caller).
    static func message(_ error: Error) -> String {
        if let e = error as? APIError {
            switch e.code {
            case "too_big": return "Ảnh quá lớn"
            case "bad_type", "empty": return "Ảnh không đọc được"
            case "no_session", "no_project": return "Phiên đã đóng"
            default: break
            }
            if e.status == 413 { return "Ảnh quá lớn" }
            if e.status == 415 { return "Ảnh không đọc được" }
        }
        return "Không gửi được ảnh, thử lại"
    }
}

/// The system camera (UIImagePickerController), shown full screen. `onDone(nil)` = cancelled.
struct CameraPicker: UIViewControllerRepresentable {
    let onDone: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (UIImage?) -> Void
        init(onDone: @escaping (UIImage?) -> Void) { self.onDone = onDone }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil) }
    }
}
