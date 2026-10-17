import SwiftUI
import UniformTypeIdentifiers

enum ImportPanel {
    @MainActor
    static func run(_ session: RecordingSession) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .mpeg4Movie, .mp3, .wav]
        panel.allowsMultipleSelection = false
        panel.message = "选择一段课程录音或视频，自动转写并生成总结"
        panel.prompt = "导入"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await session.importFile(url) }
        }
    }
}
