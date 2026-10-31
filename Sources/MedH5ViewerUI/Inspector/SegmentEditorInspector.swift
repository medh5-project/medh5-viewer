import SwiftUI
import MedH5Kit
import MedH5Render
import MedH5Editing

/// The Segment Editor tab: the active segmentation (pick one or create one
/// on the base image's grid), its classes with coverage, the voxel tools and
/// their options, the operations, undo and redo.
struct SegmentEditorInspector: View {
    let workspace: Workspace

    var body: some View {
        @Bindable var session = workspace.editing
        let _ = session.revision
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let why = session.readOnlyReason {
                    ReadOnlyNote(text: why)
                }
                SegmentationPickerSection(workspace: workspace, session: session)
                if let id = session.activeSegmentation {
                    Divider().padding(.horizontal, 14)
                    if let res = session.segmentationResource(id) {
                        SegmentClassesSection(workspace: workspace, session: session, id: id, model: res.model)
                        Divider().padding(.horizontal, 14)
                        SegmentToolSection(workspace: workspace, session: session, model: res.model)
                        Divider().padding(.horizontal, 14)
                        SegmentOperationsSection(workspace: workspace, session: session, id: id, model: res.model)
                    } else {
                        InspectorSection("Classes") {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Reading \(id)…").foregroundStyle(.secondary).font(.callout)
                            }
                        }
                    }
                }
                Divider().padding(.horizontal, 14)
                UndoSection(workspace: workspace)
                if let message = session.message {
                    EditMessageView(message: message) { session.message = nil }
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                }
            }
            .padding(.bottom, 16)
        }
        .sheet(item: $session.sheet) { sheet in
            switch sheet {
            case .newSegmentation: NewSegmentationSheet(workspace: workspace)
            case .addClass: AddClassSheet(workspace: workspace)
            case .newLabelClass: AddClassSheet(workspace: workspace, labelSetOnly: true)
            }
        }
    }
}

/// Why nothing can be edited.
struct ReadOnlyNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "lock.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.top, 10)
    }
}

/// A notice or error of the tools.
struct EditMessageView: View {
    let message: EditMessage
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(message.isError ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            Text(message.text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
    }
}

// MARK: - Segmentation

struct SegmentationPickerSection: View {
    let workspace: Workspace
    @Bindable var session: EditingSession

