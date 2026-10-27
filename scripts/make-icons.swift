#!/usr/bin/env swift
// Draws the app icon and the document icon with Core Graphics and writes
// Resources/AppIcon.icns and Resources/DocumentIcon.icns (through iconutil).
//
//   swift scripts/make-icons.swift [output-directory]
//
// The icons are generated rather than drawn by hand so that they can be
// rebuilt at any size and changed in code review.
import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// The motif shared by both icons: an axial slice (the body in grey with a
/// spine and organs), a segmented organ in colour with a crisp outline, and
/// the crosshair of an MPR viewer.
func drawMotif(_ ctx: CGContext, in rect: CGRect) {
    let s = rect.width
    let cx = rect.midX, cy = rect.midY

    // Body: a soft-edged ellipse lit from the centre.
    let body = CGRect(x: cx - s * 0.40, y: cy - s * 0.30, width: s * 0.80, height: s * 0.60)
    ctx.saveGState()
    ctx.addEllipse(in: body)
    ctx.clip()
    let grey = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xD9DEE6), color(0x9AA3B2), color(0x4A5262)] as CFArray,
                          locations: [0, 0.65, 1])!
    ctx.drawRadialGradient(grey, startCenter: CGPoint(x: cx, y: cy + s * 0.04), startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy), endRadius: s * 0.42, options: [])
    // Spine and two kidneys: brighter structures.
    ctx.setFillColor(color(0xF4F6FA))
    ctx.fillEllipse(in: CGRect(x: cx - s * 0.055, y: cy - s * 0.25, width: s * 0.11, height: s * 0.10))
    ctx.setFillColor(color(0x6F7888))
    ctx.fillEllipse(in: CGRect(x: cx - s * 0.27, y: cy - s * 0.20, width: s * 0.12, height: s * 0.10))
    ctx.fillEllipse(in: CGRect(x: cx + s * 0.15, y: cy - s * 0.20, width: s * 0.12, height: s * 0.10))
    ctx.restoreGState()

    // The segmented organ (a liver-like shape on the image's left, which is
    // the patient's right in the radiological convention) and a lesion.
    let organ = CGMutablePath()
    organ.move(to: CGPoint(x: cx - s * 0.33, y: cy + s * 0.02))
    organ.addCurve(to: CGPoint(x: cx + s * 0.05, y: cy + s * 0.20),
                   control1: CGPoint(x: cx - s * 0.33, y: cy + s * 0.22),
                   control2: CGPoint(x: cx - s * 0.10, y: cy + s * 0.25))
    organ.addCurve(to: CGPoint(x: cx - s * 0.02, y: cy + s * 0.02),
                   control1: CGPoint(x: cx + s * 0.12, y: cy + s * 0.15),
                   control2: CGPoint(x: cx + s * 0.06, y: cy + s * 0.04))
    organ.addCurve(to: CGPoint(x: cx - s * 0.33, y: cy + s * 0.02),
                   control1: CGPoint(x: cx - s * 0.12, y: cy - s * 0.02),
                   control2: CGPoint(x: cx - s * 0.25, y: cy - s * 0.10))
    organ.closeSubpath()
    ctx.addPath(organ)
    ctx.setFillColor(color(0xFF8A3D, 0.55))
    ctx.fillPath()
    ctx.addPath(organ)
    ctx.setStrokeColor(color(0xFFB07A))
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.strokePath()

    let lesion = CGRect(x: cx - s * 0.20, y: cy + s * 0.07, width: s * 0.10, height: s * 0.09)
    ctx.setFillColor(color(0x2EE6C8, 0.65))
    ctx.fillEllipse(in: lesion)
    ctx.setStrokeColor(color(0x9BFFF0))
    ctx.setLineWidth(max(1, s * 0.010))
    ctx.strokeEllipse(in: lesion)

    // Crosshair through the lesion, with a gap around it.
    let hx = lesion.midX, hy = lesion.midY
    ctx.setStrokeColor(color(0xFFD84D, 0.95))
    ctx.setLineWidth(max(1, s * 0.010))
    ctx.setLineCap(.round)
    let gap = s * 0.085
    for (a, b) in [
        (CGPoint(x: rect.minX + s * 0.06, y: hy), CGPoint(x: hx - gap, y: hy)),
        (CGPoint(x: hx + gap, y: hy), CGPoint(x: rect.maxX - s * 0.06, y: hy)),
        (CGPoint(x: hx, y: rect.minY + s * 0.06), CGPoint(x: hx, y: hy - gap)),
        (CGPoint(x: hx, y: hy + gap), CGPoint(x: hx, y: rect.maxY - s * 0.06)),
    ] {
        ctx.move(to: a)
        ctx.addLine(to: b)
    }
    ctx.strokePath()
}

func appIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // The macOS icon grid: an 824/1024 rounded square, centred, with shadow.
    let inset = s * (100.0 / 1024.0)
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x0B1020))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                colors: [color(0x1B2A55), color(0x0B1020)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: tile.minX, y: tile.maxY),
                           end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    // A faint voxel grid.
    ctx.setStrokeColor(color(0xFFFFFF, 0.05))
    ctx.setLineWidth(max(0.5, s * 0.002))
    let step = tile.width / 16
    var x = tile.minX
    while x <= tile.maxX { ctx.move(to: CGPoint(x: x, y: tile.minY)); ctx.addLine(to: CGPoint(x: x, y: tile.maxY)); x += step }
    var y = tile.minY
    while y <= tile.maxY { ctx.move(to: CGPoint(x: tile.minX, y: y)); ctx.addLine(to: CGPoint(x: tile.maxX, y: y)); y += step }
    ctx.strokePath()
    drawMotif(ctx, in: tile.insetBy(dx: tile.width * 0.04, dy: tile.width * 0.04))
    ctx.restoreGState()

    // A thin highlight on the tile's edge.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.setLineWidth(max(0.5, s * 0.003))
    ctx.strokePath()
    return ctx.makeImage()!
}

func documentIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // A page with a folded corner.
    let w = s * 0.70, h = s * 0.86
    let page = CGRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h)
    let fold = w * 0.24
    let path = CGMutablePath()
    path.move(to: CGPoint(x: page.minX, y: page.minY))
    path.addLine(to: CGPoint(x: page.maxX, y: page.minY))
    path.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    path.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    path.addLine(to: CGPoint(x: page.minX, y: page.maxY))
    path.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02, color: color(0x000000, 0.3))
    ctx.addPath(path)
    ctx.setFillColor(color(0xFBFCFE))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setStrokeColor(color(0xC9CFDA))
    ctx.setLineWidth(max(0.5, s * 0.004))
    ctx.strokePath()
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    corner.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
    corner.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    corner.closeSubpath()
    ctx.addPath(corner)
    ctx.setFillColor(color(0xE3E7EE))
    ctx.fillPath()

    // The motif on a dark plate, and the format's name.
    let plate = CGRect(x: page.minX + w * 0.12, y: page.minY + h * 0.30, width: w * 0.76, height: w * 0.76)
    ctx.saveGState()
    let platePath = CGPath(roundedRect: plate, cornerWidth: plate.width * 0.12, cornerHeight: plate.width * 0.12, transform: nil)
    ctx.addPath(platePath)
    ctx.clip()
    ctx.setFillColor(color(0x121A33))
    ctx.fill(plate)
    drawMotif(ctx, in: plate)
    ctx.restoreGState()

    if size >= 32 {
        let text = NSAttributedString(string: "MEDH5", attributes: [
            .font: NSFont.systemFont(ofSize: s * 0.085, weight: .bold),
            .foregroundColor: NSColor(cgColor: color(0x1B2A55))!,
            .kern: s * 0.006,
        ])
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let bounds = text.size()
        text.draw(at: CGPoint(x: page.midX - bounds.width / 2, y: page.minY + h * 0.10))
        NSGraphicsContext.restoreGraphicsState()
    }
    return ctx.makeImage()!
}

func writeICNS(named name: String, draw: (Int) -> CGImage) throws {
    let fm = FileManager.default
    let iconset = fm.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).iconset")
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: iconset) }
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            let rep = NSBitmapImageRep(cgImage: draw(px))
            let file = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(file))
        }
    }
    try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let out = outputDirectory.appendingPathComponent("\(name).icns")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw NSError(domain: "iconutil", code: Int(task.terminationStatus)) }
    // A 1024 px preview beside it, for the README and for review.
    let preview = NSBitmapImageRep(cgImage: draw(1024))
    try preview.representation(using: .png, properties: [:])!
        .write(to: outputDirectory.appendingPathComponent("\(name).png"))
    print("wrote \(out.path)")
}

do {
    try writeICNS(named: "AppIcon", draw: appIcon)
    try writeICNS(named: "DocumentIcon", draw: documentIcon)
} catch {
    FileHandle.standardError.write("make-icons: \(error)\n".data(using: .utf8)!)
    exit(1)
}
