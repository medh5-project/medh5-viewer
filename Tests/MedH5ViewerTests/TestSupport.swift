import Foundation
import XCTest
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Render

/// A directory of its own for a test, removed afterwards.
final class TemporaryDirectory {
    let url: URL

    init(_ tag: String = "test") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("medh5-viewer-tests-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// The demo sample, written once per test process at a small size; copy it
/// before amending.
enum Fixtures {
    static let directory = TemporaryDirectory("fixtures")

    static let demo: URL = {
        let url = directory.file("demo.medh5")
        try! Demo.write(to: url, options: DemoOptions(size: 32))
        return url
    }()

    static func demoCopy(in directory: TemporaryDirectory, name: String = "demo.medh5") -> URL {
        let url = directory.file(name)
        try! FileManager.default.copyItem(at: demo, to: url)
        return url
    }
}

@MainActor
extension Workspace {
    /// A workspace on the demo sample, with the given render context.
    static func demo(context: RenderContext? = RenderContext.shared) throws -> Workspace {
        Workspace(file: try SampleFile.open(Fixtures.demo), displayName: "demo", context: context)
    }

    /// Loads everything the views need now (as the resource tracking would).
    func loadNeeded(timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let keys = neededResources()
            for key in keys where store.failure(key) == nil {
                _ = try? await store.resource(key)
            }
            let pending = keys.filter { !store.isReady($0) && store.failure($0) == nil }
            if pending.isEmpty { return }
            if Date() > deadline { throw XCTSkip("timed out loading \(pending)") }
            // Awaiting a finished load does not suspend: let the store's own
            // completion (a main-actor task) run, or this loop spins.
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