    var body: some View {
        let candidates = session.editableSegmentations
        let active = session.activeSegmentation
        InspectorSection("Segmentation", trailing: AnyView(newButton)) {
            if candidates.isEmpty {
                Text("The sample has no segmentation to edit. Create one on the base image’s grid.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Segmentation", selection: Binding(get: { active ?? "" }, set: { session.activate(segmentation: $0) })) {
                    if active == nil { Text("Choose…").tag("") }
                    ForEach(candidates) { a in
                        Text("\(a.id) — \(KindNames.annotation(a.kind).lowercased())").tag(a.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fillsWidth()
                if let id = active, let info = workspace.summary.annotation(id) {
                    Text(caption(id: id, info: info))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var newButton: some View {
        Button {
            session.sheet = .newSegmentation
        } label: {
            Label("New…", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10.5))
        .disabled(session.readOnlyReason != nil || workspace.summary.grids.isEmpty)
        .help("New Segmentation… — an empty segmentation on a grid of the sample")
    }

    private func caption(id: String, info: AnnotationInfo) -> String {
        var parts = ["on \(info.grid ?? "—")", info.task]
        let edits = session.pendingEdits
        if edits.newSegmentations[id] != nil {
            parts.append("new, not saved")
        } else if edits.editedSegmentations.contains(id) {
            parts.append("edited, not saved")
        }
        if let res = session.segmentationResource(id), res.model.layerCount > 1 {
            parts.append("\(res.model.layerCount) layers (classes in different layers may overlap)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Classes

struct SegmentClassesSection: View {
    let workspace: Workspace
    @Bindable var session: EditingSession
    let id: String
    let model: SegmentationModel

    var body: some View {
        let counts = session.voxelCounts(id)
        let active = session.activeClass(of: id, model: model)
        let voxel = model.geometry.paddedVoxelVolume
        let units = model.geometry.units
        let readOnly = session.readOnlyReason != nil
        InspectorSection("Classes", trailing: AnyView(addButton(readOnly))) {
            VStack(spacing: 2) {
                ForEach(model.classes) { c in
                    SegmentClassRow(workspace: workspace, session: session, segmentation: id, segmentClass: c,
                                    voxels: counts[c.id, default: 0], volume: Double(counts[c.id, default: 0]) * voxel, units: units,
                                    isActive: c.id == active, isExamined: model.annotatedClassIDs.contains(c.id),
                                    canExpress: model.classIDs.contains(c.id), readOnly: readOnly)
                }
                if model.classes.isEmpty {
                    Text("No classes yet: add one from the label set, or create one.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Painting a class marks it examined. “Can express only”: not looked for, so its absence means nothing; “Mark Not Examined” needs the class to have no voxels.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addButton(_ readOnly: Bool) -> some View {
        Button {
            session.sheet = .addClass
        } label: {
            Label("Add Class…", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10.5))
        .disabled(readOnly)
        .help("Add a class of the label set, or create one")
    }
}

struct SegmentClassRow: View {
    let workspace: Workspace
    let session: EditingSession
    let segmentation: String
    let segmentClass: SegmentClass
    let voxels: Int
    let volume: Double
    let units: String
    let isActive: Bool
    let isExamined: Bool
    let canExpress: Bool
    let readOnly: Bool

    var body: some View {
        let c = segmentClass
        let layer = workspace.activeStack.layer(segmentation)
        let visible = layer?.isClassVisible(Int(c.id)) ?? true
        HStack(spacing: 7) {
            Button { session.setVisible(c.id, !visible, in: segmentation) } label: {
                Image(systemName: visible ? "eye.fill" : "eye.slash")
                    .foregroundStyle(visible ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(visible ? "Hide the class in the views" : "Show the class in the views")
            .accessibilityLabel(visible ? "Hide \(c.name)" : "Show \(c.name)")
            RoundedRectangle(cornerRadius: 3).fill(c.color.withAlpha(255).color)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(c.name).fontWeight(isActive ? .semibold : .regular).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { session.setLocked(c.id, !c.isLocked, in: segmentation) } label: {
                        Image(systemName: c.isLocked ? "lock.fill" : "lock.open")
                            .foregroundStyle(c.isLocked ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.borderless)
                    .help(c.isLocked ? "Locked: no tool changes its voxels. Click to unlock." : "Lock the class")
                    .accessibilityLabel(c.isLocked ? "Unlock \(c.name)" : "Lock \(c.name)")
                    coverageBadge
                }
                Text("id \(c.id) · \(Format.integer(voxels)) voxels · \(volumeText) \(units)³")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(isActive ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { session.activeClasses[segmentation] = c.id }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(c.name), \(voxels) voxels, \(isExamined ? "examined" : "can express only")\(isActive ? ", active" : "")")
    }

    private var volumeText: String {
        volume < 100 ? Format.number(volume, digits: 1) : Format.integer(Int(volume.rounded()))
    }

    private var coverageBadge: some View {
        let text = !canExpress ? "not expressed" : (isExamined ? "examined" : "can express only")
        return Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(isExamined ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(isExamined ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.orange.opacity(0.15))))
            .help(isExamined ? "Looked for: a voxel without it is an examined absence"
                             : "Not examined: the annotation can express it but nobody looked for it")
    }

    @ViewBuilder
    private var menu: some View {
        Button("Paint This Class") { session.activeClasses[segmentation] = segmentClass.id }
        Divider()
        Button("Mark Examined") { attempt { try session.setExamined(segmentClass.id, true, in: segmentation) } }
            .disabled(readOnly || isExamined)
        Button("Mark Not Examined") { attempt { try session.setExamined(segmentClass.id, false, in: segmentation) } }
            .disabled(readOnly || !isExamined || voxels > 0)
        Divider()
        Button(segmentClass.isLocked ? "Unlock" : "Lock") { session.setLocked(segmentClass.id, !segmentClass.isLocked, in: segmentation) }
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { session.report(error) }
    }
}

// MARK: - Tools

struct SegmentToolSection: View {
    let workspace: Workspace
    @Bindable var session: EditingSession
    let model: SegmentationModel

    var body: some View {
        let viewer = workspace.viewer
        let units = session.valueUnits
        InspectorSection("Tool") {
            HStack(spacing: 4) {
                ForEach(ViewerTool.segmentationTools) { tool in
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
            if viewer.tool == .fill {
                fillOptions(units: units)
            } else {
                brushOptions(units: units)
            }
        }
    }

    @ViewBuilder
    private func brushOptions(units: String) -> some View {
        LabeledSlider(title: "Radius", value: $session.brush.radius, range: BrushSettings.radiusRange, units: "mm")
            .help("The brush radius in millimetres ([ and ] change it)")
        LabeledRow("Shape") {
            Picker("Shape", selection: $session.brush.isSphere) {
                Text("2-D disc").tag(false)
                Text("3-D sphere").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        LabeledRow("Paint") {
            Picker("Paint policy", selection: $session.brush.policy) {
                ForEach(BrushSettings.Policy.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        .help("Overwrite replaces other classes of the same layer; Only empty paints where no class is; Only inside paints within another class")
        if session.brush.policy == .onlyInside {
            ClassPicker(title: "Inside", model: model, selection: $session.brush.insideClass)
        }
        if workspace.viewer.tool == .eraser {
            Toggle("Erase every unlocked class", isOn: $session.brush.eraserErasesAll)
        }
        Toggle("Only where the image is in a range", isOn: $session.brush.usesIntensity)
            .help("Paint only voxels whose base-image value (physical units) is in the range")
        if session.brush.usesIntensity {
            RangeFields(low: $session.brush.intensityLow, high: $session.brush.intensityHigh, units: units) {
                if let r = session.windowRange() {
                    session.brush.intensityLow = r.lowerBound
                    session.brush.intensityHigh = r.upperBound
                }
            }
        }
    }

    @ViewBuilder
    private func fillOptions(units: String) -> some View {
        LabeledRow("Fill") {
            Picker("Fill criterion", selection: $session.fill.criterion) {
                ForEach(FillSettings.Criterion.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        switch session.fill.criterion {
        case .sameLabels:
            Text("Fills the connected voxels holding what the clicked voxel holds in the class’s layer.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .tolerance:
            InspectorNumberField(title: "Tolerance", value: $session.fill.tolerance, units: units)
        case .range:
            RangeFields(low: $session.fill.rangeLow, high: $session.fill.rangeHigh, units: units) {
                if let r = session.windowRange() {
                    session.fill.rangeLow = r.lowerBound
                    session.fill.rangeHigh = r.upperBound
                }
            }
        }
        LabeledRow("Extent") {
            Picker("Extent", selection: $session.fill.is3D) {
                Text("2-D slice").tag(false)
                Text("3-D volume").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        LabeledRow("Paint") {
            Picker("Paint policy", selection: $session.brush.policy) {
                ForEach(BrushSettings.Policy.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        if session.brush.policy == .onlyInside {
            ClassPicker(title: "Inside", model: model, selection: $session.brush.insideClass)
        }
    }
}

/// A class of a segmentation, or none.
struct ClassPicker: View {
    let title: String
    let model: SegmentationModel
    @Binding var selection: UInt16?
    var excluding: UInt16?
    /// What no class means here.
    var none = "Choose…"

    var body: some View {
        LabeledRow(title) {
            Picker(title, selection: $selection) {
                Text(none).tag(UInt16?.none)
                ForEach(model.classes.filter { $0.id != excluding }) { c in
                    Text(c.name).tag(UInt16?.some(c.id))
                }
            }
            .labelsHidden()
        }
    }
}

/// A number with its units.
struct InspectorNumberField: View {
    let title: String
    @Binding var value: Double
    var units = ""

    var body: some View {
        LabeledRow(title) {
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .labelsHidden()
            Text(units).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

/// A value range with a "from the window" button.
struct RangeFields: View {
    @Binding var low: Double
    @Binding var high: Double
    var units = ""
    var fromWindow: () -> Void

    var body: some View {
        LabeledRow("Range") {
            TextField("From", value: $low, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
                .labelsHidden()
            Text("to").foregroundStyle(.secondary).fixedSize()
            TextField("To", value: $high, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
                .labelsHidden()
            Text(units).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 0)
            Button(action: fromWindow) { Image(systemName: "circle.lefthalf.filled") }
                .buttonStyle(.borderless)
                .help("Take the range from the base image’s window")
                .accessibilityLabel("Use the window")
        }
    }
}

// MARK: - Operations

struct SegmentOperationsSection: View {
    let workspace: Workspace
    @Bindable var session: EditingSession
    let id: String
    let model: SegmentationModel

    var body: some View {
        let kind = session.operation.kind
        let availability = session.operationAvailability(kind)
        let units = session.valueUnits
        InspectorSection("Operations") {
            Picker("Operation", selection: $session.operation.kind) {
                ForEach(SegmentOperationKind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fillsWidth()
            Text(kind.help)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            parameters(kind, units: units)
            HStack(spacing: 8) {
                if let running = session.running {
                    ProgressView(value: running.progress).frame(maxWidth: .infinity)
                    Button("Cancel") { session.cancelOperation() }
                } else {
                    Spacer()
                    Button("Apply to \(activeName)") { session.runOperation(kind) }
                        .disabled(!availability.isAvailable)
                        .help(availability.reason ?? "Applies \(kind.title.lowercased()) to the active class, as one undo step")
                }
            }
            if let reason = availability.reason, session.running == nil {
                Text(reason).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
    }

    private var activeName: String {
        guard let c = session.activeClass(of: id, model: model) else { return "the Class" }
        return model.classInfo(c)?.name ?? "Class \(c)"
    }

    @ViewBuilder
    private func parameters(_ kind: SegmentOperationKind, units: String) -> some View {
        switch kind {
        case .threshold:
            RangeFields(low: $session.operation.low, high: $session.operation.high, units: units) { fromWindow() }
            LabeledRow("Extent") {
                Picker("Extent", selection: $session.operation.thresholdOnSlice) {
                    Text("Volume").tag(false)
                    Text("Slice at the crosshair").tag(true)
                }
                .labelsHidden()
            }
            ClassPicker(title: "Inside", model: model, selection: $session.operation.thresholdInsideClass, none: "Anywhere")
            Toggle("Remove the class outside the range", isOn: $session.operation.thresholdClearOutside)
        case .regionGrowing:
            Picker("Criterion", selection: $session.operation.growInRange) {
                Text("Value ± tolerance").tag(false)
                Text("Value in range").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fillsWidth()
            if session.operation.growInRange {
                RangeFields(low: $session.operation.low, high: $session.operation.high, units: units) { fromWindow() }
            } else {
                InspectorNumberField(title: "Tolerance", value: $session.operation.growTolerance, units: units)
            }
            LabeledRow("Extent") {
                Picker("Extent", selection: $session.operation.growIn3D) {
                    Text("2-D slice").tag(false)
                    Text("3-D volume").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text("Seeds at the crosshair: click in a view with the Navigate tool to place it.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .morphology:
            LabeledRow("Operation") {
                Picker("Morphology", selection: $session.operation.morphology) {
                    ForEach(MorphologyKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            InspectorNumberField(title: "Radius", value: $session.operation.morphologyRadius, units: "mm")
            Toggle("In each slice of the active view (2-D)", isOn: $session.operation.morphologyIn2D)
        case .fillHoles:
            Toggle("In each slice of the active view (2-D)", isOn: $session.operation.holesIn2D)
        case .keepLargest:
            EmptyView()
        case .removeIslands:
            InspectorNumberField(title: "Smaller than", value: $session.operation.islandMinimumVolume, units: "\(model.geometry.units)³")
            Text("≈ \(Format.integer(Int((session.operation.islandMinimumVolume / max(1e-9, model.geometry.paddedVoxelVolume)).rounded(.up)))) voxels")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        case .interpolate:
            EmptyView()
        case .logical:
            LabeledRow("Operation") {
                Picker("Logical operation", selection: $session.operation.logical) {
                    ForEach(LogicalKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            if session.operation.logical.needsOther {
                ClassPicker(title: "B", model: model, selection: $session.operation.logicalOther,
                            excluding: session.activeClass(of: id, model: model))
            }
            Text("A is the active class.").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    private func fromWindow() {
        if let r = session.windowRange() {
            session.operation.low = r.lowerBound
            session.operation.high = r.upperBound
        }
    }
}

// MARK: - Undo

struct UndoSection: View {
    let workspace: Workspace

    var body: some View {
        let _ = workspace.editing.revision
        let manager = workspace.document?.undoManager
        InspectorSection("History") {
            HStack(spacing: 8) {
                Button {
                    manager?.undo()
                } label: {
                    Label(manager?.canUndo == true ? "Undo \(manager?.undoActionName ?? "")" : "Undo", systemImage: "arrow.uturn.backward")
                        .lineLimit(1)
                }
                .disabled(manager?.canUndo != true)
                Button {
                    manager?.redo()
                } label: {
                    Label(manager?.canRedo == true ? "Redo \(manager?.redoActionName ?? "")" : "Redo", systemImage: "arrow.uturn.forward")
                        .lineLimit(1)
                }
                .disabled(manager?.canRedo != true)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            Text("Every stroke and operation is one step of Edit ▸ Undo (⌘Z). Undo memory: \(Format.bytes(workspace.editing.undoMemoryInUse)) of \(Format.bytes(Preferences.undoMemoryBytes)).")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
