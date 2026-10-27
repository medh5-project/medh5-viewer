import AppKit
import SwiftUI
import MedH5Kit

// What the document and label set editors share: paths into a JSON value,
// the engine's check of an edit, number fields that keep a number's kind,
// and a plain text view for JSON and documents.

/// A step into a JSON value.
enum JSONPathComponent: Hashable, CustomStringConvertible {
    case key(String)
    case index(Int)

    var description: String {
        switch self {
        case .key(let k): return k
        case .index(let i): return String(i)
        }
    }
}

extension JSONValue {
    /// The value at `path`, `nil` when absent.
    func value(at path: [JSONPathComponent]) -> JSONValue? {
        var current: JSONValue? = self
        for step in path {
            switch step {
            case .key(let k): current = current?[k]
            case .index(let i): current = current?[i]
            }
            if current == nil { return nil }
        }
        return current
    }

    /// Sets (or, with `nil`, removes) the value at `path`, making the
    /// objects on the way. A new member goes last; an existing one keeps
    /// its place.
    mutating func set(_ value: JSONValue?, at path: [JSONPathComponent]) {
        guard let first = path.first else {
            if let value { self = value }
            return
        }
        let rest = Array(path.dropFirst())
        switch first {
        case .key(let k):
            var object = objectValue ?? JSONObject()
            if rest.isEmpty {
                object[k] = value
            } else {
                var child = object[k] ?? .object(JSONObject())
                child.set(value, at: rest)
                object[k] = child
            }
            self = .object(object)
        case .index(let i):
            guard var items = arrayValue, items.indices.contains(i) else { return }
            if rest.isEmpty {
                if let value { items[i] = value } else { items.remove(at: i) }
            } else {
                items[i].set(value, at: rest)
            }
            self = .array(items)
        }
    }

    /// A JSON pointer (RFC 6901) for a path, as the validator's locations
    /// into `/meta` read.
    static func pointer(_ path: [JSONPathComponent]) -> String {
        path.isEmpty ? "/" : path.map { "/" + $0.description.replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1") }.joined()
    }

    /// The text a form shows for a number: integers as integers, floats as
    /// Python writes them (`92.0` stays visibly a float).
    var numberText: String {
        switch self {
        case .int(let i): return String(i)
        case .uint(let u): return String(u)
        case .double(let d): return JSONValue.pythonRepr(d)
        default: return ""
        }
    }

    /// Parses a number typed into a form. An integer typed where a float
    /// was stays a float (`92` over `92.5` is `92.0`), so editing never
    /// changes a number's kind; a decimal point makes a float.
    /// Returns `.some(nil)` for empty text (remove the member) and `nil`
    /// for text that is not a number.
    static func number(from text: String, like original: JSONValue?) -> JSONValue?? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "−", with: "-")
        if t.isEmpty { return .some(nil) }
        let integral = !t.contains(".") && !t.lowercased().contains("e")
        if integral, let i = Int64(t) {
            if case .double? = original { return .some(.double(Double(i))) }
            return .some(.int(i))
        }
        if let d = Double(t), d.isFinite { return .some(.double(d)) }
        return nil
    }

    /// One line describing a value for an outline: `"text"`, `12`, `{3}`.
    var preview: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int, .uint, .double: return numberText
        case .string(let s): return "“" + (s.count > 80 ? String(s.prefix(80)) + "…" : s) + "”"
        case .array(let a): return "[\(a.count) item\(a.count == 1 ? "" : "s")]"
        case .object(let o): return "{\(o.count) member\(o.count == 1 ? "" : "s")}"
        }
    }

    /// The kind of a value, for an outline.
    var kindName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .int, .uint: return "integer"
        case .double: return "float"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

extension JSONFormat {
    /// The text the JSON editors show: two-space indent, members in order,
    /// UTF-8 as is.
    static let editing = JSONFormat(itemSeparator: ",", keySeparator: ": ", sortKeys: false, escapeNonASCII: false, indent: 2)
}

extension JSONParseError {
    /// "line 3, column 14: expected , or }".
    func describe(in text: String) -> String {
        let bytes = Array(text.utf8.prefix(offset))
        let line = bytes.filter { $0 == 0x0A }.count + 1
        let column = bytes.count - (bytes.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0) + 1
        return "Line \(line), column \(column): \(message)"
    }
}

