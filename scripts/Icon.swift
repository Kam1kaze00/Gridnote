import AppKit

@main struct Icon {
  static func main() throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    for points in [16, 32, 128, 256, 512] {
      for scale in [1, 2] {
        let side = points * scale
        let context = CGContext(
          data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let edge = CGFloat(side) * 0.045
        NotebookGlyph.drawMark(
          in: CGRect(
            x: edge, y: edge, width: CGFloat(side) - edge * 2, height: CGFloat(side) - edge * 2),
          context: context)
        let image = NSBitmapImageRep(cgImage: context.makeImage()!)
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try image.representation(using: .png, properties: [:])!.write(
          to: directory.appendingPathComponent(name))
      }
    }
  }
}
