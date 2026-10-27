import Foundation

/// A display window: values in `center ± width / 2` map to black…white.
public struct WindowPreset: Sendable, Hashable, Codable, Identifiable {
    public var name: String
    public var center: Double
    public var width: Double

    public var id: String { name }

    public init(name: String, center: Double, width: Double) {
        self.name = name
        self.center = center
        self.width = width
    }

    public var lower: Double { center - width / 2 }
    public var upper: Double { center + width / 2 }

    /// The usual CT windows, in HU.
    public static let ct: [WindowPreset] = [
        WindowPreset(name: "Soft tissue", center: 40, width: 400),
        WindowPreset(name: "Abdomen", center: 60, width: 400),
        WindowPreset(name: "Liver", center: 80, width: 150),
        WindowPreset(name: "Mediastinum", center: 50, width: 350),
        WindowPreset(name: "Lung", center: -600, width: 1500),
        WindowPreset(name: "Bone", center: 400, width: 1800),
        WindowPreset(name: "Brain", center: 40, width: 80),
        WindowPreset(name: "Subdural", center: 75, width: 215),
        WindowPreset(name: "Stroke", center: 32, width: 8),
        WindowPreset(name: "Temporal bone", center: 600, width: 2800),
    ]
}

/// An image in memory, with what a viewer needs to display it (spec §4).
///
/// `data` holds the stored values (raw, not rescaled) in stored order, every
/// axis included; `geometry` is the image's grid. Physical values are
/// `raw × rescaleSlope + rescaleIntercept` (spec §4.2), applied on display.
public struct ImageVolume: @unchecked Sendable, Identifiable {
    public var id: String
    public var data: VolumeData
    public var geometry: GridGeometry
    public var rescaleSlope: Double
    public var rescaleIntercept: Double
    public var modality: String
    /// `intensity`, `quantitative`, `rgb`, `probability`, `displacement` or `mask`.
    public var valueType: String
    public var valueUnits: String?
    public var channelNames: [String]?
    /// Presets stored with the image (`window_center` / `window_width`).
    public var windowPresets: [WindowPreset]

    public init(
        id: String,
        data: VolumeData,
        geometry: GridGeometry,
        rescaleSlope: Double = 1,
        rescaleIntercept: Double = 0,
        modality: String = "OT",
        valueType: String = "intensity",
        valueUnits: String? = nil,
        channelNames: [String]? = nil,
        windowPresets: [WindowPreset] = []
    ) {
        self.id = id
        self.data = data
        self.geometry = geometry
        self.rescaleSlope = rescaleSlope
        self.rescaleIntercept = rescaleIntercept
        self.modality = modality
        self.valueType = valueType
        self.valueUnits = valueUnits
        self.channelNames = channelNames
        self.windowPresets = windowPresets
    }

    @inline(__always)
    public func physical(fromRaw raw: Double) -> Double { raw * rescaleSlope + rescaleIntercept }

    @inline(__always)
    public func raw(fromPhysical value: Double) -> Double {
        rescaleSlope == 0 ? 0 : (value - rescaleIntercept) / rescaleSlope
    }

    public var isRescaled: Bool { rescaleSlope != 1 || rescaleIntercept != 0 }

    public var isRGB: Bool { valueType == "rgb" }

    /// Extents of the axes before the spatial ones.
    public var leadingShape: [Int] { geometry.leadingShape }

    /// The spatial frame at a leading index (channel, time…), as a view.
    public func spatialFrame(_ leading: [Int]) -> VolumeData {
        data.frame(leading).reshaped(geometry.spatialShape)
    }

    /// The spatial frame at the first leading index (the whole volume for a
    /// plain 3-D image).
    public var firstFrame: VolumeData {
        spatialFrame(Array(repeating: 0, count: leadingShape.count))
    }

    /// The stored presets, then the CT presets for CT images.
    public var allWindowPresets: [WindowPreset] {
        modality.uppercased() == "CT" ? windowPresets + WindowPreset.ct : windowPresets
    }
}
