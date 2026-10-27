import Foundation
import MedH5Kit

/// Window presets and the automatic window.
enum WindowLevel {
    /// The window covering the 1st–99th percentiles of a frame's physical
    /// values (robust to a few outliers, as most viewers' "auto" does).
    static func automatic(_ h: HistogramResource) -> WindowPreset {
        let lo = h.percentiles[1] ?? h.minimum
        let hi = h.percentiles[99] ?? h.maximum
        if hi > lo { return WindowPreset(name: "Auto", center: (lo + hi) / 2, width: hi - lo) }
        let width = max(1e-6, h.maximum - h.minimum)
        return WindowPreset(name: "Auto", center: (h.maximum + h.minimum) / 2, width: width)
    }

    /// The full range of the values.
    static func fullRange(_ h: HistogramResource) -> WindowPreset {
        WindowPreset(name: "Full Range", center: (h.maximum + h.minimum) / 2, width: max(1e-6, h.maximum - h.minimum))
    }

    /// The presets offered for an image: those stored with it, then the
    /// CT presets for a CT.
    static func presets(for image: ImageInfo) -> [WindowPreset] {
        var presets = image.windowPresets
        if image.modality.uppercased() == "CT" { presets += WindowPreset.ct }
        return presets
    }

    /// The bounds of the window sliders: the value range with a margin.
    static func sliderRange(_ h: HistogramResource?, current: (center: Double, width: Double)) -> (center: ClosedRange<Double>, width: ClosedRange<Double>) {
        let lo = min(h?.minimum ?? current.center - current.width, current.center - current.width / 2)
        let hi = max(h?.maximum ?? current.center + current.width, current.center + current.width / 2)
        let span = max(1e-6, hi - lo)
        return (lo...hi, (span / 1000)...max(span * 2, current.width))
    }

    /// The value units to show: the image's, or HU for a CT.
    static func units(of image: ImageInfo) -> String? {
        if let u = image.valueUnits, !u.isEmpty { return u }
        return image.modality.uppercased() == "CT" && image.rescaled ? "HU" : nil
    }
}
