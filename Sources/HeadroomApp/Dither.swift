import CoreGraphics
import Foundation

/// The ordered dither: an 8 by 8 Bayer screen, one cell per point. A cell is lit when its tone passes the
/// cell's threshold, so a tone between 0 and 1 prints as that share of lit cells.
enum Bayer {
    static let matrix: [UInt8] = [
        0, 32, 8, 40, 2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]

    static func threshold(_ x: Int, _ y: Int) -> Double {
        (Double(matrix[(y & 7) * 8 + (x & 7)]) + 0.5) / 64
    }

    /// A mask image, one pixel per cell, opaque where a cell is lit. `tone` returns 0 to 1 for each cell,
    /// with y measured from the top.
    static func mask(width: Int, height: Int, tone: (Int, Int) -> Double) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where tone(x, y) > threshold(x, y) {
                let i = (y * width + x) * 4
                bytes[i] = 255; bytes[i + 1] = 255; bytes[i + 2] = 255; bytes[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
