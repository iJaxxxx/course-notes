import AVFoundation
import Speech

struct TranscriptLine: Identifiable, Hashable {
    let id = UUID()
    let time: TimeInterval  // 从开始录制算起的秒数
    let text: String
}

enum TranscriberError: LocalizedError {
    case unsupported, noFormat
    var errorDescription: String? {
        switch self {
        case .unsupported: return "这台 Mac 不支持系统中文语音识别（需要 macOS 26 和 Apple 芯片）"
        case .noFormat: return "语音识别初始化失败"
        }
    }
}

/// 系统自带的离线长语音转写（SpeechAnalyzer + SpeechTranscriber），不需要下载第三方模型
final class StreamingTranscriber: @unchecked Sendable {
    static let locale = Locale(identifier: "zh_CN")

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let cont: AsyncStream<AnalyzerInput>.Continuation
    private let input: AsyncStream<AnalyzerInput>
    private var results: Task<Void, Error>?
    let format: AVAudioFormat

    private init(transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.format = format
        (input, cont) = AsyncStream<AnalyzerInput>.makeStream()
    }

    static func makeModule(volatile: Bool) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: volatile ? [.volatileResults] : [],
                          attributeOptions: [.audioTimeRange])
    }

    /// 首次使用时系统会下载中文语音模型（由 macOS 管理，几百 MB，只需一次）
    static func ensureModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unsupported }
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier == locale.identifier }) else { throw TranscriberError.unsupported }
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [makeModule(volatile: false)]) {
            let p = req.progress
            let obs = p.observe(\.fractionCompleted) { pr, _ in progress(pr.fractionCompleted) }
            try await req.downloadAndInstall()
            obs.invalidate()
        }
    }

    static func context(_ glossary: [String]) -> AnalysisContext {
        let ctx = AnalysisContext()
        if !glossary.isEmpty { ctx.contextualStrings = [.general: glossary] }
        return ctx
    }

    static func start(glossary: [String],
                      onFinal: @escaping @Sendable (TranscriptLine) -> Void,
                      onVolatile: @escaping @Sendable (String) -> Void) async throws -> StreamingTranscriber {
        let module = makeModule(volatile: true)
        let analyzer = SpeechAnalyzer(modules: [module])
        try? await analyzer.setContext(context(glossary))
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { throw TranscriberError.noFormat }
        let t = StreamingTranscriber(transcriber: module, analyzer: analyzer, format: fmt)
        t.results = Task {
            for try await r in module.results {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if r.isFinal {
                    onVolatile("")
                    if !text.isEmpty { onFinal(TranscriptLine(time: r.range.start.seconds, text: text)) }
                } else {
                    onVolatile(text)
                }
            }
        }
        try await analyzer.start(inputSequence: t.input)
        return t
    }

    /// 已转换成 format 的音频
    func append(_ buffer: AVAudioPCMBuffer) {
        cont.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async {
        cont.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = try? await results?.value
    }

    /// 导入的录音文件：整段转写（比实时快很多，10 分钟音频几秒钟）
    static func transcribeFile(_ url: URL, glossary: [String]) async throws -> [TranscriptLine] {
        let module = makeModule(volatile: false)
        let analyzer = SpeechAnalyzer(modules: [module])
        try? await analyzer.setContext(context(glossary))
        let file = try AVAudioFile(forReading: url)
        let collector = Task { () -> [TranscriptLine] in
            var lines: [TranscriptLine] = []
            for try await r in module.results {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(TranscriptLine(time: r.range.start.seconds, text: text)) }
            }
            return lines
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}
