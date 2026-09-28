import AppKit
import Foundation

/// Colours for the badge on an account without a logo of its own. Chosen to
/// read against Claude's orange icon and against each other.
enum LauncherPalette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.20, green: 0.47, blue: 0.96, alpha: 1),   // blue
        NSColor(srgbRed: 0.13, green: 0.63, blue: 0.42, alpha: 1),   // green
        NSColor(srgbRed: 0.55, green: 0.33, blue: 0.90, alpha: 1),   // violet
        NSColor(srgbRed: 0.90, green: 0.27, blue: 0.47, alpha: 1),   // pink
        NSColor(srgbRed: 0.11, green: 0.60, blue: 0.70, alpha: 1),   // teal
        NSColor(srgbRed: 0.25, green: 0.27, blue: 0.33, alpha: 1)    // slate
    ]
    static var count: Int { colors.count }
}

/// Draws launcher icons with AppKit and packs them with `iconutil`.
public struct SystemIconRenderer: LauncherIconRenderer {

    public init() {}

    /// Kept at its own proportions, at most 1024 pixels on its longest side, so
    /// the icon can decide later whether to fill with it or fit it.
    public func normalizedLogo(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), image.isValid,
              image.size.width > 0, image.size.height > 0
        else { return nil }
        let scale = 1024 / max(image.size.width, image.size.height)
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        return render(width: width, height: height) { rect in image.draw(in: rect) }
    }

    public func icns(logo: Data?, claudeApp: URL, initial: String, tint: Int) throws -> Data {
        let draw: (NSRect) -> Void
        if let logo, let image = NSImage(data: logo) {
            let claude = NSWorkspace.shared.icon(forFile: claudeApp.path)
            draw = { rect in Self.drawLogo(image, claudeBadge: claude, in: rect) }
        } else {
            let claude = NSWorkspace.shared.icon(forFile: claudeApp.path)
            let color = LauncherPalette.colors[abs(tint) % LauncherPalette.count]
            draw = { rect in Self.drawDefault(claude, initial: initial, color: color, in: rect) }
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("janus-launcher-\(UUID().uuidString).iconset", isDirectory: true)
        let output = workspace.deletingPathExtension().appendingPathExtension("icns")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: output)
        }

        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                guard let png = render(pixels: base * scale, draw) else {
                    throw IconError.renderFailed
                }
                let suffix = scale == 1 ? "" : "@2x"
                try png.write(to: workspace.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
            }
        }

        let result = try Command.run("/usr/bin/iconutil",
                                     ["-c", "icns", workspace.path, "-o", output.path])
        guard result.succeeded, let data = FileManager.default.contents(atPath: output.path) else {
            throw IconError.iconutilFailed
        }
        return data
    }

    enum IconError: LocalizedError {
        case renderFailed, iconutilFailed
        var errorDescription: String? { "Could not draw the launcher's icon." }
    }

    // MARK: - Drawing

    /// The rounded square macOS icons sit in: Apple's template puts an 824-pixel
    /// square in a 1024-pixel canvas, which is also where Claude's own icon is.
    ///
    /// Nothing is drawn outside it. macOS 26 shows an icon whose outline is not
    /// this shape, a badge sticking out of a corner included, shrunk onto a grey
    /// tile.
    static func plate(in rect: NSRect) -> NSRect {
        let margin = rect.width * 100 / 1024
        return rect.insetBy(dx: margin, dy: margin)
    }

    static func outline(of plate: NSRect) -> NSBezierPath {
        let corner = plate.width * 0.2237
        return NSBezierPath(roundedRect: plate, xRadius: corner, yRadius: corner)
    }

    /// A badge's frame in the plate's bottom-right corner, far enough in to clear
    /// the rounded corner rather than poke out of it.
    static func badge(side: CGFloat, in plate: NSRect) -> NSRect {
        let inset = plate.width * 0.06
        return NSRect(x: plate.maxX - side - inset, y: plate.minY + inset, width: side, height: side)
    }

    /// The account's logo in the icon shape, over white so a transparent logo
    /// still reads, with a small Claude mark in the corner so the launcher is
    /// recognisably Claude's.
    ///
    /// A roughly square logo fills the shape. A wordmark or banner is fitted
    /// inside it instead, since cropping it to a square would cut its ends off.
    static func drawLogo(_ logo: NSImage, claudeBadge: NSImage, in rect: NSRect) {
        let plate = plate(in: rect)
        let shape = outline(of: plate)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.white.setFill()
        plate.fill()
        let ratio = logo.size.width / max(logo.size.height, 1)
        let frame = (0.8...1.25).contains(ratio)
            ? aspectFill(logo.size, in: plate)
            : aspectFit(logo.size, in: plate.insetBy(dx: plate.width * 0.1, dy: plate.width * 0.1))
        logo.draw(in: frame, from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true,
                  hints: [.interpolation: NSImageInterpolation.high.rawValue])

        // A hairline edge, or a white icon disappears against a light Dock.
        // Stroked inside the clip, which keeps only the inner half of the line.
        NSColor.black.withAlphaComponent(0.12).setStroke()
        shape.lineWidth = max(0.5, rect.width * 0.004) * 2
        shape.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Claude's icon has the same empty margin round it as any other, so it
        // is drawn that much larger for its visible part to fill the badge.
        let mark = badge(side: plate.width * 0.3, in: plate)
        let margin = mark.width * 100 / 824
        claudeBadge.draw(in: mark.insetBy(dx: -margin, dy: -margin))
    }

    /// Claude's own icon with the account's initial in a coloured disc, the disc
    /// kept inside Claude's rounded square.
    static func drawDefault(_ claude: NSImage, initial: String, color: NSColor, in rect: NSRect) {
        claude.draw(in: rect)

        let plate = plate(in: rect)
        let disc = badge(side: plate.width * 0.44, in: plate)
        let ring = NSBezierPath(ovalIn: disc)
        color.setFill()
        ring.fill()
        NSColor.white.setStroke()
        ring.lineWidth = max(1, rect.width * 0.025)
        ring.stroke()

        let font = NSFont.systemFont(ofSize: disc.width * 0.58, weight: .bold)
        let text = NSAttributedString(string: initial, attributes: [
            .font: font,
            .foregroundColor: NSColor.white
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2))
    }

    static func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
        let scale = min(rect.width / size.width, rect.height / size.height)
        return centered(NSSize(width: size.width * scale, height: size.height * scale), in: rect)
    }

    static func aspectFill(_ size: NSSize, in rect: NSRect) -> NSRect {
        let scale = max(rect.width / size.width, rect.height / size.height)
        return centered(NSSize(width: size.width * scale, height: size.height * scale), in: rect)
    }

    private static func centered(_ size: NSSize, in rect: NSRect) -> NSRect {
        NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
               width: size.width, height: size.height)
    }

    /// A square PNG of the given size, drawn by the closure.
    private func render(pixels: Int, _ draw: (NSRect) -> Void) -> Data? {
        render(width: pixels, height: pixels, draw)
    }

    private func render(width: Int, height: Int, _ draw: (NSRect) -> Void) -> Data? {
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: canvas)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        draw(NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
    }
}
