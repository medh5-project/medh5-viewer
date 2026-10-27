import Foundation
import MedH5Kit
import MedH5Render

/// The user's settings (Preferences window), stored in `UserDefaults`.
///
/// Values are read where they apply (a new window takes the default layout,
/// the volume store reads the budget each time it enforces it), so a change
/// needs no plumbing; the Preferences window binds to the same keys with
/// `@AppStorage`.
enum Preferences {
    enum Key {
        static let defaultLayout = "defaultLayout"
        static let planeOrientation = "planeOrientation"
        static let convention = "displayConvention"
        static let interpolation = "interpolation"
        static let volumeQuality = "volumeQuality"
        static let memoryBudgetGB = "memoryBudgetGB"
        static let engineThreads = "engineThreads"
        static let demoSize = "demoSampleSize"
    }

    /// 3-D rendering quality when the camera is idle.
    enum VolumeQuality: String, CaseIterable, Identifiable {
        case draft, standard, high
        var id: String { rawValue }
        var title: String {
            switch self {
            case .draft: return "Draft"
            case .standard: return "Standard"
            case .high: return "High"
            }
        }
        /// The renderer's idle quality.
        var renderQuality: VolumeRenderQuality {
            switch self {
            case .draft: return VolumeRenderQuality(resolutionScale: 0.6, samplesPerVoxel: 1)
            case .standard: return .full
            case .high: return VolumeRenderQuality(resolutionScale: 1, samplesPerVoxel: 3)
            }
        }
    }

    static var defaults: UserDefaults { .standard }

    /// Installs the factory values (`register(defaults:)`; never overrides a
    /// value the user set).
    static func registerDefaults() {
        defaults.register(defaults: [
            Key.defaultLayout: ViewerLayout.oneByThree.rawValue,
            Key.planeOrientation: PlaneOrientationMode.anatomical.rawValue,
            Key.convention: DisplayConvention.radiological.rawValue,
            Key.interpolation: Interpolation.linear.rawValue,
            Key.volumeQuality: VolumeQuality.standard.rawValue,
            Key.memoryBudgetGB: defaultMemoryBudgetGB,
            Key.engineThreads: defaultEngineThreads,
            Key.demoSize: 128,
        ])
    }

    /// Half the machine's memory, in whole gigabytes (at least 1).
    static var defaultMemoryBudgetGB: Double {
        max(1, (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 / 2).rounded())
    }

    /// The performance cores (all cores when the split is unknown).
    static var defaultEngineThreads: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 { return Int(count) }
        return ProcessInfo.processInfo.activeProcessorCount
    }

    static var defaultLayout: ViewerLayout {
        ViewerLayout(rawValue: defaults.string(forKey: Key.defaultLayout) ?? "") ?? .oneByThree
    }

    static var planeOrientation: PlaneOrientationMode {
        PlaneOrientationMode(rawValue: defaults.string(forKey: Key.planeOrientation) ?? "") ?? .anatomical
    }

    static var convention: DisplayConvention {
        DisplayConvention(rawValue: defaults.string(forKey: Key.convention) ?? "") ?? .radiological
    }

    static var interpolation: Interpolation {
        Interpolation(rawValue: defaults.string(forKey: Key.interpolation) ?? "") ?? .linear
    }

    static var volumeQuality: VolumeQuality {
        VolumeQuality(rawValue: defaults.string(forKey: Key.volumeQuality) ?? "") ?? .standard
    }

    /// The memory the volume store may hold (CPU and GPU together: Apple
    /// silicon shares one memory), in bytes.
    static var memoryBudgetBytes: Int {
        let gb = defaults.double(forKey: Key.memoryBudgetGB)
        return Int(max(0.25, gb > 0 ? gb : defaultMemoryBudgetGB) * 1_073_741_824)
    }

    static var engineThreads: Int {
        let n = defaults.integer(forKey: Key.engineThreads)
        return n > 0 ? n : defaultEngineThreads
    }

    /// Voxels per axis of the demo sample (16–512).
    static var demoSize: Int {
        let n = defaults.integer(forKey: Key.demoSize)
        return min(512, max(16, n > 0 ? n : 128))
    }

    /// Applies the settings that live outside the app's own objects (the
    /// engine's thread count).
    static func applyEngineSettings() {
        MedH5.setThreads(engineThreads)
    }
}
