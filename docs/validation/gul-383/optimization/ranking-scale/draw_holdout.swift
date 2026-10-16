import CoreGraphics
import Foundation
import ImageIO
struct Labels: Decodable {
    struct Document: Decodable { var id: String; var kind: String; var color: String?; var shape: String? }
    var documents: [Document]
}
let labels = try JSONDecoder().decode(Labels.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let root = URL(fileURLWithPath: CommandLine.arguments[2])
for doc in labels.documents where doc.kind == "image" {
    let colors: [String: (Double, Double, Double)] = ["red": (1, 0, 0), "blue": (0, 0, 1), "green": (0, 0.7, 0), "yellow": (1, 1, 0), "black": (0, 0, 0)]
    let rgb = colors[doc.color!]!
    let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 2048,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    context.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
    func polygon(_ points: [CGPoint]) {
        context.move(to: points[0]); for point in points.dropFirst() { context.addLine(to: point) }
        context.closePath(); context.fillPath()
    }
    switch doc.shape! {
    case "square": context.fill(CGRect(x: 106, y: 106, width: 300, height: 300))
    case "rectangle": context.fill(CGRect(x: 56, y: 166, width: 400, height: 180))
    case "ellipse": context.fillEllipse(in: CGRect(x: 56, y: 166, width: 400, height: 180))
    case "pentagon", "hexagon":
        let count = doc.shape == "pentagon" ? 5 : 6
        polygon((0..<count).map { index in
            let angle = Double.pi / 2 + Double(index) * 2 * Double.pi / Double(count)
            return CGPoint(x: 256 + 185*cos(angle), y: 256 + 185*sin(angle))
        })
    case "circle": context.fillEllipse(in: CGRect(x: 76, y: 76, width: 360, height: 360))
    case "triangle": polygon([.init(x: 256, y: 436), .init(x: 76, y: 96), .init(x: 436, y: 96)])
    case "diamond": polygon([.init(x: 256, y: 436), .init(x: 436, y: 256), .init(x: 256, y: 76), .init(x: 76, y: 256)])
    case "star": polygon((0..<10).map { index in
        let radius = index.isMultiple(of: 2) ? 195.0 : 85.0, angle = Double.pi / 2 + Double(index) * Double.pi / 5
        return CGPoint(x: 256 + radius * cos(angle), y: 256 + radius * sin(angle))
    })
    default:
        context.fill(CGRect(x: 224, y: 76, width: 64, height: 360)); context.fill(CGRect(x: 76, y: 224, width: 360, height: 64))
    }
    let target = root.appendingPathComponent(doc.id + ".png")
    let writer = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(writer, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(writer))
}
