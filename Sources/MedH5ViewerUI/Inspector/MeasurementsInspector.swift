import AppKit
import SwiftUI
import MedH5Kit
import MedH5Editing

/// The Measurements tab: every measurement of the window with its value —
/// select to jump the crosshair, copy, delete, export CSV, and save rulers
/// and angles as a polyline annotation. Measurements belong to the window:
/// they are not written into the file.
struct MeasurementsInspector: View {
    let workspace: Workspace

    var body: some View {
        @Bindable var session = workspace.editing
        let viewer = workspace.viewer
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InspectorSection("Tools") {
                    HStack(spacing: 4) {
                        ForEach(ViewerTool.measuringTools) { tool in
                            let availability = session.availability(tool)
                            Toggle(isOn: Binding(get: { viewer.tool == tool }, set: { if $0 { session.select(tool) } })) {
                                Label(tool.title, systemImage: tool.symbol)
                            }
                            .toggleStyle(.button)
                            .disabled(!availability.isAvailable)
                            .help(availability.reason ?? tool.help)
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                    LabeledRow("ROI shape") {
                        Picker("ROI shape", selection: $session.roiShape) {
                            ForEach(ROIShapeKind.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .controlSize(.small)
                    Label("Measurements belong to this window and are not saved in the file. Export them as CSV, or save rulers and angles as a polyline annotation.",
                          systemImage: "info.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().padding(.horizontal, 14)
                InspectorSection("Measurements", trailing: AnyView(actions)) {
                    if session.measurements.isEmpty {
                        Text("None yet: use Ruler (M), Angle (A) or ROI (O) on a slice view.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 1) {
                            ForEach(session.measurements) { m in
                                MeasurementRow(measurement: m, isSelected: session.selectedMeasurements.contains(m.id),
                                               copy: { session.copyMeasurements([m]) },
                                               delete: { session.deleteMeasurements([m.id]) })
                                    .onTapGesture { tap(m.id) }
                                    .contextMenu { menu(m) }
                            }
                        }
                    }
                }
                if let message = session.message {
                    EditMessageView(message: message) { session.message = nil }
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var session: EditingSession { workspace.editing }

    private func tap(_ id: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if session.selectedMeasurements.contains(id) { session.selectedMeasurements.remove(id) } else { session.selectedMeasurements.insert(id) }
        } else {
            session.selectedMeasurements = [id]
        }
        if session.selectedMeasurements.contains(id) { session.jump(toMeasurement: id) }
    }

    @ViewBuilder
    private func menu(_ m: ViewerMeasurement) -> some View {
        Button("Copy") { session.copyMeasurements([m]) }
        Button("Delete") { session.deleteMeasurements([m.id]) }
        if m.isCurve {
            Divider()
            Button("Save as Polyline Annotation") { savePolylines([m.id]) }
                .disabled(session.readOnlyReason != nil)
        }
    }

    private var actions: some View {
        let list = session.measurementsForCommands
        let curves = Set(list.filter(\.isCurve).map(\.id))
        return HStack(spacing: 8) {
            Menu {
                Button("Copy \(list.count == session.measurements.count ? "All" : "Selected")") { session.copyMeasurements(list) }
                Button("Export CSV…") { exportCSV() }
                Divider()
                Button("Save Rulers and Angles as Polyline Annotation") { savePolylines(curves) }
                    .disabled(curves.isEmpty || session.readOnlyReason != nil)
                Divider()
                Button("Delete \(list.count == session.measurements.count ? "All" : "Selected")") {
                    session.deleteMeasurements(Set(list.map(\.id)))
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(session.measurements.isEmpty)
            .help("Copy, export, save as polylines, delete (the selected measurements, else all)")
            .accessibilityLabel("Measurement actions")
        }
        .font(.system(size: 10.5))
    }

    private func savePolylines(_ ids: Set<Int>) {
        do {
            try session.saveMeasurementsAsPolylines(ids)
            session.report(.notice("Saved as polylines of \(session.listedAnnotation ?? "a new annotation") — written by the next save."))
        } catch {
            session.report(error)
        }
    }

    private func exportCSV() {
        guard let window = workspace.viewports.slices.values.first?.container.window ?? NSApp.keyWindow else { return }
        MeasurementExport.run(workspace: workspace, window: window)
    }
}

struct MeasurementRow: View {
    let measurement: ViewerMeasurement
    let isSelected: Bool
    let copy: () -> Void
    let delete: () -> Void

    var body: some View {
        let m = measurement
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: m.symbol)
                .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.22))
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(m.title).fontWeight(.medium)
                    Text(m.valueText).monospacedDigit().textSelection(.enabled)
                }
                if let detail = m.detailText {
                    Text(detail).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Text("on \(m.imageID)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button(action: copy) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy the value")
                .accessibilityLabel("Copy \(m.title)")
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
                .accessibilityLabel("Delete \(m.title)")
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Color.accentColor.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(m.title), \(m.valueText)")
    }
}

/// File ▸ Export ▸ Measurements (CSV)…
@MainActor
enum MeasurementExport {
    static func run(workspace: Workspace, window: NSWindow) {
        let list = workspace.editing.measurements
        guard !list.isEmpty else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(workspace.displayName.replacingOccurrences(of: ".medh5", with: "")) measurements.csv"
        panel.message = "Measurements belong to the window; this file holds their values and points."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try MeasurementCSV.make(list).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                workspace.alert = AppAlert(title: "The measurements could not be exported", message: error.localizedDescription)
            }
        }
    }
}
