import AppKit
import SwiftUI
import MedH5Kit
import MedH5Editing

/// New Segmentation…: the grid (the base image's by default), the task,
/// the timepoints, the classes it can express from the start.
struct NewSegmentationSheet: View {
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var request = NewSegmentationRequest(id: "", grid: "")
    @State private var timepointsFromGrid = true
    @State private var timepoints: Set<String> = []
    @State private var error: String?

    var body: some View {
        let session = workspace.editing
        let summary = workspace.summary
        VStack(alignment: .leading, spacing: 14) {
            Text("New Segmentation").font(.headline)
            Form {
                TextField("Id", text: $request.id)
                Picker("Grid", selection: $request.grid) {
                    ForEach(summary.grids, id: \.id) { g in
                        Text("\(g.id) — \(Format.shape(g.spatialShape)) · \(Format.spacing(g.spacing, units: g.units))").tag(g.id)
                    }
                }
                TextField("Task", text: $request.task)
                Toggle("Timepoints of the grid", isOn: $timepointsFromGrid)
                if !timepointsFromGrid {
                    ForEach(workspace.timepointIDs, id: \.self) { tp in
                        Toggle(workspace.timepointTitle(tp), isOn: Binding(get: { timepoints.contains(tp) }, set: {
                            if $0 { timepoints.insert(tp) } else { timepoints.remove(tp) }
                        }))
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: timepointsFromGrid ? 190 : 190 + CGFloat(workspace.timepointIDs.count) * 26)
            Text("Classes it can express (not examined until painted)").font(.subheadline)
            LabelClassChecklist(labelSet: summary.labelSet, selection: Binding(get: { Set(request.classIDs) }, set: {
                request.classIDs = $0.sorted()
            }))
            .frame(height: 170)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            } else if let problem = session.idProblem(request.id) {
                Text(problem).foregroundStyle(.secondary).font(.callout)
            }
            HStack {
                Text("Held in memory and written by the next save.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.idProblem(request.id) != nil || request.grid.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            request = session.defaultNewSegmentation()
            timepoints = Set(summary.grid(request.grid)?.timepoint.map { [$0] } ?? [])
        }
    }

    private func create() {
        var r = request
        r.timepoints = timepointsFromGrid ? nil : workspace.timepointIDs.filter { timepoints.contains($0) }
        do {
            try workspace.editing.createSegmentation(r)
            dismiss()
        } catch {
            self.error = EditingSession.describe(error)
        }
    }
}

/// The label set's classes with check boxes.
struct LabelClassChecklist: View {
    let labelSet: LabelSetInfo?
    @Binding var selection: Set<Int>
    var excluded: Set<Int> = []

    var body: some View {
        let classes = (labelSet?.classes ?? []).filter { !excluded.contains($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(classes) { c in
                    Toggle(isOn: Binding(get: { selection.contains(c.id) }, set: {
                        if $0 { selection.insert(c.id) } else { selection.remove(c.id) }
                    })) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).fill(c.displayColor.withAlpha(255).color).frame(width: 11, height: 11)
                            Text(c.name)
                            Text("\(c.id) · \(c.key)").foregroundStyle(.secondary).font(.system(size: 10.5))
                        }
                    }
                }
                if classes.isEmpty {
                    Text(labelSet == nil ? "The sample has no label set." : "No other class in the label set.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

/// Add Class…: a class of the label set the segmentation cannot express
/// yet, or a new class (added to the label set too).
struct AddClassSheet: View {
    let workspace: Workspace
    /// Only a new class of the label set (no segmentation).
    var labelSetOnly = false
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var chosen: Set<Int> = []
    @State private var name = ""
    @State private var color = Color(red: 0.95, green: 0.55, blue: 0.2)
    @State private var codeSystem = "SCT"
    @State private var code = ""
    @State private var overlapping = false
    @State private var error: String?

    var body: some View {
        let session = workspace.editing
        let id = labelSetOnly ? nil : session.activeSegmentation
        let model = id.flatMap { session.segmentationResource($0)?.model }
        let present = Set(model?.classes.map { Int($0.id) } ?? [])
        let mode = labelSetOnly ? 1 : self.mode
        VStack(alignment: .leading, spacing: 14) {
            Text(labelSetOnly ? "New Class in the Label Set" : id.map { "Add a Class to \($0)" } ?? "Add a Class").font(.headline)
            if !labelSetOnly {
                Picker("", selection: $mode) {
                    Text("From the label set").tag(0)
                    Text("New class").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if mode == 0 {
                LabelClassChecklist(labelSet: workspace.summary.labelSet, selection: $chosen, excluded: present)
                    .frame(height: 220)
            } else {
                Form {
                    TextField("Name", text: $name)
                    LabeledContent("Key") { Text(name.isEmpty ? "—" : EditingSession.classKey(from: name)).foregroundStyle(.secondary) }
                    LabeledContent("Id") { Text("\(session.nextFreeClassID())").foregroundStyle(.secondary) }
                    ColorPicker("Colour", selection: $color, supportsOpacity: false)
                    LabeledContent("Ontology code") {
                        HStack {
                            TextField("System", text: $codeSystem).frame(width: 70)
                            TextField("Code (optional)", text: $code)
                        }
                        .labelsHidden()
                    }
                }
                .formStyle(.grouped)
                .frame(height: 210)
                Text("The class is added to the sample’s label set as well. Strict validation asks every class an annotation uses for an ontology code.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model != nil {
                Toggle("Can overlap the other classes (a layer of its own)", isOn: $overlapping)
            } else if !labelSetOnly {
                Text("No segmentation is active: the class is only added to the label set.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add(segmentation: model == nil ? nil : id, mode: mode) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode == 0 ? chosen.isEmpty || model == nil : name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func add(segmentation id: String?, mode: Int) {
        let session = workspace.editing
        do {
            if mode == 0, let id {
                for c in chosen.sorted() { try session.addClass(c, to: id, overlapping: overlapping) }
            } else {
                try session.createClass(name: name, color: RGBA8(color), code: (codeSystem, code), segmentation: id,
                                        overlapping: overlapping)
            }
            dismiss()
        } catch {
            self.error = EditingSession.describe(error)
        }
    }
}

extension RGBA8 {
    /// An opaque colour from SwiftUI's (sRGB).
    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent), 255)
    }
}
