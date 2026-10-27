import AppKit
import SwiftUI
import Observation
import MedH5Kit

/// Times on a clinical history's subject clock (1.1 §3): microseconds from
/// an origin (`relative`), or since 1970 in UTC (`utc`, `shifted_utc`).
enum ClinicalTime {
    static let minute: Int64 = 60_000_000
    static let hour: Int64 = 3_600_000_000
    static let day: Int64 = 86_400_000_000

    static func isAbsolute(_ clock: ClinicalClock) -> Bool { clock.reference != "relative" }

    /// "day 3, 04:00" on a relative clock (days counted from the origin,
    /// floor), "2026-01-31 04:00" on a UTC one.
    static func describe(_ us: Int64, clock: ClinicalClock) -> String {
        if isAbsolute(clock) {
            let date = Date(timeIntervalSince1970: Double(us) / 1e6)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = us % day == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
            return f.string(from: date)
        }
        let d = floorDiv(us, day)
        let rest = us - d * day
        let h = rest / hour, m = (rest % hour) / minute
        let dayText = d < 0 ? "−\(-d)" : "\(d)"
        return String(format: "day %@, %02d:%02d", dayText, h, m)
    }

    /// Bounds as one time, or "lo – hi" when the source knew less.
    static func describe(_ bounds: TimeBounds?, clock: ClinicalClock) -> String {
        guard let bounds else { return "—" }
        if bounds.lo == bounds.hi { return describe(bounds.lo, clock: clock) }
        return "\(describe(bounds.lo, clock: clock)) – \(describe(bounds.hi, clock: clock))"
    }

    /// A short axis label.
    static func tick(_ us: Int64, step: Int64, clock: ClinicalClock) -> String {
        if isAbsolute(clock) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = step < day ? "MM-dd HH:mm" : "yyyy-MM-dd"
            return f.string(from: Date(timeIntervalSince1970: Double(us) / 1e6))
        }
        if step < day {
            let d = floorDiv(us, day), h = (us - d * day) / hour
            return h == 0 ? "d\(d)" : "\(h)h"
        }
        let d = floorDiv(us, day)
        return d == 0 ? "day 0" : "d\(d < 0 ? "−\(-d)" : "\(d)")"
    }

    /// An offset from the origin: "+36 h", "+92 d", "−3 d".
    static func offset(_ us: Int64) -> String {
        let sign = us < 0 ? "−" : "+"
        let a = abs(us)
        if a % day == 0 { return "\(sign)\(a / day) d" }
        if a < 4 * day { return "\(sign)\(Format.number(Double(a) / Double(hour), digits: 1)) h" }
        return "\(sign)\(Format.number(Double(a) / Double(day), digits: 1)) d"
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// A tick step giving at most about `count` ticks over `span`.
    static func step(span: Int64, count: Int) -> Int64 {
        let steps: [Int64] = [hour, 3 * hour, 6 * hour, 12 * hour, day, 2 * day, 7 * day, 14 * day, 30 * day,
                              60 * day, 90 * day, 180 * day, 365 * day, 730 * day, 1825 * day]
        return steps.first { span / $0 <= Int64(max(1, count)) } ?? steps.last!
    }
}

/// The layout of a clinical history on its clock.
enum ClinicalTimeline {
    /// Rows of the timeline, by event kind, in this order.
    static let kindOrder = ["imaging", "document", "observation", "assessment", "procedure", "medication",
                            "condition", "encounter", "other"]

    /// Every bound an event has.
    static func times(_ e: ClinicalEvent) -> [Int64] {
        [e.effectiveStart, e.effectiveEnd, e.available].compactMap { $0 }.flatMap { [$0.lo, $0.hi] }
    }

    /// The extent of the history (every effective and available bound),
    /// padded by 4 % on each side.
    static func domain(_ records: ClinicalRecords) -> ClosedRange<Int64> {
        let all = records.events.flatMap(times)
        guard let lo = all.min(), let hi = all.max() else { return 0...ClinicalTime.day }
        let pad = max(ClinicalTime.hour, (hi - lo) / 25)
        return (lo - pad)...(hi + pad)
    }

