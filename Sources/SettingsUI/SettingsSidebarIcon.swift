import AppKit
import SwiftUI

/// Draws the settings sidebar icons as pre-coloured, non-template images.
///
/// macOS 27 changed two things about sidebar icons compared with 26, and both
/// are reproduced here from measurements of the reference screenshots:
///
/// * an unselected icon used to be the label colour (black on light, white on
///   dark); 27 dims it to a secondary grey,
/// * a selected icon used to invert to white with the row text; 27 keeps it in
///   the unselected colour.
///
/// Baking the colour into the bitmap also means the system's sidebar tinting
/// (accent colour, vibrancy, selection background) cannot repaint the icon.
enum SettingsSidebarIconRenderer {
    /// `labelColor` as macOS 26 painted it next to the 13pt sidebar text.
    static let lightLabelColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let darkLabelColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// A selected row in an active window inverts its icon to pure white, the
    /// macOS 26 behaviour that 27 dropped.
    static let selectedColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// Point size the sidebar used when the system still drew these symbols.
    static let pointSize: CGFloat = 13

    /// The label uses the same size as the icons beside it.
    static let labelPointSize: CGFloat = 13

    private static var cache: [String: NSImage] = [:]

    /// `emphasized` means "selected row inside the key window"; an unfocused
    /// window keeps the label colour, exactly like macOS 26.
    static func color(appearance: ColorScheme, emphasized: Bool) -> NSColor {
        if emphasized { return selectedColor }
        return appearance == .dark ? darkLabelColor : lightLabelColor
    }

    /// Whether a row draws with the inverted (white) content: the selected row,
    /// in the key window, while the sidebar list itself holds focus.
    ///
    /// That last condition matters because the capsule's emphasis follows the
    /// *list's* focus, not just the window's key state: clicking a text field in
    /// the detail pane greys the capsule while the window stays key. Tying the
    /// content to the window alone put white glyphs on a grey capsule.
    static func isEmphasized(
        isSelected: Bool,
        controlActiveState: ControlActiveState,
        sidebarFocused: Bool
    ) -> Bool {
        isSelected && controlActiveState == .key && sidebarFocused
    }

    /// The icon for one state, rendered once and cached. Only ever called from
    /// `body` evaluation, so the cache stays on the main thread.
    static func image(symbol: String, appearance: ColorScheme, emphasized: Bool) -> NSImage? {
        let label = "\(symbol)|\(appearance == .dark ? "dark" : "light")|\(emphasized ? "emphasized" : "plain")"
        if let cached = cache[label] {
            return cached
        }
        guard let image = render(symbol: symbol, color: color(appearance: appearance, emphasized: emphasized)) else {
            return nil
        }
        cache[label] = image
        return image
    }

    private static func render(symbol: String, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return nil
        }
        let canvas = NSSize(width: ceil(base.size.width), height: ceil(base.size.height))
        let image = NSImage(size: canvas)
        for scale in [1.0, 2.0] as [CGFloat] {
            guard let representation = bitmapRepresentation(canvas: canvas, scale: scale),
                  let context = NSGraphicsContext(bitmapImageRep: representation) else {
                continue
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let rect = NSRect(origin: .zero, size: canvas)
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            // `sourceAtop` only touches the symbol's own pixels, so the alpha
            // channel of the rendering stays exactly the symbol's shape.
            color.set()
            rect.fill(using: .sourceAtop)
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(representation)
        }
        guard !image.representations.isEmpty else { return nil }
        // The point of this type: never let the system treat the icon as a
        // tintable mask.
        image.isTemplate = false
        return image
    }

    private static func bitmapRepresentation(canvas: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((canvas.width * scale).rounded()),
            pixelsHigh: Int((canvas.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        representation.size = canvas
        return representation
    }
}

/// The settings sidebar icon: an SF Symbol painted with the macOS 26 colours,
/// so neither the system's sidebar tinting nor the macOS 27 icon change can
/// alter it.
struct SettingsSidebarIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState

    let symbol: String
    /// Whether this row is the selected one.
    let isSelected: Bool
    /// Whether the sidebar list holds focus, which is what decides the
    /// capsule's emphasis.
    let sidebarFocused: Bool

    var body: some View {
        let emphasized = SettingsSidebarIconRenderer.isEmphasized(
            isSelected: isSelected,
            controlActiveState: controlActiveState,
            sidebarFocused: sidebarFocused
        )
        if let image = SettingsSidebarIconRenderer.image(
            symbol: symbol,
            appearance: colorScheme,
            emphasized: emphasized
        ) {
            Image(nsImage: image)
                .renderingMode(.original)
        } else {
            Image(systemName: symbol)
        }
    }
}

/// The settings sidebar label, painted with the same macOS 26 colours as the
/// icon beside it.
///
/// macOS 27 dims sidebar labels to a secondary grey whenever the list is not
/// emphasised, which leaves black icons next to washed-out text, and it renders
/// the selected row with a heavier face than 26 did. Pinning both the colour
/// and the weight keeps the row looking like the 26 reference.
struct SettingsSidebarLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState

    let title: String
    /// Whether this row is the selected one.
    let isSelected: Bool
    /// Whether the sidebar list holds focus, which is what decides the
    /// capsule's emphasis.
    let sidebarFocused: Bool

    var body: some View {
        let emphasized = SettingsSidebarIconRenderer.isEmphasized(
            isSelected: isSelected,
            controlActiveState: controlActiveState,
            sidebarFocused: sidebarFocused
        )
        Text(title)
            .font(.system(size: SettingsSidebarIconRenderer.labelPointSize, weight: .regular))
            .foregroundStyle(Color(nsColor: SettingsSidebarIconRenderer.color(
                appearance: colorScheme,
                emphasized: emphasized
            )))
    }
}
