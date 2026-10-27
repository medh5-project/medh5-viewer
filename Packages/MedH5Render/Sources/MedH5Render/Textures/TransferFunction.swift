import Foundation
import simd

/// A 1-D transfer function for direct volume rendering: colour and opacity
/// as piecewise-linear functions of the **physical** value (HU for CT).
///
/// Opacity is per ``opacityUnitDistance`` millimetres of material: the ray
/// caster corrects it for its step size (`1 − (1 − α)^(step / unit)`), so an
/// image looks the same at any sampling rate.
public struct TransferFunction: Sendable, Hashable {
    /// A colour at a physical value.
    public struct ColorPoint: Sendable, Hashable {
        public var value: Double
        public var color: SIMD3<Double>
        public init(_ value: Double, _ color: SIMD3<Double>) {
            self.value = value
            self.color = color
        }
    }

    /// An opacity at a physical value.
    public struct OpacityPoint: Sendable, Hashable {
        public var value: Double
        public var opacity: Double
        public init(_ value: Double, _ opacity: Double) {
            self.value = value
            self.opacity = opacity
        }
    }

    /// Colour control points (sorted by value on evaluation).
    public var colorPoints: [ColorPoint]
    /// Opacity control points (sorted by value on evaluation).
    public var opacityPoints: [OpacityPoint]
    /// The path length (mm) the opacities are defined for.
    public var opacityUnitDistance: Double

    /// A transfer function from control points (any order).
    public init(colorPoints: [ColorPoint], opacityPoints: [OpacityPoint], opacityUnitDistance: Double = 1) {
        self.colorPoints = colorPoints
        self.opacityPoints = opacityPoints
        self.opacityUnitDistance = opacityUnitDistance
    }

    /// The span of values the control points cover (what the baked table
    /// spans; values outside take the end colours).
    public var valueRange: ClosedRange<Double> {
        let values = colorPoints.map(\.value) + opacityPoints.map(\.value)
        guard let lo = values.min(), let hi = values.max(), hi > lo else {
            let v = values.first ?? 0
            return (v - 1)...(v + 1)
        }
        return lo...hi
    }

    /// Colour and opacity at a physical value.
    public func evaluate(_ value: Double) -> SIMD4<Double> {
        let c = Self.interpolate(colorPoints.sorted { $0.value < $1.value }.map { ($0.value, $0.color) }, value)
            ?? SIMD3(1, 1, 1)
        let a = Self.interpolate(opacityPoints.sorted { $0.value < $1.value }.map { ($0.value, SIMD3(repeating: $0.opacity)) },
                                 value)?.x ?? 0
        return SIMD4(c, min(1, max(0, a)))
    }

    /// The function sampled at `entries` values evenly spread over
    /// ``valueRange`` (RGBA, straight alpha).
    public func table(entries: Int = 1024) -> [SIMD4<Float>] {
        let r = valueRange
        let colors = colorPoints.sorted { $0.value < $1.value }.map { ($0.value, $0.color) }
        let alphas = opacityPoints.sorted { $0.value < $1.value }.map { ($0.value, SIMD3(repeating: $0.opacity)) }
        return (0..<entries).map { i in
            let v = r.lowerBound + (r.upperBound - r.lowerBound) * Double(i) / Double(entries - 1)
            let c = Self.interpolate(colors, v) ?? SIMD3(1, 1, 1)
            let a = Self.interpolate(alphas, v)?.x ?? 0
            return SIMD4<Float>(Float(c.x), Float(c.y), Float(c.z), Float(min(1, max(0, a))))
        }
    }

    private static func interpolate(_ points: [(Double, SIMD3<Double>)], _ v: Double) -> SIMD3<Double>? {
        guard let first = points.first, let last = points.last else { return nil }
        if v <= first.0 { return first.1 }
        if v >= last.0 { return last.1 }
        for i in 1..<points.count where v <= points[i].0 {
            let (x0, c0) = points[i - 1]
            let (x1, c1) = points[i]
            let w = (v - x0) / max(1e-12, x1 - x0)
            return c0 + (c1 - c0) * w
        }
        return last.1
    }

    // MARK: Presets

