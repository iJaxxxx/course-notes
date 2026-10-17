import AVFoundation
import CoreGraphics
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case needsScreenPermission, needsMicPermission, noDisplay, failed(String)

    var errorDescription: String? {
        switch self {
        case .needsScreenPermission:
            return "需要「屏幕与系统录音」权限才能录制电脑声音。请在系统设置里打开「课程笔记」，然后退出并重新打开本 App。"
        case .needsMicPermission:
            return "需要麦克风权限。请在系统设置 → 隐私与安全性 → 麦克风里打开「课程笔记」。"
        case .noDisplay: return "没有找到可录制的显示器"
        case .failed(let s): return s
        }
    }

    var settingsURL: URL? {
        switch self {
        case .needsScreenPermission: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .needsMicPermission: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        default: return nil
        }
    }
}

protocol CaptureSource: AnyObject {
    /// handler 在后台串行队列上回调
    func start(handler: @escaping (AVAudioPCMBuffer) -> Void) async throws
    func stop() async
}

/// 电脑声音：ScreenCaptureKit 只取音频（不需要 BlackHole），排除本 App 自己的声音
final class SystemAudioSource: NSObject, CaptureSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var handler: ((AVAudioPCMBuffer) -> Void)?
    private let queue = DispatchQueue(label: "capture.system.audio")
    private let videoQueue = DispatchQueue(label: "capture.system.video")

    func start(handler: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw CaptureError.needsScreenPermission
        }
        self.handler = handler
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.needsScreenPermission
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.width = 2
        cfg.height = 2  // 只要声音，画面取最小
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        do { try await s.startCapture() } catch {
            let ns = error as NSError
            if ns.code == -3801 { throw CaptureError.needsScreenPermission }
            throw CaptureError.failed("开始录制失败：\(error.localizedDescription)")
        }
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        queue.sync {}
        handler = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let desc = sb.formatDescription,
              var asbd = desc.audioStreamBasicDescription,
              let fmt = AVAudioFormat(streamDescription: &asbd) else { return }
        let n = AVAudioFrameCount(sb.numSamples)
        guard n > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
        pcm.frameLength = n
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: pcm.mutableAudioBufferList) == noErr else { return }
        handler?(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("系统声音录制中断：\(error)")
    }
}

/// 麦克风（没有屏幕录制权限，或想录现场课时用）
final class MicrophoneSource: CaptureSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "capture.mic")

    func start(handler: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CaptureError.needsMicPermission }
        default: throw CaptureError.needsMicPermission
        }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [queue] buf, _ in
            // tap 回调的 buffer 会被复用，拷一份再交给后台队列
            guard let copy = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength) else { return }
            copy.frameLength = buf.frameLength
            let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buf.audioBufferList))
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (s, d) in zip(src, dst) {
                if let sp = s.mData, let dp = d.mData { memcpy(dp, sp, Int(min(s.mDataByteSize, d.mDataByteSize))) }
            }
            queue.async { handler(copy) }
        }
        do { try engine.start() } catch { throw CaptureError.failed("麦克风启动失败：\(error.localizedDescription)") }
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync {}
    }
}
