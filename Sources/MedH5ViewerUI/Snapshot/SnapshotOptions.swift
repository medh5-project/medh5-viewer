import AppKit
import MedH5Kit
import MedH5Render

/// The command line of the snapshot mode, the way the app is looked at in
/// QA: it opens a document without user interaction, waits until every
/// visible volume is loaded and drawn, and writes PNGs of the window and of
/// each viewport.
public struct SnapshotOptions: Equatable {
    public enum Source: Equatable {
        case file(URL)
        case demo
    }

    public var source: Source
    public var outDirectory: URL
    public var layout: ViewerLayout?
    /// The window's content size in points, no smaller than its minimum.
    public var size = CGSize(width: 1600, height: 1000)
    public var appearance: NSAppearance.Name?
    /// A sidebar item to select (id, object id or title).
    public var select: String?
    public var inspector: InspectorTab?
    /// Pixels per point of the PNGs.
    public var scale: CGFloat = 1
    /// Overlays to add: annotation ids, or `all` (every annotation of the
    /// base timepoint).
    public var overlays: [String] = []
    /// The plane of the single view and of Compare.
    public var plane: ViewPlane?
    /// Voxels per axis of the demo sample.
    public var demoSize: Int?
    public var timeout: TimeInterval = 120
    /// Whether to run the integrity check (on by default, as on open).
    public var verify = true
    /// Makes the app active for the capture: the window looks as it does
    /// in use, and the keyboard focus leaves the app it was in for a moment.
    public var activate = false
    /// Drags the panels to their widest in a window of the default size,
    /// then the window in to `size`, as a user would (QA: `PanelLimits`).
    public var widestPanels = false
    public var hideSidebar = false
    public var hideInspector = false
    /// The view made active (its stack shows in the Layers tab).
    public var activeView: ViewportID?
    /// 3-D rendering mode and segmentation surface style.
    public var volumeMode: String?
    public var surfaces: String?
    /// The slice views' thick slab.
    public var slab: SlabSettings?
    /// Another window to capture instead of a document: `welcome` or
    /// `settings`, or a panel or app window (`AuxiliarySnapshot.windows`).
    public var auxiliaryWindow: String?
    /// The clinical window's cutoff, in hours of the subject clock.
    public var clinicalCutoffHours: Double?
    /// The tool selected (after a scripted edit).
    public var tool: ViewerTool?
    /// A scripted edit made before the capture, to look at the editing
    /// tools (QA, tests): `segment`, `annotate`, `measure` or `all`.
    public var editScript: String?

    public init(source: Source, outDirectory: URL) {
        self.source = source
        self.outDirectory = outDirectory
    }

    /// `size`, for a window that goes no smaller than its minimum.
    func contentSize(in window: NSWindow) -> NSSize {
        let least = window.contentRect(forFrameRect: NSRect(origin: .zero, size: window.minSize)).size
        return NSSize(width: max(size.width, least.width), height: max(size.height, least.height))
    }

    static let usage = """
    usage: medh5-viewer [file.medh5 …]
           medh5-viewer --snapshot <file.medh5 | --demo> --out <dir> [options]

    Snapshot mode opens the document without user interaction, waits until every
    visible volume is loaded and rendered, writes <dir>/window.png (the whole
    window) and <dir>/view-<n>.png (each viewport), prints their paths, and exits.

      --layout single|1x3|2x2|3d|compare   the viewer layout (default: Preferences)
      --size WxH                           window content size in points (1600x1000), no smaller
                                           than the window's minimum
      --appearance dark|light              the window chrome's appearance
      --select <item>                      select a sidebar item (id, object or title)
      --inspector layers|segment-editor|annotations|measurements|info
                                           the inspector tab
      --overlays all|<id,id,…>             add annotations as overlays
      --plane axial|coronal|sagittal       the plane of the single view / compare
      --active <view>                      the active view: axial, coronal, sagittal, 3d, left, right
      --scale <n>                          pixels per point of the PNGs (1); the window's chrome is
                                           no sharper than the display it is on
      --demo-size <n>                      voxels per axis of the demo sample (128)
      --no-sidebar, --no-inspector         hide a panel
      --widest-panels                      drag the panels to their widest, then the window to --size
      --no-verify                          skip the integrity check
      --activate                           capture the window active, as in use (without it, as a
                                           window in the background); takes the keyboard focus briefly
      --timeout <seconds>                  give up after this long (120)
      --window welcome|settings[-editing…] capture that window instead of a document (a Settings
                                           pane: settings-general, -rendering, -editing, -performance)
      --window validate|verify|document|label-set|clinical|help|shortcuts|acknowledgements|import-nifti
                                           a panel of the document, or an app window; --select picks a
                                           page, class, event or filter in it
      --cutoff <hours>                     the clinical window's cutoff on the subject clock
      --3d-mode dvr|mip|minip|average|isosurface
      --3d-surfaces raycast|meshes         how segmentations show in 3-D
      --slab mip|minip|average[:<mm>]      a thick slab in the slice views (10 mm)
      --tool <name>                        the tool: navigate, window-level, pan, zoom, ruler, angle,
                                           roi, brush, eraser, fill, box, point, polyline, contour
      --edit segment|annotate|measure|all  a scripted edit before the capture (QA): a new
                                           segmentation painted, annotation items drawn,
                                           measurements made, gestures left in progress
    """

    struct ParseError: Error, CustomStringConvertible {
        var description: String
    }

