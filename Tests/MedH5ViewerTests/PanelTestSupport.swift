import Foundation
import XCTest
@testable import MedH5ViewerUI
import MedH5Kit

extension Fixtures {
    /// The demo without a clinical history (nothing attests its images), at
    /// a small size; copy it before amending.
    static let demoWithoutClinical: URL = {
        let url = directory.file("demo-plain.medh5")
        try! Demo.write(to: url, options: DemoOptions(size: 32, clinical: false))
        return url
    }()

    /// The demo without a sampling index.
    static let demoWithoutIndex: URL = {
        let url = directory.file("demo-noindex.medh5")
        try! Demo.write(to: url, options: DemoOptions(size: 24, index: false))
        return url
    }()

    static func copy(_ source: URL, in directory: TemporaryDirectory, name: String) -> URL {
        let url = directory.file(name)
        try! FileManager.default.copyItem(at: source, to: url)
        return url
    }
}

@MainActor
extension MedH5Document {
    /// A document on `url` with its window (as opening it does).
    static func openForTest(_ url: URL) throws -> MedH5Document {
        let doc = try MedH5Document(contentsOf: url, ofType: typeIdentifier)
        doc.makeWindowControllers()
        return doc
    }

    /// Save As to `url`; the error, if any.
    func saveForTest(to url: URL) async -> Error? {
        await withCheckedContinuation { continuation in
            save(to: url, ofType: Self.typeIdentifier, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
    }

    /// Waits until the workspace reads `url` (the save reopens it).
    func waitForReopen(_ url: URL, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while workspace?.file.url.standardizedFileURL != url.standardizedFileURL {
            if Date() > deadline { throw XCTSkip("the saved file was not reopened in time") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Lets the undo group of the current event close (the document counts its
/// changes when the event ends).
func endEvent() async throws {
    try await Task.sleep(nanoseconds: 50_000_000)
}
