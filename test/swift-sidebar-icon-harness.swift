import AppKit
import Foundation
import SwiftUI

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

/// Verifies the macOS 26 colours the sidebar icons must reproduce: label colour
/// when plain, pure white while an emphasised (key-window) row is selected, and
/// never a template image the system could tint.
@main
struct SidebarIconHarness {
    struct Raster {
        let pixels: [UInt8]

        /// The most opaque pixel: an anti-aliased edge blends, the core does not.
        var coreColour: (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            var best: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
            for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > best.3 {
                best = (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
            }
            return best
        }
    }

    static func main() {
        let symbols = ["gearshape", "shippingbox", "puzzlepiece.extension", "info.circle"]
        // Measured from the macOS 26 reference screenshots.
        let expected: [String: (red: UInt8, green: UInt8, blue: UInt8)] = [
            "light|plain": (0, 0, 0),
            "light|emphasized": (255, 255, 255),
            "dark|plain": (255, 255, 255),
            "dark|emphasized": (255, 255, 255),
        ]
        var signatures: Set<Int> = []

        for symbol in symbols {
            var rasters: [String: Raster] = [:]
            var symbolSignatures: Set<Int> = []
            for appearance in [ColorScheme.light, ColorScheme.dark] {
                for emphasized in [false, true] {
                    let appearanceLabel = appearance == .dark ? "dark" : "light"
                    let key = "\(appearanceLabel)|\(emphasized ? "emphasized" : "plain")"
                    guard let colour = expected[key] else {
                        require(false, "no pinned colour for \(key)")
                        continue
                    }
                    require(
                        matches(
                            components(of: SettingsSidebarIconRenderer.color(appearance: appearance, emphasized: emphasized)),
                            colour
                        ),
                        "\(key) colour constant no longer matches the pinned value \(colour)"
                    )
                    guard let image = SettingsSidebarIconRenderer.image(
                        symbol: symbol,
                        appearance: appearance,
                        emphasized: emphasized
                    ) else {
                        require(false, "\(symbol)/\(key) did not render")
                        continue
                    }
                    require(!image.isTemplate, "\(symbol)/\(key) must not be a template image, or the system would tint it")
                    require(image.representations.count >= 2, "\(symbol)/\(key) should carry 1x and 2x representations")

                    guard let raster = raster(of: image) else {
                        require(false, "\(symbol)/\(key) has no raster representation")
                        continue
                    }
                    let core = raster.coreColour
                    require(core.alpha == 255, "\(symbol)/\(key) core pixel is not opaque (a=\(core.alpha))")
                    require(
                        core.red == colour.red && core.green == colour.green && core.blue == colour.blue,
                        "\(symbol)/\(key) core colour (\(core.red),\(core.green),\(core.blue)) != \(colour)"
                    )
                    rasters[key] = raster
                    let signature = raster.pixels.reduce(0) { ($0 &* 31) &+ Int($1) }
                    symbolSignatures.insert(signature)
                    signatures.insert(signature)
                }
            }

            // The macOS 26 behaviour macOS 27 dropped: light-mode selection
            // inverts the icon to white.
            if let plain = rasters["light|plain"], let emphasized = rasters["light|emphasized"] {
                require(plain.pixels != emphasized.pixels, "\(symbol) light icons must invert when emphasised")
            }
            // Dark mode is white in both states, light mode has two colours.
            require(symbolSignatures.count >= 2, "\(symbol) should render distinct bitmaps for its states")
        }

        require(
            signatures.count >= symbols.count,
            "every symbol should rasterize to a distinct image (got \(signatures.count))"
        )
        // The system's own symbol image is tintable; ours must not be.
        let systemSymbol = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        require(systemSymbol?.isTemplate == true, "expected the raw system symbol to be a template image")

        print("swift sidebar icon harness passed")
    }

    private static func components(of colour: NSColor) -> (red: UInt8, green: UInt8, blue: UInt8) {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (
            UInt8((srgb.redComponent * 255).rounded()),
            UInt8((srgb.greenComponent * 255).rounded()),
            UInt8((srgb.blueComponent * 255).rounded())
        )
    }

    private static func matches(
        _ pixel: (red: UInt8, green: UInt8, blue: UInt8),
        _ expected: (red: UInt8, green: UInt8, blue: UInt8)
    ) -> Bool {
        pixel.red == expected.red && pixel.green == expected.green && pixel.blue == expected.blue
    }

    private static func raster(of image: NSImage) -> Raster? {
        guard let representation = image.representations.compactMap({ $0 as? NSBitmapImageRep }).last,
              let cgImage = representation.cgImage else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Raster(pixels: pixels)
    }
}
