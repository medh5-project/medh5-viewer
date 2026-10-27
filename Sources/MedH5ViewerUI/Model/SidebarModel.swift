import Foundation
import MedH5Kit

/// One row of the sidebar outline.
struct SidebarNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case sample
        case timepoint(String)
        case grid(String)
        case image(String)
        case annotation(String)
        case transform(String)
        case labelSet
        case labelClass(Int)
        case provenance
        case quality
        case deidentification
        case clinical
        case index
        case unreadable(String)
    }

    let id: String
    let kind: Kind
    var title: String
    var subtitle: String?
    var symbol: String
    var children: [SidebarNode]?
    /// A coverage badge (`6/7 examined`) or a count.
    var badge: String?
    /// The colour swatch of a label class.
    var color: RGBA8?
    /// Drawn with a warning tint (an unreadable object, no de-identification).
    var isWarning = false
    /// Whether the eye button can add the object to a view.
    var isDisplayable = false

    /// The image or annotation the row stands for.
    var objectID: String? {
        switch kind {
        case .image(let id), .annotation(let id): return id
        default: return nil
        }
    }

    static func == (a: SidebarNode, b: SidebarNode) -> Bool { a.id == b.id && a.title == b.title && a.subtitle == b.subtitle && a.badge == b.badge && a.children == b.children }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A titled group of rows.
struct SidebarSection: Identifiable {
    let id: String
    let title: String
    var nodes: [SidebarNode]
}

/// Builds the outline from the sample summary (no voxels read).
enum SidebarBuilder {
    static func sections(for s: SampleSummary) -> [SidebarSection] {
        var sections: [SidebarSection] = []
        let across = s.annotations.filter { $0.timepoints.count > 1 }
        let acrossIDs = Set(across.map(\.id))

        // Timepoints → grids → images and annotations.
        var timepointNodes: [SidebarNode] = []
        let timepoints = s.timepoints.sorted { $0.index < $1.index }
        var listed = Set<String>()
        for tp in timepoints {
            var children: [SidebarNode] = []
            for grid in s.grids where grid.timepoint == tp.id {
                var gridChildren: [SidebarNode] = []
                for image in s.images where image.grid == grid.id {
                    gridChildren.append(imageNode(image))
                    listed.insert("image:\(image.id)")
                }
                for a in s.annotations where a.grid == grid.id && !acrossIDs.contains(a.id) {
                    gridChildren.append(annotationNode(a, s))
                    listed.insert("ann:\(a.id)")
                }
                children.append(SidebarNode(
                    id: "grid:\(grid.id)", kind: .grid(grid.id), title: grid.id,
                    subtitle: "\(Format.shape(grid.spatialShape)) · \(Format.spacing(grid.spacing, units: grid.units))",
                    symbol: Symbols.grid, children: gridChildren))
            }
            for a in s.annotations where a.grid == nil && a.timepoints == [tp.id] && !acrossIDs.contains(a.id) {
                children.append(annotationNode(a, s))
                listed.insert("ann:\(a.id)")
            }
            var details = tp.label == nil ? [] : [tp.id]
            if let date = tp.date { details.append(date) }
            if let day = Format.day(tp.daysFromBaseline) { details.append(day) }
            timepointNodes.append(SidebarNode(
                id: "tp:\(tp.id)", kind: .timepoint(tp.id), title: tp.label?.capitalizedFirst ?? tp.id,
                subtitle: details.isEmpty ? nil : details.joined(separator: " · "), symbol: Symbols.timepoint,
                children: children))
        }
        // Grids whose timepoint is not declared (should not happen; shown anyway).
        for grid in s.grids where !timepoints.contains(where: { $0.id == grid.timepoint }) {
            var gridChildren: [SidebarNode] = []
            for image in s.images where image.grid == grid.id && !listed.contains("image:\(image.id)") {
                gridChildren.append(imageNode(image))
                listed.insert("image:\(image.id)")
            }
            for a in s.annotations where a.grid == grid.id && !acrossIDs.contains(a.id) && !listed.contains("ann:\(a.id)") {
                gridChildren.append(annotationNode(a, s))
                listed.insert("ann:\(a.id)")
            }
            timepointNodes.append(SidebarNode(
                id: "grid:\(grid.id)", kind: .grid(grid.id), title: grid.id,
                subtitle: Format.shape(grid.spatialShape), symbol: Symbols.grid, children: gridChildren))
        }
        let rest = s.annotations.filter { !listed.contains("ann:\($0.id)") && !acrossIDs.contains($0.id) }
        for a in rest { timepointNodes.append(annotationNode(a, s)) }
        sections.append(SidebarSection(id: "timepoints", title: "Timepoints", nodes: timepointNodes))

        if !across.isEmpty {
            sections.append(SidebarSection(id: "across", title: "Across Timepoints", nodes: across.map { annotationNode($0, s) }))
        }

        if !s.transforms.isEmpty {
            sections.append(SidebarSection(id: "transforms", title: "Transforms", nodes: s.transforms.map { t in
                SidebarNode(id: "tf:\(t.id)", kind: .transform(t.id), title: t.id,
                            subtitle: "\(t.kind) · \(shortFrame(t.fromFrame)) → \(shortFrame(t.toFrame))",
                            symbol: Symbols.transform)
            }))
        }

        if !s.unreadable.isEmpty {
            sections.append(SidebarSection(id: "unreadable", title: "Unreadable", nodes: s.unreadable.map { u in
                var node = SidebarNode(id: "bad:\(u.group)/\(u.id)", kind: .unreadable("\(u.group)/\(u.id)"),
                                       title: u.id, subtitle: (u.code.map { "[\($0)] " } ?? "") + u.message,
                                       symbol: Symbols.warning)
                node.isWarning = true
                return node
            }))
        }

        if let labels = s.labelSet {
            let classes = labels.classes.map { c in
                var n = SidebarNode(id: "class:\(c.id)", kind: .labelClass(c.id), title: c.name,
                                    subtitle: "\(c.id) · \(c.key)", symbol: "circle.fill")
                n.color = c.displayColor
                return n
            }
            sections.append(SidebarSection(id: "labels", title: "Label Set", nodes: [
                SidebarNode(id: "labelset", kind: .labelSet, title: labels.id,
                            subtitle: "version \(labels.version) · \(labels.classes.count) classes",
                            symbol: Symbols.labelSet, children: classes),
            ]))
        }

        var curation: [SidebarNode] = []
        let agents = s.provenance.agents.count, activities = s.provenance.activities.count
        curation.append(SidebarNode(id: "provenance", kind: .provenance, title: "Provenance",
                                    subtitle: agents + activities == 0 ? "none recorded"
                                        : "\(agents) agent\(agents == 1 ? "" : "s") · \(activities) activit\(activities == 1 ? "y" : "ies")",
                                    symbol: Symbols.provenance))
        curation.append(SidebarNode(id: "quality", kind: .quality, title: "Quality",
                                    subtitle: s.quality.isEmpty ? "none recorded" : "\(s.quality.count) record\(s.quality.count == 1 ? "" : "s")",
                                    symbol: Symbols.quality))
        var deid = SidebarNode(id: "deid", kind: .deidentification, title: "De-identification",
                               subtitle: s.deidentification.map { d in d["method"]?.stringValue ?? "recorded" }
                                   ?? "none recorded — treat as identifying",
                               symbol: Symbols.deidentification)
        deid.isWarning = s.deidentification == nil
        curation.append(deid)
        let clinicalSubtitle: String
        if s.clinical.present {
            var parts: [String] = []
            if let e = s.clinical.events { parts.append("\(e) events") }
            if let d = s.clinical.documents { parts.append("\(d) documents") }
            if s.clinical.projection == true { parts.append("projection") }
            clinicalSubtitle = parts.isEmpty ? "present" : parts.joined(separator: " · ")
        } else {
            clinicalSubtitle = "none (format 1.1)"
        }
        curation.append(SidebarNode(id: "clinical", kind: .clinical, title: "Clinical History", subtitle: clinicalSubtitle,
                                    symbol: Symbols.clinical))
        let fresh = s.index.filter { $0.fresh == true }.count
        curation.append(SidebarNode(id: "index", kind: .index, title: "Sampling Index",
                                    subtitle: s.index.isEmpty ? "none" : "\(s.index.count) entr\(s.index.count == 1 ? "y" : "ies") · \(fresh) fresh",
                                    symbol: Symbols.index))
        sections.append(SidebarSection(id: "curation", title: "Curation", nodes: curation))
        return sections
    }

