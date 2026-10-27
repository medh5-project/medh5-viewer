import SwiftUI
import AppKit
import simd
import MedH5Kit

/// Everything about the selected object: an image's grid, type, rescale,
/// presets, storage and digest; an annotation's header and coverage; a
/// transform's summary; the label set, curation records; and the raw HDF5
/// attributes.
struct InfoInspector: View {
    let workspace: Workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let id = workspace.selection ?? "sample"
                ForEach(Array(InfoBuilder(workspace: workspace).sections(for: id).enumerated()), id: \.offset) { i, section in
                    if i > 0 { Divider().padding(.horizontal, 14) }
                    InspectorSection(section.title) {
                        if let text = section.note {
                            Text(text).font(.system(size: 11.5)).foregroundStyle(section.isWarning ? .orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !section.rows.isEmpty { KeyValueGrid(rows: section.rows) }
                        if let c = section.classification {
                            ClassificationAssertions(classification: c, labelSet: workspace.summary.labelSet)
                        }
                    }
                }
                if let path = workspace.objectPath(forNode: id) {
                    Divider().padding(.horizontal, 14)
                    AttributesSection(workspace: workspace, path: path)
                }
            }
            .padding(.bottom, 16)
        }
        .textSelection(.enabled)
        .task(id: workspace.selection) {
            // A classification's assertions are read on demand.
            if let id = workspace.selection, id.hasPrefix("ann:"),
               let a = workspace.summary.annotation(String(id.dropFirst(4))), a.kind == "classification" {
                workspace.store.request(.geometry(a.id))
            }
        }
    }
}

/// The raw attributes of an object, as HDF5 stores them.
struct AttributesSection: View {
    let workspace: Workspace
    let path: String

    var body: some View {
        InspectorSection("HDF5 Attributes", trailing: AnyView(copyButton)) {
            Text(path == "/" ? "/ (the root group)" : "/\(path)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            switch workspace.attributeState(path) {
            case .loaded(let attrs)?:
                if attrs.isEmpty {
                    Text("None").foregroundStyle(.secondary).font(.callout)
                } else {
                    KeyValueGrid(rows: attrs.entries.map { ($0.key, AttributesSection.text($0.value)) })
                        .font(.system(size: 11, design: .monospaced))
                }
            case .failed(let why)?:
                Text(why).foregroundStyle(.orange).font(.callout)
            case .loading?, nil:
                ProgressView().controlSize(.small)
            }
        }
        .onAppear { workspace.requestAttributes(path) }
        .onChange(of: path) { _, new in workspace.requestAttributes(new) }
    }

    private var copyButton: some View {
        Button {
            if case .loaded(let attrs)? = workspace.attributeState(path) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(JSONValue.object(attrs).serialized(.pretty), forType: .string)
            }
        } label: { Image(systemName: "doc.on.doc") }
        .buttonStyle(.borderless)
        .help("Copy the attributes as JSON")
    }

    static func text(_ v: JSONValue) -> String {
        if let s = v.stringValue { return s.count > 400 ? String(s.prefix(400)) + "…" : s }
        let t = v.serialized(.meta)
        return t.count > 400 ? String(t.prefix(400)) + "…" : t
    }
}

/// One group of rows in the Info tab.
struct InfoSection {
    var title: String
    var rows: [(String, String)] = []
    var note: String?
    var isWarning = false
    var classification: GeometricAnnotation.Classification?
}

/// Builds the Info tab's sections for a sidebar node.
@MainActor
struct InfoBuilder {
    let workspace: Workspace
    var s: SampleSummary { workspace.summary }