    /// The kinds present, in row order.
    static func rows(_ records: ClinicalRecords) -> [String] {
        let present = Set(records.events.map(\.kind))
        return kindOrder.filter(present.contains) + present.subtracting(kindOrder).sorted()
    }

    /// The imaging timepoints on the clock: each timepoint's first imaging
    /// event (its effective start).
    static func timepointMarkers(_ records: ClinicalRecords, summary: SampleSummary) -> [(id: String, label: String, at: Int64)] {
        var out: [(String, String, Int64)] = []
        for tp in summary.timepoints.sorted(by: { $0.index < $1.index }) {
            let times = records.events.filter { $0.kind == "imaging" && $0.timepointID == tp.id }.compactMap { $0.effectiveStart?.lo }
            if let at = times.min() { out.append((tp.id, tp.label?.capitalizedFirst ?? tp.id, at)) }
        }
        return out
    }

    /// When an event happened, for ordering: its effective start (else its
    /// availability).
    static func order(_ e: ClinicalEvent) -> Int64 { e.effectiveStart?.lo ?? e.available?.lo ?? Int64.max }

    /// What the event says: a value with its unit, a text, a code.
    static func value(_ e: ClinicalEvent) -> String {
        var parts: [String] = []
        if let v = e.valueNum {
            parts.append([e.valueComparator, Format.number(v, digits: 4), e.unit].compactMap { $0 }.joined(separator: " "))
        }
        if let t = e.valueText { parts.append(t) }
        if let code = e.code { parts.append(parts.isEmpty ? "\(e.codeSystem.map(shortSystem) ?? "")\(e.codeSystem == nil ? "" : " ")\(code)" : "(\(code))") }
        if let reason = e.missingReason { parts.append("missing: \(reason)") }
        return parts.joined(separator: " ")
    }

    static func shortSystem(_ system: String) -> String {
        switch system {
        case "http://loinc.org": return "LOINC"
        case "http://snomed.info/sct": return "SCT"
        default: return system.split(separator: "/").last.map(String.init) ?? system
        }
    }
}

/// Window ▸ Clinical History (format 1.1): the events on the subject clock,
/// when each happened and when it became known, and what was known at a
/// cutoff — selected by the engine (strict prospective selection, 1.1 §9).
@MainActor
@Observable
final class ClinicalModel {
    let workspace: Workspace
    private(set) var records: ClinicalRecords?
    private(set) var state: TaskState = .idle
    private(set) var domain: ClosedRange<Int64> = 0...ClinicalTime.day
    private(set) var cutoff: Int64 = 0
    private(set) var selection: ClinicalSelection?
    private(set) var selectionError: String?
    var selectedEventID: String?
    var selectedDocumentID: String?
    private(set) var texts: [String: String] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var selectTask: Task<Void, Never>?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    var hasHistory: Bool { records != nil }

    func load() {
        loadTask?.cancel()
        let file = workspace.file
        state = .running("Reading the clinical history…")
        loadTask = Task { [weak self] in
            do {
                let records = try await blocking { try file.clinicalRecords() }
                guard let self, !Task.isCancelled else { return }
                self.records = records
                self.state = .idle
                if let records {
                    self.domain = ClinicalTimeline.domain(records)
                    self.selectedDocumentID = records.documents.first?.documentID
                    await self.select(at: self.domain.upperBound)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(VolumeStore.describe(error))
            }
        }
    }

    /// Waits for the load (and its first selection).
    func wait() async {
        await loadTask?.value
        await selectTask?.value
    }

    /// Moves the cutoff; the engine's selection follows (debounced).
    func setCutoff(_ us: Int64) {
        cutoff = min(max(us, domain.lowerBound), domain.upperBound)
        selectTask?.cancel()
        let target = cutoff
        selectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            await self?.select(at: target)
        }
    }

