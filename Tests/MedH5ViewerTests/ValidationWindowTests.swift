import XCTest
@testable import MedH5ViewerUI
import MedH5Kit

/// Validate… and Verify Integrity: the report grouped by severity, filtered,
/// copied and exported; runs against the demo and a damaged copy.
@MainActor
final class ValidationWindowTests: XCTestCase {
    private func report(_ diagnostics: [(String, String, String, String, String)]) throws -> ValidationReport {
        let json: JSONValue = .object(JSONObject([
            ("path", "/x.medh5"), ("level", "strict"), ("profiles", .strings(["core", "seg"])), ("ok", false),
            ("errors", .int(Int64(diagnostics.filter { $0.2 == "error" }.count))),
            ("warnings", .int(Int64(diagnostics.filter { $0.2 == "warning" }.count))), ("promoted", 1),
            ("codes", .strings(diagnostics.map(\.0))),
            ("diagnostics", .array(diagnostics.map { d in
                .object(JSONObject([("code", .string(d.0)), ("severity", .string(d.1)), ("effective_severity", .string(d.2)),
                                    ("location", .string(d.3)), ("message", .string(d.4)), ("level", "semantic"),
                                    ("summary", .string("summary of \(d.0)"))]))
            })),
            ("checked", ["objects": 12]),
        ]))
        return try json.decode(ValidationReport.self)
    }

    func testFindingsAreGroupedBySeverityFilteredAndCopied() throws {
        let r = try report([
            ("W914", "warning", "warning", "/clinical/events#lab0", "a numeric value carries no unit"),
            ("E701", "error", "error", "/images/CT", "digest mismatch"),
            ("W305", "warning", "error", "/meta#/label_set", "a promoted warning"),
            ("E402", "error", "error", "/annotations/organs", "class 13 is not in the label set"),
        ])
        let groups = ValidationPresentation.groups(r)
        XCTAssertEqual(groups.map(\.severity), ["error", "warning"], "errors first")
        XCTAssertEqual(groups[0].rows.map(\.diagnostic.code), ["E701", "W305", "E402"], "report order within a group")
        XCTAssertEqual(groups[0].title, "Errors")
        XCTAssertTrue(groups[0].rows[1].isPromoted, "strict promotes the warning; it shows under errors")
        XCTAssertEqual(ValidationPresentation.counts(r), ["error": 3, "warning": 1])
        XCTAssertEqual(ValidationPresentation.headline(r), "3 errors, 1 warning")

        XCTAssertEqual(ValidationPresentation.groups(r, filter: "e701").flatMap(\.rows).map(\.diagnostic.code), ["E701"])
        XCTAssertEqual(ValidationPresentation.groups(r, filter: "organs label").flatMap(\.rows).map(\.diagnostic.code), ["E402"],
                       "every word must match: location and message")
        XCTAssertEqual(ValidationPresentation.groups(r, filter: "summary of W914").flatMap(\.rows).map(\.diagnostic.code), ["W914"],
                       "the code table's summary is searched too")
        XCTAssertEqual(ValidationPresentation.groups(r, hidden: ["error"]).map(\.severity), ["warning"])
        XCTAssertTrue(ValidationPresentation.groups(r, filter: "nothing like this").isEmpty)

        let text = ValidationPresentation.text(groups[0].rows)
        XCTAssertEqual(text.split(separator: "\n").first, "E701 error /images/CT: digest mismatch")
        XCTAssertTrue(text.contains("W305 error (promoted from warning) /meta#/label_set: a promoted warning"))
    }

    func testTheJSONExportKeepsTheEngineMemberOrderAndReadsBack() throws {
        let r = try report([("E701", "error", "error", "/images/CT", "digest mismatch")])
        let json = ValidationPresentation.json(r)
        XCTAssertEqual(json.objectValue?.keys, ["path", "level", "profiles", "ok", "errors", "warnings", "promoted", "codes",
                                               "diagnostics", "checked"])
        XCTAssertEqual(json["diagnostics"]?[0]?.objectValue?.keys,
                       ["code", "severity", "effective_severity", "location", "message", "level", "summary"])
        let back = try JSONValue.parse(json.serialized(.pretty)).decode(ValidationReport.self)
        XCTAssertEqual(back, r, "what is exported reads back as the same report")
        XCTAssertEqual(json["checked"]?["objects"], .int(12))
    }

