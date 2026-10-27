import Foundation

/// A small Markdown → HTML renderer for the bundled user guide.
///
/// It covers what the guide uses: ATX headings (with GitHub-style anchors,
/// so `#section` links work), paragraphs and hard breaks, emphasis
/// (`*em*`, `**strong**`, `~~del~~`), inline code and fenced code blocks,
/// ordered and unordered lists (nested by indentation), pipe tables with
/// column alignment, images, links and autolinks, block quotes and
/// horizontal rules. Everything else is text, escaped.
struct MarkdownRenderer {
    struct Heading: Equatable {
        var level: Int
        var text: String
        var anchor: String
    }

    /// What the page loads for an image source (a `data:` URL for a local
    /// file); `nil` drops the image, keeping its alt text.
    var resolveImage: (String) -> String? = { $0 }
    /// Where a link goes (a relative link to another document can become
    /// an online one).
    var resolveLink: (String) -> String = { $0 }

    /// The rendered body and the headings, in order.
    func render(_ markdown: String) -> (html: String, headings: [Heading]) {
        var state = State()
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let html = blocks(lines, &state)
        return (html, state.headings)
    }

    /// A whole page: the body in a document styled for light and dark.
    func page(_ markdown: String, title: String) -> (html: String, headings: [Heading]) {
        let (body, headings) = render(markdown)
        return (MarkdownRenderer.template(title: title, body: body), headings)
    }

    private struct State {
        var headings: [Heading] = []
        var anchors: [String: Int] = [:]

        mutating func anchor(for text: String) -> String {
            let base = MarkdownRenderer.slug(text)
            let n = anchors[base, default: 0]
            anchors[base] = n + 1
            return n == 0 ? base : "\(base)-\(n)"
        }
    }

    // MARK: Blocks

    private func blocks(_ lines: [String], _ state: inout State) -> String {
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                i += 1
                continue
            }
            if let fence = fenceOpening(line) {
                var code: [String] = []
                i += 1
                while i < lines.count, !isFenceClose(lines[i], fence.marker) {
                    code.append(stripIndent(lines[i], fence.indent))
                    i += 1
                }
                i += 1
                let lang = fence.info.isEmpty ? "" : " class=\"language-\(escape(fence.info))\""
                out.append("<pre><code\(lang)>\(escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }
            if let (level, text) = heading(line) {
                let plain = MarkdownRenderer.plainText(inline(text))
                let anchor = state.anchor(for: plain)
                state.headings.append(Heading(level: level, text: plain, anchor: anchor))
                out.append("<h\(level) id=\"\(anchor)\">\(inline(text))</h\(level)>")
                i += 1
                continue
            }
            if isRule(line) {
                out.append("<hr>")
                i += 1
                continue
            }
            if quoteContent(line) != nil {
                var quoted: [String] = []
                while i < lines.count, let q = quoteContent(lines[i]) {
                    quoted.append(q)
                    i += 1
                }
                out.append("<blockquote>\(blocks(quoted, &state))</blockquote>")
                continue
            }
            if i + 1 < lines.count, line.contains("|"), let aligns = tableSeparator(lines[i + 1]) {
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                out.append(table(header: header, aligns: aligns, rows: rows))
                continue
            }
            if listItem(line) != nil {
                let (html, next) = list(lines, from: i, &state)
                out.append(html)
                i = next
                continue
            }
            // A paragraph: up to a blank line or another block.
            var text: [String] = [line]
            i += 1
            while i < lines.count, !isBlank(lines[i]), !startsBlock(lines[i], next: i + 1 < lines.count ? lines[i + 1] : nil) {
                text.append(lines[i])
                i += 1
            }
            out.append("<p>\(paragraph(text))</p>")
        }
        return out.joined(separator: "\n")
    }

    private func startsBlock(_ line: String, next: String?) -> Bool {
        if fenceOpening(line) != nil || heading(line) != nil || isRule(line) || quoteContent(line) != nil { return true }
        if listItem(line) != nil { return true }
        if let next, line.contains("|"), tableSeparator(next) != nil { return true }
        return false
    }

