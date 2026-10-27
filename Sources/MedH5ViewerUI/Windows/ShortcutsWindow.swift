import AppKit
import SwiftUI
import Observation

/// One shortcut: what it does, its keys or gesture, and where it lives.
struct ShortcutEntry: Identifiable, Hashable {
    var title: String
    var keys: String
    /// The submenu path, or what the tool does.
    var detail: String?
    var id: String { "\(title)|\(keys)" }
}

struct ShortcutSection: Identifiable, Hashable {
    var title: String
    var entries: [ShortcutEntry]
    var id: String { title }
}

/// Every shortcut of the app, built from what defines it so the list stays
/// true: the main menu's key equivalents (walked at run time), what each
/// tool does (APP_DESIGN's tools table; a test holds the two together), and
/// the pointer and keys of the views (MedH5Render's SliceNavigation and
/// VolumeNavigation).
enum ShortcutCatalog {
    /// What each tool does: the "Does" column of the tools table in
    /// docs/APP_DESIGN.md.
    static let toolDescriptions: [ViewerTool: String] = [
        .navigate: "click sets the crosshair; drag pans with ⌥, zooms with ⌃, windows with ⇧",
        .windowLevel: "drag horizontally for width, vertically for level",
        .pan: "drag pans the view",
        .zoom: "drag zooms about where the drag began",
        .ruler: "distances in mm, angles in degrees, stored as measurements",
        .angle: "distances in mm, angles in degrees, stored as measurements",
        .roi: "ellipse or rectangle: area, mean, SD, min, max in physical units",
        .brush: "paint the active class; radius in mm ([ and ]); 2-D disc or 3-D sphere; paint policy; optional intensity range",
        .eraser: "paint the active class; radius in mm ([ and ]); 2-D disc or 3-D sphere; paint policy; optional intensity range",
        .fill: "2-D or 3-D flood fill / region growing from the clicked voxel",
        .box: "draw geometric annotations on the active annotation",
        .point: "draw geometric annotations on the active annotation",
        .polyline: "draw geometric annotations on the active annotation",
        .contour: "draw geometric annotations on the active annotation",
    ]

    /// The pointer and keys in the views.
    static let viewSections: [ShortcutSection] = [
        ShortcutSection(title: "Slice Views", entries: [
            ShortcutEntry(title: "Next or previous slice (one voxel of the base image)", keys: "Scroll  ·  ↑ ↓"),
            ShortcutEntry(title: "Ten slices", keys: "Page Up  ·  Page Down"),
            ShortcutEntry(title: "First or last slice", keys: "Home  ·  End"),
            ShortcutEntry(title: "Set the crosshair (Navigate)", keys: "Click"),
            ShortcutEntry(title: "Pan", keys: "⌥-drag  ·  middle drag"),
            ShortcutEntry(title: "Zoom about where the drag began", keys: "⌃-drag  ·  right drag"),
            ShortcutEntry(title: "Zoom", keys: "⌘-scroll  ·  pinch"),
            ShortcutEntry(title: "Window/level of the base image (width across, level up and down)", keys: "⇧-drag"),
        ]),
        ShortcutSection(title: "3-D View", entries: [
            ShortcutEntry(title: "Orbit", keys: "Drag"),
            ShortcutEntry(title: "Pan", keys: "⌥-drag  ·  ⇧-drag  ·  middle drag"),
            ShortcutEntry(title: "Zoom", keys: "Scroll  ·  pinch  ·  ⌃-drag"),
            ShortcutEntry(title: "Roll", keys: "Two-finger rotate"),
            ShortcutEntry(title: "Reset the camera", keys: "Double-click"),
        ]),
    ]

    /// The glyphs of a key equivalent, in the order menus show them
    /// (⌃ ⌥ ⇧ ⌘, then the key).
    static func glyphs(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var out = ""
        var mods = modifiers
        if key.count == 1, let c = key.first, c.isUppercase { mods.insert(.shift) }
        if mods.contains(.control) { out += "⌃" }
        if mods.contains(.option) { out += "⌥" }
        if mods.contains(.shift) { out += "⇧" }
        if mods.contains(.command) { out += "⌘" }
        return out + keyName(key)
    }