    func sections(for nodeID: String) -> [InfoSection] {
        let parts = nodeID.split(separator: ":", maxSplits: 1).map(String.init)
        let key = parts.count == 2 ? parts[1] : ""
        switch parts.first ?? "" {
        case "image": return image(key)
        case "ann": return annotation(key)
        case "grid": return s.grid(key).map { [gridSection($0, title: "Grid")] } ?? []
        case "tp": return timepoint(key)
        case "tf": return transform(key)
        case "class": return Int(key).map(labelClass) ?? []
        case "labelset": return labelSet()
        case "provenance": return provenance()
        case "quality": return quality()
        case "deid": return deidentification()
        case "clinical": return clinical()
        case "index": return index()
        case "bad": return unreadable(key)
        default: return sample()
        }
    }

    // MARK: Sample

    func sample() -> [InfoSection] {
        var id = InfoSection(title: "Sample")
        id.rows = [
            ("Subject", s.identity.subjectID), ("Sample", s.identity.sampleID),
            ("Format", "\(s.formatVersion) (\(s.support == .full ? "read fully" : "projection"); engine \(MedH5.engineVersion), format \(MedH5.formatVersion))"),
            ("Profiles", Format.list(s.profiles)),
            ("Content id", s.contentID ?? "—"), ("Digest", s.digestAlgorithm ?? "—"),
            ("Created", s.created ?? "—"), ("Generator", s.generator ?? "—"),
        ]
        if let sex = s.identity.sex { id.rows.append(("Sex", sex)) }
        if let b = s.identity.bodypart { id.rows.append(("Body part", b)) }
        if let l = s.identity.laterality { id.rows.append(("Laterality", l)) }
        var out = [id]
        if let c = s.cohort {
            var cohort = InfoSection(title: "Cohort")
            cohort.rows = [("Dataset", c.datasetID), ("Site", c.siteID), ("Scanner", c.scannerID), ("Group", c.groupID),
                           ("Protocol", c.acquisitionProtocol)].compactMap { k, v in v.map { (k, $0) } }
            out.append(cohort)
        }
        var contents = InfoSection(title: "Contents")
        contents.rows = [("Timepoints", "\(s.timepoints.count)"), ("Grids", "\(s.grids.count)"), ("Images", "\(s.images.count)"),
                         ("Annotations", "\(s.annotations.count)"), ("Transforms", "\(s.transforms.count)"),
                         ("Path", s.path)]
        out.append(contents)
        out.append(verificationSection())
        if !s.leftOut.isEmpty {
            var left = InfoSection(title: "Left Out of the Projection")
            left.rows = s.leftOut.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            left.isWarning = true
            out.append(left)
        }
        return out
    }

    func verificationSection() -> InfoSection {
        var v = InfoSection(title: "Integrity")
        switch workspace.verification {
        case .notStarted: v.note = "Not checked."
        case .running: v.note = "Checking every digest and the content id…"
        case .passed: v.note = "Every object digest and the content id verify (§13)."
        case .failed(let why):
            v.note = "Verification failed: \(why). The document is read-only."
            v.isWarning = true
        case .error(let why):
            v.note = "Could not verify: \(why)"
            v.isWarning = true
        }
        return v
    }

    // MARK: Images

