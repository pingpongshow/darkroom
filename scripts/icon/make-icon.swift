import AppKit
import CoreGraphics

let size = 1024.0
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

// macOS icon grid: 824×824 body centred, corner radius ≈ 185, with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0, 0, 0, 0.45))
ctx.addPath(shape); ctx.setFillColor(color(0.08, 0.08, 0.09)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
// Background: near-black with a faint warm vertical gradient.
let bg = CGGradient(colorsSpace: cs, colors: [color(0.16, 0.15, 0.16), color(0.05, 0.05, 0.06)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Safelight glow behind the lens.
let glow = CGGradient(colorsSpace: cs, colors: [color(0.95, 0.12, 0.08, 0.55), color(0.6, 0.02, 0.02, 0.0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 430, options: [])

let center = CGPoint(x: 512, y: 512)
// Lens barrel ring.
let ringR = 300.0
ctx.setFillColor(color(0.11, 0.11, 0.12))
ctx.fillEllipse(in: CGRect(x: center.x - ringR, y: center.y - ringR, width: ringR * 2, height: ringR * 2))
let ringG = CGGradient(colorsSpace: cs, colors: [color(0.42, 0.42, 0.44), color(0.12, 0.12, 0.13)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - ringR, y: center.y - ringR, width: ringR * 2, height: ringR * 2))
ctx.addEllipse(in: CGRect(x: center.x - 262, y: center.y - 262, width: 524, height: 524))
ctx.clip(using: .evenOdd)
ctx.drawLinearGradient(ringG, start: CGPoint(x: 512, y: 812), end: CGPoint(x: 512, y: 212), options: [])
ctx.restoreGState()

// Aperture: six curved blades in safelight red, leaving a hexagonal opening.
let bladeR = 258.0, hole = 92.0, blades = 6
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - bladeR, y: center.y - bladeR, width: bladeR * 2, height: bladeR * 2))
ctx.clip()
for i in 0..<blades {
    let a = Double(i) / Double(blades) * 2 * .pi + .pi / 12
    let path = CGMutablePath()
    // A blade: from a point on the hexagonal hole out to the rim, swept by 70°.
    let p0 = CGPoint(x: center.x + cos(a) * hole, y: center.y + sin(a) * hole)
    let p1 = CGPoint(x: center.x + cos(a + .pi / 3) * hole, y: center.y + sin(a + .pi / 3) * hole)
    let rimA = a + .pi / 3 + 0.9
    let p2 = CGPoint(x: center.x + cos(rimA) * (bladeR + 40), y: center.y + sin(rimA) * (bladeR + 40))
    let p3 = CGPoint(x: center.x + cos(a + 0.9) * (bladeR + 40), y: center.y + sin(a + 0.9) * (bladeR + 40))
    path.move(to: p0); path.addLine(to: p1); path.addLine(to: p2); path.addLine(to: p3); path.closeSubpath()
    let shade = 0.78 + 0.22 * Double(i % 2)
    let g = CGGradient(colorsSpace: cs, colors: [color(0.93 * shade, 0.16 * shade, 0.12 * shade), color(0.45 * shade, 0.04, 0.04)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.drawRadialGradient(g, startCenter: center, startRadius: hole, endCenter: center, endRadius: bladeR, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.addPath(path); ctx.setStrokeColor(color(0.05, 0.0, 0.0, 0.55)); ctx.setLineWidth(5); ctx.strokePath()
}
ctx.restoreGState()
// Dark opening with a small highlight, like glass.
let holePath = CGMutablePath()
for i in 0..<blades {
    let a = Double(i) / Double(blades) * 2 * .pi + .pi / 12
    let p = CGPoint(x: center.x + cos(a) * hole, y: center.y + sin(a) * hole)
    i == 0 ? holePath.move(to: p) : holePath.addLine(to: p)
}
holePath.closeSubpath()
ctx.addPath(holePath); ctx.setFillColor(color(0.03, 0.02, 0.03)); ctx.fillPath()
ctx.setFillColor(color(1, 1, 1, 0.22))
ctx.fillEllipse(in: CGRect(x: center.x - 52, y: center.y + 18, width: 40, height: 26))
// Subtle top highlight on the body.
let shine = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.10), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 620), options: [])
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
