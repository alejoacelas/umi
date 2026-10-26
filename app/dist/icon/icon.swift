// icon: Umi's app icon, drawn on Apple's macOS icon grid.
//
//   swift icon.swift design OUT.png          draw Umi's own icon (1024 × 1024)
//   swift icon.swift shape IN.png OUT.png    put a square image into the same icon shape
//
// The grid is Apple's for macOS (Big Sur and later): a 1024-point canvas, an 824-point body
// centred in it (100-point margins), corners of radius 185.4 with continuous curvature (60%
// corner smoothing), and a soft drop shadow inside the margin. `shape` crops the image to a
// centred square, fills the body with it and clips it to that outline.
import AppKit
import CoreGraphics
import Foundation

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185.4
let smoothing: CGFloat = 0.6

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("icon: \(message)\n".utf8))
    exit(1)
}

// MARK: The outline

/// A rounded rectangle with smoothed corners (the curve Figma calls corner smoothing; at 60% it
/// matches Apple's icon shape), as a dense polygon in y-down coordinates.
func squircle(_ rect: CGRect, radius r: CGFloat, smoothing xi: CGFloat) -> CGPath {
    func rad(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }
    let p = (1 + xi) * r
    let arcMeasure = 90 * (1 - xi)
    let arcLength = sin(rad(arcMeasure / 2)) * r * sqrt(2)
    let alpha = (90 - arcMeasure) / 2
    let p3ToP4 = r * tan(rad(alpha / 2))
    let beta = 45 * xi
    let c = p3ToP4 * cos(rad(beta))
    let d = c * tan(rad(beta))
    let b = (p - arcLength - c - d) / 3
    let a = 2 * b

    func bezier(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, steps: Int = 48) -> [CGPoint] {
        (1...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps), u = 1 - t
            let x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p1.x
            let y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p1.y
            return CGPoint(x: x, y: y)
        }
    }

    // The top-right corner of a W × H box at the origin, from (W - p, 0) to (W, p).
    let w = rect.width, h = rect.height
    let p0 = CGPoint(x: w - p, y: 0)
    var corner = [p0]
    let q0 = CGPoint(x: p0.x + a + b + c, y: d)
    corner += bezier(p0, CGPoint(x: p0.x + a, y: 0), CGPoint(x: p0.x + a + b, y: 0), q0)
    let centre = CGPoint(x: w - r, y: r)
    let q1 = CGPoint(x: q0.x + arcLength, y: q0.y + arcLength)
    let start = atan2(q0.y - centre.y, q0.x - centre.x), end = atan2(q1.y - centre.y, q1.x - centre.x)
    for i in 1...32 {
        let angle = start + (end - start) * CGFloat(i) / 32
        corner.append(CGPoint(x: centre.x + r * cos(angle), y: centre.y + r * sin(angle)))
    }
    corner += bezier(q1, CGPoint(x: q1.x + d, y: q1.y + c), CGPoint(x: q1.x + d, y: q1.y + b + c),
                     CGPoint(x: q1.x + d, y: q1.y + a + b + c))

    // The other three corners by symmetry, in drawing order (clockwise in y-down space).
    let topRight = corner
    let bottomRight = corner.reversed().map { CGPoint(x: $0.x, y: h - $0.y) }
    let bottomLeft = corner.map { CGPoint(x: w - $0.x, y: h - $0.y) }
    let topLeft = corner.reversed().map { CGPoint(x: w - $0.x, y: $0.y) }
    let path = CGMutablePath()
    path.addLines(between: (topRight + bottomRight + bottomLeft + topLeft).map {
        CGPoint(x: $0.x + rect.minX, y: $0.y + rect.minY)
    })
    path.closeSubpath()
    return path
}

// MARK: Drawing

func makeContext() -> CGContext {
    guard let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no drawing context") }
    // y grows downwards, like the numbers below.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// The body's drop shadow, as Apple's template has it: soft, a little below the body.
func drawShadow(_ ctx: CGContext, _ outline: CGPath) {
    ctx.saveGState()
    // The context is flipped, so a positive height moves the shadow up: negate it.
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.32))
    ctx.addPath(outline)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.restoreGState()
}

