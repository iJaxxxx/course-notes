import AppKit
import AVFoundation
import UserNotifications

/// 一次录制的完整流程：准备 → 录制（实时转写 + 下课检测）→ 收尾（写转写稿）→ 大模型总结 → 导出 Word
@MainActor
final class RecordingSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case recording
        case finishing(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0
    @Published var lines: [TranscriptLine] = []
    @Published var volatileText = ""
    @Published var endCountdown: Double?  // 听到结束语后，距离自动结束还有几秒
    @Published var endKeyword: String?
    @Published var notice: String?
    @Published var captureError: CaptureError?
    @Published var records: [ClassRecord] = []
    @Published var selection: ClassRecord.ID?
    @Published var busyRecordID: ClassRecord.ID?

    let settings = AppSettings.shared
    private var source: CaptureSource?
    private var transcriber: StreamingTranscriber?
    private var pipeline: AudioPipeline?
    private var detector: EndDetector?
    private var ticker: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var folder: URL?
    private var title = ""
    private var startedAt = Date()
    private var lastLevelUpdate = Date.distantPast

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool {
        switch phase {
        case .preparing, .recording, .finishing: return true
        default: return false
        }
    }

    init() {
        refresh()
        if Bundle.main.bundleIdentifier != nil {  // 通知只在打包成 .app 时可用
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func refresh() {
        records = ClassStore.list(root: settings.outputURL)
    }

    // MARK: - 开始

    func start(title rawTitle: String) async {
        guard !isBusy else { return }
        title = rawTitle.trimmingCharacters(in: .whitespaces).isEmpty ? "网课" : rawTitle.trimmingCharacters(in: .whitespaces)
        lines = []; volatileText = ""; elapsed = 0; level = 0
        endCountdown = nil; endKeyword = nil; notice = nil; captureError = nil
        selection = nil

        phase = .preparing("正在准备语音识别…")
        do {
            try await StreamingTranscriber.ensureModel { p in
                Task { @MainActor in self.phase = .preparing("首次使用，正在下载系统中文语音模型 \(Int(p * 100))%") }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        do {
            let folder = try ClassStore.newFolder(root: settings.outputURL, title: title)
            self.folder = folder
            let t = try await StreamingTranscriber.start(
                glossary: settings.glossaryTerms,
                onFinal: { line in Task { @MainActor in self.handleFinal(line) } },
                onVolatile: { text in Task { @MainActor in self.volatileText = text } })
            transcriber = t
            let p = AudioPipeline(fileURL: folder.appendingPathComponent("录音.m4a"), transcriber: t)
            p.onLevel = { lv in Task { @MainActor in self.updateLevel(lv) } }
            pipeline = p

            let src: CaptureSource = settings.source == .system ? SystemAudioSource() : MicrophoneSource()
            phase = .preparing(settings.source == .system ? "正在连接电脑声音…" : "正在打开麦克风…")
            try await src.start { buf in p.process(buf) }
            source = src
        } catch {
            await transcriber?.finish()
            transcriber = nil; pipeline = nil
            if let folder { try? FileManager.default.removeItem(at: folder) }
            folder = nil
            captureError = error as? CaptureError
            phase = .failed(error.localizedDescription)
            return
        }

        detector = EndDetector(graceSec: settings.graceSec, cancelChars: settings.cancelChars, silenceMin: settings.silenceMin)
        startedAt = Date()
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "正在录制课程")
        phase = .recording
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    private func updateLevel(_ lv: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelUpdate) > 0.08 else { return }
        lastLevelUpdate = now
        level = level * 0.4 + lv * 0.6
    }

    private func handleFinal(_ line: TranscriptLine) {
        guard phase != .idle else { return }
        lines.append(line)
        guard settings.autoStop, var d = detector else { return }
        switch d.feed(line.text) {
        case .triggered(let k):
            endKeyword = k
            notice = nil
        case .cancelled:
            endKeyword = nil
            endCountdown = nil
            notice = "结束语之后老师还在讲，已继续录制"
        case .none: break
        }
        detector = d
    }

    private func tick() {
        guard phase == .recording else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        guard settings.autoStop, let d = detector else { return }
        endCountdown = d.remaining()
        if let reason = d.shouldStop() {
            switch reason {
            case .keyword(let k): notice = "听到「\(k)」，已自动结束"
            case .silence: notice = "已经 \(Int(settings.silenceMin)) 分钟没人讲话，已自动结束"
            }
            Task { await stop() }
        }
    }

    /// 听到结束语后，用户点「继续录制」
    func keepRecording() {
        detector?.dismiss()
        endKeyword = nil
        endCountdown = nil
    }

    // MARK: - 结束

    func stop() async {
        guard phase == .recording, let folder else { return }
        phase = .finishing("正在整理录音和转写…")
        ticker?.cancel()
        await source?.stop()
        await transcriber?.finish()
        try? await Task.sleep(for: .milliseconds(300))  // 让最后几句转写结果回到主线程
        let audioProblem: String? = {
            guard let p = pipeline else { return nil }
            if let e = p.writeError { return "录音文件写入出错（\(e.localizedDescription)），转写稿已保存" }
            if p.framesWritten == 0 { return "这次没有录到任何声音：请检查录制来源和权限，转写稿已保存" }
            return nil
        }()
        pipeline?.close()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        source = nil; transcriber = nil; pipeline = nil
        endCountdown = nil
        volatileText = ""
        level = 0

        let record = ClassRecord(folder: folder)
        do {
            try ClassStore.writeTranscript(lines, title: title, start: startedAt, to: record.transcriptURL)
        } catch {
            phase = .failed("保存转写失败：\(error.localizedDescription)")
            return
        }
        self.folder = nil
        refresh()
        await summarize(record, title: title, startedAt: startedAt, duration: elapsed)
        if let audioProblem { notice = audioProblem + (notice.map { "；" + $0 } ?? "") }
    }

    // MARK: - 总结

    func summarize(_ record: ClassRecord, title: String? = nil, startedAt: Date? = nil, duration: TimeInterval? = nil) async {
        let title = title ?? record.title
        let transcript = ClassStore.transcriptBody(record.transcriptURL)
        busyRecordID = record.id
        defer { busyRecordID = nil }

        guard !transcript.isEmpty else {
            finish(record, error: "没有转写到内容（可能没有声音），录音已保存")
            return
        }
        guard let profile = settings.selectedProfile else {
            finish(record, error: "还没有选择总结模型，录音和转写已保存。设置好模型后点「生成总结」")
            return
        }
        phase = .finishing("正在用 \(profile.name) 生成课程总结…")
        do {
            let client = try LLMClient(profile: profile)
            let lastTime = transcript.components(separatedBy: "\n").last { $0.hasPrefix("[") }
                .flatMap { line -> TimeInterval? in
                    let p = line.dropFirst().prefix(8).split(separator: ":").compactMap { Double($0) }
                    return p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : nil
                } ?? 0
            let prompt = Prompts.final(title: title, startedAt: startedAt ?? record.date,
                                       duration: duration ?? lastTime, transcript: transcript)
            var md = try await client.complete(system: Prompts.system(glossary: settings.glossaryTerms),
                                               prompt: prompt, maxTokens: 8000)
            md = md.replacingOccurrences(of: "^```(markdown)?\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
            try md.write(to: record.summaryURL, atomically: true, encoding: .utf8)

            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            if let old = record.docxURL { try? FileManager.default.removeItem(at: old) }
            let docx = record.folder.appendingPathComponent("\(f.string(from: startedAt ?? record.date))_\(ClassStore.safeName(title))_课程总结.docx")
            try DocxExporter.export(markdown: md, title: title, to: docx)
            finish(record, error: nil)
        } catch {
            finish(record, error: "总结没有生成：\(error.localizedDescription)。录音和转写已保存，可以稍后点「生成总结」重试")
        }
    }

    private func finish(_ record: ClassRecord, error: String?) {
        refresh()
        selection = record.id
        phase = .idle
        if let error { notice = error }
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = error == nil ? "课程总结已生成" : "录音已保存"
        content.body = error == nil ? "\(record.title)：录音、转写和 Word 总结都在课程文件夹里" : error!
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - 导入已有录音

    func importFile(_ url: URL) async {
        guard !isBusy else { return }
        let title = url.deletingPathExtension().lastPathComponent
        notice = nil
        phase = .preparing("正在准备语音识别…")
        do {
            try await StreamingTranscriber.ensureModel { p in
                Task { @MainActor in self.phase = .preparing("首次使用，正在下载系统中文语音模型 \(Int(p * 100))%") }
            }
            let folder = try ClassStore.newFolder(root: settings.outputURL, title: title)
            let dest = folder.appendingPathComponent("录音.\(url.pathExtension.lowercased())")
            try FileManager.default.copyItem(at: url, to: dest)
            phase = .finishing("正在转写「\(title)」…")
            let lines = try await StreamingTranscriber.transcribeFile(dest, glossary: settings.glossaryTerms)
            let record = ClassRecord(folder: folder)
            try ClassStore.writeTranscript(lines, title: title, start: Date(), to: record.transcriptURL)
            refresh()
            await summarize(record, title: title, startedAt: Date(), duration: lines.last?.time ?? 0)
        } catch {
            phase = .failed("导入失败：\(error.localizedDescription)")
        }
    }

    func delete(_ record: ClassRecord) {
        try? FileManager.default.trashItem(at: record.folder, resultingItemURL: nil)
        if selection == record.id { selection = nil }
        refresh()
    }
}
