import AVFoundation

/// 采集到的每块音频：写进 m4a 录音文件 + 转换格式喂给转写 + 计算音量
final class AudioPipeline: @unchecked Sendable {
    private let fileURL: URL
    private let transcriber: StreamingTranscriber
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let lock = NSLock()
    private(set) var writeError: Error?
    private(set) var seconds: Double = 0
    private(set) var framesWritten: AVAudioFramePosition = 0
    var onLevel: (@Sendable (Float) -> Void)?

    init(fileURL: URL, transcriber: StreamingTranscriber) {
        self.fileURL = fileURL
        self.transcriber = transcriber
    }

    func process(_ pcm: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        let fmt = pcm.format
        if sourceFormat == nil || sourceFormat != fmt {
            sourceFormat = fmt
            converter = AVAudioConverter(from: fmt, to: transcriber.format)
            if file == nil {
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                               AVSampleRateKey: fmt.sampleRate,
                                               AVNumberOfChannelsKey: min(fmt.channelCount, 2),
                                               AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
                do {
                    file = try AVAudioFile(forWriting: fileURL, settings: settings,
                                           commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
                } catch { writeError = error }
            }
        }
        if let file, file.processingFormat == fmt {
            do { try file.write(from: pcm); framesWritten += AVAudioFramePosition(pcm.frameLength) } catch { writeError = error }
        }
        seconds += Double(pcm.frameLength) / fmt.sampleRate

        // 音量（0…1，用来画电平条）
        if let ch = pcm.floatChannelData, pcm.frameLength > 0 {
            var sum: Float = 0
            let n = Int(pcm.frameLength)
            for i in 0..<n { sum += ch[0][i] * ch[0][i] }
            let rms = sqrt(sum / Float(n))
            let db = 20 * log10(max(rms, 1e-6))
            onLevel?(max(0, min(1, (db + 55) / 50)))
        }

        guard let converter else { return }
        let cap = AVAudioFrameCount(Double(pcm.frameLength) * transcriber.format.sampleRate / fmt.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: transcriber.format, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return pcm
        }
        if err == nil, out.frameLength > 0 { transcriber.append(out) }
    }

    /// 关闭录音文件（AVAudioFile 释放时写完 m4a 尾部）
    func close() {
        lock.lock(); defer { lock.unlock() }
        file = nil
    }
}
