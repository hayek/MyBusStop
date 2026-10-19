#!/usr/bin/env swift
// Draws Apple TV's app icon and Top Shelf images from the same geometry as Icon.icon (three lines
// running into a station), which Icon Composer does not produce for tvOS.
//
// tvOS icons are layered for the focus parallax: the white ground at the back, the lines in the
// middle, the station in front. The Top Shelf banners add the wordmark.
//
//     swift scripts/tv-brand-assets.swift
//
// Writes BusBus/Assets.xcassets/App Icon & Top Shelf Image.brandassets.

import AppKit
import CoreText
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let brand = root.appending(path: "BusBus/Assets.xcassets/App Icon & Top Shelf Image.brandassets")

// MARK: Geometry (Icon.icon/Assets, on its 1024-point square)

let red = CGColor(red: 0xD3 / 255, green: 0x20 / 255, blue: 0x29 / 255, alpha: 1)
let amber = CGColor(red: 0xEF / 255, green: 0xA4 / 255, blue: 0x00 / 255, alpha: 1)
let teal = CGColor(red: 0x0E / 255, green: 0x7C / 255, blue: 0x86 / 255, alpha: 1)
let ink = CGColor(red: 0x14 / 255, green: 0x14 / 255, blue: 0x0F / 255, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

enum Layer { case back, middle, front, all }

/// The icon drawn into `rect` of a context whose y runs down: one design unit is rect.height / 1024,
/// the station centred on `stationX` (in units from the rect's left).
func drawMark(_ c: CGContext, in rect: CGRect, stationX: CGFloat, layer: Layer, rightEdge: CGFloat? = nil) {
    let u = rect.height / 1024
    func x(_ v: CGFloat) -> CGFloat { rect.minX + (stationX + v - 512) * u }
    func y(_ v: CGFloat) -> CGFloat { rect.minY + v * u }
    let right = rightEdge ?? rect.maxX + 80 * u
    let left = rect.minX - 80 * u

    if layer == .middle || layer == .all {
        c.setLineWidth(76 * u)
        c.setLineCap(.round)
        // Red: down from the top, turning right into the station's upper slot.
        let r = CGMutablePath()
        r.move(to: CGPoint(x: x(232), y: y(-60)))
        r.addLine(to: CGPoint(x: x(232), y: y(230)))
        r.addCurve(to: CGPoint(x: x(392), y: y(400)), control1: CGPoint(x: x(232), y: y(330)),
                   control2: CGPoint(x: x(292), y: y(400)))
        r.addLine(to: CGPoint(x: right, y: y(400)))
        c.addPath(r); c.setStrokeColor(red); c.strokePath()
        // Amber: straight through.
        c.move(to: CGPoint(x: left, y: y(512)))
        c.addLine(to: CGPoint(x: right, y: y(512)))
        c.setStrokeColor(amber); c.strokePath()
        // Teal: up from the bottom into the lower slot.
        let t = CGMutablePath()
        t.move(to: CGPoint(x: x(232), y: y(1084)))
        t.addLine(to: CGPoint(x: x(232), y: y(794)))
        t.addCurve(to: CGPoint(x: x(392), y: y(624)), control1: CGPoint(x: x(232), y: y(694)),
                   control2: CGPoint(x: x(292), y: y(624)))
        t.addLine(to: CGPoint(x: right, y: y(624)))
        c.addPath(t); c.setStrokeColor(teal); c.strokePath()
    }
    if layer == .front || layer == .all {
        let pill = CGRect(x: x(440), y: y(318), width: 144 * u, height: 388 * u)
        let path = CGPath(roundedRect: pill, cornerWidth: 72 * u, cornerHeight: 72 * u, transform: nil)
        c.addPath(path); c.setFillColor(white); c.fillPath()
        c.addPath(path); c.setStrokeColor(ink); c.setLineWidth(36 * u); c.strokePath()
    }
}

// MARK: Rendering

func png(width: Int, height: Int, opaque: Bool, draw: (CGContext) -> Void) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: info)!
    // Flip so y runs down, as the SVGs do.
    c.translateBy(x: 0, y: CGFloat(height))
    c.scaleBy(x: 1, y: -1)
    draw(c)
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

func json(_ object: Any, to url: URL) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    write(data, to: url)
}

let info: [String: Any] = ["author": "xcode", "version": 1]

