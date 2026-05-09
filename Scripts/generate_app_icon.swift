#!/usr/bin/env swift

import AppKit
import Foundation

let outputDirectory: URL
if CommandLine.arguments.count > 1 {
    outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
} else {
    outputDirectory = URL(
        fileURLWithPath: "DJIImporter/Assets.xcassets/AppIcon.appiconset",
        isDirectory: true
    )
}

let iconSizes = [
    ("camera-icon-16.png", 16),
    ("camera-icon-32.png", 32),
    ("camera-icon-64.png", 64),
    ("camera-icon-128.png", 128),
    ("camera-icon-256.png", 256),
    ("camera-icon-512.png", 512),
    ("camera-icon-1024.png", 1024),
]

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

for (filename, size) in iconSizes {
    try writeEmojiIcon(
        emoji: "📷",
        size: size,
        destination: outputDirectory.appendingPathComponent(filename)
    )
}

func writeEmojiIcon(emoji: String, size: Int, destination: URL) throws {
    let canvasSize = NSSize(width: size, height: size)
    let fontSize = CGFloat(size) * 0.76
    let font = NSFont(name: "Apple Color Emoji", size: fontSize)
        ?? NSFont.systemFont(ofSize: fontSize)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )

    guard let bitmap else {
        throw IconError.renderFailed(destination.path)
    }

    bitmap.size = canvasSize
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconError.renderFailed(destination.path)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    graphicsContext.cgContext.clear(CGRect(origin: .zero, size: canvasSize))

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
    ]
    let text = NSAttributedString(string: emoji, attributes: attributes)
    let textSize = text.size()
    let rect = NSRect(
        x: (canvasSize.width - textSize.width) / 2,
        y: (canvasSize.height - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.renderFailed(destination.path)
    }

    try png.write(to: destination)
}

enum IconError: LocalizedError {
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed(let path):
            return "Failed to render icon at \(path)"
        }
    }
}
