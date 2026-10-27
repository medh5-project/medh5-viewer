import Foundation
import XCTest
import simd
@testable import MedH5Kit

/// A directory of its own for a test, removed afterwards.
final class TemporaryDirectory {
    let url: URL

    init(_ tag: String = "test") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("medh5kit-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// The demo sample, written once per test process; copy it before amending.
enum Fixtures {
    static let directory = TemporaryDirectory("fixtures")

    static let demo: URL = {
        let url = directory.file("demo.medh5")
        try! Demo.write(to: url)
        return url
    }()

    /// A copy of the demo in `directory`.
    static func demoCopy(in directory: TemporaryDirectory, name: String = "demo.medh5") -> URL {
        let url = directory.file(name)
        try! FileManager.default.copyItem(at: demo, to: url)
        return url
    }
}

extension VolumeData {
    /// Every element as `Double`.
    var doubles: [Double] { (0..<count).map { value(at: $0) } }
}

func XCTAssertThrowsMedH5<T>(_ expression: @autoclosure () throws -> T, kind: String? = nil, code: String? = nil,
                             status: MedH5Error.Status? = nil, file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try expression()
        XCTFail("expected a MedH5Error", file: file, line: line)
    } catch let error as MedH5Error {
        if let kind { XCTAssertEqual(error.kind, kind, "\(error)", file: file, line: line) }
        if let code { XCTAssertEqual(error.code, code, "\(error)", file: file, line: line) }
        if let status { XCTAssertEqual(error.status, status, "\(error)", file: file, line: line) }
        XCTAssertFalse(error.message.isEmpty, file: file, line: line)
    } catch {
        XCTFail("expected a MedH5Error, got \(error)", file: file, line: line)
    }
}

func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tolerance: Double = 1e-6) -> Bool {
    simd_distance(a, b) <= tolerance * max(1, simd_length(b))
}