/// A wave across the body: the area below y = base + amplitude · sin(…), as a closed path.
func wave(base: CGFloat, amplitude: CGFloat, length: CGFloat, phase: CGFloat) -> (fill: CGPath, crest: CGPath) {
    let crest = CGMutablePath()
    var points: [CGPoint] = []
    var x = body.minX - 20
    while x <= body.maxX + 20 {
        let y = base + amplitude * sin(2 * .pi * (x - body.minX) / length + phase)
        points.append(CGPoint(x: x, y: y))
        x += 2
    }
    crest.addLines(between: points)
    let fill = CGMutablePath()
    fill.addLines(between: points + [CGPoint(x: body.maxX + 20, y: body.maxY + 20), CGPoint(x: body.minX - 20, y: body.maxY + 20)])
    fill.closeSubpath()
    return (fill, crest)
}

/// Umi's own icon: a prompt over the sea at night.
func design() -> CGImage {
    let ctx = makeContext()
    let outline = squircle(body, radius: cornerRadius, smoothing: smoothing)
    drawShadow(ctx, outline)

    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()

    // The sky: deep blue, lighter towards the horizon.
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        color(0x0B1B33), color(0x123A5E),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.minY + 600), options: [.drawsAfterEndLocation])

    // The sea: two waves, the front one with a light crest.
    let back = wave(base: 640, amplitude: 22, length: 412, phase: 0.9)
    ctx.addPath(back.fill)
    ctx.setFillColor(color(0x1C6E97))
    ctx.fillPath()
    let front = wave(base: 712, amplitude: 26, length: 412, phase: 2.6)
    let sea = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        color(0x2AA7CF), color(0x16729C),
    ] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(front.fill)
    ctx.clip()
    ctx.drawLinearGradient(sea, start: CGPoint(x: 0, y: 680), end: CGPoint(x: 0, y: body.maxY), options: [])
    ctx.restoreGState()
    ctx.addPath(front.crest)
    ctx.setStrokeColor(color(0xE6F6FB))
    ctx.setLineWidth(14)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // The prompt: a chevron and a cursor.
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: 236, y: 246))
    chevron.addLine(to: CGPoint(x: 372, y: 360))
    chevron.addLine(to: CGPoint(x: 236, y: 474))
    ctx.addPath(chevron)
    ctx.setStrokeColor(color(0xF4F6F8))
    ctx.setLineWidth(62)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    let cursor = CGPath(roundedRect: CGRect(x: 420, y: 444, width: 196, height: 60), cornerWidth: 30, cornerHeight: 30, transform: nil)
    ctx.addPath(cursor)
    ctx.setFillColor(color(0x7FD8EE))
    ctx.fillPath()

    ctx.restoreGState()
    guard let image = ctx.makeImage() else { fail("couldn't draw the icon") }
    return image
}

/// A square image in the icon's shape (centre-cropped to a square first).
func shape(_ path: String) -> CGImage {
    guard let source = NSImage(contentsOfFile: path),
          let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fail("can't read \(path)") }
    let side = min(image.width, image.height)
    let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
    guard let square = image.cropping(to: crop) else { fail("can't crop \(path)") }

    let ctx = makeContext()
    let outline = squircle(body, radius: cornerRadius, smoothing: smoothing)
    drawShadow(ctx, outline)
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    // Undo the flip for the image itself, which CoreGraphics draws y-up.
    ctx.translateBy(x: 0, y: body.maxY + body.minY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(square, in: body)
    ctx.restoreGState()
    guard let result = ctx.makeImage() else { fail("couldn't shape the icon") }
    return result
}

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: canvas, height: canvas)
    guard let data = rep.representation(using: .png, properties: [:]) else { fail("couldn't encode PNG") }
    do { try data.write(to: URL(fileURLWithPath: path)) } catch { fail("can't write \(path): \(error)") }
}

let args = CommandLine.arguments
switch (args.count, args.count > 1 ? args[1] : "") {
case (3, "design"):
    writePNG(design(), to: args[2])
case (4, "shape"):
    writePNG(shape(args[2]), to: args[3])
default:
    fail("usage: icon.swift design OUT.png | icon.swift shape IN.png OUT.png")
}
