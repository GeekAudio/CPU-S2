//  gen_icon.swift —— CPU-S2 图标生成器（macOS 26 玻璃质感版）
//
//  参考原版 CPU-S（/Applications/CPU-S.app）的识别点：一块「面板 + 频率波形线」。
//  那条折线是它的招牌，v2.2.0 换成四根柱子之后反而丢了辨识度。
//
//  这一版回到波形，但按 macOS 26（Tahoe / Liquid Glass）的语言重画：
//    · 圆角方块底：蓝色双段渐变 + 左上柔光 + 底部压暗，边缘一圈白色内描边（玻璃厚度）
//    · 面板：半透明白玻璃，竖向渐变 + 亮边，浮在底板上
//    · 波形：白色圆头折线 + 微弱外发光；最高点换成橙色圆点并带光晕（= 睿频峰值）
//    · 16/32 px 走简化版：去掉面板，线加粗、点放大，避免糊成一团
//
//  用法：swiftc -O gen_icon.swift -o /tmp/gen_icon && /tmp/gen_icon <输出目录>

import AppKit
import CoreGraphics

func hex(_ s: String, _ a: CGFloat = 1) -> CGColor {
    var v: UInt64 = 0
    Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                   green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255,
                   alpha: a)
}

func render(_ S: CGFloat) -> Data? {
    let px = Int(S)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let k = S / 1024.0
    let small = S <= 32

    // 设计坐标（左上原点）→ CG 坐标（左下原点）
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * k, y: S - (y + h) * k, width: w * k, height: h * k)
    }
    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: rect(x, y, w, h), cornerWidth: r * k, cornerHeight: r * k, transform: nil)
    }

    // ── 底板
    let inset: CGFloat = 100
    let tile = rect(inset, inset, 1024 - inset * 2, 1024 - inset * 2)
    let tileR = (1024 - inset * 2) * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tileR * k, cornerHeight: tileR * k, transform: nil)

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    let base = CGGradient(colorsSpace: cs,
                          colors: [hex("#5AAAF4"), hex("#2F7ED2"), hex("#1B5FAE")] as CFArray,
                          locations: [0, 0.52, 1])!
    ctx.drawLinearGradient(base,
                           start: CGPoint(x: tile.midX, y: tile.maxY),
                           end: CGPoint(x: tile.midX, y: tile.minY),
                           options: [])

    // 左上柔光
    let glowCenter = CGPoint(x: tile.minX + tile.width * 0.28, y: tile.maxY - tile.height * 0.20)
    let glow = CGGradient(colorsSpace: cs,
                          colors: [hex("#FFFFFF", 0.22), hex("#FFFFFF", 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: glowCenter, startRadius: 0,
                           endCenter: glowCenter, endRadius: tile.width * 0.62,
                           options: [])

    // 底部压暗，制造玻璃厚底
    let bottom = CGGradient(colorsSpace: cs,
                            colors: [hex("#0A2E5C", 0), hex("#0A2E5C", 0.28)] as CFArray,
                            locations: [0, 1])!
    ctx.drawLinearGradient(bottom,
                           start: CGPoint(x: tile.midX, y: tile.midY),
                           end: CGPoint(x: tile.midX, y: tile.minY),
                           options: [])

    // ── 玻璃面板（小尺寸不要，会糊）
    if !small {
        let px0: CGFloat = 148
        let pw: CGFloat = 1024 - px0 * 2
        let panel = rr(px0, px0, pw, pw, 132)
        ctx.saveGState()
        ctx.addPath(panel)
        ctx.clip()
        let glass = CGGradient(colorsSpace: cs,
                               colors: [hex("#FFFFFF", 0.26), hex("#FFFFFF", 0.10)] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(glass,
                               start: CGPoint(x: 0, y: S - px0 * k),
                               end: CGPoint(x: 0, y: S - (px0 + pw) * k),
                               options: [])
        ctx.restoreGState()

        ctx.addPath(panel)
        ctx.setStrokeColor(hex("#FFFFFF", 0.30))
        ctx.setLineWidth(3 * k)
        ctx.strokePath()
    }

    // ── 波形：形状照原版那条折线（平 → 小峰 → 大峰 → 次峰 → 平）
    let pts: [(CGFloat, CGFloat)] = small
        ? [(0.00, 0.66), (0.20, 0.66), (0.36, 0.36), (0.52, 0.66), (0.64, 0.22), (0.80, 0.62), (1.00, 0.62)]
        : [(0.00, 0.70), (0.13, 0.70), (0.23, 0.50), (0.32, 0.70), (0.44, 0.70),
           (0.55, 0.20), (0.64, 0.62), (0.72, 0.44), (0.81, 0.70), (1.00, 0.70)]

    let ax: CGFloat = small ? 150 : 208
    let aw: CGFloat = (1024 - ax) - ax
    let ay: CGFloat = small ? 170 : 222
    let ah: CGFloat = (1024 - ay) - ay

    func pt(_ i: Int) -> CGPoint {
        CGPoint(x: (ax + aw * pts[i].0) * k, y: S - (ay + ah * pts[i].1) * k)
    }

    let line = CGMutablePath()
    line.move(to: pt(0))
    for i in 1..<pts.count { line.addLine(to: pt(i)) }

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26 * k, color: hex("#CFE6FF", 0.55))
    ctx.addPath(line)
    ctx.setStrokeColor(hex("#FFFFFF"))
    ctx.setLineWidth((small ? 46 : 30) * k)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // ── 峰值段点亮：最高峰左右两段改成橙色，并带一点橙色外发光
    //（原来这里是「白色折线 + 橙色圆点」，缩到 32px 会读成一个火柴人，改成段着色就没有这个问题）
    let peakIdx = small ? 4 : 5
    let peak = CGMutablePath()
    peak.move(to: pt(peakIdx - 1))
    peak.addLine(to: pt(peakIdx))
    peak.addLine(to: pt(peakIdx + 1))

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18 * k, color: hex("#FFB65C", 0.62))
    ctx.addPath(peak)
    ctx.setStrokeColor(hex("#FFAE4E"))
    ctx.setLineWidth((small ? 46 : 30) * k)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState()

    // 整块图标的玻璃内描边
    ctx.addPath(tilePath)
    ctx.setStrokeColor(hex("#FFFFFF", 0.26))
    ctx.setLineWidth(4 * k)
    ctx.strokePath()

    guard let img = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: S, height: S)
    return rep.representation(using: .png, properties: [:])
}

// ── 输出 iconset

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in specs {
    guard let data = render(size) else { print("渲染失败 \(name)"); exit(1) }
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    print("  \(name)  \(Int(size))px")
}
print("OK -> \(outDir)")
