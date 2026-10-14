import AppKit

/// Shared by native overlays and tests; all placement inputs use AppKit coordinates.
enum ScreenRecordingLayout {
    static func capsule(target: CGRect, size: CGSize, screen: CGRect) -> CGRect {
        let originX = min(max(target.midX - size.width / 2, screen.minX + 12), screen.maxX - size.width - 12)
        let originY: CGFloat = if target.minY - size.height - 12 >= screen.minY {
            target.minY - size.height - 12
        } else if target.maxY + size.height + 12 <= screen.maxY {
            target.maxY + 12
        } else {
            max(screen.minY + 12, target.minY + 12)
        }
        return CGRect(x: originX, y: min(originY, screen.maxY - size.height), width: size.width, height: size.height)
    }

    static func time(at position: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0, duration.isFinite, position.isFinite else { return 0 }
        return min(1, max(0, position / width)) * max(0, duration)
    }

    static func position(time: Double, width: CGFloat, duration: Double) -> CGFloat {
        guard duration > 0, time.isFinite else { return 0 }
        return min(1, max(0, time / duration)) * max(0, width)
    }

    static func cameraCorner(at point: CGPoint, in size: CGSize) -> ScreenRecordingOptions.CameraCorner {
        if point.y < size.height / 2 {
            return point.x < size.width / 2 ? .topLeft : .topRight
        }
        return point.x < size.width / 2 ? .bottomLeft : .bottomRight
    }

    static func cameraFraction(width: CGFloat, targetWidth: CGFloat) -> Double {
        guard targetWidth > 0, width.isFinite else { return 0.22 }
        return min(0.4, max(0.12, Double(width / targetWidth)))
    }

    static func validRegion(_ rect: CGRect) -> Bool {
        rect.width.isFinite && rect.height.isFinite && rect.width >= 40 && rect.height >= 40
    }

    static func fileName(_ value: String) -> String {
        var cleaned = value.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r").union(.controlCharacters))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.utf8.count > 220 {
            cleaned.removeLast()
        }
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Typeflux Recording" : String(cleaned.prefix(180))
    }

    static func preciseTime(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%02d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
}