    static func imageNode(_ image: ImageInfo) -> SidebarNode {
        var parts = [image.modality, image.dtype]
        if image.valueType != "intensity" && image.valueType != "quantitative" { parts.append(image.valueType) }
        var node = SidebarNode(id: "image:\(image.id)", kind: .image(image.id), title: image.id,
                               subtitle: parts.joined(separator: " · ") + " · " + Format.shape(image.shape),
                               symbol: Symbols.image(modality: image.modality, valueType: image.valueType))
        node.isDisplayable = true
        return node
    }

    static func annotationNode(_ a: AnnotationInfo, _ s: SampleSummary) -> SidebarNode {
        var parts = [KindNames.annotation(a.kind)]
        if !a.classIDs.isEmpty { parts.append("\(a.classIDs.count) class\(a.classIDs.count == 1 ? "" : "es")") }
        if let items = a.items, a.geometric || a.kind == "instances" { parts.append("\(items) item\(items == 1 ? "" : "s")") }
        var node = SidebarNode(id: "ann:\(a.id)", kind: .annotation(a.id), title: a.id,
                               subtitle: parts.joined(separator: " · "), symbol: Symbols.annotation(kind: a.kind))
        if !a.classIDs.isEmpty {
            node.badge = "\(a.annotatedClassIDs.count)/\(a.classIDs.count)"
        }
        node.isDisplayable = a.kind != "classification"
        return node
    }

    /// `demo:frame-tp0` → `frame-tp0` (the namespace is in the Info panel).
    static func shortFrame(_ frame: String) -> String {
        frame.split(separator: ":").last.map(String.init) ?? frame
    }

    /// Every node, depth first.
    static func flatten(_ sections: [SidebarSection]) -> [SidebarNode] {
        var out: [SidebarNode] = []
        func walk(_ n: SidebarNode) {
            out.append(n)
            n.children?.forEach(walk)
        }
        sections.forEach { $0.nodes.forEach(walk) }
        return out
    }

    /// The ids of the nodes expanded at first: timepoints and grids.
    static func initiallyExpanded(_ sections: [SidebarSection]) -> Set<String> {
        Set(flatten(sections).filter {
            switch $0.kind {
            case .timepoint, .grid: return true
            default: return false
            }
        }.map(\.id))
    }
}

extension String {
    /// "baseline" → "Baseline".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
