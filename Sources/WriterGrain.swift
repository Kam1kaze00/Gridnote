import AppKit

// Fixed paper-space tiles keep the density stable at a given point when zooming or replaying ink.
enum WriterGrain {
  static let pixels = 96
  static let period: CGFloat = 13
  private static let cache = NSCache<NSString, CGImage>()
  private static let atlas: Data? = {
    let resource = Bundle.main.url(forResource: "writer-grain", withExtension: "bin", subdirectory: "assets")
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("web/assets/writer-grain.bin")
    let url = Bundle.main.bundleURL.pathExtension == "app" ? resource : resource ?? source
    guard let url, let data = try? Data(contentsOf: url), data.count == pixels * pixels * 7 else { return nil }
    cache.countLimit = 48
    return data
  }()

  static func tile(for nib: InkNib?, color: InkColor) -> CGImage? {
    guard let nib, nib.textured == true, let atlas else { return nil }
    let index: Int
    switch nib.tip {
    case "Pen": index = 0
    case "Brush": index = nib.finish == .dry ? 2 : 1
    case "Fineliner": index = 3
    case "Gel": index = 4
    case "Fountain": index = 5
    case "Pencil": index = 6
    default: return nil
    }
    let rgb = [color.r, color.g, color.b].map { Int((min(1, max(0, $0)) * 255).rounded()) }
    let key = "\(index)/\(rgb[0])/\(rgb[1])/\(rgb[2])" as NSString
    if let image = cache.object(forKey: key) { return image }
    let count = pixels * pixels
    var bytes = [UInt8](repeating: 0, count: count * 4)
    for i in 0..<count {
      let alpha = Int(atlas[index * count + i])
      for c in 0..<3 { bytes[i*4+c] = UInt8((rgb[c]*alpha+127)/255) }
      bytes[i*4+3] = UInt8(alpha)
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let image = CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: pixels*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    cache.setObject(image, forKey: key)
    return image
  }
}