    func image(_ id: String) -> [InfoSection] {
        guard let i = s.image(id) else { return [] }
        var img = InfoSection(title: "Image")
        img.rows = [
            ("Id", i.id), ("Modality", i.modality), ("Timepoint", i.timepoint.map(workspace.timepointTitle) ?? "—"),
            ("Value type", i.valueType), ("Units", WindowLevel.units(of: i) ?? "—"),
            ("Stored type", i.dtype), ("Shape", Format.shape(i.shape)),
            ("Rescale", i.rescaled ? "raw × \(Format.number(i.rescaleSlope, digits: 6)) + \(Format.number(i.rescaleIntercept, digits: 6))" : "none (values are physical)"),
        ]
        if let names = i.channelNames { img.rows.append(("Channels", Format.list(names))) }
        let presets = i.windowPresets
        img.rows.append(("Windows", presets.isEmpty ? "none stored" : presets.map { "W \(Format.number($0.width)) L \(Format.number($0.center))" }.joined(separator: "; ")))
        if let m = i.validMask { img.rows.append(("Valid region", m)) }
        if let p = i.prov { img.rows.append(("Provenance", activityText(p))) }
        var storage = InfoSection(title: "Storage")
        storage.rows = [("Chunks", i.chunks.map(Format.shape) ?? "contiguous"), ("Codec", i.codec ?? "—"),
                        ("Size", i.nbytes.map(Format.bytes) ?? "—"), ("Stored", i.storedBytes.map(Format.bytes) ?? "—"),
                        ("Levels", i.multiscale ? "\(i.levels) (multiscale)" : "\(i.levels)"), ("Digest", i.digest ?? "—")]
        var out = [img]
        if let g = s.grid(i.grid) { out.append(gridSection(g, title: "Grid · \(g.id)")) }
        out.append(storage)
        if let acq = s.acquisition[i.id]?.objectValue, !acq.isEmpty {
            var a = InfoSection(title: "Acquisition")
            a.rows = acq.entries.map { ($0.key, AttributesSection.text($0.value)) }
            out.append(a)
        }
        return out
    }

    func gridSection(_ g: GridGeometry, title: String) -> InfoSection {
        var grid = InfoSection(title: title)
        let direction = g.direction.map { row in "[" + row.map { Format.fixed($0, digits: 4) }.joined(separator: ", ") + "]" }
            .joined(separator: "\n")
        grid.rows = [
            ("Shape", Format.shape(g.shape)), ("Axes", zip(g.axisNames, g.axisKinds).map { "\($0) (\($1.rawValue))" }.joined(separator: ", ")),
            ("Spacing", Format.spacing(g.spacing, units: g.units)),
            ("Origin", g.origin.map { Format.number($0, digits: 3) }.joined(separator: ", ") + " " + g.units),
            ("Direction", direction), ("Coordinates", g.coordSystem), ("Frame", g.frameUID ?? "none"),
            ("Timepoint", g.timepoint.map(workspace.timepointTitle) ?? "—"),
            ("Extent", g.physicalSize.map { Format.number($0, digits: 1) }.joined(separator: " × ") + " " + g.units),
        ]
        if let t = g.timeValues { grid.rows.append(("Time", "\(t.count) values\(g.timeUnits.map { " (\($0))" } ?? "")")) }
        return grid
    }

    // MARK: Annotations