    /// What was known at `us`, as the engine selects it.
    func select(at us: Int64) async {
        cutoff = us
        let file = workspace.file
        do {
            let s = try await blocking { try file.clinicalSelect(cutoffMicroseconds: us) }
            guard cutoff == us else { return }
            selection = s
            selectionError = nil
        } catch {
            selection = nil
            selectionError = VolumeStore.describe(error)
        }
    }

    var knownEventIDs: Set<String> { Set(selection?.eventIDs ?? []) }

    var knownDocumentIDs: Set<String> { Set(selection?.documents ?? []) }

    /// Events in time order.
    var events: [ClinicalEvent] {
        (records?.events ?? []).sorted { (ClinicalTimeline.order($0), $0.available?.lo ?? 0) < (ClinicalTimeline.order($1), $1.available?.lo ?? 0) }
    }

    /// The links of an event (from it, to it, or asserted by it).
    func links(of eventID: String) -> [ClinicalLink] {
        (records?.links ?? []).filter {
            ($0.sourceType == "event" && $0.sourceID == eventID) || ($0.targetType == "event" && $0.targetID == eventID)
                || $0.assertedByEventID == eventID
        }
    }

    /// The document an event owns (its `describes` link to a document).
    func document(of eventID: String) -> String? {
        records?.links.first { $0.sourceType == "event" && $0.sourceID == eventID && $0.targetType == "document" && $0.relation == "describes" }?.targetID
    }

    func selectEvent(_ id: String?) {
        selectedEventID = id
        if let id, let doc = document(of: id) { showDocument(doc) }
    }

    func showDocument(_ id: String) {
        selectedDocumentID = id
        guard texts[id] == nil else { return }
        let file = workspace.file
        Task { [weak self] in
            let text = (try? await blocking { try file.clinicalDocumentText(id) }) ?? ""
            self?.texts[id] = text
        }
    }

    /// The grounded spans of a document (UTF-8 byte ranges in the links),
    /// as ranges of its text.
    func spans(in documentID: String) -> [NSRange] {
        guard let text = texts[documentID] else { return [] }
        let utf8 = text.utf8
        return (records?.links ?? []).compactMap { link -> NSRange? in
            guard link.sourceType == "document", link.sourceID == documentID, let span = link.sourceSpan, span.count == 2,
                  let a = utf8.index(utf8.startIndex, offsetBy: Int(span[0]), limitedBy: utf8.endIndex),
                  let b = utf8.index(utf8.startIndex, offsetBy: Int(span[1]), limitedBy: utf8.endIndex), a <= b
            else { return nil }
            return NSRange(a..<b, in: text)
        }
    }
}

// MARK: - Views

struct ClinicalHistoryView: View {
    @Bindable var model: ClinicalModel

