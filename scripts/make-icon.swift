// Renders Resources/AppIcon.icns: sharp color blobs on the left, the same scene
// frosted behind a glass pane on the right. Run: swift scripts/make-icon.swift
import AppKit
import CoreImage

let size: CGFloat = 1024
let inset: CGFloat = 100            // macOS icon grid: 824pt body in a 1024 canvas
let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = 185

func render() -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Scene: deep background + bright blobs.
    let scene = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bg = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 0.10, green: 0.11, blue: 0.22, alpha: 1),
        CGColor(srgbRed: 0.05, green: 0.06, blue: 0.12, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    scene.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    let blobs: [(CGFloat, CGFloat, CGFloat, CGColor)] = [
        (330, 640, 170, CGColor(srgbRed: 1.00, green: 0.55, blue: 0.25, alpha: 1)),
        (560, 380, 190, CGColor(srgbRed: 0.98, green: 0.30, blue: 0.55, alpha: 1)),
        (700, 700, 150, CGColor(srgbRed: 0.30, green: 0.65, blue: 1.00, alpha: 1)),
        (280, 300, 110, CGColor(srgbRed: 0.45, green: 0.95, blue: 0.75, alpha: 1)),
    ]
    for (x, y, r, c) in blobs {
        scene.setFillColor(c)
        scene.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    let sharp = scene.makeImage()!

    let ci = CIImage(cgImage: sharp)
    let blurred = ci.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 70])
        .cropped(to: ci.extent)
    let blurredCG = CIContext().createCGImage(blurred, from: ci.extent)!

    // Clip everything to the icon body.
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.draw(sharp, in: CGRect(x: 0, y: 0, width: size, height: size))

    // Glass pane.
    let pane = CGRect(x: 430, y: 200, width: 440, height: 620)
    let panePath = CGPath(roundedRect: pane, cornerWidth: 70, cornerHeight: 70, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(panePath)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(panePath)
    ctx.clip()
    ctx.draw(blurredCG, in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.16))
    ctx.fill(pane)
    ctx.restoreGState()
    ctx.addPath(panePath)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
    ctx.setLineWidth(4)
    ctx.strokePath()

    return ctx.makeImage()!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let master = render()
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
print("wrote \(out.path)")