/// The engine's check of an edit before the viewer accepts it: amend a
/// temporary copy of the saved file with it and commit (the writer checks
/// every field and every reference), then validate the copy at the
/// semantic level. Errors the saved file already had do not count.
enum EngineCheck {
    /// What the engine refused, in its words.
    struct Refusal: Error, LocalizedError, Equatable {
        var messages: [String]
        var errorDescription: String? { messages.joined(separator: "\n") }
    }

    /// Applies `edit` to an amendment of `source` written to a temporary
    /// file; returns the document as the engine stores it. Throws
    /// `Refusal` when the engine refuses.
    static func run(source: URL, edit: (SampleWriter) throws -> Void) throws -> JSONValue {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("medh5-viewer-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("check.medh5")
        let writer = try SampleWriter.amend(url: source, outURL: out)
        let stored: JSONValue
        do {
            try edit(writer)
            stored = try writer.document()
            try writer.commit(digests: false)
        } catch let error as MedH5Error {
            writer.abort()
            throw Refusal(messages: [describe(error)])
        } catch {
            writer.abort()
            throw error
        }
        let after = try Validator.validate(url: out, level: "semantic")
        let errors = after.diagnostics.filter(\.isError)
        if !errors.isEmpty {
            let before = try Validator.validate(url: source, level: "semantic")
            let known = Set(before.diagnostics.filter(\.isError).map { "\($0.code)|\($0.location)" })
            let new = errors.filter { !known.contains("\($0.code)|\($0.location)") }
            if !new.isEmpty {
                throw Refusal(messages: new.map { "[\($0.code)] \($0.location): \($0.message)" })
            }
        }
        return stored
    }

    /// The engine's message with its code.
    static func describe(_ error: MedH5Error) -> String {
        error.code.map { "[\($0)] \(error.message)" } ?? error.message
    }

    /// A document checked by the engine; returns it as stored.
    static func document(_ document: JSONValue, source: URL) throws -> JSONValue {
        try run(source: source) { try $0.setDocument(document) }
    }

    /// A label set checked by the engine; returns it as stored (`nil`:
    /// removed).
    static func labelSet(_ labelSet: JSONValue?, source: URL) throws -> JSONValue? {
        let stored = try run(source: source) { try $0.setLabelSet(labelSet) }
        return stored["label_set"].flatMap { $0.isNull ? nil : $0 }
    }
}

/// A text field for a number that keeps its kind (`JSONValue.number`):
/// it commits on Return and when it loses focus, and shows what it holds
/// otherwise.
struct NumberField: View {
    let title: String
    let value: JSONValue?
    var prompt: String = ""
    let commit: (JSONValue?) -> Void
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .focused($focused)
            .onAppear { text = value?.numberText ?? "" }
            .onChange(of: value) { _, new in if !focused { text = new?.numberText ?? "" } }
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
            .onSubmit { save() }
            .foregroundStyle(invalid ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
            .help(invalid ? "Not a number" : (value.map { "\($0.kindName)" } ?? "empty"))
    }

    private func save() {
        guard let parsed = JSONValue.number(from: text, like: value) else {
            invalid = true
            return
        }
        invalid = false
        if parsed != value { commit(parsed) }
        text = parsed?.numberText ?? ""
    }
}

/// A plain-text view (AppKit): monospaced JSON with no smart quotes or
/// substitutions, or read-only text with highlighted ranges.
struct PlainTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    /// Ranges (UTF-16) to highlight in a read-only view.
    var highlights: [NSRange] = []
    /// A range to scroll to and select.
    var reveal: NSRange?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.font = font
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        update(view)
        DispatchQueue.main.async { scrollIfNeeded(view, context.coordinator) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        update(view)
        scrollIfNeeded(view, context.coordinator)
    }

    private func update(_ view: NSTextView) {
        view.isEditable = isEditable
        view.isSelectable = true
        if view.string != text {
            view.string = text
            view.font = font
            view.textColor = .textColor
        }
        if !isEditable, let storage = view.textStorage {
            let whole = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.backgroundColor, range: whole)
            for r in highlights where NSMaxRange(r) <= storage.length {
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: r)
            }
        }
    }

    /// Scrolls to `reveal` when it changed (not on every update).
    private func scrollIfNeeded(_ view: NSTextView, _ coordinator: Coordinator) {
        guard let reveal, reveal != coordinator.revealed, NSMaxRange(reveal) <= (view.string as NSString).length else { return }
        coordinator.revealed = reveal
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        view.setSelectedRange(reveal)
        view.scrollRangeToVisible(reveal)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextView
        var revealed: NSRange?
        init(_ parent: PlainTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}