    func annotation(_ id: String) -> [InfoSection] {
        guard let a = s.annotation(id) else { return [] }
        let labels = s.labelSet
        func names(_ ids: [Int]) -> String {
            ids.isEmpty ? "none" : ids.map { "\(className($0, labelSet: labels)) (\($0))" }.joined(separator: ", ")
        }
        var head = InfoSection(title: "Annotation · \(KindNames.annotation(a.kind))")
        head.rows = [("Id", a.id), ("Kind", a.kind), ("Task", a.task), ("Grid", a.grid ?? "none"),
                     ("Space", a.space ?? (a.voxel ? "voxels of the grid" : "—")), ("Frame", a.frameUID ?? "—"),
                     ("Timepoints", a.timepoints.map(workspace.timepointTitle).joined(separator: ", "))]
        if let items = a.items { head.rows.append(("Items", "\(items)")) }
        var coverage = InfoSection(title: "Classes and Coverage")
        coverage.rows = [("Can express", names(a.classIDs)), ("Examined", names(a.annotatedClassIDs))]
        if !a.unexaminedClassIDs.isEmpty {
            coverage.rows.append(("Not examined", names(a.unexaminedClassIDs)))
            coverage.note = "The annotation can express classes nobody looked for: their absence is not evidence (§6.2)."
        } else {
            coverage.note = a.classIDs.isEmpty ? nil : "Every class it can express was examined."
        }
        coverage.rows.append(("Closure", a.closure))
        if a.voxel {
            coverage.rows.append(("Ignore", a.ignoreMask.map { "region in mask \($0)" } ?? "id \(a.ignoreID)"))
        }
        var details = InfoSection(title: "Header")
        if let q = a.quality { details.rows.append(("Quality", qualityText(q))) }
        if let p = a.prov { details.rows.append(("Provenance", activityText(p))) }
        if !a.derivedFrom.isEmpty { details.rows.append(("Derived from", Format.list(a.derivedFrom))) }
        if let l = a.layers { details.rows.append(("Layers", "\(l)")) }
        if let lc = a.layerClasses { details.rows.append(("Layer classes", lc.map { "[" + Format.ids($0) + "]" }.joined(separator: " "))) }
        if let p = a.planes { details.rows.append(("Planes", "\(p)")) }
        if let t = a.threshold { details.rows.append(("Threshold", Format.number(t, digits: 3))) }
        if let n = a.normalized { details.rows.append(("Normalized", n ? "yes" : "no")) }
        if let ids = a.instanceIDs { details.rows.append(("Instance ids", ids.prefix(20).map(String.init).joined(separator: ", ") + (ids.count > 20 ? "…" : ""))) }
        if let k = a.skeleton { details.rows.append(("Skeleton", k)) }
        if let c = a.correspondence { details.rows.append(("Corresponds to", c)) }
        if let n = a.names { details.rows.append(("Names", Format.list(n))) }
        if let m = a.submeshes { details.rows.append(("Submeshes", "\(m)")) }
        if let scope = a.scope { details.rows.append(("Scope", scope)) }
        if let m = a.multilabel { details.rows.append(("Multi-label", m ? "yes" : "no")) }
        if a.changeLabel == true { details.rows.append(("Change label", "yes")) }
        if let shape = a.shape { details.rows.append(("Stored shape", Format.shape(shape))) }
        if let d = a.dtype { details.rows.append(("Stored type", d)) }
        if let c = a.codec { details.rows.append(("Codec", c)) }
        details.rows.append(("Digest", a.digest ?? "—"))
        var out = [head, coverage, details]
        if a.kind == "classification",
           let g = workspace.store.ready(.geometry(a.id), as: GeometryResource.self), case .classification(let c) = g.annotation {
            var cls = InfoSection(title: "Assertions")
            cls.classification = c
            out.insert(cls, at: 1)
        }
        if !a.attributes.isEmpty {
            var extra = InfoSection(title: "Other Attributes")
            extra.rows = a.attributes.entries.map { ($0.key, AttributesSection.text($0.value)) }
            out.append(extra)
        }
        return out
    }

    // MARK: Others

    func timepoint(_ id: String) -> [InfoSection] {
        guard let tp = s.timepoint(id) else { return [] }
        var t = InfoSection(title: "Timepoint")
        t.rows = [("Id", tp.id), ("Index", "\(tp.index)"), ("Label", tp.label ?? "—"), ("Date", tp.date ?? "—"),
                  ("From baseline", tp.daysFromBaseline.map { "\(Format.number($0, digits: 1)) days" } ?? "—")]
        if let d = tp.description { t.rows.append(("Description", d)) }
        if let age = tp.subjectAgeYears { t.rows.append(("Subject age", "\(Format.number(age, digits: 1)) years")) }
        if let st = tp.studyUID { t.rows.append(("Study UID", st)) }
        let images = s.images(at: tp.id).map(\.id)
        let annotations = s.annotations(at: tp.id).map(\.id)
        t.rows.append(("Images", Format.list(images)))
        t.rows.append(("Annotations", Format.list(annotations)))
        return [t]
    }

