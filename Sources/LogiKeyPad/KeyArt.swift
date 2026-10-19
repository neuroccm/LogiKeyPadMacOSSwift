import Foundation
import AppKit

/// Renders key faces as exact-pixel JPEGs for the 480x480 panel.
/// Full-panel renders clear the inter-key gaps; single-tile renders
/// serve cheap 1 Hz updates (focus timer).
enum KeyArt {
    static let panelSize = 480
    static let tileSize = 118

    static func tileOrigin(slot: Int) -> (x: Int, y: Int) {
        (x: 23 + (slot % 3) * 158, y: 6 + (slot / 3) * 158)
    }

    struct Badge {
        let text: String
        let color: NSColor
    }

    // MARK: Public renders

    static func panelJPEG(actions: [CatalogAction?], theme: PadTheme,
                          badges: [Int: Badge]) -> Data? {
        guard let rep = makeRep(width: panelSize, height: panelSize) else { return nil }
        draw(in: rep) {
            panelBackground(theme).setFill()
            NSRect(x: 0, y: 0, width: panelSize, height: panelSize).fill()
            for slot in 0..<9 {
                let o = tileOrigin(slot: slot)
                // Panel y axis: device origin is top-left; AppKit is bottom-left.
                let rect = NSRect(x: o.x, y: panelSize - o.y - tileSize, width: tileSize, height: tileSize)
                drawTile(rect: rect, action: slot < actions.count ? actions[slot] : nil,
                         theme: theme, badge: badges[slot])
            }
        }
        return jpeg(rep)
    }

    static func tileJPEG(action: CatalogAction?, theme: PadTheme, badge: Badge?) -> Data? {
        guard let rep = makeRep(width: tileSize, height: tileSize) else { return nil }
        draw(in: rep) {
            drawTile(rect: NSRect(x: 0, y: 0, width: tileSize, height: tileSize),
                     action: action, theme: theme, badge: badge)
        }
        return jpeg(rep)
    }

    // MARK: Drawing

    private static func panelBackground(_ theme: PadTheme) -> NSColor {
        theme == .midnight ? .black : NSColor(red: 0.008, green: 0.06, blue: 0.30, alpha: 1)
    }

    private static func tileBackground(_ theme: PadTheme) -> NSColor {
        theme == .midnight
            ? NSColor(white: 0.07, alpha: 1)
            : NSColor(red: 0.02, green: 0.18, blue: 0.85, alpha: 1)
    }

    private static func drawTile(rect: NSRect, action: CatalogAction?, theme: PadTheme, badge: Badge?) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        tileBackground(theme).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1.5
        path.stroke()
        guard let action else { return }

        if let symbol = whiteSymbol(action.symbol, pointSize: 34) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.maxY - s.height - 10,
                                   width: s.width, height: s.height))
        }
        drawCentered(action.title, in: rect, yFromTop: 52,
                     font: .systemFont(ofSize: 20, weight: .semibold), color: .white)
        if !action.sub.isEmpty {
            drawCentered(action.sub, in: rect, yFromTop: 76,
                         font: .systemFont(ofSize: 12.5, weight: .regular),
                         color: NSColor.white.withAlphaComponent(0.72))
        }
        if let badge {
            drawCentered(badge.text, in: rect, yFromTop: 94,
                         font: .systemFont(ofSize: 12.5, weight: .bold), color: badge.color)
        }
    }

    private static func drawCentered(_ text: String, in rect: NSRect, yFromTop: CGFloat,
                                     font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: rect.midX - s.width / 2,
                                            y: rect.maxY - yFromTop - s.height),
                                withAttributes: attrs)
    }

    private static func whiteSymbol(_ name: String, pointSize: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let tinted = NSImage(size: img.size)
        tinted.lockFocus()
        img.draw(at: .zero, from: NSRect(origin: .zero, size: img.size), operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }

    // MARK: Bitmap plumbing (exact pixels — Retina points need not apply)

    private static func makeRep(width: Int, height: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: width, height: height)
        return rep
    }

    private static func draw(in rep: NSBitmapImageRep, _ body: () -> Void) {
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func jpeg(_ rep: NSBitmapImageRep) -> Data? {
        rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }
}
