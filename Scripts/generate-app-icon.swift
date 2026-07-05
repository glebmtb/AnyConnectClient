#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let assetsURL = rootURL.appendingPathComponent("Assets", isDirectory: true)
let sourceURL = assetsURL.appendingPathComponent("AppIconSource.png")
let iconsetURL = assetsURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let previewURL = assetsURL.appendingPathComponent("AppIcon.png")
let icnsURL = assetsURL.appendingPathComponent("AppIcon.icns")

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    throw IconError.failedToReadSource(sourceURL.path)
}

func squareCropRect(for image: CGImage) -> CGRect {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let side = min(width, height)
    return CGRect(
        x: (width - side) / 2,
        y: (height - side) / 2,
        width: side,
        height: side
    )
}

func resizeIcon(_ image: CGImage, to size: Int) throws -> CGImage {
    let side = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.failedToCreateBitmap(size)
    }

    let cropRect = squareCropRect(for: image)
    guard let cropped = image.cropping(to: cropRect) else {
        throw IconError.failedToCropSource
    }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.clear(CGRect(x: 0, y: 0, width: side, height: side))
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))

    guard let resized = context.makeImage() else {
        throw IconError.failedToRender(size)
    }
    return resized
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw IconError.failedToCreatePNG(url.path)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError.failedToWritePNG(url.path)
    }
}

let iconFiles: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for file in iconFiles {
    try writePNG(
        try resizeIcon(sourceImage, to: file.size),
        to: iconsetURL.appendingPathComponent(file.name)
    )
}

try writePNG(try resizeIcon(sourceImage, to: 1024), to: previewURL)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns",
    iconsetURL.path,
    "-o", icnsURL.path
]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw IconError.iconutilFailed(process.terminationStatus)
}

print(icnsURL.path)

enum IconError: Error, CustomStringConvertible {
    case failedToReadSource(String)
    case failedToCreateBitmap(Int)
    case failedToCropSource
    case failedToRender(Int)
    case failedToCreatePNG(String)
    case failedToWritePNG(String)
    case iconutilFailed(Int32)

    var description: String {
        switch self {
        case .failedToReadSource(let path):
            "Failed to read source icon: \(path)"
        case .failedToCreateBitmap(let size):
            "Failed to create bitmap context for \(size)x\(size)."
        case .failedToCropSource:
            "Failed to crop source icon."
        case .failedToRender(let size):
            "Failed to render icon image for \(size)x\(size)."
        case .failedToCreatePNG(let path):
            "Failed to create PNG destination: \(path)"
        case .failedToWritePNG(let path):
            "Failed to write PNG: \(path)"
        case .iconutilFailed(let status):
            "iconutil failed with status \(status)."
        }
    }
}