    static func parse(_ arguments: [String]) throws -> SnapshotOptions {
        var source: Source?
        var out: URL?
        var o = SnapshotOptions(source: .demo, outDirectory: URL(fileURLWithPath: "."))
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < arguments.count else { throw ParseError(description: "\(flag) needs a value") }
            return arguments[i]
        }
        while i < arguments.count {
            let a = arguments[i]
            switch a {
            case "--snapshot":
                if i + 1 < arguments.count {
                    let next = arguments[i + 1]
                    if next == "--demo" {
                        source = .demo
                        i += 1
                    } else if !next.hasPrefix("--") {
                        source = .file(URL(fileURLWithPath: next))
                        i += 1
                    }
                }
            case "--demo": source = .demo
            case "--out": out = URL(fileURLWithPath: try value(a), isDirectory: true)
            case "--layout":
                let v = try value(a)
                guard let l = ViewerLayout(argument: v) else { throw ParseError(description: "unknown layout \(v)") }
                o.layout = l
            case "--size":
                let v = try value(a)
                let parts = v.lowercased().split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2, parts[0] >= 400, parts[1] >= 300 else { throw ParseError(description: "bad size \(v) (WxH, at least 400x300)") }
                o.size = CGSize(width: parts[0], height: parts[1])
            case "--appearance":
                switch try value(a).lowercased() {
                case "dark": o.appearance = .darkAqua
                case "light": o.appearance = .aqua
                case let v: throw ParseError(description: "unknown appearance \(v)")
                }
            case "--select": o.select = try value(a)
            case "--inspector":
                let v = try value(a)
                guard let t = InspectorTab(argument: v) else { throw ParseError(description: "unknown inspector tab \(v)") }
                o.inspector = t
            case "--overlays":
                o.overlays = try value(a).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            case "--plane":
                let v = try value(a)
                guard let p = ViewPlane(rawValue: v.lowercased()) else { throw ParseError(description: "unknown plane \(v)") }
                o.plane = p
            case "--active":
                switch try value(a).lowercased() {
                case "axial": o.activeView = .slice(.axial)
                case "coronal": o.activeView = .slice(.coronal)
                case "sagittal": o.activeView = .slice(.sagittal)
                case "3d", "volume": o.activeView = .volume
                case "left": o.activeView = .compareLeft
                case "right": o.activeView = .compareRight
                case let v: throw ParseError(description: "unknown view \(v)")
                }
            case "--scale":
                let v = try value(a)
                guard let s = Double(v), s >= 0.5, s <= 4 else { throw ParseError(description: "bad scale \(v)") }
                o.scale = CGFloat(s)
            case "--demo-size":
                let v = try value(a)
                guard let n = Int(v), n >= 16, n <= 512 else { throw ParseError(description: "bad demo size \(v)") }
                o.demoSize = n
            case "--timeout":
                let v = try value(a)
                guard let t = Double(v), t > 0 else { throw ParseError(description: "bad timeout \(v)") }
                o.timeout = t
            case "--window":
                let v = try value(a).lowercased()
                let panes = ["settings-general", "settings-rendering", "settings-editing", "settings-performance"]
                guard ["welcome", "settings", "preferences"].contains(v) || panes.contains(v)
                        || AuxiliarySnapshot.windows.contains(v) else {
                    throw ParseError(description: "unknown window \(v)")
                }
                o.auxiliaryWindow = v == "preferences" ? "settings" : v
            case "--3d-mode":
                let v = try value(a).lowercased()
                guard ["dvr", "mip", "minip", "average", "isosurface"].contains(v) else { throw ParseError(description: "unknown 3-D mode \(v)") }
                o.volumeMode = v
            case "--3d-surfaces":
                let v = try value(a).lowercased()
                guard ["raycast", "meshes"].contains(v) else { throw ParseError(description: "unknown surface style \(v)") }
                o.surfaces = v
            case "--slab":
                let v = try value(a).lowercased()
                let parts = v.split(separator: ":", maxSplits: 1).map(String.init)
                let modes: [String: SlabMode] = ["mip": .maximum, "minip": .minimum, "average": .mean]
                guard let mode = modes[parts[0]], let mm = parts.count > 1 ? Double(parts[1]) : 10, mm > 0 else {
                    throw ParseError(description: "bad slab \(v) (mip, minip or average, then :<mm>)")
                }
                o.slab = SlabSettings(mode: mode, thickness: mm)
            case "--cutoff":
                let v = try value(a)
                guard let h = Double(v.lowercased().replacingOccurrences(of: "h", with: "")) else { throw ParseError(description: "bad cutoff \(v)") }
                o.clinicalCutoffHours = h
            case "--tool":
                let v = try value(a)
                guard let t = ViewerTool(argument: v) else { throw ParseError(description: "unknown tool \(v)") }
                o.tool = t
            case "--edit":
                let v = try value(a).lowercased()
                guard EditScript.names.contains(v) else { throw ParseError(description: "unknown edit script \(v)") }
                o.editScript = v
            case "--no-verify": o.verify = false
            case "--activate": o.activate = true
            case "--widest-panels": o.widestPanels = true
            case "--no-sidebar": o.hideSidebar = true
            case "--no-inspector": o.hideInspector = true
            default:
                if a.hasPrefix("-") && !a.hasPrefix("--") {
                    i += 1   // AppKit's own `-Key value` arguments
                } else if source == nil && !a.hasPrefix("--") {
                    source = .file(URL(fileURLWithPath: a))
                } else {
                    throw ParseError(description: "unknown option \(a)")
                }
            }
            i += 1
        }
        guard let source = source ?? (o.auxiliaryWindow != nil ? .demo : nil) else {
            throw ParseError(description: "--snapshot needs a file or --demo")
        }
        guard let out else { throw ParseError(description: "--snapshot needs --out <dir>") }
        o.source = source
        o.outDirectory = out
        return o
    }
}
