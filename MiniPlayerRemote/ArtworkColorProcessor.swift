import UIKit

final class ArtworkColorProcessor {
    static let shared = ArtworkColorProcessor()

    private struct Processed {
        let color: UIColor
        let isDark: Bool
    }

    private let queue = DispatchQueue(label: "app.artwork.processor", qos: .userInitiated)
    private var cache: [String: Processed] = [:]

    func process(image: UIImage?, key: String, completion: @escaping (UIColor?, Bool) -> Void) {
        guard let image else {
            DispatchQueue.main.async {
                completion(nil, false)
            }
            return
        }

        if let cached = cache[key] {
            DispatchQueue.main.async {
                completion(cached.color, cached.isDark)
            }
            return
        }

        queue.async { [weak self] in
            autoreleasepool {
                guard let color = averageColor(from: image) else {
                    DispatchQueue.main.async {
                        completion(nil, false)
                    }
                    return
                }
                let isDark = color.isDark()
                let processed = Processed(color: color, isDark: isDark)
                self?.cache[key] = processed
                DispatchQueue.main.async {
                    completion(color, isDark)
                }
            }
        }
    }
}

private func averageColor(from image: UIImage) -> UIColor? {
    guard let cgImage = image.cgImage else { return nil }
    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return nil }

    let bytesPerPixel = 4
    let bytesPerRow = bytesPerPixel * width
    var data = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: &data,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var totalR: CGFloat = 0
    var totalG: CGFloat = 0
    var totalB: CGFloat = 0
    var totalWeight: CGFloat = 0

    let step = 4
    for y in stride(from: 0, to: height, by: step) {
        for x in stride(from: 0, to: width, by: step) {
            let offset = (y * bytesPerRow) + (x * bytesPerPixel)
            let r = CGFloat(data[offset]) / 255.0
            let g = CGFloat(data[offset + 1]) / 255.0
            let b = CGFloat(data[offset + 2]) / 255.0
            let color = UIColor(red: r, green: g, blue: b, alpha: 1.0)

            var h: CGFloat = 0
            var s: CGFloat = 0
            var br: CGFloat = 0
            var a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &br, alpha: &a)

            let weight = (s * 0.7) + (br * 0.3)
            totalR += r * weight
            totalG += g * weight
            totalB += b * weight
            totalWeight += weight
        }
    }

    guard totalWeight > 0 else { return nil }
    let r = totalR / totalWeight
    let g = totalG / totalWeight
    let b = totalB / totalWeight

    var final = UIColor(red: r, green: g, blue: b, alpha: 1.0)
    var h: CGFloat = 0
    var s: CGFloat = 0
    var br: CGFloat = 0
    var a: CGFloat = 0
    final.getHue(&h, saturation: &s, brightness: &br, alpha: &a)

    s *= 0.75
    br = min(br * 1.15, 1.0)
    final = UIColor(hue: h, saturation: s, brightness: br, alpha: 1.0)

    if br < 0.35 {
        final = final.blended(withFraction: 0.45, of: .white)
    } else {
        final = final.blended(withFraction: 0.18, of: .white)
    }

    return final.withAlphaComponent(0.94)
}

private extension UIColor {
    func isDark(threshold: CGFloat = 0.5) -> Bool {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance < threshold
    }

    func blended(withFraction fraction: CGFloat, of color: UIColor) -> UIColor {
        let f = max(0, min(1, fraction))
        var r1: CGFloat = 0
        var g1: CGFloat = 0
        var b1: CGFloat = 0
        var a1: CGFloat = 0
        var r2: CGFloat = 0
        var g2: CGFloat = 0
        var b2: CGFloat = 0
        var a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        color.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red: r1 + (r2 - r1) * f,
            green: g1 + (g2 - g1) * f,
            blue: b1 + (b2 - b1) * f,
            alpha: a1 + (a2 - a1) * f
        )
    }
}
