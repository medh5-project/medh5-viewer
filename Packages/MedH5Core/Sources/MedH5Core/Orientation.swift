import Foundation
import simd

/// One of the six anatomical directions a world axis can point to.
public enum AnatomicalDirection: Character, Sendable, CaseIterable {
    case left = "L"
    case right = "R"
    case posterior = "P"
    case anterior = "A"
    case superior = "S"
    case inferior = "I"

    public var opposite: AnatomicalDirection {
        switch self {
        case .left: return .right
        case .right: return .left
        case .posterior: return .anterior
        case .anterior: return .posterior
        case .superior: return .inferior
        case .inferior: return .superior
        }
    }

    /// The LPS axis this direction lies on (0 = L/R, 1 = P/A, 2 = S/I).
    public var lpsAxis: Int {
        switch self {
        case .left, .right: return 0
        case .posterior, .anterior: return 1
        case .superior, .inferior: return 2
        }
    }

    /// +1 when the direction is LPS-positive (L, P, S), -1 otherwise.
    public var lpsSign: Double {
        switch self {
        case .left, .posterior, .superior: return 1
        case .right, .anterior, .inferior: return -1
        }
    }

    public var letter: String { String(rawValue) }
}

/// A grid's `coord_system` (spec §3.2): three letters naming the anatomical
/// direction each positive world axis points to (`"LPS"`: +x is the
/// patient's left, +y posterior, +z superior), or `"custom"`.
public struct CoordinateSystem: Sendable, Hashable, CustomStringConvertible {
    public let code: String
    /// The direction of +x, +y and +z, or `nil` when the code names no
    /// anatomical system.
    public let axes: [AnatomicalDirection]?

    public init(_ code: String) {
        self.code = code
        let letters = Array(code.uppercased())
        guard letters.count == 3 else {
            axes = nil
            return
        }
        let parsed = letters.compactMap(AnatomicalDirection.init(rawValue:))
        guard parsed.count == 3, Set(parsed.map(\.lpsAxis)).count == 3 else {
            axes = nil
            return
        }
        axes = parsed
    }

    public static let lps = CoordinateSystem("LPS")
    public static let ras = CoordinateSystem("RAS")

    public var isAnatomical: Bool { axes != nil }

    public var description: String { code }

    /// The matrix taking world coordinates in this system to LPS, or `nil`
    /// when the system is not anatomical. It is a signed permutation, so its
    /// inverse is its transpose.
    public var toLPS: simd_double3x3? {
        guard let axes else { return nil }
        var m = simd_double3x3(0)
        for (worldAxis, dir) in axes.enumerated() {
            // LPS[dir.lpsAxis] = sign * world[worldAxis]
            m[worldAxis][dir.lpsAxis] = dir.lpsSign
        }
        return m
    }

    /// The matrix taking LPS coordinates to this system's world coordinates.
    public var fromLPS: simd_double3x3? { toLPS?.transpose }

    /// The anatomical label of a world direction: the directions of its
    /// components larger than `threshold` of its length, strongest first
    /// (`"L"`, `"LA"`, `"SPL"`), or `"?"` when the system is not anatomical.
    public func label(forWorldDirection v: SIMD3<Double>, threshold: Double = 0.3) -> String {
        guard let axes, simd_length(v) > 0 else { return "?" }
        let u = simd_normalize(v)
        let parts = (0..<3)
            .filter { abs(u[$0]) >= threshold }
            .sorted { abs(u[$0]) > abs(u[$1]) }
            .map { u[$0] >= 0 ? axes[$0].letter : axes[$0].opposite.letter }
        return parts.isEmpty ? "?" : parts.joined()
    }
}

/// The three standard viewing planes, and an arbitrary one.
public enum ViewPlane: String, Sendable, CaseIterable, Codable {
    case axial
    case coronal
    case sagittal

    public var title: String {
        switch self {
        case .axial: return "Axial"
        case .coronal: return "Coronal"
        case .sagittal: return "Sagittal"
        }
    }
}

/// Whether the patient's left is drawn on the screen's right (radiological,
/// the default) or on its left (neurological).
public enum DisplayConvention: String, Sendable, CaseIterable, Codable {
    case radiological
    case neurological
}

/// The screen axes of a view: world unit vectors for screen-right and
/// screen-down, and the plane normal (`right × down`, pointing away from the
/// viewer).
public struct PlaneAxes: Sendable, Hashable {
    public var right: SIMD3<Double>
    public var down: SIMD3<Double>
    public var normal: SIMD3<Double> { simd_normalize(simd_cross(right, down)) }

    public init(right: SIMD3<Double>, down: SIMD3<Double>) {
        self.right = simd_normalize(right)
        self.down = simd_normalize(down)
    }

    /// The standard plane, in LPS coordinates: axial shows the patient from
    /// the feet with anterior up, coronal from the front with superior up,
    /// sagittal from the patient's left with anterior on the screen's left.
    public static func standard(_ plane: ViewPlane, convention: DisplayConvention = .radiological) -> PlaneAxes {
        let l = SIMD3<Double>(1, 0, 0)
        let p = SIMD3<Double>(0, 1, 0)
        let s = SIMD3<Double>(0, 0, 1)
        let flip: Double = convention == .radiological ? 1 : -1
        switch plane {
        case .axial: return PlaneAxes(right: l * flip, down: p)
        case .coronal: return PlaneAxes(right: l * flip, down: -s)
        case .sagittal: return PlaneAxes(right: p, down: -s)
        }
    }

    /// The standard plane in the world coordinates of `system`; for a system
    /// that is not anatomical, the plane of the world axes that the same
    /// plane would use under LPS.
    public static func standard(
        _ plane: ViewPlane,
        in system: CoordinateSystem,
        convention: DisplayConvention = .radiological
    ) -> PlaneAxes {
        let lps = standard(plane, convention: convention)
        guard let m = system.fromLPS else { return lps }
        return PlaneAxes(right: m * lps.right, down: m * lps.down)
    }

    /// The plane through a grid's own index axes: the one perpendicular to
    /// the padded index axis that is closest to the standard plane's normal,
    /// with screen axes snapped to the grid's other two axes. Viewing along
    /// acquisition axes avoids reformatting an oblique acquisition.
    public static func aligned(
        _ plane: ViewPlane,
        to grid: GridGeometry,
        convention: DisplayConvention = .radiological
    ) -> PlaneAxes {
        let target = standard(plane, in: grid.coordinateSystem, convention: convention)
        let dirs = grid.axisDirections
        if grid.is2D {
            // A 2-D grid has one plane: its own. Screen-down takes the axis
            // screen-right did not, so the two never coincide.
            let inPlane = [dirs[1], dirs[2]]
            let right = snap(target.right, to: inPlane)
            let other = inPlane.filter { abs(simd_dot($0, right)) < 0.5 }
            return PlaneAxes(right: right, down: snap(target.down, to: other.isEmpty ? inPlane : other))
        }
        let right = snap(target.right, to: dirs)
        let remaining = dirs.filter { abs(simd_dot($0, right)) < 0.5 }
        let down = snap(target.down, to: remaining.isEmpty ? dirs : remaining)
        return PlaneAxes(right: right, down: down)
    }

    private static func snap(_ v: SIMD3<Double>, to candidates: [SIMD3<Double>]) -> SIMD3<Double> {
        var best = v
        var bestDot = -Double.infinity
        for c in candidates {
            let d = simd_dot(v, c)
            if abs(d) > bestDot {
                bestDot = abs(d)
                best = d >= 0 ? c : -c
            }
        }
        return best
    }
}
