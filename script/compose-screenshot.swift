// Places a window screenshot (with its shadow, from FOLIO_PREVIEW_SHADOW=1 script/preview.sh) on a
// desktop picture, for the README:
//   swift script/compose-screenshot.swift <window.png> <wallpaper> <out.jpg> [width]
// The wallpaper is scaled to fill and centred; the output is a JPEG `width` pixels wide (default 2400).
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: compose-screenshot.swift <window.png> <wallpaper> <out.jpg> [width]\n".data(using: .utf8)!)
    exit(2)
}

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return image
}

let window = load(args[1])
let wallpaper = load(args[2])
let outWidth = args.count > 4 ? Int(args[4]) ?? 2400 : 2400

// Canvas: the window plus a margin of 7% of its width on every side.
let margin = Double(window.width) * 0.07
let canvas = CGSize(width: Double(window.width) + 2 * margin, height: Double(window.height) + 2 * margin)
let scale = Double(outWidth) / canvas.width
let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.interpolationQuality = .high

// Wallpaper: aspect fill.
let fill = max(size.width / Double(wallpaper.width), size.height / Double(wallpaper.height))
let wallSize = CGSize(width: Double(wallpaper.width) * fill, height: Double(wallpaper.height) * fill)
context.draw(wallpaper, in: CGRect(x: (size.width - wallSize.width) / 2, y: (size.height - wallSize.height) / 2,
                                   width: wallSize.width, height: wallSize.height))

// Window, centred.
let windowRect = CGRect(x: margin * scale, y: margin * scale, width: Double(window.width) * scale, height: Double(window.height) * scale)
context.draw(window, in: windowRect)

let out = URL(fileURLWithPath: args[3])
let type = out.pathExtension.lowercased() == "png" ? UTType.png : UTType.jpeg
guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
CGImageDestinationFinalize(destination)
print(out.path)
