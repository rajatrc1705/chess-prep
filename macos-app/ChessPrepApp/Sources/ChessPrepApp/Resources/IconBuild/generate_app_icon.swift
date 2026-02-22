import AppKit

let outputPath = "/Users/rajat/hackathons/chessOS/chess-prep/macos-app/ChessPrepApp/Sources/ChessPrepApp/Resources/IconBuild/AppIcon-1024.png"
let size = CGFloat(1024)
let canvas = NSRect(x: 0, y: 0, width: size, height: size)

let image = NSImage(size: canvas.size, flipped: false) { rect in
    NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.14, alpha: 1).setFill()
    rect.fill()

    let inset: CGFloat = 56
    let badgeRect = rect.insetBy(dx: inset, dy: inset)
    let corner = size * 0.20
    let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: corner, yRadius: corner)

    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.93, green: 0.87, blue: 0.72, alpha: 1),
            NSColor(calibratedRed: 0.58, green: 0.42, blue: 0.28, alpha: 1),
        ]
    )
    gradient?.draw(in: badgePath, angle: -35)

    NSColor(calibratedRed: 0.10, green: 0.08, blue: 0.07, alpha: 0.44).setStroke()
    badgePath.lineWidth = 16
    badgePath.stroke()

    let glyph = "♞"
    let font = NSFont.systemFont(ofSize: size * 0.62, weight: .black)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]

    let glyphSize = glyph.size(withAttributes: attributes)
    let glyphPoint = NSPoint(
        x: (size - glyphSize.width) / 2,
        y: (size - glyphSize.height) / 2 - size * 0.04
    )

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.34)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 16
    shadow.set()
    glyph.draw(at: glyphPoint, withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()

    return true
}

if let tiff = image.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
    do {
        try png.write(to: URL(fileURLWithPath: outputPath))
        print("Wrote \(outputPath)")
    } catch {
        fputs("Failed to write PNG: \(error)\n", stderr)
        exit(1)
    }
} else {
    fputs("Failed to render PNG\n", stderr)
    exit(1)
}
