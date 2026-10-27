import Foundation
import simd
import MedH5Core

/// The built-in colormaps for image, probability and MIP display.
///
/// Every map takes `t ∈ [0, 1]` (the windowed value) to an RGB colour. The
/// perceptually uniform maps (viridis, magma, inferno, plasma, turbo) use
/// published polynomial fits, accurate to about 1 %; cividis is a
/// piecewise-linear approximation through nine of its colours.
public enum Colormap: String, CaseIterable, Sendable, Codable, Identifiable {
    case grayscale
    case inverted
    case hot
    case cool
    case bone
    case copper
    case jet
    case turbo
    case viridis
    case magma
    case inferno
    case plasma
    case cividis
    /// The PET "hot iron" map: black, red, orange, yellow, white.
    case hotIron
    case rainbow
    case red
    case green
    case blue
    case yellow
    case cyan
    case magenta

    public var id: String { rawValue }

    /// A name for menus.
    public var displayName: String {
        switch self {
        case .grayscale: return "Grayscale"
        case .inverted: return "Inverted"
        case .hot: return "Hot"
        case .cool: return "Cool"
        case .bone: return "Bone"
        case .copper: return "Copper"
        case .jet: return "Jet"
        case .turbo: return "Turbo"
        case .viridis: return "Viridis"
        case .magma: return "Magma"
        case .inferno: return "Inferno"
        case .plasma: return "Plasma"
        case .cividis: return "Cividis"
        case .hotIron: return "Hot Iron (PET)"
        case .rainbow: return "Rainbow"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .cyan: return "Cyan"
        case .magenta: return "Magenta"
        }
    }

