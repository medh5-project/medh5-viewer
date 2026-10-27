import XCTest
@testable import MedH5Kit

final class LibraryTests: XCTestCase {
    func testVersionsThreadsCodesAndLevels() throws {
        XCTAssertEqual(MedH5.engineVersion, "2.2.3")
        XCTAssertEqual(MedH5.formatVersion, "1.2")
        XCTAssertFalse(MedH5.bridgeVersion.isEmpty)
        let before = MedH5.threads
        MedH5.setThreads(4)
        XCTAssertEqual(MedH5.threads, 4)
        MedH5.setThreads(0)
        XCTAssertGreaterThanOrEqual(MedH5.threads, 1)
        MedH5.setThreads(before)
        let codes = try MedH5.codeTable()
        XCTAssertGreaterThan(codes.count, 90)
        let e701 = try XCTUnwrap(codes.first { $0.code == "E701" })
        XCTAssertEqual(e701.severity, "error")
        XCTAssertEqual(e701.domain, "integrity")
        XCTAssertEqual(try MedH5.validationLevels(), ["structural", "semantic", "integrity", "strict"])
    }

    func testErrorsCarryKindCodeAndMessage() {
        XCTAssertThrowsMedH5(try SampleFile.open(URL(fileURLWithPath: "/nonexistent/sample.medh5")), status: .failed)
        do {
            _ = try SampleFile.open(URL(fileURLWithPath: "/nonexistent/sample.medh5"))
        } catch let error as MedH5Error {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.isCancellation)
        } catch {
            XCTFail("\(error)")
        }
    }
}