/// One layered icon. The mark is scaled to sit inside the safe zone the system crops and tilts.
func imageStack(named name: String, size: CGSize, scales: [Int]) {
    let stack = brand.appending(path: "\(name).imagestack")
    let layers: [(String, Layer)] = [("Front", .front), ("Middle", .middle), ("Back", .back)]
    json(["info": info, "layers": layers.map { ["filename": "\($0.0).imagestacklayer"] }],
         to: stack.appending(path: "Contents.json"))
    for (layerName, layer) in layers {
        let folder = stack.appending(path: "\(layerName).imagestacklayer")
        json(["info": info], to: folder.appending(path: "Contents.json"))
        var images: [[String: String]] = []
        for scale in scales {
            let w = Int(size.width) * scale, h = Int(size.height) * scale
            let file = "\(layerName)@\(scale)x.png"
            let data = png(width: w, height: h, opaque: layer == .back) { c in
                if layer == .back {
                    c.setFillColor(white); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
                } else {
                    // The mark a little inside the height, so the tilt never crops the station.
                    let markHeight = CGFloat(h) * 0.9
                    let rect = CGRect(x: 0, y: (CGFloat(h) - markHeight) / 2, width: CGFloat(w), height: markHeight)
                    let unitsWide = CGFloat(w) / (markHeight / 1024)
                    drawMark(c, in: rect, stationX: unitsWide / 2, layer: layer)
                }
            }
            write(data, to: folder.appending(path: "Content.imageset/\(file)"))
            images.append(["idiom": "tv", "scale": "\(scale)x", "filename": file])
        }
        json(["images": images, "info": info], to: folder.appending(path: "Content.imageset/Contents.json"))
    }
}

/// A Top Shelf banner: the name and the mark side by side in the middle, on white.
func topShelf(named name: String, size: CGSize) {
    let folder = brand.appending(path: "\(name).imageset")
    var images: [[String: String]] = []
    for scale in [1, 2] {
        let w = Int(size.width) * scale, h = Int(size.height) * scale
        let file = "\(name.replacingOccurrences(of: " ", with: ""))@\(scale)x.png"
        let data = png(width: w, height: h, opaque: true) { c in
            c.setFillColor(white); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let markHeight = CGFloat(h) * 0.86
            let rect = CGRect(x: 0, y: (CGFloat(h) - markHeight) / 2, width: CGFloat(w), height: markHeight)
            let unit = markHeight / 1024
            let unitsWide = CGFloat(w) / unit
            // tvOS fills the whole screen with the shelf, scaling the banner to the screen's height
            // and cropping its sides: only the middle 55% or so of the width shows. The wordmark
            // and the station both sit inside that; the lines run on to the edges.
            drawMark(c, in: rect, stationX: unitsWide * 0.64, layer: .all)
            drawWordmark(c, in: CGRect(x: CGFloat(w) * 0.26, y: 0, width: CGFloat(w) * 0.3, height: CGFloat(h)),
                         size: CGFloat(h) * 0.13)
        }
        write(data, to: folder.appending(path: file))
        images.append(["idiom": "tv", "scale": "\(scale)x", "filename": file])
    }
    json(["images": images, "info": info], to: folder.appending(path: "Contents.json"))
}

func registerArchivo() {
    let url = root.appending(path: "BusBus/Resources/Fonts/Archivo-Black.ttf")
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}

/// "MY BUS / STOP" in Archivo Black, on the banner's left, over a white panel that hides the
/// amber line behind it.
func drawWordmark(_ c: CGContext, in rect: CGRect, size: CGFloat) {
    let font = CTFontCreateWithName("Archivo-Black" as CFString, size, nil)
    let lines = ["MY BUS", "STOP"]
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
        .kern: -size * 0.015,
    ]
    let lineHeight = size * 1.0
    let blockHeight = lineHeight * CGFloat(lines.count)
    let widths = lines.map { CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
        NSAttributedString(string: $0, attributes: attributes)), nil, nil, nil) }
    let panel = CGRect(x: rect.minX - size * 0.4, y: rect.midY - blockHeight / 2 - size * 0.35,
                       width: CGFloat(widths.max() ?? 0) + size * 0.8, height: blockHeight + size * 0.7)
    c.setFillColor(white)
    c.addPath(CGPath(roundedRect: panel, cornerWidth: size * 0.3, cornerHeight: size * 0.3, transform: nil))
    c.fillPath()
    c.saveGState()
    // Core Text draws with y up.
    c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    for (index, text) in lines.enumerated() {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let baseline = rect.midY - blockHeight / 2 + lineHeight * CGFloat(index + 1) - size * 0.2
        c.textPosition = CGPoint(x: rect.minX, y: baseline)
        CTLineDraw(line, c)
    }
    c.restoreGState()
}

registerArchivo()
try? FileManager.default.removeItem(at: brand)
imageStack(named: "App Icon - App Store", size: CGSize(width: 1280, height: 768), scales: [1])
imageStack(named: "App Icon", size: CGSize(width: 400, height: 240), scales: [1, 2])
topShelf(named: "Top Shelf Image", size: CGSize(width: 1920, height: 720))
topShelf(named: "Top Shelf Image Wide", size: CGSize(width: 2320, height: 720))
json(["info": info, "assets": [
    ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
    ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
    ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
    ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
]], to: brand.appending(path: "Contents.json"))
print("wrote \(brand.path)")
