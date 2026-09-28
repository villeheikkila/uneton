import CoreImage.CIFilterBuiltins
import SwiftUI

struct QRCodeImage: View {
    let value: String
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let image = image {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    private var image: UIImage? {
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = context.createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
