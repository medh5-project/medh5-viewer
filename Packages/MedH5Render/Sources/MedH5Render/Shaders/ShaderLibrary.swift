import Foundation
import Metal

/// The engine's shaders: Metal Shading Language source embedded in Swift
/// strings (one file per area), compiled at run time once per device.
///
/// No `.metal` files and no SwiftPM resources: the app bundle is assembled by
/// a script and resource bundles break code signing, and building needs no
/// Metal toolchain.
enum ShaderLibrary {
    /// The complete source, in dependency order.
    static var source: String {
        [
            CommonShaders.source,
            SliceShaders.source,
            OverlayShaders.source,
            VolumeShaders.source,
            MeshShaders.source,
            UtilityShaders.source,
        ].joined(separator: "\n")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [UInt64: any MTLLibrary] = [:]

    /// The compiled library for `device`, compiled on first use.
    static func library(for device: any MTLDevice) throws -> any MTLLibrary {
        lock.lock()
        defer { lock.unlock() }
        if let lib = cache[device.registryID] { return lib }
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        let lib: any MTLLibrary
        do {
            lib = try device.makeLibrary(source: source, options: options)
        } catch {
            throw RenderError.shaderCompilation("\(error)")
        }
        lib.label = "MedH5Render"
        cache[device.registryID] = lib
        return lib
    }
}
