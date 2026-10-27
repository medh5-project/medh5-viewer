import AppKit
import SwiftUI
import MedH5Kit

/// A `.medh5c` collection: a list of its member samples. Opening a member
/// opens a read-only sample window.
@objc(MedH5CollectionDocument)
public final class MedH5CollectionDocument: NSDocument {
    public static let typeIdentifier = "io.github.medh5-project.medh5c"
    public static let fileExtension = "medh5c"

    private(set) var members: [CollectionMember] = []

    override public class var autosavesInPlace: Bool { false }
    override public class var readableTypes: [String] { [typeIdentifier] }
    override public class var writableTypes: [String] { [] }
    override public class func isNativeType(_ type: String) -> Bool { false }
    override public class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override public func read(from url: URL, ofType typeName: String) throws {
        members = try Collections.list(url)
    }

    override public func makeWindowControllers() {
        MainActor.assumeIsolated {
            let view = CollectionView(document: self, members: members)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 900, height: 480))
            window.center()
            addWindowController(NSWindowController(window: window))
        }
    }

    /// Opens one member as a read-only sample window.
    @MainActor
    func openMember(_ name: String) {
        guard let url = fileURL else { return }
        do {
            let title = "\(url.deletingPathExtension().lastPathComponent) › \(name)"
            let doc = try MedH5Document.untitled(from: url, name: title, readOnly: [.collectionMember(name)], member: name)
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers()
            doc.showWindows()
        } catch {
            presentError(error)
        }
    }
}

/// The members of a collection.
struct CollectionView: View {
    let document: MedH5CollectionDocument
    let members: [CollectionMember]
    @State private var selection = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                Text("\(members.count) sample\(members.count == 1 ? "" : "s")").font(.headline)
                Spacer()
                Text("Double-click a sample to open it read-only").foregroundStyle(.secondary).font(.callout)
            }
            .padding(12)
            Divider()
            Table(members.map(MemberRow.init), selection: $selection) {
                TableColumn("Member") { r in Text(r.member.name) }
                TableColumn("Sample") { r in Text(r.member.sampleID ?? "—") }
                TableColumn("Subject") { r in Text(r.member.subjectID ?? "—") }
                TableColumn("Timepoints") { r in Text(Format.list(r.member.timepoints ?? [])) }
                TableColumn("Images") { r in Text("\(r.member.images?.count ?? 0)") }.width(60)
                TableColumn("Annotations") { r in Text("\(r.member.annotations?.count ?? 0)") }.width(80)
                TableColumn("Content id") { r in Text(Format.shortDigest(r.member.contentID)).font(.system(.body, design: .monospaced)) }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Open") { ids.forEach(document.openMember) }
            } primaryAction: { ids in
                ids.forEach(document.openMember)
            }
        }
        .frame(minWidth: 640, minHeight: 300)
    }
}

/// A member as a table row.
struct MemberRow: Identifiable {
    let member: CollectionMember
    var id: String { member.name }
}