    func transform(_ id: String) -> [InfoSection] {
        guard let t = s.transform(id) else { return [] }
        var x = InfoSection(title: "Transform")
        x.rows = [("Id", t.id), ("Kind", t.kind), ("From frame", t.fromFrame), ("To frame", t.toFrame),
                  ("From grid", t.fromGrid ?? "—"), ("To grid", t.toGrid ?? "—"), ("Units", t.units),
                  ("Timepoints", t.timepoints.joined(separator: ", ")), ("Invertible", t.invertible ? "yes" : "no")]
        if let inv = t.inverseID { x.rows.append(("Inverse", inv)) }
        if let j = t.jacobianDeterminant { x.rows.append(("Jacobian det.", Format.number(j, digits: 6))) }
        if let f = t.fieldGrid { x.rows.append(("Field grid", f)) }
        if let fs = t.fieldShape { x.rows.append(("Field shape", Format.shape(fs))) }
        if let v = t.vectorSpace { x.rows.append(("Vectors", v)) }
        if let i = t.interpolation { x.rows.append(("Interpolation", i)) }
        if let e = t.extrapolation { x.rows.append(("Extrapolation", e)) }
        if let cp = t.cpGrid { x.rows.append(("Control grid", cp)) }
        if let o = t.order { x.rows.append(("Order", "\(o)")) }
        if let c = t.components { x.rows.append(("Components", c.joined(separator: " ∘ ")) ) }
        if let ok = t.chainOK { x.rows.append(("Chain", ok ? "consistent" : "broken")) }
        if let m = t.metrics { x.rows.append(("Metrics", m)) }
        if let p = t.prov { x.rows.append(("Provenance", activityText(p))) }
        x.note = "x_to = T(x_from), in world \(t.units) (§10.2)."
        return [x]
    }

    func labelSet() -> [InfoSection] {
        guard let l = s.labelSet else { return [InfoSection(title: "Label Set", note: "This sample has no label set.")] }
        var ls = InfoSection(title: "Label Set")
        ls.rows = [("Id", l.id), ("Version", l.version), ("Classes", "\(l.classes.count)")]
        if let f = l.form { ls.rows.append(("Form", f)) }
        if let u = l.uri { ls.rows.append(("URI", u)) }
        if !l.relations.isEmpty { ls.rows.append(("Relations", "\(l.relations.count)")) }
        var out = [ls]
        for k in l.skeletons {
            var sk = InfoSection(title: "Skeleton · \(k.id)")
            sk.rows = [("Keypoints", k.keypoints.map { className($0, labelSet: l) }.joined(separator: ", ")),
                       ("Edges", k.edges.map { $0.map { className($0, labelSet: l) }.joined(separator: "–") }.joined(separator: "; "))]
            out.append(sk)
        }
        return out
    }

    func labelClass(_ id: Int) -> [InfoSection] {
        guard let c = s.labelSet?.labelClass(id: id) else { return [] }
        var x = InfoSection(title: "Class")
        x.rows = [("Id", "\(c.id)"), ("Key", c.key), ("Name", c.name),
                  ("Colour", c.color.map { "\($0.description)" } ?? "none stored (palette \(LabelPalette.color(forClassID: c.id).description))")]
        if !c.parents.isEmpty { x.rows.append(("Is a", c.parents.map { className($0, labelSet: s.labelSet) }.joined(separator: ", "))) }
        if let cat = c.category { x.rows.append(("Category", cat)) }
        if let lat = c.laterality { x.rows.append(("Laterality", lat)) }
        for code in c.codes { x.rows.append((code.system, code.code + (code.name.map { " · \($0)" } ?? ""))) }
        if !c.properties.isEmpty {
            x.rows.append(("Properties", JSONValue.object(c.properties).serialized(.meta)))
        }
        let used = s.annotations.filter { $0.classIDs.contains(id) }.map(\.id)
        x.rows.append(("Used by", Format.list(used, empty: "no annotation")))
        return [x]
    }