    /// The colour at `t` (clamped to `[0, 1]`), components in `[0, 1]`.
    public func color(at t: Double) -> SIMD3<Double> {
        let x = min(1, max(0, t))
        let c: SIMD3<Double>
        switch self {
        case .grayscale: c = SIMD3(repeating: x)
        case .inverted: c = SIMD3(repeating: 1 - x)
        case .hot:
            c = SIMD3(0.0416 + 0.9584 * Self.ramp(x, 0, 0.365), Self.ramp(x, 0.365, 0.746), Self.ramp(x, 0.746, 1))
        case .cool: c = SIMD3(x, 1 - x, 1)
        case .bone:
            c = SIMD3(Self.piecewise(x, [(0, 0), (0.746032, 0.652778), (1, 1)]),
                      Self.piecewise(x, [(0, 0), (0.365079, 0.319444), (0.746032, 0.777778), (1, 1)]),
                      Self.piecewise(x, [(0, 0), (0.365079, 0.444444), (1, 1)]))
        case .copper: c = SIMD3(min(1, 1.25 * x), 0.7812 * x, 0.4975 * x)
        case .jet:
            c = SIMD3(Self.piecewise(x, [(0, 0), (0.35, 0), (0.66, 1), (0.89, 1), (1, 0.5)]),
                      Self.piecewise(x, [(0, 0), (0.125, 0), (0.375, 1), (0.64, 1), (0.91, 0), (1, 0)]),
                      Self.piecewise(x, [(0, 0.5), (0.11, 1), (0.34, 1), (0.65, 0), (1, 0)]))
        case .turbo: c = Self.turbo(x)
        case .viridis: c = Self.polynomial(x, Self.viridisCoefficients)
        case .magma: c = Self.polynomial(x, Self.magmaCoefficients)
        case .inferno: c = Self.polynomial(x, Self.infernoCoefficients)
        case .plasma: c = Self.polynomial(x, Self.plasmaCoefficients)
        case .cividis: c = Self.stops(x, Self.cividisStops)
        case .hotIron: c = SIMD3(Self.ramp(x, 0, 0.5), Self.ramp(x, 0.5, 1), Self.ramp(x, 0.75, 1))
        case .rainbow: c = Self.hsv(hue: (1 - x) * 2.0 / 3.0)
        case .red: c = SIMD3(x, 0, 0)
        case .green: c = SIMD3(0, x, 0)
        case .blue: c = SIMD3(0, 0, x)
        case .yellow: c = SIMD3(x, x, 0)
        case .cyan: c = SIMD3(0, x, x)
        case .magenta: c = SIMD3(x, 0, x)
        }
        return simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    /// The map sampled at `entries` evenly spaced points (`t = i / (entries - 1)`),
    /// opaque.
    public func table(entries: Int = 256) -> [RGBA8] {
        let n = max(2, entries)
        return (0..<n).map { i in
            let c = color(at: Double(i) / Double(n - 1))
            return RGBA8(UInt8((c.x * 255).rounded()), UInt8((c.y * 255).rounded()), UInt8((c.z * 255).rounded()), 255)
        }
    }

    // MARK: Definitions

    private static func ramp(_ x: Double, _ a: Double, _ b: Double) -> Double {
        min(1, max(0, (x - a) / (b - a)))
    }

    private static func piecewise(_ x: Double, _ points: [(Double, Double)]) -> Double {
        if x <= points[0].0 { return points[0].1 }
        for i in 1..<points.count where x <= points[i].0 {
            let (x0, y0) = points[i - 1]
            let (x1, y1) = points[i]
            return y0 + (y1 - y0) * (x - x0) / max(1e-12, x1 - x0)
        }
        return points[points.count - 1].1
    }

    private static func stops(_ x: Double, _ colors: [SIMD3<Double>]) -> SIMD3<Double> {
        let f = x * Double(colors.count - 1)
        let i = min(colors.count - 2, Int(f))
        let w = f - Double(i)
        return colors[i] + (colors[i + 1] - colors[i]) * w
    }

    private static func polynomial(_ t: Double, _ c: [SIMD3<Double>]) -> SIMD3<Double> {
        var r = c[c.count - 1]
        for k in stride(from: c.count - 2, through: 0, by: -1) {
            r = c[k] + t * r
        }
        return r
    }

    private static func hsv(hue: Double) -> SIMD3<Double> {
        let h = (hue - floor(hue)) * 6
        let i = Int(h) % 6
        let f = h - floor(h)
        switch i {
        case 0: return SIMD3(1, f, 0)
        case 1: return SIMD3(1 - f, 1, 0)
        case 2: return SIMD3(0, 1, f)
        case 3: return SIMD3(0, 1 - f, 1)
        case 4: return SIMD3(f, 0, 1)
        default: return SIMD3(1, 0, 1 - f)
        }
    }

    /// Google's polynomial approximation of Turbo.
    private static func turbo(_ x: Double) -> SIMD3<Double> {
        let v4 = SIMD4<Double>(1, x, x * x, x * x * x)
        let v2 = SIMD2<Double>(v4.z, v4.w) * v4.z
        let r = simd_dot(v4, SIMD4(0.13572138, 4.61539260, -42.66032258, 132.13108234))
            + simd_dot(v2, SIMD2(-152.94239396, 59.28637943))
        let g = simd_dot(v4, SIMD4(0.09140261, 2.19418839, 4.84296658, -14.18503333))
            + simd_dot(v2, SIMD2(4.27729857, 2.82956604))
        let b = simd_dot(v4, SIMD4(0.10667330, 12.64194608, -60.58204836, 110.36276771))
            + simd_dot(v2, SIMD2(-89.90310912, 27.34824973))
        return SIMD3(r, g, b)
    }

    // Degree-6 fits of the matplotlib maps (coefficients of t^0 … t^6).
    private static let viridisCoefficients: [SIMD3<Double>] = [
        SIMD3(0.2777273272234177, 0.005407344544966578, 0.3340998053353061),
        SIMD3(0.1050930431085774, 1.404613529898575, 1.384590162594685),
        SIMD3(-0.3308618287255563, 0.214847559468213, 0.09509516302823659),
        SIMD3(-4.634230498983486, -5.799100973351585, -19.33244095627987),
        SIMD3(6.228269936347081, 14.17993336680509, 56.69055260068105),
        SIMD3(4.776384997670288, -13.74514537774601, -65.35303263337234),
        SIMD3(-5.435455855934631, 4.645852612178535, 26.3124352495832),
    ]
    private static let plasmaCoefficients: [SIMD3<Double>] = [
        SIMD3(0.05873234392399702, 0.02333670892565664, 0.5433401826748754),
        SIMD3(2.176514634195958, 0.2383834171260182, 0.7539604599784036),
        SIMD3(-2.689460476458034, -7.455851135738909, 3.110799939717086),
        SIMD3(6.130348345893603, 42.3461881477227, -28.51885465332158),
        SIMD3(-11.10743619062271, -82.66631109428045, 60.13984767418263),
        SIMD3(10.02306557647065, 71.41361770095349, -54.07218655560067),
        SIMD3(-3.658713842777788, -22.93153465461149, 18.19190778539828),
    ]
    private static let magmaCoefficients: [SIMD3<Double>] = [
        SIMD3(-0.002136485053939582, -0.000749655052795221, -0.005386127855323933),
        SIMD3(0.2516605407371642, 0.6775232436837668, 2.494026599312351),
        SIMD3(8.353717279216625, -3.577719514958484, 0.3144679030132573),
        SIMD3(-27.66873308576866, 14.26473078096533, -13.64921318813922),
        SIMD3(52.17613981234068, -27.94360607168351, 12.94416944238394),
        SIMD3(-50.76852536473588, 29.04658282127291, 4.23415299384598),
        SIMD3(18.65570506591883, -11.48977351997711, -5.601961508734096),
    ]
    private static let infernoCoefficients: [SIMD3<Double>] = [
        SIMD3(0.0002189403691192265, 0.001651004631001012, -0.01948089843709184),
        SIMD3(0.1065134194856116, 0.5639564367884091, 3.932712388889277),
        SIMD3(11.60249308247187, -3.972853965665698, -15.9423941062914),
        SIMD3(-41.70399613139459, 17.43639888205313, 44.35414519872813),
        SIMD3(77.162935699427, -33.40235894210092, -81.80730925738993),
        SIMD3(-71.31942824499214, 32.62606426397723, 73.20951985803202),
        SIMD3(25.13112622477341, -12.24266895238567, -23.07032500287172),
    ]
    private static let cividisStops: [SIMD3<Double>] = [
        SIMD3(0, 34, 78), SIMD3(18, 53, 112), SIMD3(59, 73, 108), SIMD3(87, 92, 109),
        SIMD3(125, 124, 120), SIMD3(157, 151, 117), SIMD3(188, 175, 111), SIMD3(221, 203, 93),
        SIMD3(254, 232, 56),
    ].map { $0 / 255 }
}
