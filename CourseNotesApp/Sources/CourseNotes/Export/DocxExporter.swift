import Foundation

/// 直接生成 Word（Office Open XML）：标题、段落、两级列表、待办、引用、表格（带边框和表头底色）、加粗、链接。
/// AppKit 自带的 docx 导出会丢表格，所以自己写 XML，再用系统的 /usr/bin/zip 打包。
enum DocxExporter {
    enum ExportError: LocalizedError {
        case zip(String), io(Error)
        var errorDescription: String? {
            switch self {
            case .zip(let s): return "打包 Word 失败：\(s)"
            case .io(let e): return "写入 Word 失败：\(e.localizedDescription)"
            }
        }
    }

    static let accent = "1F4E79"
    static let font = "PingFang SC"
    static let pageWidth = 9638  // A4 宽 11906 减左右边距各 1134（twip）

    static func export(markdown: String, title: String, to url: URL) throws {
        let body = renderBody(markdown)
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("docx-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: tmp.appendingPathComponent("_rels"), withIntermediateDirectories: true)
            try fm.createDirectory(at: tmp.appendingPathComponent("word/_rels"), withIntermediateDirectories: true)
            try fm.createDirectory(at: tmp.appendingPathComponent("docProps"), withIntermediateDirectories: true)
            let files: [String: String] = [
                "[Content_Types].xml": contentTypes,
                "_rels/.rels": rootRels,
                "word/_rels/document.xml.rels": docRels,
                "word/document.xml": document(body),
                "word/styles.xml": styles,
                "word/numbering.xml": numbering,
                "docProps/core.xml": core(title),
            ]
            for (path, xml) in files {
                try xml.write(to: tmp.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: url)
        } catch { throw ExportError.io(error) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = tmp
        p.arguments = ["-X", "-q", "-r", url.path, "[Content_Types].xml", "_rels", "word", "docProps"]
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { throw ExportError.zip(error.localizedDescription) }
        p.waitUntilExit()
        try? fm.removeItem(at: tmp)
        if p.terminationStatus != 0 {
            throw ExportError.zip(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        }
    }

    // MARK: - Markdown → WordprocessingML

    static func renderBody(_ markdown: String) -> String {
        var out: [String] = []
        var tableRows: [String] = []

        func flushTable() {
            guard !tableRows.isEmpty else { return }
            out.append(table(tableRows))
            out.append(paragraph(runs: ""))
            tableRows = []
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { tableRows.append(trimmed); continue }
            flushTable()
            if trimmed.isEmpty || trimmed.hasPrefix("```") { continue }
            let indent = line.prefix { $0 == " " }.count

            if let m = MarkdownHTML.match("^(#{1,4})\\s+(.*)$", trimmed) {
                let style = ["Title", "Heading1", "Heading2", "Heading3"][min(m[0].count, 4) - 1]
                out.append(paragraph(style: style, runs: runs(m[1])))
            } else if MarkdownHTML.match("^(-{3,}|\\*{3,})$", trimmed) != nil {
                out.append("<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BFBFBF\"/></w:pBdr></w:pPr></w:p>")
            } else if let m = MarkdownHTML.match("^>\\s?(.*)$", trimmed) {
                out.append(paragraph(extra: "<w:ind w:left=\"360\"/><w:pBdr><w:left w:val=\"single\" w:sz=\"12\" w:space=\"8\" w:color=\"\(accent)\"/></w:pBdr>",
                                     runs: runs(m[0], color: "595959")))
            } else if let m = MarkdownHTML.match("^[-*]\\s+\\[( |x|X)\\]\\s+(.*)$", trimmed) {
                out.append(paragraph(extra: "<w:ind w:left=\"360\"/>", runs: run(m[0] == " " ? "☐ " : "☑ ") + runs(m[1])))
            } else if let m = MarkdownHTML.match("^([-*]|\\d+[.)])\\s+(.*)$", trimmed) {
                let numbered = m[0].first!.isNumber
                let level = indent >= 2 ? 1 : 0
                let numId = numbered && level == 0 ? 2 : 1
                out.append(paragraph(extra: "<w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numId)\"/></w:numPr>", runs: runs(m[1])))
            } else {
                out.append(paragraph(runs: runs(trimmed)))
            }
        }
        flushTable()
        return out.joined()
    }

    static func paragraph(style: String? = nil, extra: String = "", runs: String) -> String {
        let pPr = (style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? "") + extra
        return "<w:p>" + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>") + runs + "</w:p>"
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func run(_ text: String, bold: Bool = false, color: String? = nil, underline: Bool = false, mono: Bool = false) -> String {
        var rPr = ""
        if mono { rPr += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\"/>" }
        if bold { rPr += "<w:b/>" }
        if let color { rPr += "<w:color w:val=\"\(color)\"/>" }
        if underline { rPr += "<w:u w:val=\"single\"/>" }
        return "<w:r>" + (rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>") + "<w:t xml:space=\"preserve\">\(xmlEscape(text))</w:t></w:r>"
    }

    /// 行内格式：**加粗**、`代码`、链接
    static func runs(_ text: String, bold: Bool = false, color: String? = nil) -> String {
        guard let re = try? NSRegularExpression(pattern: "(\\*\\*[^*]+\\*\\*|`[^`]+`|https?://\\S+)") else { return run(text) }
        var out = ""
        var last = text.startIndex
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            if last < r.lowerBound { out += run(String(text[last..<r.lowerBound]), bold: bold, color: color) }
            let tok = String(text[r])
            if tok.hasPrefix("**") {
                out += run(String(tok.dropFirst(2).dropLast(2)), bold: true, color: color)
            } else if tok.hasPrefix("`") {
                out += run(String(tok.dropFirst().dropLast()), bold: bold, color: color, mono: true)
            } else {
                out += run(tok, bold: bold, color: "0563C1", underline: true)
            }
            last = r.upperBound
        }
        if last < text.endIndex { out += run(String(text[last...]), bold: bold, color: color) }
        return out
    }

    static func table(_ rows: [String]) -> String {
        let cells = rows.map { row -> [String] in
            var r = row
            if r.hasPrefix("|") { r.removeFirst() }
            if r.hasSuffix("|") { r.removeLast() }
            return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let header = cells[0]
        let body = cells.dropFirst().filter { row in !row.allSatisfy { cell in cell.allSatisfy { "-: ".contains($0) } } }
        let n = max(header.count, 1)
        let first = n > 1 ? pageWidth * 26 / 100 : pageWidth
        var widths = [first] + Array(repeating: n > 1 ? (pageWidth - first) / (n - 1) : 0, count: n - 1)
        widths[n - 1] += pageWidth - widths.reduce(0, +)

        let border = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFBF\""
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"\(pageWidth)\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/>"
        xml += "<w:tblBorders><w:top \(border)/><w:left \(border)/><w:bottom \(border)/><w:right \(border)/><w:insideH \(border)/><w:insideV \(border)/></w:tblBorders>"
        xml += "<w:tblCellMar><w:top w:w=\"60\" w:type=\"dxa\"/><w:left w:w=\"100\" w:type=\"dxa\"/><w:bottom w:w=\"60\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr>"
        xml += "<w:tblGrid>" + widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"
        for (r, row) in ([header] + body).enumerated() {
            xml += "<w:tr>" + (r == 0 ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
            for c in 0..<n {
                let shade = r == 0 ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"DCE6F1\"/>" : ""
                xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(widths[c])\" w:type=\"dxa\"/>\(shade)</w:tcPr>"
                xml += paragraph(extra: "<w:spacing w:after=\"0\"/>", runs: runs(c < row.count ? row[c] : "", bold: r == 0)) + "</w:tc>"
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    // MARK: - 固定部件

    static func document(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1200" w:right="1134" w:bottom="1200" w:left="1134" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
    }

    static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
    """

    static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
    """

    static let docRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/></Relationships>
    """

    static func core(_ title: String) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(xmlEscape(title))</dc:title><dc:creator>课程笔记</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created></cp:coreProperties>
        """
    }

    static let styles: String = {
        func heading(_ id: String, _ name: String, size: Int, color: String, before: Int, after: Int, outline: Int?) -> String {
            let ol = outline.map { "<w:outlineLvl w:val=\"\($0)\"/>" } ?? ""
            return "<w:style w:type=\"paragraph\" w:styleId=\"\(id)\"><w:name w:val=\"\(name)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before=\"\(before)\" w:after=\"\(after)\"/>\(ol)</w:pPr><w:rPr><w:b/><w:color w:val=\"\(color)\"/><w:sz w:val=\"\(size)\"/></w:rPr></w:style>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:eastAsia="\(font)" w:cs="\(font)"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US" w:eastAsia="zh-CN"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="80" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\(heading("Title", "Title", size: 40, color: accent, before: 0, after: 240, outline: nil))\(heading("Heading1", "heading 1", size: 30, color: accent, before: 320, after: 140, outline: 0))\(heading("Heading2", "heading 2", size: 26, color: "000000", before: 220, after: 100, outline: 1))\(heading("Heading3", "heading 3", size: 23, color: "000000", before: 160, after: 80, outline: 2))</w:styles>
        """
    }()

    static let numbering = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="360" w:hanging="260"/></w:pPr></w:lvl><w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="◦"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="900" w:hanging="260"/></w:pPr></w:lvl></w:abstractNum><w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="360" w:hanging="360"/></w:pPr></w:lvl><w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="◦"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="900" w:hanging="260"/></w:pPr></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num></w:numbering>
    """
}
