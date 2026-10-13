import AppKit
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let factor = CGFloat(size) / 1024
        let transform = AffineTransform(scale: factor); (transform as NSAffineTransform).concat()
        let shape = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(red: 0.36, green: 0.49, blue: 1, alpha: 1), ending: NSColor(red: 0.16, green: 0.25, blue: 0.76, alpha: 1))!.draw(in: shape, angle: -90)
        NSColor.white.setStroke()
        let path = NSBezierPath(); path.lineWidth = 62; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: NSPoint(x: 512, y: 740)); path.line(to: NSPoint(x: 512, y: 360))
        path.move(to: NSPoint(x: 360, y: 510)); path.line(to: NSPoint(x: 512, y: 358)); path.line(to: NSPoint(x: 664, y: 510))
        path.move(to: NSPoint(x: 310, y: 285)); path.line(to: NSPoint(x: 714, y: 285)); path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
