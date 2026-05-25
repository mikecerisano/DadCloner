import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "DadCloner/Assets.xcassets/AppIcon.appiconset")
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func scaled(_ value: CGFloat, for side: CGFloat) -> CGFloat {
    value * side / 1024.0
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawLine(from start: CGPoint, to end: CGPoint, width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    path.lineWidth = width
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}

func drawArrowHead(at tip: CGPoint, angle: CGFloat, side: CGFloat, color: NSColor) {
    let size = scaled(56, for: side)
    let wing = CGFloat.pi * 0.78
    let p1 = CGPoint(x: tip.x + cos(angle + wing) * size, y: tip.y + sin(angle + wing) * size)
    let p2 = CGPoint(x: tip.x + cos(angle - wing) * size, y: tip.y + sin(angle - wing) * size)

    let path = NSBezierPath()
    path.move(to: tip)
    path.line(to: p1)
    path.line(to: p2)
    path.close()
    color.setFill()
    path.fill()
}

func drawDrive(in rect: CGRect, side: CGFloat, fill: NSColor, stroke: NSColor, accent: NSColor) {
    let shadow = NSShadow()
    shadow.shadowBlurRadius = scaled(24, for: side)
    shadow.shadowOffset = CGSize(width: 0, height: -scaled(10, for: side))
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
    shadow.set()

    let body = roundedRect(rect, radius: scaled(58, for: side))
    fill.setFill()
    body.fill()

    NSShadow().set()
    stroke.setStroke()
    body.lineWidth = scaled(9, for: side)
    body.stroke()

    let slot = roundedRect(
        CGRect(
            x: rect.minX + rect.width * 0.20,
            y: rect.maxY - rect.height * 0.20,
            width: rect.width * 0.60,
            height: scaled(24, for: side)
        ),
        radius: scaled(12, for: side)
    )
    NSColor.white.withAlphaComponent(0.58).setFill()
    slot.fill()

    let indicator = NSBezierPath(ovalIn: CGRect(
        x: rect.midX - scaled(24, for: side),
        y: rect.minY + rect.height * 0.17,
        width: scaled(48, for: side),
        height: scaled(48, for: side)
    ))
    accent.setFill()
    indicator.fill()
}

func drawHardDrive(in rect: CGRect, side: CGFloat) {
    let shadow = NSShadow()
    shadow.shadowBlurRadius = scaled(34, for: side)
    shadow.shadowOffset = CGSize(width: 0, height: -scaled(18, for: side))
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.set()

    let body = roundedRect(rect, radius: scaled(74, for: side))
    let bodyGradient = NSGradient(colors: [
        NSColor(red: 0.08, green: 0.14, blue: 0.20, alpha: 1.0),
        NSColor(red: 0.09, green: 0.36, blue: 0.43, alpha: 1.0)
    ])!
    bodyGradient.draw(in: body, angle: 290)

    NSShadow().set()

    NSColor.white.withAlphaComponent(0.28).setStroke()
    body.lineWidth = scaled(10, for: side)
    body.stroke()

    let inner = roundedRect(rect.insetBy(dx: scaled(28, for: side), dy: scaled(28, for: side)), radius: scaled(50, for: side))
    NSColor.white.withAlphaComponent(0.10).setStroke()
    inner.lineWidth = scaled(5, for: side)
    inner.stroke()

    let slot = roundedRect(
        CGRect(
            x: rect.minX + rect.width * 0.20,
            y: rect.maxY - rect.height * 0.26,
            width: rect.width * 0.60,
            height: scaled(34, for: side)
        ),
        radius: scaled(17, for: side)
    )
    NSColor.white.withAlphaComponent(0.55).setFill()
    slot.fill()

    let foot = roundedRect(
        CGRect(
            x: rect.minX + rect.width * 0.20,
            y: rect.minY + rect.height * 0.17,
            width: rect.width * 0.38,
            height: scaled(24, for: side)
        ),
        radius: scaled(12, for: side)
    )
    NSColor.black.withAlphaComponent(0.20).setFill()
    foot.fill()

    let led = NSBezierPath(ovalIn: CGRect(
        x: rect.maxX - rect.width * 0.27,
        y: rect.minY + rect.height * 0.16,
        width: scaled(54, for: side),
        height: scaled(54, for: side)
    ))
    NSColor(red: 0.70, green: 1.00, blue: 0.36, alpha: 1.0).setFill()
    led.fill()
}

func drawEmoji(_ scalar: UInt32, in rect: CGRect, side: CGFloat) {
    guard let unicode = UnicodeScalar(scalar) else {
        return
    }

    let emoji = String(unicode) as NSString
    let font = NSFont(name: "Apple Color Emoji", size: rect.height * 0.88)
        ?? NSFont.systemFont(ofSize: rect.height * 0.88)
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let textSize = emoji.size(withAttributes: attributes)
    let drawPoint = CGPoint(
        x: rect.midX - textSize.width / 2,
        y: rect.midY - textSize.height / 2 + scaled(4, for: side)
    )

    emoji.draw(at: drawPoint, withAttributes: attributes)
}

func drawIcon(side: Int) -> NSBitmapImageRep {
    let side = CGFloat(side)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(side),
        pixelsHigh: Int(side),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not create bitmap context")
    }

    bitmap.size = CGSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let bounds = CGRect(x: 0, y: 0, width: side, height: side)
    NSColor.clear.setFill()
    bounds.fill()

    let background = roundedRect(bounds.insetBy(dx: scaled(52, for: side), dy: scaled(52, for: side)), radius: scaled(220, for: side))
    let gradient = NSGradient(colors: [
        NSColor(red: 1.00, green: 0.91, blue: 0.72, alpha: 1.0),
        NSColor(red: 0.76, green: 0.91, blue: 0.91, alpha: 1.0),
        NSColor(red: 0.18, green: 0.50, blue: 0.56, alpha: 1.0)
    ])!
    gradient.draw(in: background, angle: 315)

    NSColor.white.withAlphaComponent(0.55).setStroke()
    background.lineWidth = scaled(8, for: side)
    background.stroke()

    let haloShadow = NSShadow()
    haloShadow.shadowBlurRadius = scaled(24, for: side)
    haloShadow.shadowOffset = CGSize(width: 0, height: -scaled(10, for: side))
    haloShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    haloShadow.set()

    let emojiHalo = NSBezierPath(ovalIn: CGRect(
        x: scaled(114, for: side),
        y: scaled(430, for: side),
        width: scaled(444, for: side),
        height: scaled(444, for: side)
    ))
    NSColor.white.withAlphaComponent(0.74).setFill()
    emojiHalo.fill()
    NSShadow().set()

    drawEmoji(
        0x1F474,
        in: CGRect(
            x: scaled(132, for: side),
            y: scaled(454, for: side),
            width: scaled(408, for: side),
            height: scaled(408, for: side)
        ),
        side: side
    )

    let driveRect = CGRect(
        x: scaled(360, for: side),
        y: scaled(185, for: side),
        width: scaled(500, for: side),
        height: scaled(365, for: side)
    )
    drawHardDrive(in: driveRect, side: side)

    let cable = NSBezierPath()
    cable.move(to: CGPoint(x: scaled(435, for: side), y: scaled(430, for: side)))
    cable.curve(
        to: CGPoint(x: scaled(518, for: side), y: scaled(500, for: side)),
        controlPoint1: CGPoint(x: scaled(465, for: side), y: scaled(435, for: side)),
        controlPoint2: CGPoint(x: scaled(490, for: side), y: scaled(476, for: side))
    )
    cable.lineWidth = scaled(28, for: side)
    cable.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.68).setStroke()
    cable.stroke()

    if side >= 128 {
        let badge = NSBezierPath(ovalIn: CGRect(
            x: scaled(138, for: side),
            y: scaled(168, for: side),
            width: scaled(190, for: side),
            height: scaled(190, for: side)
        ))
        NSColor.white.withAlphaComponent(0.88).setFill()
        badge.fill()
        NSColor.black.withAlphaComponent(0.08).setStroke()
        badge.lineWidth = scaled(5, for: side)
        badge.stroke()

        let check = NSBezierPath()
        check.move(to: CGPoint(x: scaled(184, for: side), y: scaled(268, for: side)))
        check.line(to: CGPoint(x: scaled(236, for: side), y: scaled(222, for: side)))
        check.line(to: CGPoint(x: scaled(302, for: side), y: scaled(306, for: side)))
        check.lineWidth = scaled(34, for: side)
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSColor(red: 0.72, green: 1.00, blue: 0.30, alpha: 1.0).setStroke()
        check.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for size in sizes {
    let bitmap = drawIcon(side: size)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not render icon_\(size)x\(size).png")
    }

    let outputURL = outputDirectory.appendingPathComponent("icon_\(size)x\(size).png")
    try data.write(to: outputURL, options: .atomic)
}
