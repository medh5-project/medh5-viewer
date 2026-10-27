import AppKit
import SwiftUI
import MedH5Kit
import MedH5Render

/// Settings: General (layout, planes, convention), Rendering (interpolation,
/// 3-D quality, memory budget), Editing (brush radius, undo memory),
/// Performance (engine threads), as toolbar tabs.
@MainActor
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = false
        func pane<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
            let hosting = NSHostingController(rootView: view.frame(width: 540))
            hosting.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: hosting)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        tabs.addTabViewItem(pane("General", "gearshape", GeneralPreferences()))
        tabs.addTabViewItem(pane("Rendering", "cube.transparent", RenderingPreferences()))
        tabs.addTabViewItem(pane("Editing", "paintbrush.pointed", EditingPreferences()))
        tabs.addTabViewItem(pane("Performance", "speedometer", PerformancePreferences()))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        window.isRestorable = false
        window.toolbarStyle = .preference
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }
}

struct GeneralPreferences: View {
    @AppStorage(Preferences.Key.defaultLayout) private var layout = ViewerLayout.oneByThree.rawValue
    @AppStorage(Preferences.Key.planeOrientation) private var orientation = PlaneOrientationMode.anatomical.rawValue
    @AppStorage(Preferences.Key.convention) private var convention = DisplayConvention.radiological.rawValue
    @AppStorage(Preferences.Key.demoSize) private var demoSize = 128

    var body: some View {
        Form {
            Section {
                Picker("Default layout", selection: $layout) {
                    ForEach(ViewerLayout.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Slice planes", selection: $orientation) {
                    Text("Anatomical").tag(PlaneOrientationMode.anatomical.rawValue)
                    Text("Aligned with the image").tag(PlaneOrientationMode.aligned.rawValue)
                }
                Picker("Left–right convention", selection: $convention) {
                    Text("Radiological").tag(DisplayConvention.radiological.rawValue)
                    Text("Neurological").tag(DisplayConvention.neurological.rawValue)
                }
            } footer: {
                Text("Anatomical planes reformat an oblique acquisition into true axial, coronal and sagittal planes; aligned planes follow the base image’s own axes. Radiological puts the patient’s left on the screen’s right. These apply to windows opened from now on.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("Demo sample size", selection: $demoSize) {
                    Text("64 voxels").tag(64)
                    Text("128 voxels").tag(128)
                    Text("192 voxels").tag(192)
                    Text("256 voxels").tag(256)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct RenderingPreferences: View {
    @AppStorage(Preferences.Key.interpolation) private var interpolation = Interpolation.linear.rawValue
    @AppStorage(Preferences.Key.volumeQuality) private var quality = Preferences.VolumeQuality.standard.rawValue
    @AppStorage(Preferences.Key.memoryBudgetGB) private var budget = Preferences.defaultMemoryBudgetGB

    private var physicalGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    var body: some View {
        Form {
            Section {
                Picker("Interpolation", selection: $interpolation) {
                    Text("Nearest").tag(Interpolation.nearest.rawValue)
                    Text("Linear").tag(Interpolation.linear.rawValue)
                    Text("Cubic").tag(Interpolation.cubic.rawValue)
                }
                Picker("3-D quality", selection: $quality) {
                    ForEach(Preferences.VolumeQuality.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section {
                LabeledContent("Memory budget") {
                    HStack {
                        Slider(value: $budget, in: 1...max(2, physicalGB.rounded(.down)), step: 1)
                            .frame(width: 200)
                        Text("\(Int(budget)) GB").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
            } footer: {
                Text("Of \(Int(physicalGB.rounded())) GB. Beyond the budget, volumes no view shows are released, least recently used first, and read again when needed.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct EditingPreferences: View {
    @AppStorage(Preferences.Key.defaultBrushRadius) private var radius = 5.0
    @AppStorage(Preferences.Key.undoMemoryMB) private var undoMB = 512

    var body: some View {
        Form {
            Section {
                LabeledContent("Default brush radius") {
                    HStack {
                        Slider(value: $radius, in: 0.5...50)
                            .frame(width: 200)
                        Text("\(Format.number(radius, digits: 1)) mm").monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
            } footer: {
                Text("The radius the brush and eraser start with in a new window; [ and ] change it while you paint.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("Undo memory", selection: $undoMB) {
                    Text("128 MB").tag(128)
                    Text("256 MB").tag(256)
                    Text("512 MB").tag(512)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("4 GB").tag(4096)
                }
            } footer: {
                Text("What the undo steps of a window’s segmentation edits may hold. Beyond it the oldest steps can no longer be undone; the newest always can.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PerformancePreferences: View {
    @AppStorage(Preferences.Key.engineThreads) private var threads = Preferences.defaultEngineThreads

    var body: some View {
        Form {
            Section {
                Stepper(value: $threads, in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount)) {
                    LabeledContent("Engine threads") { Text("\(threads)").monospacedDigit() }
                }
            } footer: {
                Text("How many threads one engine call uses to decompress and hash. The default is the number of performance cores (\(Preferences.defaultEngineThreads)).")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: threads) { _, _ in Preferences.applyEngineSettings() }
    }
}