    /// Lines of a paragraph, rendered as one run (emphasis may span lines):
    /// two trailing spaces or a backslash make a `<br>`.
    private func paragraph(_ lines: [String]) -> String {
        var parts: [String] = []
        for (n, raw) in lines.enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if n < lines.count - 1 {
                var hard = raw.hasSuffix("  ")
                if line.hasSuffix("\\") {
                    hard = true
                    line.removeLast()
                }
                if hard { line.append(MarkdownRenderer.hardBreak) }
            }
            parts.append(line)
        }
        return inline(parts.joined(separator: "\n"))
    }

    /// Marks a hard line break inside a paragraph's text.
    static let hardBreak: Character = "\u{1}"

    // MARK: Lists

    private struct ItemMatch {
        var indent: Int
        var ordered: Bool
        var start: Int
        /// Where the item's text begins (its content indent).
        var content: Int
        var text: String
    }

    private func listItem(_ line: String) -> ItemMatch? {
        let indent = leadingSpaces(line)
        guard indent < 16 else { return nil }
        let rest = line.dropFirst(indent)
        guard let first = rest.first else { return nil }
        if "-*+".contains(first) {
            let after = rest.dropFirst()
            guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
            if isRule(line) { return nil }
            let spaces = min(4, max(1, after.prefix { $0 == " " }.count))
            return ItemMatch(indent: indent, ordered: false, start: 1, content: indent + 1 + spaces,
                             text: after.trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")" else { return nil }
        let body = after.dropFirst()
        guard body.isEmpty || body.first == " " else { return nil }
        let spaces = min(4, max(1, body.prefix { $0 == " " }.count))
        return ItemMatch(indent: indent, ordered: true, start: Int(digits) ?? 1, content: indent + digits.count + 1 + spaces,
                         text: body.trimmingCharacters(in: .whitespaces))
    }

    /// A list and the line after it. An item holds its first line, lines
    /// indented to its content (nested lists, more paragraphs) and lazy
    /// continuation lines.
    private func list(_ lines: [String], from start: Int, _ state: inout State) -> (String, Int) {
        guard let first = listItem(lines[start]) else { return ("", start + 1) }
        var items: [(lines: [String], loose: Bool)] = []
        var i = start
        var loose = false
        while i < lines.count {
            guard let m = listItem(lines[i]), m.indent == first.indent || (m.indent < first.content && m.indent >= first.indent),
                  m.ordered == first.ordered else { break }
            var body = [m.text]
            i += 1
            var sawBlank = false
            while i < lines.count {
                let line = lines[i]
                if isBlank(line) {
                    // A blank line continues the item when indented content follows.
                    var j = i + 1
                    while j < lines.count, isBlank(lines[j]) { j += 1 }
                    if j < lines.count, leadingSpaces(lines[j]) >= m.content {
                        body.append("")
                        sawBlank = true
                        i += 1
                        continue
                    }
                    if j < lines.count, let next = listItem(lines[j]), next.indent == first.indent, next.ordered == first.ordered {
                        loose = true
                    }
                    break
                }
                let indent = leadingSpaces(line)
                if indent >= m.content {
                    body.append(stripIndent(line, m.content))
                } else if listItem(line) == nil, !startsBlock(line, next: nil), !sawBlank {
                    body.append(line.trimmingCharacters(in: .whitespaces))
                } else if let nested = listItem(line), nested.indent > m.indent {
                    body.append(stripIndent(line, min(indent, m.content)))
                } else {
                    break
                }
                i += 1
            }
            if sawBlank { loose = true }
            items.append((body, false))
            while i < lines.count, isBlank(lines[i]) {
                var j = i
                while j < lines.count, isBlank(lines[j]) { j += 1 }
                if j < lines.count, let next = listItem(lines[j]), next.indent == first.indent, next.ordered == first.ordered {
                    i = j
                } else {
                    break
                }
            }
        }
        let tag = first.ordered ? "ol" : "ul"
        let startAttr = first.ordered && first.start != 1 ? " start=\"\(first.start)\"" : ""
        var html = "<\(tag)\(startAttr)>"
        for item in items {
            var inner = blocks(item.lines, &state)
            if !loose, inner.hasPrefix("<p>"), let close = inner.range(of: "</p>") {
                // A tight item: its first paragraph without <p>.
                inner = String(inner[inner.index(inner.startIndex, offsetBy: 3)..<close.lowerBound]) + inner[close.upperBound...]
            }
            html += "<li>\(inner)</li>"
        }
        html += "</\(tag)>"
        return (html, i)
    }

    // MARK: Tables

    private enum Align { case none, left, center, right }

    private func tableSeparator(_ line: String) -> [Align]? {
        let parts = cells(line)
        guard !parts.isEmpty else { return nil }
        var aligns: [Align] = []
        for p in parts {
            let t = p.trimmingCharacters(in: .whitespaces)
            let core = t.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            switch (t.hasPrefix(":"), t.hasSuffix(":")) {
            case (true, true): aligns.append(.center)
            case (true, false): aligns.append(.left)
            case (false, true): aligns.append(.right)
            default: aligns.append(.none)
            }
        }
        return aligns
    }

    /// The cells of a table row (`|` escaped as `\|` stays in a cell).
    private func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = []
        var current = ""
        var inCode = false
        var previous: Character?
        for c in t {
            if c == "`" { inCode.toggle() }
            if c == "|" && !inCode && previous != "\\" {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else if c == "|" && previous == "\\" {
                current.removeLast()
                current.append(c)
            } else {
                current.append(c)
            }
            previous = c
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }

    private func table(header: [String], aligns: [Align], rows: [[String]]) -> String {
        func attr(_ i: Int) -> String {
            switch i < aligns.count ? aligns[i] : .none {
            case .none: return ""
            case .left: return " style=\"text-align:left\""
            case .center: return " style=\"text-align:center\""
            case .right: return " style=\"text-align:right\""
            }
        }
        var html = "<table><thead><tr>"
        for (i, h) in header.enumerated() { html += "<th\(attr(i))>\(inline(h))</th>" }
        html += "</tr></thead><tbody>"
        for row in rows {
            html += "<tr>"
            for i in 0..<header.count { html += "<td\(attr(i))>\(inline(i < row.count ? row[i] : ""))</td>" }
            html += "</tr>"
        }
        return html + "</tbody></table>"
    }

    // MARK: Line kinds

    private func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    private func leadingSpaces(_ line: String) -> Int {
        var n = 0
        for c in line {
            if c == " " { n += 1 } else if c == "\t" { n += 4 - n % 4 } else { break }
        }
        return n
    }

    private func stripIndent(_ line: String, _ count: Int) -> String {
        var removed = 0
        var index = line.startIndex
        while index < line.endIndex, removed < count, line[index] == " " || line[index] == "\t" {
            removed += line[index] == "\t" ? 4 - removed % 4 : 1
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    private func heading(_ line: String) -> (Int, String)? {
        guard leadingSpaces(line) < 4 else { return nil }
        let t = line.trimmingCharacters(in: .whitespaces)
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = t.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s.
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private func isRule(_ line: String) -> Bool {
        guard leadingSpaces(line) < 4 else { return false }
        let t = line.filter { $0 != " " && $0 != "\t" }
        guard t.count >= 3, let c = t.first, "-*_".contains(c) else { return false }
        return t.allSatisfy { $0 == c }
    }

    private func quoteContent(_ line: String) -> String? {
        guard leadingSpaces(line) < 4 else { return nil }
        let t = line.drop { $0 == " " }
        guard t.first == ">" else { return nil }
        let rest = t.dropFirst()
        return String(rest.first == " " ? rest.dropFirst() : rest)
    }

    private struct Fence {
        var marker: String
        var indent: Int
        var info: String
    }

    private func fenceOpening(_ line: String) -> Fence? {
        let indent = leadingSpaces(line)
        guard indent < 4 else { return nil }
        let t = line.dropFirst(indent)
        for c: Character in ["`", "~"] {
            let run = t.prefix { $0 == c }.count
            if run >= 3 {
                let info = t.dropFirst(run).trimmingCharacters(in: .whitespaces)
                if c == "`" && info.contains("`") { return nil }
                return Fence(marker: String(repeating: c, count: run), indent: indent,
                             info: String(info.split(separator: " ").first ?? ""))
            }
        }
        return nil
    }

    private func isFenceClose(_ line: String, _ marker: String) -> Bool {
        guard leadingSpaces(line) < 4 else { return false }
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let c = marker.first else { return false }
        return t.count >= marker.count && t.allSatisfy { $0 == c }
    }

    // MARK: Inline

    /// Emphasis, code, links, images and autolinks in one line of text.
    func inline(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\" where i + 1 < chars.count && "\\`*_{}[]()#+-.!|<>~\"".contains(chars[i + 1]):
                out += escape(String(chars[i + 1]))
                i += 2
            case "`":
                let run = count(chars, from: i, of: "`")
                if let close = findRun(chars, from: i + run, of: "`", length: run) {
                    var code = String(chars[(i + run)..<close])
                    if code.hasPrefix(" ") && code.hasSuffix(" ") && code.count > 2 { code = String(code.dropFirst().dropLast()) }
                    out += "<code>\(escape(code))</code>"
                    i = close + run
                } else {
                    out += String(repeating: "`", count: run)
                    i += run
                }
            case "!" where i + 1 < chars.count && chars[i + 1] == "[":
                if let (alt, dest, title, end) = linkParts(chars, from: i + 1) {
                    let plainAlt = MarkdownRenderer.plainText(inline(alt))
                    if let src = resolveImage(dest) {
                        out += "<img src=\"\(escape(src))\" alt=\"\(escape(plainAlt))\"\(title.map { " title=\"\(escape($0))\"" } ?? "")>"
                    } else {
                        out += escape(plainAlt)
                    }
                    i = end
                } else {
                    out += "!"
                    i += 1
                }
            case "[":
                if let (label, dest, title, end) = linkParts(chars, from: i) {
                    out += "<a href=\"\(escape(resolveLink(dest)))\"\(title.map { " title=\"\(escape($0))\"" } ?? "")>\(inline(label))</a>"
                    i = end
                } else {
                    out += "["
                    i += 1
                }
            case "<":
                if let close = chars[i...].firstIndex(of: ">") {
                    let inner = String(chars[(i + 1)..<close])
                    if (inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:")),
                       !inner.contains(" ") {
                        let shown = inner.hasPrefix("mailto:") ? String(inner.dropFirst(7)) : inner
                        out += "<a href=\"\(escape(inner))\">\(escape(shown))</a>"
                        i = close + 1
                        continue
                    }
                }
                out += "&lt;"
                i += 1
            case "*", "_", "~":
                let run = count(chars, from: i, of: c)
                let length = c == "~" ? 2 : min(run, 2)
                if c == "~" && run < 2 {
                    out.append(c)
                    i += 1
                    continue
                }
                let opensWord = i + length < chars.count && !chars[i + length].isWhitespace
                let leftOK = c != "_" || i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber)
                if opensWord, leftOK, let close = findClosing(chars, from: i + length, of: c, length: length) {
                    let inner = inline(String(chars[(i + length)..<close]))
                    let tag = c == "~" ? "del" : (length == 2 ? "strong" : "em")
                    out += "<\(tag)>\(inner)</\(tag)>"
                    i = close + length
                } else {
                    out += String(repeating: c, count: run)
                    i += run
                }
            case MarkdownRenderer.hardBreak:
                out += "<br>"
                i += 1
            case "&":
                out += "&amp;"
                i += 1
            case ">":
                out += "&gt;"
                i += 1
            case "\"":
                out += "&quot;"
                i += 1
            default:
                out.append(c)
                i += 1
            }
        }
        return out
    }

    private func count(_ chars: [Character], from i: Int, of c: Character) -> Int {
        var n = 0
        while i + n < chars.count, chars[i + n] == c { n += 1 }
        return n
    }

    /// The start of the next run of exactly `length` `c`s.
    private func findRun(_ chars: [Character], from start: Int, of c: Character, length: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == c {
                let run = count(chars, from: i, of: c)
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    /// A closing emphasis run: not after whitespace, not inside code.
    private func findClosing(_ chars: [Character], from start: Int, of c: Character, length: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "`" {
                let run = count(chars, from: i, of: "`")
                if let close = findRun(chars, from: i + run, of: "`", length: run) { i = close + run; continue }
                i += run
                continue
            }
            if chars[i] == c {
                let run = count(chars, from: i, of: c)
                if run >= length, i > start, !chars[i - 1].isWhitespace {
                    let rightOK = c != "_" || i + run >= chars.count || !(chars[i + run].isLetter || chars[i + run].isNumber)
                    if rightOK { return i + (run - length) }
                }
                i += run
                continue
            }
            i += 1
        }
        return nil
    }

    /// `[label](dest "title")` starting at `[`: the label, destination,
    /// title and the index after it.
    private func linkParts(_ chars: [Character], from start: Int) -> (String, String, String?, Int)? {
        guard start < chars.count, chars[start] == "[" else { return nil }
        var depth = 0
        var i = start
        var close: Int?
        while i < chars.count {
            switch chars[i] {
            case "\\": i += 1
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { close = i }
            default: break
            }
            if close != nil { break }
            i += 1
        }
        guard let labelEnd = close, labelEnd + 1 < chars.count, chars[labelEnd + 1] == "(" else { return nil }
        var j = labelEnd + 2
        while j < chars.count, chars[j] == " " { j += 1 }
        var dest = ""
        var parens = 0
        while j < chars.count {
            let c = chars[j]
            if c == "(" { parens += 1 }
            if c == ")" {
                if parens == 0 { break }
                parens -= 1
            }
            if c == " " { break }
            dest.append(c)
            j += 1
        }
        while j < chars.count, chars[j] == " " { j += 1 }
        var title: String?
        if j < chars.count, chars[j] == "\"" || chars[j] == "'" {
            let q = chars[j]
            guard let end = chars[(j + 1)...].firstIndex(of: q) else { return nil }
            title = String(chars[(j + 1)..<end])
            j = end + 1
            while j < chars.count, chars[j] == " " { j += 1 }
        }
        guard j < chars.count, chars[j] == ")" else { return nil }
        if dest.hasPrefix("<") && dest.hasSuffix(">") { dest = String(dest.dropFirst().dropLast()) }
        return (String(chars[(start + 1)..<labelEnd]), dest, title, j + 1)
    }

    // MARK: Text

    func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    /// Text without tags, entities decoded (for anchors and alt text).
    static func plainText(_ html: String) -> String {
        var out = ""
        var inTag = false
        for c in html {
            if c == "<" { inTag = true; continue }
            if c == ">" && inTag { inTag = false; continue }
            if !inTag { out.append(c) }
        }
        return out.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// GitHub's heading anchor: lower case, punctuation dropped, spaces as
    /// hyphens.
    static func slug(_ text: String) -> String {
        var out = ""
        for c in text.lowercased() {
            if c.isLetter || c.isNumber || c == "-" || c == "_" {
                out.append(c)
            } else if c == " " {
                out.append("-")
            }
        }
        return out.isEmpty ? "section" : out
    }

    static func template(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <title>\(title)</title>
        <style>
        :root { --fg: #1d1d1f; --bg: #ffffff; --muted: #6e6e73; --rule: #d2d2d7; --code: #f2f2f5; --accent: #0a66c2; }
        @media (prefers-color-scheme: dark) {
          :root { --fg: #ececf0; --bg: #1e1e20; --muted: #a1a1a8; --rule: #3a3a3e; --code: #2b2b2f; --accent: #5aa9ff; }
        }
        html { background: var(--bg); }
        body { font: 14px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: var(--fg);
               background: var(--bg); margin: 0 auto; padding: 26px 36px 56px; max-width: 860px; -webkit-font-smoothing: antialiased; }
        h1 { font-size: 27px; line-height: 1.25; margin: 4px 0 14px; }
        h2 { font-size: 19px; margin: 32px 0 10px; padding-bottom: 5px; border-bottom: 1px solid var(--rule); }
        h3 { font-size: 15.5px; margin: 24px 0 8px; }
        h4, h5, h6 { font-size: 14px; margin: 18px 0 6px; }
        p, ul, ol, table, pre, blockquote { margin: 10px 0; }
        ul, ol { padding-left: 24px; }
        li { margin: 3px 0; }
        a { color: var(--accent); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code { font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); padding: 1px 4px; border-radius: 4px; }
        pre { background: var(--code); padding: 10px 13px; border-radius: 7px; overflow-x: auto; }
        pre code { background: none; padding: 0; font-size: 12px; }
        table { border-collapse: collapse; font-size: 13px; }
        th, td { border: 1px solid var(--rule); padding: 5px 10px; text-align: left; vertical-align: top; }
        th { background: var(--code); font-weight: 600; }
        img { max-width: 100%; border-radius: 7px; border: 1px solid var(--rule); }
        blockquote { padding: 2px 14px; border-left: 3px solid var(--rule); color: var(--muted); }
        hr { border: none; border-top: 1px solid var(--rule); margin: 26px 0; }
        del { color: var(--muted); }
        </style></head>
        <body>
        \(body)
        </body></html>
        """
    }
}
