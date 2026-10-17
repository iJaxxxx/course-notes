import Foundation

/// 把课程总结用到的 Markdown 子集转成 HTML：标题、段落、列表（两级）、待办、引用、表格、加粗、代码、链接、分隔线。
enum MarkdownHTML {
    /// 整行匹配，返回各捕获组（没匹配返回 nil）
    static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<max(m.numberOfRanges, 1)).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }

    static func replace(_ pattern: String, in s: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    static func render(_ markdown: String) -> String {
        var html: [String] = []
        var listStack: [String] = []  // "ul" / "ol"，按缩进层级
        var tableRows: [String] = []

        func closeLists(to depth: Int = 0) {
            while listStack.count > depth { html.append("</li></\(listStack.removeLast())>") }
        }
        func flushTable() {
            guard !tableRows.isEmpty else { return }
            let rows = tableRows.map { row -> [String] in
                var r = row.trimmingCharacters(in: .whitespaces)
                if r.hasPrefix("|") { r.removeFirst() }
                if r.hasSuffix("|") { r.removeLast() }
                return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            let body = rows.dropFirst().filter { row in !row.allSatisfy { cell in cell.allSatisfy { "-: ".contains($0) } } }
            var t = "<table><thead><tr>" + rows[0].map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
            for r in body { t += "<tr>" + r.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }
            html.append(t + "</tbody></table>")
            tableRows = []
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") {
                closeLists()
                tableRows.append(trimmed)
                continue
            }
            flushTable()
            if trimmed.isEmpty || trimmed.hasPrefix("```") { continue }  // 模型偶尔包代码块，丢掉围栏

            let indent = line.prefix { $0 == " " }.count
            if let m = match("^(#{1,4})\\s+(.*)$", trimmed) {
                closeLists()
                let level = m[0].count
                html.append("<h\(level)>\(inline(m[1]))</h\(level)>")
            } else if match("^(-{3,}|\\*{3,})$", trimmed) != nil {
                closeLists()
                html.append("<hr>")
            } else if let m = match("^>\\s?(.*)$", trimmed) {
                closeLists()
                html.append("<blockquote>\(inline(m[0]))</blockquote>")
            } else if let m = match("^[-*]\\s+\\[( |x|X)\\]\\s+(.*)$", trimmed) {
                closeLists()
                html.append("<p class=\"todo\">\(m[0] == " " ? "☐" : "☑") \(inline(m[1]))</p>")
            } else if let m = match("^([-*]|\\d+[.)])\\s+(.*)$", trimmed) {
                let tag = m[0].first!.isNumber ? "ol" : "ul"
                let depth = indent >= 2 ? 2 : 1
                if listStack.count < depth {
                    while listStack.count < depth { html.append("<\(tag)><li>"); listStack.append(tag) }
                } else {
                    closeLists(to: depth)
                    if listStack.last != tag {
                        html.append("</li></\(listStack.removeLast())><\(tag)><li>")
                        listStack.append(tag)
                    } else {
                        html.append("</li><li>")
                    }
                }
                html.append(inline(m[1]))
            } else {
                closeLists()
                html.append("<p>\(inline(trimmed))</p>")
            }
        }
        flushTable()
        closeLists()
        return html.joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ s: String) -> String {
        var out = escape(s)
        out = replace("\\*\\*([^*]+)\\*\\*", in: out, with: "<b>$1</b>")
        out = replace("`([^`]+)`", in: out, with: "<code>$1</code>")
        out = replace("(https?://[^\\s<]+)", in: out, with: "<a href=\"$1\">$1</a>")
        return out
    }

    /// 用于 Word 导出的完整 HTML（AppKit 的 HTML 解析只认一部分 CSS，样式尽量简单）
    static func document(_ markdown: String, title: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body { font-family: 'PingFang SC', 'Helvetica Neue'; font-size: 11pt; line-height: 1.45; color: #1d1d1f; }
        h1 { font-size: 20pt; color: #1F4E79; margin: 0 0 10pt 0; }
        h2 { font-size: 15pt; color: #1F4E79; margin: 16pt 0 6pt 0; }
        h3 { font-size: 12.5pt; margin: 12pt 0 4pt 0; }
        p, li { font-size: 11pt; margin: 2pt 0; }
        table { border-collapse: collapse; width: 100%; margin: 6pt 0 10pt 0; }
        th, td { border: 1px solid #BFBFBF; padding: 4pt 6pt; vertical-align: top; font-size: 10.5pt; }
        th { background-color: #DCE6F1; text-align: left; }
        blockquote { color: #595959; margin-left: 12pt; }
        code { font-family: Menlo; }
        </style></head><body>
        \(render(markdown))
        </body></html>
        """
    }
}
