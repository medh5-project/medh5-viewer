import Foundation

/// An 8-bit RGBA colour, as a label set stores one (spec §5.2).
public struct RGBA8: Sendable, Hashable, Codable, CustomStringConvertible {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// From a label set's `color` array (3 or 4 integers 0–255).
    public init?(array: [Int]) {
        guard array.count == 3 || array.count == 4 else { return nil }
        let c = array.map { UInt8(clamping: $0) }
        self.init(c[0], c[1], c[2], array.count == 4 ? c[3] : 255)
    }

    public var array: [Int] { [Int(r), Int(g), Int(b), Int(a)] }

    /// Components in 0…1.
    public var normalized: SIMD4<Float> {
        SIMD4(Float(r), Float(g), Float(b), Float(a)) / 255
    }

    public var description: String {
        String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
        } else {
            self.init(UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
        }
    }
}

/// Reserved class ids (spec §5.3).
public enum ClassID {
    /// Background: explicitly no class.
    public static let background: UInt16 = 0
    /// Ignore: outside what was annotated; neither foreground nor background.
    public static let ignore: UInt16 = 65535
}

/// Colours for classes whose label set gives none.
public enum LabelPalette {
    /// A qualitative palette of distinguishable colours, the first few chosen
    /// to read well over grayscale anatomy.
    public static let colors: [RGBA8] = [
        RGBA8(230, 25, 75), RGBA8(60, 180, 75), RGBA8(255, 225, 25), RGBA8(0, 130, 200),
        RGBA8(245, 130, 48), RGBA8(145, 30, 180), RGBA8(70, 240, 240), RGBA8(240, 50, 230),
        RGBA8(210, 245, 60), RGBA8(250, 190, 212), RGBA8(0, 128, 128), RGBA8(220, 190, 255),
        RGBA8(170, 110, 40), RGBA8(255, 250, 200), RGBA8(128, 0, 0), RGBA8(170, 255, 195),
        RGBA8(128, 128, 0), RGBA8(255, 215, 180), RGBA8(0, 0, 128), RGBA8(128, 128, 128),
        RGBA8(255, 99, 71), RGBA8(124, 252, 0), RGBA8(30, 144, 255), RGBA8(255, 165, 0),
        RGBA8(186, 85, 211), RGBA8(0, 206, 209), RGBA8(255, 20, 147), RGBA8(154, 205, 50),
        RGBA8(244, 164, 96), RGBA8(100, 149, 237), RGBA8(221, 160, 221), RGBA8(46, 139, 87),
    ]

    /// The colour of a class id: the palette in order, then golden-angle hues.
    public static func color(forClassID id: Int) -> RGBA8 {
        guard id > 0 else { return RGBA8(0, 0, 0, 0) }
        if id <= colors.count { return colors[id - 1] }
        let hue = (Double(id) * 0.618033988749895).truncatingRemainder(dividingBy: 1)
        return hsv(hue: hue, saturation: 0.75, value: 0.95)
    }

    /// The colour used for the ignore region.
    public static let ignoreColor = RGBA8(255, 255, 255, 96)

    static func hsv(hue: Double, saturation s: Double, value v: Double) -> RGBA8 {
        let h = hue * 6
        let i = Int(h) % 6
        let f = h - Double(Int(h))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return RGBA8(UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }
}