    var body: some View {
        Group {
            if let failure = model.state.failure {
                VStack { NoticeBar(style: .error, text: failure); Spacer() }
            } else if let records = model.records {
                content(records)
            } else if model.state.isRunning {
                ProgressView("Reading the clinical history…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: Symbols.clinical).font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
                    Text("No clinical history").font(.title3.weight(.semibold))
                    Text("This sample holds no clinical profile. Format 1.1 records labs, reports and assessments on a subject clock beside the images.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    private func content(_ records: ClinicalRecords) -> some View {
        VStack(spacing: 0) {
            ClinicalHeader(model: model, records: records)
            if records.projection {
                NoticeBar(style: .warning, text: "Read from a later format minor: what this engine knows of the history is shown.")
            }
            Divider()
            CutoffBar(model: model, records: records)
            ClinicalTimelineView(model: model, records: records)
                .frame(height: CGFloat(ClinicalTimeline.rows(records).count) * 30 + 64)
            Divider()
            HSplitView {
                ClinicalEventTable(model: model, records: records)
                    .frame(minWidth: 460, idealWidth: 760)
                ClinicalSidePanel(model: model, records: records)
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 420)
            }
        }
    }
}

private struct ClinicalHeader: View {
    let model: ClinicalModel
    let records: ClinicalRecords

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Symbols.clinical).font(.system(size: 26)).foregroundStyle(.secondary).frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("Clinical history").font(.system(size: 17, weight: .semibold))
                Text("Clock \(records.clock.id) · \(records.clock.reference)\(records.clock.originDescription.map { " · origin: \($0)" } ?? "")")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            FactGrid(rows: [
                ("Events", "\(records.events.count) in \(Set(records.events.map(\.recordID)).count) records"),
                ("Documents", "\(records.documents.count)"),
                ("Links", "\(records.links.count)"),
            ])
            .frame(width: 210)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The cutoff: a slider over the history, what the engine selected, and
/// jumps to the imaging timepoints.
private struct CutoffBar: View {
    let model: ClinicalModel
    let records: ClinicalRecords

    var body: some View {
        let clock = records.clock
        let markers = ClinicalTimeline.timepointMarkers(records, summary: model.workspace.summary)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Known at").fontWeight(.medium)
                Text(ClinicalTime.describe(model.cutoff, clock: clock))
                    .font(.system(.body, design: .monospaced))
                if !ClinicalTime.isAbsolute(clock) {
                    Text("(\(ClinicalTime.offset(model.cutoff)))").foregroundStyle(.secondary)
                }
                if let s = model.selection {
                    Label(s.certified ? "certified" : s.status, systemImage: s.certified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(s.certified ? .green : .orange)
                        .help("The engine's \(s.policy.replacingOccurrences(of: "_", with: " ")) selection: \(s.status)")
                    Text(summary(s)).foregroundStyle(.secondary)
                }
                if let error = model.selectionError { Text(error).foregroundStyle(.red).lineLimit(1) }
                Spacer()
                Menu("Jump to") {
                    ForEach(markers, id: \.id) { m in
                        Button("\(m.label) scan (\(ClinicalTime.describe(m.at, clock: clock)))") { model.setCutoff(m.at) }
                    }
                    if !markers.isEmpty { Divider() }
                    Button("Start of the history") { model.setCutoff(model.domain.lowerBound) }
                    Button("Everything known") { model.setCutoff(model.domain.upperBound) }
                }
                .fixedSize()
            }
            .font(.callout)
            Slider(value: Binding(get: { Double(model.cutoff) },
                                  set: { model.setCutoff(Int64($0.rounded())) }),
                   in: Double(model.domain.lowerBound)...Double(model.domain.upperBound))
                .accessibilityLabel("Cutoff on the subject clock")
                .accessibilityValue(ClinicalTime.describe(model.cutoff, clock: clock))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func summary(_ s: ClinicalSelection) -> String {
        var parts = ["\(s.eventIDs.count) of \(records.events.count) events", "\(s.documents.count) document\(s.documents.count == 1 ? "" : "s")"]
        let excluded = s.excluded.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key.replacingOccurrences(of: "_", with: " "))" }
        if !excluded.isEmpty { parts.append("excluded: " + excluded.joined(separator: ", ")) }
        if !s.uncertainRecords.isEmpty { parts.append("\(s.uncertainRecords.count) uncertain") }
        return parts.joined(separator: " · ")
    }
}

/// The events on the clock: a row per kind; the effective time as a dot (a
/// bar for an interval, a pale bar where the source knew only bounds); when
/// it became available as a triangle, joined to it; the imaging timepoints
/// and the cutoff as vertical lines. What was not known at the cutoff is
/// faded.
private struct ClinicalTimelineView: View {
    let model: ClinicalModel
    let records: ClinicalRecords
    private let left: CGFloat = 104
    private let right: CGFloat = 24
    private let top: CGFloat = 22
    private let rowHeight: CGFloat = 30

    var body: some View {
        let rows = ClinicalTimeline.rows(records)
        let known = model.knownEventIDs
        let markers = ClinicalTimeline.timepointMarkers(records, summary: model.workspace.summary)
        GeometryReader { geo in
            Canvas { ctx, size in
                draw(&ctx, size: size, rows: rows, known: known, markers: markers)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                model.selectEvent(hit(location, rows: rows, width: geo.size.width))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline of \(records.events.count) clinical events; \(known.count) known at the cutoff")
    }

    private func x(_ us: Int64, width: CGFloat) -> CGFloat {
        let d = model.domain
        let span = max(1, Double(d.upperBound - d.lowerBound))
        return left + CGFloat(Double(us - d.lowerBound) / span) * (width - left - right)
    }

    private func y(_ row: Int) -> CGFloat { top + CGFloat(row) * rowHeight + rowHeight / 2 }

    private func color(_ kind: String) -> Color {
        switch kind {
        case "imaging": return .blue
        case "document": return .purple
        case "observation": return .teal
        case "assessment": return .orange
        case "procedure": return .pink
        default: return .gray
        }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, rows: [String], known: Set<String>,
                      markers: [(id: String, label: String, at: Int64)]) {
        let width = size.width
        let bottom = top + CGFloat(rows.count) * rowHeight
        // Rows.
        for (i, kind) in rows.enumerated() {
            if i % 2 == 0 {
                ctx.fill(Path(CGRect(x: 0, y: top + CGFloat(i) * rowHeight, width: width, height: rowHeight)),
                         with: .color(.primary.opacity(0.035)))
            }
            ctx.draw(Text(kind.capitalizedFirst).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary),
                     at: CGPoint(x: 10, y: y(i)), anchor: .leading)
        }
        // Ticks.
        let d = model.domain
        let step = ClinicalTime.step(span: d.upperBound - d.lowerBound, count: max(2, Int((width - left - right) / 90)))
        var t = ClinicalTime.floorDiv(d.lowerBound, step) * step
        while t <= d.upperBound {
            if t >= d.lowerBound {
                let px = x(t, width: width)
                var line = Path()
                line.move(to: CGPoint(x: px, y: top))
                line.addLine(to: CGPoint(x: px, y: bottom))
                ctx.stroke(line, with: .color(.primary.opacity(t == 0 ? 0.25 : 0.08)), lineWidth: t == 0 ? 1 : 0.5)
                ctx.draw(Text(ClinicalTime.tick(t, step: step, clock: records.clock)).font(.system(size: 9.5)).foregroundStyle(.secondary),
                         at: CGPoint(x: px, y: bottom + 10), anchor: .center)
            }
            t += step
        }
        // Imaging timepoints.
        for m in markers {
            let px = x(m.at, width: width)
            var line = Path()
            line.move(to: CGPoint(x: px, y: top - 4))
            line.addLine(to: CGPoint(x: px, y: bottom))
            ctx.stroke(line, with: .color(.blue.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ctx.draw(Text(m.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.blue),
                     at: CGPoint(x: px + 3, y: top - 11), anchor: .leading)
        }
        // Events.
        for e in records.events {
            guard let row = rows.firstIndex(of: e.kind) else { continue }
            let isKnown = known.contains(e.eventID)
            let selected = e.eventID == model.selectedEventID
            let tint = color(e.kind).opacity(isKnown ? 1 : 0.28)
            let cy = y(row) + jitter(e, rowEvents: records.events.filter { $0.kind == e.kind })
            var effectiveX: CGFloat?
            if let start = e.effectiveStart {
                let a = x(start.lo, width: width)
                if let end = e.effectiveEnd {
                    let b = x(end.hi, width: width)
                    ctx.fill(Path(roundedRect: CGRect(x: a, y: cy - 3.5, width: max(2, b - a), height: 7), cornerRadius: 3.5), with: .color(tint))
                } else if start.hi != start.lo {
                    let b = x(start.hi, width: width)
                    ctx.fill(Path(roundedRect: CGRect(x: a, y: cy - 4, width: max(2, b - a), height: 8), cornerRadius: 4),
                             with: .color(tint.opacity(0.35)))
                }
                let mid = (a + x(start.hi, width: width)) / 2
                effectiveX = mid
                let r: CGFloat = selected ? 6 : 4.5
                ctx.fill(Path(ellipseIn: CGRect(x: mid - r, y: cy - r, width: 2 * r, height: 2 * r)), with: .color(tint))
                if selected {
                    ctx.stroke(Path(ellipseIn: CGRect(x: mid - r - 2.5, y: cy - r - 2.5, width: 2 * r + 5, height: 2 * r + 5)),
                               with: .color(.accentColor), lineWidth: 1.5)
                }
            }
            if let available = e.available {
                let ax = x(available.lo, width: width)
                if let ex = effectiveX, abs(ax - ex) > 1 {
                    var link = Path()
                    link.move(to: CGPoint(x: ex, y: cy))
                    link.addLine(to: CGPoint(x: ax, y: cy))
                    ctx.stroke(link, with: .color(tint.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                var tri = Path()
                tri.move(to: CGPoint(x: ax, y: cy + 1))
                tri.addLine(to: CGPoint(x: ax - 4.5, y: cy - 7))
                tri.addLine(to: CGPoint(x: ax + 4.5, y: cy - 7))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(tint))
            }
        }
        // The cutoff.
        let cx = x(model.cutoff, width: width)
        var cut = Path()
        cut.move(to: CGPoint(x: cx, y: top - 6))
        cut.addLine(to: CGPoint(x: cx, y: bottom))
        ctx.stroke(cut, with: .color(.red), lineWidth: 1.5)
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 3.5, y: top - 9.5, width: 7, height: 7)), with: .color(.red))
        // Legend.
        let legend = Text("●  happened   ▼  became available   ┆  imaging timepoint   │  cutoff")
            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
        ctx.draw(legend, at: CGPoint(x: width - right, y: bottom + 26), anchor: .trailing)
    }

    /// Spreads events that share a row and a time a little, so each shows.
    private func jitter(_ e: ClinicalEvent, rowEvents: [ClinicalEvent]) -> CGFloat {
        let same = rowEvents.filter { ($0.effectiveStart?.lo ?? $0.available?.lo) == (e.effectiveStart?.lo ?? e.available?.lo) }
        guard same.count > 1, let i = same.firstIndex(where: { $0.eventID == e.eventID }) else { return 0 }
        return CGFloat(i) * 7 - CGFloat(same.count - 1) * 3.5
    }

    private func hit(_ p: CGPoint, rows: [String], width: CGFloat) -> String? {
        var best: (String, CGFloat)?
        for e in records.events {
            guard let row = rows.firstIndex(of: e.kind) else { continue }
            let cy = y(row)
            for t in [e.effectiveStart.map { ($0.lo + $0.hi) / 2 }, e.available?.lo].compactMap({ $0 }) {
                let dx = x(t, width: width) - p.x, dy = cy - p.y
                let dist = (dx * dx + dy * dy).squareRoot()
                if dist < 12, dist < (best?.1 ?? .infinity) { best = (e.eventID, dist) }
            }
        }
        return best?.0
    }
}

private struct EventRow: Identifiable, Hashable {
    let event: ClinicalEvent
    let known: Bool
    var id: String { event.eventID }
}

private struct ClinicalEventTable: View {
    let model: ClinicalModel
    let records: ClinicalRecords

    var body: some View {
        let known = model.knownEventIDs
        let rows = model.events.map { EventRow(event: $0, known: known.contains($0.eventID)) }
        let clock = records.clock
        Table(rows, selection: Binding(get: { model.selectedEventID.map { Set([$0]) } ?? [] },
                                      set: { model.selectEvent($0.first) })) {
            TableColumn("") { r in
                Image(systemName: r.known ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(r.known ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                    .help(r.known ? "Known at the cutoff" : "Not known at the cutoff")
            }
            .width(18)
            TableColumn("Event") { r in
                Text(r.event.eventID).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(r.known ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .width(min: 80, ideal: 96)
            TableColumn("Kind") { r in Text(r.event.kind) }.width(min: 60, ideal: 76)
            TableColumn("Status") { r in Text(r.event.status).foregroundStyle(.secondary) }.width(min: 56, ideal: 70)
            TableColumn("Happened") { r in Text(ClinicalTime.describe(r.event.effectiveStart, clock: clock)).monospacedDigit() }
                .width(min: 90, ideal: 106)
            TableColumn("Available") { r in Text(ClinicalTime.describe(r.event.available, clock: clock)).monospacedDigit() }
                .width(min: 90, ideal: 106)
            TableColumn("Value") { r in Text(ClinicalTimeline.value(r.event)).lineLimit(1).help(ClinicalTimeline.value(r.event)) }
                .width(min: 80, ideal: 140)
            TableColumn("Timepoint") { r in Text(r.event.timepointID ?? "").foregroundStyle(.secondary) }
                .width(min: 50, ideal: 64)
        }
    }
}

/// The selected event's links and record, and the documents with their
/// text (grounded spans highlighted).
private struct ClinicalSidePanel: View {
    let model: ClinicalModel
    let records: ClinicalRecords

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let id = model.selectedEventID, let e = records.event(id) {
                eventDetail(e)
                Divider()
            }
            documents
        }
    }

    private func eventDetail(_ e: ClinicalEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(e.eventID).font(.headline)
            FactGrid(rows: [
                ("Record", "\(e.recordID) (\(records.versions(of: e.recordID).count) version\(records.versions(of: e.recordID).count == 1 ? "" : "s"))"),
                ("Kind", "\(e.kind) · \(e.temporalType) · \(e.status)"),
                ("Happened", ClinicalTime.describe(e.effectiveStart, clock: records.clock)
                    + (e.effectiveEnd.map { " to " + ClinicalTime.describe($0, clock: records.clock) } ?? "")),
                ("Available", ClinicalTime.describe(e.available, clock: records.clock)),
            ] + (ClinicalTimeline.value(e).isEmpty ? [] : [("Value", ClinicalTimeline.value(e))])
              + (e.prov.map { [("Provenance", $0)] } ?? []))
            let links = model.links(of: e.eventID)
            if !links.isEmpty {
                Text("Links").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(Array(links.enumerated()), id: \.offset) { _, l in
                    Text("\(l.sourceType) \(l.sourceID) → \(l.relation) → \(l.targetType) \(l.targetID)\(l.targetAnnotationID.map { " of \($0)" } ?? "")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
    }

    private var documents: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Documents").font(.headline)
                Spacer()
                Picker("Document", selection: Binding(get: { model.selectedDocumentID ?? "" }, set: { model.showDocument($0) })) {
                    ForEach(records.documents) { d in
                        Text("\(d.documentID)\(model.knownDocumentIDs.contains(d.documentID) ? "" : " (not an input at the cutoff)")").tag(d.documentID)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(records.documents.isEmpty)
            }
            if let id = model.selectedDocumentID, let info = records.documents.first(where: { $0.documentID == id }) {
                Text("\(info.mediaType)\(info.language.map { " · \($0)" } ?? "")\(info.sourceType.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? "") · \(info.bytes) bytes"
                     + (model.knownDocumentIDs.contains(id) ? " · an input at the cutoff" : " · not an input at the cutoff (later, or superseded)"))
                    .font(.caption)
                    .foregroundStyle(model.knownDocumentIDs.contains(id) ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                PlainTextView(text: .constant(model.texts[id] ?? ""), isEditable: false,
                              font: .systemFont(ofSize: 12.5), highlights: model.spans(in: id))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                    .onAppear { model.showDocument(id) }
            } else {
                Text("No documents").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(12)
    }
}
