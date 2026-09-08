// IconGen.swift — Sona App Icon 生成器
// 设计：深灰亚克力圆角底板 + 波形→云朵渐变线（#FC3C44 → #FF9F0A，本地流向云端）
// 用法: swift IconGen.swift <output.png> <size>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3,
      let size = Int(args[2]), size > 0 else {
    FileHandle.standardError.write("用法: swift IconGen.swift <output.png> <size>\n".data(using: .utf8)!)
    exit(1)
}
let outPath = args[1]

let S = CGFloat(size)
let k = S / 1024.0 // 设计稿以 1024 为基准的缩放系数

// MARK: - 颜色

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let red    = rgba(252, 60, 68)    // #FC3C44 Apple Red
let amber  = rgba(255, 159, 10)   // #FF9F0A 云端琥珀
let midGlow = rgba(255, 110, 40)  // 渐变中点（用于光晕）

// MARK: - 画布

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// macOS 坐标系（原点左下），与设计直觉一致
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// MARK: - 1. 亚克力底板（圆角矩形 + 纵向渐变）

let radius = 229.0 * k // Big Sur 风格 ~22.37% 圆角比
let plate = CGPath(
    roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
    cornerWidth: radius, cornerHeight: radius, transform: nil
)

let bgColors = [rgba(42, 42, 46), rgba(28, 28, 31), rgba(20, 20, 22)] as CFArray
let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0])!
ctx.saveGState()
ctx.addPath(plate)
ctx.clip()
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: S),
    options: []
)

// 环境暖光：右下角极淡琥珀径向渐变，模拟云朵透出的光
let ambient = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgba(255, 159, 10, 0.14), rgba(255, 159, 10, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    ambient,
    startCenter: CGPoint(x: 760 * k, y: 560 * k), startRadius: 0,
    endCenter: CGPoint(x: 760 * k, y: 560 * k), endRadius: 520 * k,
    options: []
)
// 左上角极淡红光，呼应波形起点
let ambient2 = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgba(252, 60, 68, 0.10), rgba(252, 60, 68, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    ambient2,
    startCenter: CGPoint(x: 220 * k, y: 512 * k), startRadius: 0,
    endCenter: CGPoint(x: 220 * k, y: 512 * k), endRadius: 460 * k,
    options: []
)
ctx.restoreGState()

// 顶部内高光：0.5 描边的渐变亮边（上亮下透明）
ctx.saveGState()
ctx.addPath(plate)
ctx.clip()
let rim = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgba(255, 255, 255, 0.28), rgba(255, 255, 255, 0.0)] as CFArray,
    locations: [0, 1]
)!
let inset = 2.0 * k
let rimPath = CGPath(
    roundedRect: CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2),
    cornerWidth: radius - inset, cornerHeight: radius - inset, transform: nil
)
ctx.addPath(rimPath)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(rim, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: S / 2), options: [])
ctx.restoreGState()

// MARK: - 2. 波形 → 云朵 路径

let path = CGMutablePath()

// -- 波形：从左侧中带开始，3.2 个周期，振幅从 150 衰减到 60，末端上扬接入云朵
let waveStart = CGPoint(x: 118 * k, y: 512 * k)
let waveEndX = 600 * k
path.move(to: waveStart)
let samples = 240
for i in 1...samples {
    let t = CGFloat(i) / CGFloat(samples)
    let x = waveStart.x + (waveEndX - waveStart.x) * t
    let amp = (150 - 90 * t) * k
    let phase = t * CGFloat.pi * 2 * 3.2
    var y = 512 * k + sin(phase) * amp
    // 末端（最后 15%）平滑上扬至云朵起笔 y=424
    if t > 0.85 {
        let u = (t - 0.85) / 0.15
        let blend = u * u * (3 - 2 * u) // smoothstep
        y = y * (1 - blend) + 424 * k * blend
    }
    path.addLine(to: CGPoint(x: x, y: y))
}

// -- 云朵：一笔连续轮廓。波形上扬 → 左瓣 → 主瓣 → 右瓣 → 拖尾
let cp = { (x: CGFloat, y: CGFloat) in CGPoint(x: x * k, y: y * k) }

// 左瓣：从波形末端轻盈升起
path.addCurve(to: cp(676, 372), control1: cp(620, 410), control2: cp(650, 365))
// 主瓣：圆润隆起的核心
path.addCurve(to: cp(772, 350), control1: cp(710, 360), control2: cp(742, 352))
// 右瓣：稍小，保持视觉重心在主瓣
path.addCurve(to: cp(874, 396), control1: cp(812, 348), control2: cp(852, 360))
// 拖尾：自然回落，像声波消散
path.addCurve(to: cp(906, 608), control1: cp(920, 470), control2: cp(925, 545))

// MARK: - 3. 渐变描边 + 内发光

let lineWidth = 44.0 * k
let strokeRegion = path.copy(
    strokingWithWidth: lineWidth,
    lineCap: .round, lineJoin: .round, miterLimit: 10
)

// Pass 1: 光晕（低透明度 + 大模糊阴影）
ctx.saveGState()
ctx.addPath(plate)
ctx.clip()
ctx.setShadow(offset: .zero, blur: 46 * k, color: rgba(255, 130, 40, 0.55))
ctx.setFillColor(rgba(255, 110, 40, 0.32))
ctx.addPath(strokeRegion)
ctx.fillPath()
ctx.restoreGState()

// Pass 2: 渐变主线（红 → 琥珀，本地 → 云端）
ctx.saveGState()
ctx.addPath(plate)
ctx.clip()
ctx.addPath(strokeRegion)
ctx.clip()
let lineGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [red, rgba(255, 96, 48), amber] as CFArray,
    locations: [0.0, 0.5, 1.0]
)!
ctx.drawLinearGradient(
    lineGradient,
    start: CGPoint(x: 118 * k, y: 512 * k),
    end: CGPoint(x: 890 * k, y: 560 * k),
    options: []
)
ctx.restoreGState()

// MARK: - 4. 输出 PNG

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: outPath) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("PNG 写入失败: \(outPath)\n".data(using: .utf8)!)
    exit(1)
}
print("✅ \(outPath) (\(size)×\(size))")
