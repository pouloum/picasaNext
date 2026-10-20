import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The "Phoenix rising" app icon, drawn with Core Graphics from the same paths as the design
/// (320-unit artboard). Used for the Dock icon at runtime and to generate AppIcon.icns at build time
/// (`PicasaNext --write-iconset DIR`).
enum AppIcon {
    static func color(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Mini SVG path reader for the M/L/C/Z commands used by the design.
    static func path(_ d: String) -> CGPath {
        let p = CGMutablePath()
        var nums: [CGFloat] = []
        var cmd: Character = "M"
        func flush() {
            switch cmd {
            case "M" where nums.count >= 2: p.move(to: CGPoint(x: nums[0], y: nums[1]))
            case "L" where nums.count >= 2: p.addLine(to: CGPoint(x: nums[0], y: nums[1]))
            case "C" where nums.count >= 6:
                p.addCurve(to: CGPoint(x: nums[4], y: nums[5]), control1: CGPoint(x: nums[0], y: nums[1]),
                           control2: CGPoint(x: nums[2], y: nums[3]))
            default: break
            }
            nums = []
        }
        var token = ""
        for ch in d + " " {
            if ch.isLetter {
                if !token.isEmpty { nums.append(CGFloat(Double(token) ?? 0)); token = "" }
                flush()
                if ch == "Z" { p.closeSubpath() }
                cmd = ch
            } else if ch == " " || ch == "," {
                if !token.isEmpty { nums.append(CGFloat(Double(token) ?? 0)); token = "" }
            } else {
                token.append(ch)
            }
        }
        flush()
        return p
    }

    static let wing: [(String, UInt32)] = [
        ("M160 168 C132 150 100 112 78 62 C112 88 140 118 160 152 Z", 0xFFD166),
        ("M160 176 C126 168 90 140 62 102 C102 120 134 142 160 164 Z", 0xF6A23A),
        ("M160 184 C124 186 90 172 64 148 C102 158 134 166 160 174 Z", 0xE3562D),
    ]

    /// Draws the icon into `ctx` (y-down artboard units mapped to a `size`×`size` square, macOS icon grid margins).
    static func draw(in ctx: CGContext, size: CGFloat) {
        ctx.saveGState()
        // Apple's grid: the rounded square spans 824/1024 of the canvas, centred.
        let k = size * (824.0 / 1024.0) / 304.0
        let offset = size * (100.0 / 1024.0) - 8 * k
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: offset, y: offset)
        ctx.scaleBy(x: k, y: k)

        func fill(_ d: String, _ c: UInt32) { ctx.addPath(path(d)); ctx.setFillColor(color(c)); ctx.fillPath() }

        ctx.addPath(CGPath(roundedRect: CGRect(x: 8, y: 8, width: 304, height: 304), cornerWidth: 72, cornerHeight: 72, transform: nil))
        ctx.setFillColor(color(0x3A1838)); ctx.fillPath()
        for (d, c) in wing { fill(d, c) }
        ctx.saveGState()
        ctx.translateBy(x: 320, y: 0); ctx.scaleBy(x: -1, y: 1) // mirrored wing
        for (d, c) in wing { fill(d, c) }
        ctx.restoreGState()
        fill("M160 118 C174 140 174 196 160 236 C146 196 146 140 160 118 Z", 0xFBF1E4) // body
        ctx.addEllipse(in: CGRect(x: 147, y: 93, width: 26, height: 26)); ctx.setFillColor(color(0xFBF1E4)); ctx.fillPath() // head
        fill("M160 100 L176 104 L160 110 Z", 0xF6A23A) // beak
        fill("M156 232 C146 250 134 264 118 276 C142 272 154 258 160 244 Z", 0xE3562D)
        fill("M164 232 C174 250 186 264 202 276 C178 272 166 258 160 244 Z", 0xE3562D)
        fill("M160 236 C154 254 156 272 160 290 C164 272 166 254 160 236 Z", 0xC93A3A)
        ctx.restoreGState()
    }

    static func image(size: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        draw(in: ctx, size: CGFloat(size))
        return ctx.makeImage()
    }

    /// Dock icon when running without an app bundle (swift run / bare executable).
    static var nsImage: NSImage? {
        image(size: 1024).map { NSImage(cgImage: $0, size: NSSize(width: 1024, height: 1024)) }
    }

    static func png(size: Int) -> Data? {
        guard let img = image(size: size) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Writes AppIcon.icns directly (no iconutil): 'icns' header, then one PNG per size, each tagged
    /// with its OSType (icp4/icp5 = 16/32, ic07…ic10 = 128…1024, ic11…ic14 = the @2x of 16…256).
    static func writeIcns(to url: URL) throws {
        let entries: [(String, Int)] = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64), ("ic07", 128),
                                        ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]
        func be32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).bigEndian) { Data($0) } }
        var body = Data()
        for (type, px) in entries {
            guard let png = png(size: px) else { throw CocoaError(.fileWriteUnknown) }
            body += Data(type.utf8) + be32(8 + png.count) + png
        }
        try (Data("icns".utf8) + be32(8 + body.count) + body).write(to: url)
    }

}
