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
        NSColor(red: 0.06, green: 0.10, blue: 0.16, alpha: 1.0),
        NSColor(red: 0.08, green: 0.18, blue: 0.24, alpha: 1.0),
        NSColor(red: 0.03, green: 0.31, blue: 0.36, alpha: 1.0)
    ])!
    gradient.draw(in: background, angle: 305)

    NSColor(red: 0.84, green: 0.95, blue: 1.0, alpha: 0.22).setStroke()
    background.lineWidth = scaled(7, for: side)
    background.stroke()

    let backDrive = CGRect(
        x: scaled(520, for: side),
        y: scaled(268, for: side),
        width: scaled(270, for: side),
        height: scaled(438, for: side)
    )
    let frontDrive = CGRect(
        x: scaled(235, for: side),
        y: scaled(318, for: side),
        width: scaled(270, for: side),
        height: scaled(438, for: side)
    )

    drawDrive(
        in: backDrive,
        side: side,
        fill: NSColor(red: 0.10, green: 0.57, blue: 0.68, alpha: 1.0),
        stroke: NSColor(red: 0.79, green: 0.96, blue: 1.0, alpha: 0.70),
        accent: NSColor(red: 0.75, green: 1.00, blue: 0.50, alpha: 1.0)
    )
    drawDrive(
        in: frontDrive,
        side: side,
        fill: NSColor(red: 0.91, green: 0.96, blue: 0.98, alpha: 1.0),
        stroke: NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 0.86),
        accent: NSColor(red: 0.05, green: 0.62, blue: 0.69, alpha: 1.0)
    )

    let arrowColor = NSColor(red: 0.74, green: 1.00, blue: 0.34, alpha: 1.0)
    drawLine(
        from: CGPoint(x: scaled(450, for: side), y: scaled(516, for: side)),
        to: CGPoint(x: scaled(615, for: side), y: scaled(516, for: side)),
        width: scaled(54, for: side),
        color: NSColor.black.withAlphaComponent(0.24)
    )
    drawLine(
        from: CGPoint(x: scaled(445, for: side), y: scaled(532, for: side)),
        to: CGPoint(x: scaled(625, for: side), y: scaled(532, for: side)),
        width: scaled(48, for: side),
        color: arrowColor
    )
    drawArrowHead(at: CGPoint(x: scaled(650, for: side), y: scaled(532, for: side)), angle: 0, side: side, color: arrowColor)

    if side >= 128 {
        let check = NSBezierPath()
        check.move(to: CGPoint(x: scaled(364, for: side), y: scaled(260, for: side)))
        check.line(to: CGPoint(x: scaled(438, for: side), y: scaled(195, for: side)))
        check.line(to: CGPoint(x: scaled(562, for: side), y: scaled(334, for: side)))
        check.lineWidth = scaled(38, for: side)
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.92).setStroke()
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
