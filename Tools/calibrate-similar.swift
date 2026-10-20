// Calibrates the "similar photos" threshold on your own pictures (Vision must run outside a sandbox).
// For each image listed in FILE (one path per line), compares the Vision print of the original with
// a recompressed copy, an 85 % crop and a brightened copy, and all originals with each other.
// Pick `picasa-cli similar --threshold T` with T between "different max" and "same photo min".
//   swift Tools/calibrate-similar.swift FILE

import Foundation; import ImageIO; import CoreGraphics; import Vision; import Accelerate
func load(_ p: String, _ px: Int) -> CGImage? {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: px] as CFDictionary)
}
func recompress(_ img: CGImage, q: Double) -> CGImage {
    let d = NSMutableData(); let dst = CGImageDestinationCreateWithData(d, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary); CGImageDestinationFinalize(dst)
    let s = CGImageSourceCreateWithData(d, nil)!; return CGImageSourceCreateImageAtIndex(s, 0, nil)!
}
func scaled(_ img: CGImage, _ k: Double) -> CGImage {
    let w = Int(Double(img.width) * k), h = Int(Double(img.height) * k)
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.interpolationQuality = .high; c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)); return c.makeImage()!
}
func brighter(_ img: CGImage) -> CGImage {
    let c = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.15)); c.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height)); return c.makeImage()!
}
func fprint(_ img: CGImage) -> [Float] {
    let r = VNGenerateImageFeaturePrintRequest(); try! VNImageRequestHandler(cgImage: img).perform([r])
    var v = r.results![0].data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    var n: Float = 0; vDSP_svesq(v, 1, &n, vDSP_Length(v.count)); n = sqrt(n); vDSP_vsdiv(v, 1, &n, &v, 1, vDSP_Length(v.count)); return v
}
func cos(_ a: [Float], _ b: [Float]) -> Float { var s: Float = 0; vDSP_dotpr(a, 1, b, 1, &s, vDSP_Length(a.count)); return s }
let paths = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n").map(String.init)
var originals: [[Float]] = []; var same: [(String, Float)] = []
for p in paths {
    guard let o = load(p, 1600) else { continue }
    let po = fprint(o); originals.append(po)
    let crop = o.cropping(to: CGRect(x: Double(o.width) * 0.075, y: Double(o.height) * 0.075, width: Double(o.width) * 0.85, height: Double(o.height) * 0.85))!
    same.append(("recompressed 700px q40", cos(po, fprint(recompress(scaled(o, 700.0 / Double(max(o.width, o.height))), q: 0.4)))))
    same.append(("crop 85%", cos(po, fprint(crop))))
    same.append(("brighter", cos(po, fprint(brighter(o)))))
}
for kind in ["recompressed 700px q40", "crop 85%", "brighter"] {
    let v = same.filter { $0.0 == kind }.map(\.1)
    print(String(format: "same photo, %-24@ min %.3f  mean %.3f", kind as NSString, v.min()!, v.reduce(0, +) / Float(v.count)))
}
var diff: [Float] = []
for i in 0..<originals.count { for j in (i+1)..<originals.count { diff.append(cos(originals[i], originals[j])) } }
diff.sort()
print(String(format: "different photos (%d pairs): max %.3f  p99 %.3f  median %.3f", diff.count, diff.last!, diff[Int(Double(diff.count) * 0.99)], diff[diff.count / 2]))