    /// A preset; CT presets are in HU. `range` (the image's value range,
    /// e.g. its 1st–99th percentiles) is used by ``TransferFunctionPreset/mrDefault``.
    public static func preset(_ preset: TransferFunctionPreset,
                              range: ClosedRange<Double>? = nil) -> TransferFunction {
        switch preset {
        case .ctBone:
            return TransferFunction(
                colorPoints: [
                    ColorPoint(-1000, SIMD3(0.3, 0.3, 0.3)),
                    ColorPoint(150, SIMD3(0.65, 0.42, 0.3)),
                    ColorPoint(300, SIMD3(0.9, 0.82, 0.66)),
                    ColorPoint(700, SIMD3(1.0, 0.95, 0.86)),
                    ColorPoint(1500, SIMD3(1, 1, 1)),
                ],
                opacityPoints: [
                    OpacityPoint(-1000, 0), OpacityPoint(140, 0), OpacityPoint(250, 0.35),
                    OpacityPoint(450, 0.85), OpacityPoint(3000, 0.95),
                ])
        case .ctSoftTissue:
            return TransferFunction(
                colorPoints: [
                    ColorPoint(-1000, SIMD3(0, 0, 0)),
                    ColorPoint(-200, SIMD3(0.55, 0.25, 0.15)),
                    ColorPoint(0, SIMD3(0.75, 0.38, 0.3)),
                    ColorPoint(80, SIMD3(0.9, 0.55, 0.45)),
                    ColorPoint(300, SIMD3(1.0, 0.92, 0.8)),
                    ColorPoint(1000, SIMD3(1, 1, 1)),
                ],
                opacityPoints: [
                    OpacityPoint(-1000, 0), OpacityPoint(-300, 0), OpacityPoint(-100, 0.04),
                    OpacityPoint(20, 0.12), OpacityPoint(120, 0.25), OpacityPoint(300, 0.7),
                    OpacityPoint(1000, 0.9),
                ])
        case .ctLung:
            return TransferFunction(
                colorPoints: [
                    ColorPoint(-1000, SIMD3(0.3, 0.45, 0.8)),
                    ColorPoint(-850, SIMD3(0.55, 0.7, 0.95)),
                    ColorPoint(-500, SIMD3(0.95, 0.75, 0.7)),
                    ColorPoint(0, SIMD3(0.9, 0.5, 0.45)),
                    ColorPoint(400, SIMD3(1, 1, 1)),
                ],
                opacityPoints: [
                    OpacityPoint(-1000, 0), OpacityPoint(-950, 0), OpacityPoint(-850, 0.03),
                    OpacityPoint(-600, 0.12), OpacityPoint(-400, 0), OpacityPoint(200, 0),
                    OpacityPoint(400, 0.6),
                ])
        case .ctAngiography:
            return TransferFunction(
                colorPoints: [
                    ColorPoint(-1000, SIMD3(0, 0, 0)),
                    ColorPoint(100, SIMD3(0.55, 0.05, 0.05)),
                    ColorPoint(250, SIMD3(0.9, 0.2, 0.15)),
                    ColorPoint(450, SIMD3(1.0, 0.75, 0.6)),
                    ColorPoint(900, SIMD3(1, 1, 0.95)),
                ],
                opacityPoints: [
                    OpacityPoint(-1000, 0), OpacityPoint(120, 0), OpacityPoint(200, 0.3),
                    OpacityPoint(350, 0.7), OpacityPoint(900, 0.9),
                ])
        case .ctSkin:
            return TransferFunction(
                colorPoints: [
                    ColorPoint(-1000, SIMD3(0.3, 0.2, 0.15)),
                    ColorPoint(-500, SIMD3(0.85, 0.65, 0.55)),
                    ColorPoint(0, SIMD3(0.95, 0.78, 0.68)),
                    ColorPoint(500, SIMD3(1, 0.95, 0.9)),
                ],
                opacityPoints: [
                    OpacityPoint(-1000, 0), OpacityPoint(-550, 0), OpacityPoint(-350, 0.9),
                    OpacityPoint(3000, 1),
                ])
        case .mrDefault:
            let r = range ?? 0...1000
            let lo = r.lowerBound, w = max(1e-6, r.upperBound - r.lowerBound)
            return TransferFunction(
                colorPoints: [
                    ColorPoint(lo, SIMD3(0, 0, 0)),
                    ColorPoint(lo + 0.25 * w, SIMD3(0.6, 0.35, 0.25)),
                    ColorPoint(lo + 0.55 * w, SIMD3(0.9, 0.75, 0.6)),
                    ColorPoint(lo + w, SIMD3(1, 1, 1)),
                ],
                opacityPoints: [
                    OpacityPoint(lo, 0), OpacityPoint(lo + 0.2 * w, 0), OpacityPoint(lo + 0.45 * w, 0.15),
                    OpacityPoint(lo + 0.8 * w, 0.6), OpacityPoint(lo + w, 0.8),
                ])
        }
    }
}

/// Transfer-function presets: CT ones in HU, a generic one for MR.
public enum TransferFunctionPreset: String, CaseIterable, Sendable, Codable, Identifiable {
    case ctBone
    case ctSoftTissue
    case ctLung
    case ctAngiography
    case ctSkin
    case mrDefault

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ctBone: return "CT Bone"
        case .ctSoftTissue: return "CT Soft Tissue"
        case .ctLung: return "CT Lung"
        case .ctAngiography: return "CT Angiography"
        case .ctSkin: return "CT Skin"
        case .mrDefault: return "MR Default"
        }
    }
}
