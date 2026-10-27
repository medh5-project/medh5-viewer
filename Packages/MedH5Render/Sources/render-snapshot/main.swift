// render-snapshot: renders a synthetic phantom through every view type of
// MedH5Render and writes PNGs, so the output can be inspected; `bench`
// measures upload and frame times.
//
//   render-snapshot <output-directory>
//   render-snapshot bench
import Foundation
import MedH5Render

let arguments = Array(CommandLine.arguments.dropFirst())
guard let first = arguments.first else {
    log("usage: render-snapshot <output-directory> | render-snapshot bench")
    exit(2)
}
do {
    let context = try RenderContext()
    log("device: \(context.device.name), float32 filtering: \(context.supportsFloat32Filtering)")
    if first == "bench" {
        try Bench(context: context).run()
    } else {
        let output = URL(fileURLWithPath: first, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let snapshots = try Snapshots(context: context, output: output)
        try snapshots.slices()
        try snapshots.fusion()
        try snapshots.probabilityMap()
        try snapshots.slab()
        try snapshots.oblique()
        try snapshots.zoomedOutlines()
        try snapshots.ignoreRegion()
        try snapshots.colormaps()
        try snapshots.volumes()
    }
} catch RenderError.noMetalDevice {
    log("no Metal device")
    exit(1)
} catch {
    log("error: \(error)")
    exit(1)
}
