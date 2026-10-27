import XCTest
@testable import MedH5ViewerUI
import MedH5Kit

/// The clinical history window: the timeline's layout, times on the subject
/// clock, and what was known at a cutoff, selected by the engine.
@MainActor
final class ClinicalWindowTests: XCTestCase {
    private func clock(_ reference: String) throws -> ClinicalClock {
        try JSONValue.object(JSONObject([("id", "c"), ("unit", "us"), ("reference", .string(reference))])).decode(ClinicalClock.self)
    }

    func testTimesOnTheSubjectClock() throws {
        let h = ClinicalTime.hour, d = ClinicalTime.day
        let relative = try clock("relative")
        XCTAssertEqual(ClinicalTime.describe(0, clock: relative), "day 0, 00:00")
        XCTAssertEqual(ClinicalTime.describe(36 * h, clock: relative), "day 1, 12:00")
        XCTAssertEqual(ClinicalTime.describe(-3 * d + 2 * h, clock: relative), "day −3, 02:00", "days count down from the origin, floored")
        XCTAssertEqual(ClinicalTime.describe(TimeBounds(lo: 0, hi: d), clock: relative), "day 0, 00:00 – day 1, 00:00")
        XCTAssertEqual(ClinicalTime.offset(36 * h), "+36 h")
        XCTAssertEqual(ClinicalTime.offset(-3 * d), "−3 d")
        XCTAssertEqual(ClinicalTime.floorDiv(-1, 10), -1)
        let utc = try clock("utc")
        XCTAssertEqual(ClinicalTime.describe(1_700_000_000_000_000, clock: utc), "2023-11-14 22:13")
        XCTAssertEqual(ClinicalTime.step(span: 100 * d, count: 10), 14 * d)
    }

    /// The demo's history: the timeline spans every event; the imaging
    /// timepoints sit at their scans; at 36 h the engine knows the amended
    /// report, not the preliminary one nor the follow-up; at 100 days the
    /// assessment.
    func testTheCutoffShowsWhatWasKnown() async throws {
        let w = Workspace(file: try SampleFile.open(Fixtures.demo), displayName: "demo", context: nil)
        let model = ClinicalModel(workspace: w)
        model.load()
        await model.wait()
        let records = try XCTUnwrap(model.records)
        XCTAssertEqual(records.events.count, 11)
        for e in records.events {
            for t in ClinicalTimeline.times(e) { XCTAssertTrue(model.domain.contains(t), "\(e.eventID) on the timeline") }
        }
        XCTAssertEqual(ClinicalTimeline.rows(records), ["imaging", "document", "observation", "assessment", "other"])
        let markers = ClinicalTimeline.timepointMarkers(records, summary: w.summary)
        XCTAssertEqual(markers.map(\.id), ["tp0", "tp1"])
        XCTAssertEqual(markers.first?.at, 0)
        XCTAssertEqual(markers.last?.at, 92 * ClinicalTime.day)
        XCTAssertEqual(model.cutoff, model.domain.upperBound, "opens knowing everything")
        XCTAssertEqual(Set(model.selection?.eventIDs ?? []).count, model.knownEventIDs.count)

        await model.select(at: 36 * ClinicalTime.hour)
        let known = model.knownEventIDs
        let engine = try w.file.clinicalSelect(cutoffHours: 36)
        XCTAssertEqual(known, Set(engine.eventIDs), "the window shows the engine's selection")
        XCTAssertTrue(known.contains("report0_v2"))
        XCTAssertFalse(known.contains("report0_v1"), "superseded by its amendment")
        XCTAssertFalse(known.contains("ct1"), "the follow-up had not happened")
        XCTAssertEqual(model.knownDocumentIDs, ["report0_text_v2"])
        XCTAssertEqual(model.selection?.policy, "strict_prospective")

        await model.select(at: 100 * ClinicalTime.day)
        XCTAssertTrue(model.knownEventIDs.contains("response1"))

        // The order the table shows: by when each happened.
        XCTAssertEqual(model.events.first?.eventID, "alt0")
        XCTAssertEqual(ClinicalTimeline.value(try XCTUnwrap(records.event("afp1"))), "480 ng/mL (1834-1)")

        // An event's document, and the grounded span in the follow-up report.
        model.selectEvent("report1")
        XCTAssertEqual(model.selectedDocumentID, "report1_text")
        let deadline = Date().addingTimeInterval(10)
        while model.texts["report1_text"] == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let text = try XCTUnwrap(model.texts["report1_text"])
        let spans = model.spans(in: "report1_text")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual((text as NSString).substring(with: spans[0]), "54 mm")
        XCTAssertTrue(model.links(of: "response1").contains { $0.relation == "assesses" })
    }

    func testASampleWithoutAHistory() async throws {
        let w = Workspace(file: try SampleFile.open(Fixtures.demoWithoutClinical), displayName: "plain", context: nil)
        let model = ClinicalModel(workspace: w)
        model.load()
        await model.wait()
        XCTAssertFalse(model.hasHistory)
        XCTAssertNil(model.state.failure)
    }
}
