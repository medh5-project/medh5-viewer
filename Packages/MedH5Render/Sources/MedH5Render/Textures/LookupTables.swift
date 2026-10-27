import Foundation
import Metal
import MedH5Core

/// Width of every colormap lookup table texture (texels per row).
let lookupTableWidth = 256

/// All built-in ``Colormap``s as one 2-D texture, a row per map (256 × N,
/// `rgba8Unorm`). Image layers choose a row with a uniform, so switching
/// colormaps binds nothing new. Made once per ``RenderContext``.
public final class ColormapAtlas: @unchecked Sendable {
    /// The atlas texture: width 256, one row per `Colormap.allCases` entry.
    public let texture: any MTLTexture
    private let rows: [Colormap: Int]

    init(device: any MTLDevice) throws {
        let maps = Colormap.allCases
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: lookupTableWidth, height: maps.count, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else {
            throw RenderError.allocationFailed("colormap atlas")
        }
        t.label = "colormaps"
        var rows: [Colormap: Int] = [:]
        for (row, map) in maps.enumerated() {
            let table = map.table(entries: lookupTableWidth)
            table.withUnsafeBytes { raw in
                t.replace(region: MTLRegionMake2D(0, row, lookupTableWidth, 1), mipmapLevel: 0,
                          withBytes: raw.baseAddress!, bytesPerRow: lookupTableWidth * 4)
            }
            rows[map] = row
        }
        texture = t
        self.rows = rows
    }

    /// The row holding `map`.
    public func row(of map: Colormap) -> Int { rows[map] ?? 0 }

    /// The normalised `v` texture coordinate of `map`'s row centre.
    public func textureRow(of map: Colormap) -> Float {
        (Float(row(of: map)) + 0.5) / Float(texture.height)
    }
}

/// A custom colormap: a 256-entry RGBA table (alpha included, so a map can
/// fade in), for image and probability layers. Interpolated linearly between
/// entries.
public final class LookupTable: @unchecked Sendable {
    /// One row, 256 texels, `rgba8Unorm`.
    public let texture: any MTLTexture

    /// A table from colours; resampled to 256 entries when `colors` has
    /// another count.
    public init(context: RenderContext, colors: [RGBA8]) throws {
        precondition(!colors.isEmpty, "a lookup table needs colours")
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: lookupTableWidth, height: 1, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = context.device.makeTexture(descriptor: d) else {
            throw RenderError.allocationFailed("lookup table")
        }
        t.label = "lookup table"
        texture = t
        update(colors)
    }

    /// A table sampling a built-in colormap with a constant alpha ramp:
    /// alpha goes from `alphaStart` to `alphaEnd`.
    public convenience init(context: RenderContext, colormap: Colormap,
                            alphaStart: Double = 1, alphaEnd: Double = 1) throws {
        let table = colormap.table(entries: lookupTableWidth).enumerated().map { i, c -> RGBA8 in
            let a = alphaStart + (alphaEnd - alphaStart) * Double(i) / Double(lookupTableWidth - 1)
            return RGBA8(c.r, c.g, c.b, UInt8((min(1, max(0, a)) * 255).rounded()))
        }
        try self.init(context: context, colors: table)
    }

    /// Replaces the entries.
    public func update(_ colors: [RGBA8]) {
        var table = [RGBA8](repeating: RGBA8(0, 0, 0, 0), count: lookupTableWidth)
        for i in 0..<lookupTableWidth {
            if colors.count == lookupTableWidth {
                table[i] = colors[i]
            } else {
                let f = Double(i) / Double(lookupTableWidth - 1) * Double(colors.count - 1)
                let j = min(colors.count - 1, Int(f))
                let k = min(colors.count - 1, j + 1)
                let w = f - Double(j)
                func lerp(_ a: UInt8, _ b: UInt8) -> UInt8 {
                    UInt8((Double(a) + (Double(b) - Double(a)) * w).rounded())
                }
                let a = colors[j], b = colors[k]
                table[i] = RGBA8(lerp(a.r, b.r), lerp(a.g, b.g), lerp(a.b, b.b), lerp(a.a, b.a))
            }
        }
        table.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, lookupTableWidth, 1), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: lookupTableWidth * 4)
        }
    }

    /// The `v` coordinate of the single row.
    var textureRow: Float { 0.5 }
}

