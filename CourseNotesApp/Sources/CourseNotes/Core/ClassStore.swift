import Foundation

/// 一节课的文件夹：录音.m4a、transcript.md、summary.md、课程总结.docx
struct ClassRecord: Identifiable, Hashable {
    let folder: URL
    var id: String { folder.path }

    var title: String {
        let name = folder.lastPathComponent
        // 文件夹名：2026-10-17_1455_课程名
        let parts = name.split(separator: "_", maxSplits: 2)
        return parts.count == 3 ? String(parts[2]).replacingOccurrences(of: "_", with: " ") : name
    }

    var date: Date {
        (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    var audioURL: URL? { existing(["录音.m4a", "recording.m4a"]) ?? firstAudio }
    var transcriptURL: URL { folder.appendingPathComponent("transcript.md") }
    var summaryURL: URL { folder.appendingPathComponent("summary.md") }
    var docxURL: URL? {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "docx" }
    }
    var hasSummary: Bool { FileManager.default.fileExists(atPath: summaryURL.path) }
    var summary: String? { try? String(contentsOf: summaryURL, encoding: .utf8) }

    private func existing(_ names: [String]) -> URL? {
        names.map { folder.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var firstAudio: URL? {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first { ["m4a", "mp3", "wav", "aac", "mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
    }
}

enum ClassStore {
    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.whitespacesAndNewlines)
        let out = s.components(separatedBy: bad).filter { !$0.isEmpty }.joined(separator: "_")
        return out.isEmpty ? "网课" : String(out.prefix(60))
    }

    static func newFolder(root: URL, title: String, date: Date = Date()) throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        var url = root.appendingPathComponent("\(f.string(from: date))_\(safeName(title))")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(f.string(from: date))_\(safeName(title))_\(i)")
            i += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func list(root: URL) -> [ClassRecord] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey]) else { return [] }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("transcript.md").path) }
            .map(ClassRecord.init)
            .sorted { $0.folder.lastPathComponent > $1.folder.lastPathComponent }
    }

    static func writeTranscript(_ lines: [TranscriptLine], title: String, start: Date, to url: URL) throws {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var s = "# \(title)\n\n开始时间：\(f.string(from: start))\n\n"
        for l in lines { s += "[\(Clock.hms(l.time))] \(l.text)\n\n" }
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 读回 transcript.md 里的正文（去掉文件头），给大模型用
    static func transcriptBody(_ url: URL) -> String {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s.components(separatedBy: "\n").dropFirst(3).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