    /// The window's model on the demo (valid at every level), then on
    /// invalid cases of the engine's conformance corpus (errors, grouped).
    func testValidatingTheDemoAndInvalidCorpusCases() async throws {
        let dir = TemporaryDirectory("validate")
        let w = Workspace(file: try SampleFile.open(Fixtures.demoCopy(in: dir)), displayName: "demo", context: nil)
        let model = ValidationModel(workspace: w)
        XCTAssertEqual(model.levels, ["structural", "semantic", "integrity", "strict"], "the levels the engine offers")
        XCTAssertEqual(model.level, "integrity")
        model.run()
        await model.wait()
        let r = try XCTUnwrap(model.report)
        XCTAssertTrue(r.ok, "\(r.codes)")
        XCTAssertEqual(r.level, "integrity")
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertFalse(model.unsavedWhenRun)
        model.setLevel("strict")
        await model.wait()
        XCTAssertEqual(model.report?.level, "strict")

        // A conformance case with errors that still opens: its errors, grouped.
        let corpus = TemporaryDirectory("corpus")
        let manifest = try Conformance.write(to: corpus.url)
        var checked = 0
        for c in manifest.cases where !c.valid && !c.expectErrors.isEmpty && c.file.hasSuffix(".medh5") {
            guard let file = try? SampleFile.open(corpus.url.appendingPathComponent(c.file)) else { continue }
            let broken = ValidationModel(workspace: Workspace(file: file, displayName: c.name, context: nil))
            broken.setLevel(c.level)
            await broken.wait()
            let b = try XCTUnwrap(broken.report, c.name)
            XCTAssertFalse(b.ok, c.name)
            XCTAssertEqual(broken.groups.first?.severity, "error", c.name)
            let codes = Set(broken.groups.first?.rows.map(\.diagnostic.code) ?? [])
            XCTAssertTrue(Set(c.expectErrors).isSubset(of: codes), "\(c.name): \(codes)")
            XCTAssertFalse(ValidationPresentation.text(broken.rowsToCopy).isEmpty)
            file.close()
            checked += 1
            if checked == 3 { break }
        }
        XCTAssertEqual(checked, 3, "three invalid cases of the corpus open and validate")
    }

    func testIntegrityListsEveryObjectWithItsDigestAndTheContentID() async throws {
        let w = Workspace(file: try SampleFile.open(Fixtures.demo), displayName: "demo", context: nil)
        let model = IntegrityModel(workspace: w)
        model.run()
        await model.wait()
        let report = try XCTUnwrap(model.report)
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.contentID.stored, w.summary.contentID)
        XCTAssertEqual(report.contentID.stored, report.contentID.computed)
        let deadline = Date().addingTimeInterval(20)
        while model.digests.count < report.objects.count && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.digests.count, report.objects.count, "every object's stored digest")
        XCTAssertTrue(model.digests.values.allSatisfy { $0.hasPrefix("sha256:") })
        XCTAssertEqual(model.rows.count, report.objects.count)
        model.onlyProblems = true
        XCTAssertTrue(model.rows.isEmpty)
        model.onlyProblems = false
        model.filter = "organs_tp0"
        XCTAssertTrue(!model.rows.isEmpty && model.rows.allSatisfy { $0.path.contains("organs_tp0") })
        let json = IntegrityPresentation.json(report, digests: model.digests)
        XCTAssertEqual(json["content_id"]?["stored"]?.stringValue, w.summary.contentID)
        XCTAssertEqual(json["objects"]?.arrayValue?.count, report.objects.count)
        XCTAssertNotNil(json["objects"]?[0]?["digest"]?.stringValue)
        XCTAssertTrue(IntegrityPresentation.problems(report).isEmpty)
        XCTAssertEqual(IntegrityPresentation.headline(report), "Every digest and the content id verify")
    }
}