/// The colour and visibility of every class id of a segmentation: 65536
/// entries as a 256 × 256 `rgba8Unorm` texture (class `id` at texel
/// `(id % 256, id / 256)`), alpha 0 for hidden classes.
///
/// Toggling a class or changing a colour edits a CPU copy and marks its row
/// dirty; ``synchronize()`` (which every renderer calls before drawing)
/// uploads only the dirty rows, so updates cost microseconds. Several label
/// layers may share one table (one label set).
public final class LabelLookupTable: @unchecked Sendable {
    /// The table texture. Up to date after ``synchronize()``.
    public let texture: any MTLTexture

    private let lock = NSLock()
    private var colors: [RGBA8]
    private var visible: [Bool]
    private var dirtyRows = Set<Int>()
    private var shownVersion = 0

    /// Incremented whenever the set of drawn classes changes (visibility, or
    /// a colour's alpha becoming zero or nonzero) — what 3-D label surfaces
    /// depend on.
    public var visibilityVersion: Int {
        lock.lock()
        defer { lock.unlock() }
        return shownVersion
    }

    private func isShown(_ id: Int) -> Bool { visible[id] && colors[id].a > 0 }

    /// A table with `LabelPalette`'s colours for every class, overridden by
    /// `colors`; class 0 (background) and 65535 (ignore) are transparent.
    public init(context: RenderContext, colors overrides: [UInt16: RGBA8] = [:]) throws {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 256,
                                                         mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = context.device.makeTexture(descriptor: d) else {
            throw RenderError.allocationFailed("label lookup table")
        }
        t.label = "label lookup table"
        texture = t
        var table = [RGBA8](repeating: RGBA8(0, 0, 0, 0), count: 65536)
        for id in 1..<65535 {
            table[id] = LabelPalette.color(forClassID: id)
        }
        for (id, c) in overrides { table[Int(id)] = c }
        colors = table
        visible = [Bool](repeating: true, count: 65536)
        visible[0] = false
        visible[65535] = false
        dirtyRows = Set(0..<256)
        synchronize()
    }

    /// The colour of a class (its alpha as stored, regardless of visibility).
    public func color(forClass id: UInt16) -> RGBA8 {
        lock.lock()
        defer { lock.unlock() }
        return colors[Int(id)]
    }

    /// Sets a class's colour (alpha scales the class's opacity).
    public func setColor(_ color: RGBA8, forClass id: UInt16) {
        lock.lock()
        let was = isShown(Int(id))
        colors[Int(id)] = color
        if was != isShown(Int(id)) { shownVersion += 1 }
        dirtyRows.insert(Int(id) >> 8)
        lock.unlock()
    }

    /// Sets several colours at once.
    public func setColors(_ map: [UInt16: RGBA8]) {
        lock.lock()
        for (id, c) in map {
            let was = isShown(Int(id))
            colors[Int(id)] = c
            if was != isShown(Int(id)) { shownVersion += 1 }
            dirtyRows.insert(Int(id) >> 8)
        }
        lock.unlock()
    }

    /// Whether a class is drawn.
    public func isVisible(_ id: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return visible[Int(id)]
    }

    /// Shows or hides a class.
    public func setVisible(_ isVisible: Bool, forClass id: UInt16) {
        lock.lock()
        if visible[Int(id)] != isVisible { shownVersion += 1 }
        visible[Int(id)] = isVisible
        dirtyRows.insert(Int(id) >> 8)
        lock.unlock()
    }

    /// Shows or hides every class except background and ignore.
    public func setAllVisible(_ isVisible: Bool) {
        lock.lock()
        for id in 1..<65535 { visible[id] = isVisible }
        dirtyRows = Set(0..<256)
        shownVersion += 1
        lock.unlock()
    }

    /// Shows exactly `ids`.
    public func showOnly(_ ids: Set<UInt16>) {
        lock.lock()
        for id in 1..<65535 { visible[id] = ids.contains(UInt16(id)) }
        dirtyRows = Set(0..<256)
        shownVersion += 1
        lock.unlock()
    }

    /// Uploads the rows changed since the last call. Cheap when nothing
    /// changed.
    public func synchronize() {
        lock.lock()
        defer { lock.unlock() }
        guard !dirtyRows.isEmpty else { return }
        var row = [RGBA8](repeating: RGBA8(0, 0, 0, 0), count: 256)
        for r in dirtyRows {
            for x in 0..<256 {
                let id = r * 256 + x
                var c = colors[id]
                if !visible[id] { c.a = 0 }
                row[x] = c
            }
            row.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, r, 256, 1), mipmapLevel: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: 256 * 4)
            }
        }
        dirtyRows.removeAll()
    }
}
