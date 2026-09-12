import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const settingsViewSource = fs.readFileSync(
  new URL("../Sources/SettingsUI/SettingsView.swift", import.meta.url),
  "utf8",
);
const iconSource = fs.readFileSync(
  new URL("../Sources/SettingsUI/SettingsSidebarIcon.swift", import.meta.url),
  "utf8",
);
const projectSource = fs.readFileSync(
  new URL("../DSH.xcodeproj/project.pbxproj", import.meta.url),
  "utf8",
);
const windowControllerSource = fs.readFileSync(
  new URL("../Sources/SettingsUI/SettingsWindowController.swift", import.meta.url),
  "utf8",
);

test("settings sidebar draws the SF Symbol with the macOS 26 colours", () => {
  assert.doesNotMatch(settingsViewSource, /Label\(panel\.navTitle, systemImage: panel\.icon\)/);
  assert.match(settingsViewSource, /SettingsSidebarLabel\(\s*title: panel\.navTitle,\s*isSelected: panel == currentPanel,\s*sidebarFocused: sidebarFocused\s*\)/);
  assert.match(settingsViewSource, /SettingsSidebarIcon\(\s*symbol: panel\.icon,\s*isSelected: panel == currentPanel,\s*sidebarFocused: sidebarFocused\s*\)/);
  // The sidebar list reports its own focus; the capsule's emphasis follows it.
  assert.match(settingsViewSource, /@FocusState private var sidebarFocused: Bool/);
  assert.match(settingsViewSource, /\.focused\(\$sidebarFocused\)/);
  // The four symbols from before the experiment stay in place.
  assert.match(settingsViewSource, /case \.general: return "gearshape"/);
  assert.match(settingsViewSource, /case \.versions: return "shippingbox"/);
  assert.match(settingsViewSource, /case \.plugins: return "puzzlepiece\.extension"/);
  assert.match(settingsViewSource, /case \.about: return "info\.circle"/);
});

test("sidebar labels pin the macOS 26 colour and weight", () => {
  // macOS 27 dims the label to a secondary grey when the list is not
  // emphasised, and renders the selected row heavier than 26 did.
  assert.match(iconSource, /struct SettingsSidebarLabel: View/);
  assert.match(iconSource, /\.font\(\.system\(size: SettingsSidebarIconRenderer\.labelPointSize, weight: \.regular\)\)/);
  assert.match(iconSource, /static let labelPointSize: CGFloat = 13/);
  assert.match(iconSource, /foregroundStyle\(Color\(nsColor: SettingsSidebarIconRenderer\.color\(/);
});

test("row colours follow the capsule's emphasis, not just the window's key state", () => {
  // Clicking a text field greys the capsule while the window stays key; the
  // content must fall back to the label colour instead of staying white.
  assert.match(
    iconSource,
    /static func isEmphasized\(\s*isSelected: Bool,\s*controlActiveState: ControlActiveState,\s*sidebarFocused: Bool\s*\) -> Bool/,
  );
  assert.match(iconSource, /isSelected && controlActiveState == \.key && sidebarFocused/);
  assert.match(iconSource, /let sidebarFocused: Bool/);
});

test("sidebar icons are non-template bitmaps that invert on an emphasised selection", () => {
  assert.match(iconSource, /image\.isTemplate = false/);
  assert.match(iconSource, /\.renderingMode\(\.original\)/);
  assert.match(iconSource, /rect\.fill\(using: \.sourceAtop\)/);
  // Measured macOS 26 values: label colour when plain, white when emphasised.
  assert.match(iconSource, /static let lightLabelColor = NSColor\(srgbRed: 0, green: 0, blue: 0, alpha: 1\)/);
  assert.match(iconSource, /static let darkLabelColor = NSColor\(srgbRed: 1, green: 1, blue: 1, alpha: 1\)/);
  assert.match(iconSource, /static let selectedColor = NSColor\(srgbRed: 1, green: 1, blue: 1, alpha: 1\)/);
  assert.match(iconSource, /if emphasized \{ return selectedColor \}/);
  // The inversion only applies while the window is key.
  assert.match(iconSource, /@Environment\(\\\.controlActiveState\) private var controlActiveState/);
  assert.match(iconSource, /SettingsSidebarIconRenderer\.isEmphasized\(/);
  // No dynamic system colours: they would reintroduce system-driven colour.
  assert.doesNotMatch(iconSource, /NSColor\.(labelColor|secondaryLabelColor|controlAccentColor|windowBackgroundColor)/);
});

test("Xcode target compiles the sidebar icon source and drops the Phosphor experiment", () => {
  assert.match(projectSource, /SettingsSidebarIcon\.swift in Sources/);
  assert.match(projectSource, /SettingsSidebarIcon\.swift \*\/ = \{isa = PBXFileReference/);
  // The bundled Phosphor font and its copy steps are gone again.
  assert.doesNotMatch(projectSource, /Phosphor/);
  assert.doesNotMatch(projectSource, /fonts\//);
  assert.equal(fs.existsSync(new URL("../assets/fonts", import.meta.url)), false);
  assert.equal(fs.existsSync(new URL("../Sources/SettingsUI/PhosphorIcon.swift", import.meta.url)), false);
});

test("settings window focuses the sidebar so the selected row stays emphasised", () => {
  // Clearing focus to the window itself left AppKit reporting
  // NSTableRowView.isEmphasized == false, which paints the capsule grey even
  // while the window is key.
  assert.match(windowControllerSource, /private func focusSidebar\(\)/);
  assert.match(windowControllerSource, /private static func sidebarList\(in window: NSWindow\) -> NSTableView\?/);
  assert.match(windowControllerSource, /window\.makeFirstResponder\(sidebar\)/);
  // Selecting a panel re-focuses the sidebar when its window is key.
  assert.match(windowControllerSource, /self\?\.focusSidebar\(\)/);
  assert.match(windowControllerSource, /guard let window, window\.isKeyWindow else \{ return \}/);

  const showBody = windowControllerSource.slice(
    windowControllerSource.indexOf("public func show()"),
    windowControllerSource.indexOf("public func updateTitle"),
  );
  assert.match(showBody, /focusSidebar\(\)/);
  assert.doesNotMatch(showBody, /makeFirstResponder\(nil\)/);
});