    static func keyName(_ key: String) -> String {
        guard let scalar = key.unicodeScalars.first else { return key }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSPageUpFunctionKey: return "Page Up"
        case NSPageDownFunctionKey: return "Page Down"
        case NSHomeFunctionKey: return "Home"
        case NSEndFunctionKey: return "End"
        case 0x0D, 0x03: return "↩"
        case 0x1B: return "⎋"
        case 0x08, 0x7F: return "⌫"
        case 0x09: return "⇥"
        case 0x20: return "Space"
        default: return key.uppercased()
        }
    }

    /// Items AppKit adds to the Edit menu (their keys are the system's).
    static let systemActions: Set<Selector?> = [
        NSSelectorFromString("orderFrontCharacterPalette:"), NSSelectorFromString("startDictation:"),
        NSSelectorFromString("_handleInsertFromContinuityCamera:"),
    ]

    /// The menu's items with key equivalents, by top-level menu; tools get
    /// what they do.
    static func menuSections(_ menu: NSMenu) -> [ShortcutSection] {
        var sections: [ShortcutSection] = []
        for top in menu.items {
            guard let submenu = top.submenu, submenu !== NSApp?.servicesMenu else { continue }
            var entries: [ShortcutEntry] = []
            func walk(_ m: NSMenu, path: [String]) {
                for item in m.items where !item.isSeparatorItem && !item.isHidden {
                    if let sub = item.submenu {
                        if sub.title != "Services" && sub.title != "Open Recent" { walk(sub, path: path + [item.title]) }
                        continue
                    }
                    guard !item.keyEquivalent.isEmpty, !systemActions.contains(item.action) else { continue }
                    var detail: String? = path.isEmpty ? nil : path.joined(separator: " ▸ ")
                    if let raw = item.representedObject as? String, let tool = ViewerTool(rawValue: raw),
                       item.action == #selector(DocumentWindowController.selectTool(_:)) {
                        detail = toolDescriptions[tool]
                    }
                    entries.append(ShortcutEntry(title: item.title, keys: glyphs(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask),
                                                 detail: detail))
                }
            }
            walk(submenu, path: [])
            if !entries.isEmpty { sections.append(ShortcutSection(title: top.title, entries: entries)) }
        }
        return sections
    }

    /// Everything: the menus, then the views.
    static func sections(menu: NSMenu) -> [ShortcutSection] {
        menuSections(menu) + viewSections
    }

    /// The sections with entries matching every word of `filter`.
    static func filter(_ sections: [ShortcutSection], _ filter: String) -> [ShortcutSection] {
        let words = filter.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return sections }
        return sections.compactMap { s in
            let entries = s.entries.filter { e in
                let text = "\(s.title) \(e.title) \(e.keys) \(e.detail ?? "")".lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            return entries.isEmpty ? nil : ShortcutSection(title: s.title, entries: entries)
        }
    }

    /// The list as text (to copy or print).
    static func text(_ sections: [ShortcutSection]) -> String {
        sections.map { s in
            ([s.title] + s.entries.map { "  \($0.keys)\t\($0.title)\($0.detail.map { " — \($0)" } ?? "")" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

@MainActor
@Observable
final class ShortcutsModel {
    var filter = ""
    private(set) var sections: [ShortcutSection] = []

    func refresh() {
        sections = ShortcutCatalog.sections(menu: NSApp.mainMenu ?? MainMenu.build())
    }

    var shown: [ShortcutSection] { ShortcutCatalog.filter(sections, filter) }
}

/// Help ▸ Keyboard Shortcuts.
@MainActor
enum ShortcutsWindow {
    static let model = ShortcutsModel()

    static func show() {
        model.refresh()
        window().show()
    }

    static func window() -> AppWindowController {
        AppWindowController.shared("shortcuts", title: "Keyboard Shortcuts", size: NSSize(width: 720, height: 720),
                                   minSize: NSSize(width: 520, height: 400)) {
            let hosting = NSHostingController(rootView: ShortcutsView(model: model))
            hosting.sizingOptions = []
            return hosting
        }
    }
}

struct ShortcutsView: View {
    @Bindable var model: ShortcutsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a command or key", text: $model.filter)
                    .textFieldStyle(.plain)
                Button {
                    copyToPasteboard(ShortcutCatalog.text(model.shown))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the list as text")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            List {
                ForEach(model.shown) { section in
                    Section(section.title) {
                        ForEach(section.entries) { e in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.title)
                                    if let detail = e.detail {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 12)
                                Text(e.keys)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                                    .fixedSize()
                            }
                            .padding(.vertical, 1)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .onAppear { if model.sections.isEmpty { model.refresh() } }
    }
}