    func provenance() -> [InfoSection] {
        var agents = InfoSection(title: "Agents")
        agents.rows = s.provenance.agents.map { a in
            (a.id, "\(a.name) · \(a.type)\(a.role.map { " · \($0)" } ?? "")\(a.version.map { " \($0)" } ?? "")")
        }
        if agents.rows.isEmpty { agents.note = "None recorded." }
        var activities = InfoSection(title: "Activities")
        activities.rows = s.provenance.activities.map { a in
            var t = a.type
            if let agent = a.agent { t += " by \(s.provenance.agent(agent)?.name ?? agent)" }
            if let tool = a.tool { t += " · \(tool)" }
            if let started = a.started { t += " · \(started)" }
            if let o = a.outputs, !o.isEmpty { t += " → \(o.joined(separator: ", "))" }
            return (a.id, t)
        }
        if activities.rows.isEmpty { activities.note = "None recorded." }
        return [agents, activities]
    }

    func quality() -> [InfoSection] {
        var q = InfoSection(title: "Quality")
        q.rows = s.quality.sorted { $0.key < $1.key }.map { ($0.key, qualityText($0.key)) }
        if q.rows.isEmpty { q.note = "No quality records." }
        return [q]
    }

    func deidentification() -> [InfoSection] {
        guard let d = s.deidentification else {
            return [InfoSection(title: "De-identification",
                                note: "None recorded: treat this file as potentially identifying.", isWarning: true)]
        }
        var x = InfoSection(title: "De-identification")
        x.rows = (d.objectValue?.entries ?? []).map { ($0.key, AttributesSection.text($0.value)) }
        return [x]
    }

    func clinical() -> [InfoSection] {
        let c = s.clinical
        guard c.present else {
            return [InfoSection(title: "Clinical History", note: "This sample holds no clinical history (format 1.1 profile).")]
        }
        var x = InfoSection(title: "Clinical History")
        x.rows = [("Events", c.events.map(String.init) ?? "—"), ("Records", c.records.map(String.init) ?? "—"),
                  ("Documents", c.documents.map(String.init) ?? "—"), ("Links", c.links.map(String.init) ?? "—")]
        if let kinds = c.kinds { x.rows.append(("Kinds", kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))) }
        if let u = c.unknownAvailability, u > 0 { x.rows.append(("Unknown availability", "\(u)")) }
        if let clock = c.clock, let ref = clock["reference"]?.stringValue { x.rows.append(("Clock", ref + (clock["origin_description"]?.stringValue.map { " · \($0)" } ?? ""))) }
        if c.projection == true { x.rows.append(("Read as", "projection")) }
        x.note = "The clinical history window (timeline, cutoff) comes in a later version."
        return [x]
    }

    func index() -> [InfoSection] {
        var x = InfoSection(title: "Sampling Index")
        x.rows = s.index.map { ($0.annotation, $0.fresh.map { $0 ? "fresh" : "stale — rebuild it" } ?? "unknown") }
        if x.rows.isEmpty { x.note = "No sampling index (§14.3)." }
        return [x]
    }

    func unreadable(_ key: String) -> [InfoSection] {
        guard let u = s.unreadable.first(where: { "\($0.group)/\($0.id)" == key }) else { return [] }
        var x = InfoSection(title: "Unreadable Object")
        x.rows = [("Object", "\(u.group)/\(u.id)"), ("Error", u.kind), ("Code", u.code ?? "—"), ("Message", u.message)]
        x.isWarning = true
        return [x]
    }

    private func activityText(_ id: String) -> String {
        guard let a = s.provenance.activity(id) else { return id }
        let agent = a.agent.flatMap { s.provenance.agent($0)?.name } ?? a.agent
        return "\(id) · \(a.type)\(agent.map { " by \($0)" } ?? "")"
    }

    private func qualityText(_ key: String) -> String {
        guard let q = s.quality[key] else { return key }
        var t = q.status
        if let c = q.confidence { t += " · confidence \(Format.number(c, digits: 2))" }
        if let r = q.reviewedBy, !r.isEmpty { t += " · reviewed by \(r.map { s.provenance.agent($0)?.name ?? $0 }.joined(separator: ", "))" }
        return t
    }
}
