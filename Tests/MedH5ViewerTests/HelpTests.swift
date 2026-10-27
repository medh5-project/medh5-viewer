import XCTest
import AppKit
@testable import MedH5ViewerUI

/// The Help window's Markdown renderer and guide, the keyboard shortcuts
/// (held to the menus and to the tools table of docs/APP_DESIGN.md), and
/// the acknowledgements.
@MainActor
final class HelpTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func render(_ markdown: String) -> String { MarkdownRenderer().render(markdown).html }

    func testHeadingsParagraphsAndInlineMarkup() {
        let (html, headings) = MarkdownRenderer().render("""
        # The Guide
        Some *emphasis*, **strong**, ~~gone~~, `code with *stars* & <tags>` and a
        [link](https://example.org "Example") over
        two lines; <https://medh5.readthedocs.io/> is an autolink.

        ## Getting started
        ## Getting started
        ### What's new? (1.2)
        """)
        XCTAssertTrue(html.contains("<h1 id=\"the-guide\">The Guide</h1>"), html)
        XCTAssertEqual(headings.map(\.anchor), ["the-guide", "getting-started", "getting-started-1", "whats-new-12"])
        XCTAssertEqual(headings.map(\.level), [1, 2, 2, 3])
        XCTAssertTrue(html.contains("<em>emphasis</em>"))
        XCTAssertTrue(html.contains("<strong>strong</strong>"))
        XCTAssertTrue(html.contains("<del>gone</del>"))
        XCTAssertTrue(html.contains("<code>code with *stars* &amp; &lt;tags&gt;</code>"), "no markup inside code; escaped")
        XCTAssertTrue(html.contains("<a href=\"https://example.org\" title=\"Example\">link</a>"))
        XCTAssertTrue(html.contains("<a href=\"https://medh5.readthedocs.io/\">https://medh5.readthedocs.io/</a>"))
        XCTAssertEqual(html.components(separatedBy: "<p>").count - 1, 1, "one paragraph over its lines")
        XCTAssertTrue(render("*a stub,\nover lines*").contains("<em>a stub,\nover lines</em>"), "emphasis spans a line break")
        XCTAssertTrue(render("line one  \nline two").contains("line one<br>"))
        XCTAssertTrue(render("snake_case_word and 2*3*4").contains("snake_case_word"), "an underscore inside a word is text")
        XCTAssertTrue(render("a < b & c").contains("a &lt; b &amp; c"))
        XCTAssertTrue(render("\\*not em\\*").contains("*not em*"))
    }

    func testCodeListsTablesQuotesAndImages() {
        let html = render("""
        ```sh
        medh5 validate a.medh5 --level <level>
        ```

        1. First
        2. Second
           - nested *one*
           - nested two
        3. Third

        - [x] tight
        - loose item

          with a second paragraph

        | Keys | Does | N |
        |:-----|:----:|--:|
        | `⇧⌘V` | validate \\| check | 3 |

        > A quote with **strong** text.

        ---
        ![Alt *text*](images/a.png "Title")
        """)
        XCTAssertTrue(html.contains("<pre><code class=\"language-sh\">medh5 validate a.medh5 --level &lt;level&gt;</code></pre>"), html)
        XCTAssertTrue(html.replacingOccurrences(of: "\n", with: "").contains("<ol><li>First</li><li>Second<ul><li>nested <em>one</em></li><li>nested two</li></ul></li><li>Third</li></ol>"), html)
        XCTAssertTrue(html.contains("<p>with a second paragraph</p>"), "a loose item keeps its paragraphs")
        XCTAssertTrue(html.contains("<th style=\"text-align:left\">Keys</th><th style=\"text-align:center\">Does</th><th style=\"text-align:right\">N</th>"), html)
        XCTAssertTrue(html.contains("<td style=\"text-align:center\">validate | check</td>"), "an escaped pipe stays in its cell")
        XCTAssertTrue(html.contains("<blockquote><p>A quote with <strong>strong</strong> text.</p></blockquote>"))
        XCTAssertTrue(html.contains("<hr>"))
        XCTAssertTrue(html.contains("<img src=\"images/a.png\" alt=\"Alt text\" title=\"Title\">"), html)
        XCTAssertTrue(render("3. Three\n4. Four").contains("<ol start=\"3\">"))

        var dropping = MarkdownRenderer()
        dropping.resolveImage = { _ in nil }
        XCTAssertTrue(dropping.render("![Shown instead](missing.png)").html.contains("Shown instead"), "a missing image leaves its alt text")
    }

    /// The bundled guide renders: its headings, its table, its image inlined.
    func testTheGuideRendersWithItsImage() throws {
        let docs = repository.appendingPathComponent("docs")
        guard FileManager.default.fileExists(atPath: docs.appendingPathComponent(HelpBook.guideName).path) else {
            throw XCTSkip("no docs/USER_GUIDE.md")
        }
        let (html, headings) = try HelpBook.render(directory: docs)
        XCTAssertFalse(headings.isEmpty)
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"), "local images are inlined")
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"))
        let renderer = HelpBook.renderer(directory: docs)
        XCTAssertEqual(renderer.resolveLink("ARCHITECTURE.md"), "https://github.com/medh5-project/medh5-viewer/blob/main/docs/ARCHITECTURE.md")
        XCTAssertEqual(renderer.resolveLink("#keyboard-basics"), "#keyboard-basics")
        XCTAssertNil(renderer.resolveImage("../../etc/passwd"), "nothing outside the guide's folder")
        XCTAssertNotNil(HelpBook.directory, "a debug build finds the repository's guide")
    }

    /// The shortcuts list is built from the menus; what each tool does is
    /// the tools table of docs/APP_DESIGN.md, and the keys there are the
    /// tools' keys.
    func testShortcutsComeFromTheMenusAndTheDesignsToolsTable() throws {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let sections = ShortcutCatalog.sections(menu: menu)
        func entry(_ section: String, _ title: String) -> ShortcutEntry? {
            sections.first { $0.title == section }?.entries.first { $0.title == title }
        }
        XCTAssertEqual(entry("Tools", "Validate…")?.keys, "⇧⌘V")
        XCTAssertEqual(entry("Window", "Document")?.keys, "⌥⌘D")
        XCTAssertEqual(entry("View", "Reset View")?.keys, "⌘0")
        XCTAssertEqual(entry("Tools", "Box")?.keys, "⇧B")
        XCTAssertEqual(entry("File", "Screenshot…")?.detail, "Export")
        XCTAssertEqual(entry("Tools", "Navigate")?.detail, ShortcutCatalog.toolDescriptions[.navigate])
        XCTAssertTrue(sections.contains { $0.title == "Slice Views" })
        XCTAssertEqual(ShortcutCatalog.glyphs(key: "v", modifiers: [.command, .shift, .option, .control]), "⌃⌥⇧⌘V")
        XCTAssertEqual(ShortcutCatalog.glyphs(key: "V", modifiers: [.command]), "⇧⌘V", "an upper-case key implies ⇧")
        XCTAssertEqual(ShortcutCatalog.filter(sections, "validate").flatMap(\.entries).map(\.title), ["Validate…"])

        // The design's tools table.
        let design = try String(contentsOf: repository.appendingPathComponent("docs/APP_DESIGN.md"), encoding: .utf8)
        guard let start = design.range(of: "| Tool | Key | Does |") else { return XCTFail("no tools table") }
        var rows = 0
        for line in design[start.upperBound...].split(separator: "\n").dropFirst() {
            guard line.hasPrefix("|") else { break }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4 else { continue }
            let names = cells[1].components(separatedBy: ", ").flatMap { $0.components(separatedBy: " / ") }
            let keys = cells[2].components(separatedBy: ", ").flatMap { $0.components(separatedBy: " / ") }
            XCTAssertEqual(names.count, keys.count, String(line))
            for (name, key) in zip(names, keys) {
                guard let tool = ViewerTool.allCases.first(where: { $0.title == name }) else {
                    XCTFail("the design names a tool \(name) the app does not have")
                    continue
                }
                let shift = key.hasPrefix("⇧")
                XCTAssertEqual(tool.key.0, key.replacingOccurrences(of: "⇧", with: "").lowercased(), name)
                XCTAssertEqual(tool.key.shift, shift, name)
                if !cells[3].isEmpty { XCTAssertEqual(ShortcutCatalog.toolDescriptions[tool], cells[3], name) }
                rows += 1
            }
        }
        XCTAssertEqual(rows, ViewerTool.allCases.count, "every tool is in the design's table")
    }

    func testAcknowledgementsListEveryPackageAndFindItsLicence() throws {
        let url = try XCTUnwrap(Acknowledgements.noticesURL, "a debug build finds the repository's notices")
        let text = try String(contentsOf: url, encoding: .utf8)
        let packages = Acknowledgements.packages(text)
        XCTAssertGreaterThan(packages.count, 50)
        let medh5 = try XCTUnwrap(packages.first { $0.name == "medh5" })
        XCTAssertEqual(medh5.version, "2.2.3")
        XCTAssertEqual(medh5.license, "MIT")
        XCTAssertEqual(medh5.url, "https://github.com/medh5-project/medh5")
        let hdf5 = try XCTUnwrap(packages.first { $0.name == "hdf5-metno-src" })
        let range = try XCTUnwrap(Acknowledgements.licenceRange(of: hdf5, in: text))
        XCTAssertTrue((text as NSString).substring(with: range).hasPrefix("hdf5-metno-src 0.10.4 (HDF5"))
    }
}
