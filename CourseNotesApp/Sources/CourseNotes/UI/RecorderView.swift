import SwiftUI

struct RecorderView: View {
    @EnvironmentObject var session: RecordingSession

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                RecorderPanel()
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 32)
                    .padding(.top, 36)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: session.isRecording || !session.lines.isEmpty ? 430 : .infinity)

            if session.isRecording || !session.lines.isEmpty {
                LiveTranscript()
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(.background)
        .navigationTitle(session.isRecording ? "正在录制" : "新录制")
    }
}

/// 课程名 + 录制设置 + 录制按钮 + 提示条
struct RecorderPanel: View {
    @EnvironmentObject var session: RecordingSession
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 28) {
            header
            if !session.isBusy { setupCards }
            recordControl
            banners
        }
        .onAppear { titleFocused = !session.isBusy }
    }

    // MARK: 课程名

    private var header: some View {
        VStack(spacing: 6) {
            TextField("课程名称", text: $title, prompt: Text("给这节课起个名字"))
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .semibold))
                .multilineTextAlignment(.center)
                .focused($titleFocused)
                .disabled(session.isBusy)
                .onSubmit { startIfPossible() }
            Text(session.isRecording ? "录音期间 Mac 不会休眠，锁屏也会继续录" : "开始后自动转写，听到「下课」「拜拜」等会自动结束并生成总结")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 录制设置

    private var setupCards: some View {
        VStack(spacing: 12) {
            SettingCard(symbol: settings.source.symbol, tint: .blue, title: "录制来源", detail: settings.source.detail) {
                Picker("", selection: $settings.source) {
                    ForEach(AudioSource.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            SettingCard(symbol: "sparkles", tint: .purple, title: "总结模型", detail: modelDetail) {
                HStack(spacing: 8) {
                    Picker("", selection: $settings.selectedProfileID) {
                        ForEach(settings.profiles) { p in
                            Text(p.name + (settings.isReady(p) ? "" : "（未配置）")).tag(Optional(p.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    Button("设置…") { openSettings() }
                }
            }
        }
    }

    private var modelDetail: String {
        guard let p = settings.selectedProfile else { return "选择一个模型用来写课后总结" }
        if settings.isReady(p) { return "\(p.model) · API Key 已保存在钥匙串" }
        if p.model.isEmpty { return "还没填模型名，点「设置…」补上" }
        return "还没填 API Key，点「设置…」粘贴（没有也能先录，之后再生成总结）"
    }

    // MARK: 录制按钮

    private var recordControl: some View {
        VStack(spacing: 14) {
            switch session.phase {
            case .preparing(let msg), .finishing(let msg):
                ProgressView().controlSize(.large).frame(height: 84)
                Text(msg).font(.headline).foregroundStyle(.secondary)
            default:
                RecordButton(recording: session.isRecording) {
                    if session.isRecording { Task { await session.stop() } } else { startIfPossible() }
                }
                if session.isRecording {
                    Text(Clock.short(session.elapsed))
                        .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    LevelMeter(level: session.level)
                        .frame(width: 220, height: 22)
                } else {
                    Text("开始录制").font(.headline)
                    Text("⌘O 也可以导入已有录音").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .animation(.smooth, value: session.isRecording)
    }

    private func startIfPossible() {
        guard !session.isBusy else { return }
        titleFocused = false
        Task { await session.start(title: title) }
    }

    // MARK: 提示条

    @ViewBuilder private var banners: some View {
        if let k = session.endKeyword, session.isRecording {
            Banner(symbol: "bell.badge.fill", tint: .orange,
                   text: "听到「\(k)」，\(Clock.short(session.endCountdown ?? 0)) 后自动结束并生成总结") {
                Button("继续录制") { session.keepRecording() }
                Button("立即结束") { Task { await session.stop() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
        if case .failed(let msg) = session.phase {
            Banner(symbol: "exclamationmark.triangle.fill", tint: .red, text: msg) {
                if let url = session.captureError?.settingsURL {
                    Button("打开系统设置") { NSWorkspace.shared.open(url) }
                }
            }
        }
        if let n = session.notice, !session.isBusy || session.isRecording {
            Banner(symbol: "info.circle.fill", tint: .blue, text: n) { EmptyView() }
        }
    }
}

// MARK: - 组件

struct RecordButton: View {
    let recording: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.quaternary, lineWidth: 4)
                    .frame(width: 84, height: 84)
                RoundedRectangle(cornerRadius: recording ? 8 : 34, style: .continuous)
                    .fill(.red.gradient)
                    .frame(width: recording ? 32 : 68, height: recording ? 32 : 68)
                    .shadow(color: .red.opacity(hover ? 0.45 : 0.25), radius: hover ? 12 : 6, y: 2)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .keyboardShortcut("r", modifiers: .command)
        .help(recording ? "结束录制（⌘R）" : "开始录制（⌘R）")
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: recording)
    }
}

struct LevelMeter: View {
    let level: Float
    private let bars = 24

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                let on = Float(i) / Float(bars) < level
                Capsule()
                    .fill(on ? (i > bars * 3 / 4 ? Color.orange : Color.green) : Color.secondary.opacity(0.18))
                    .frame(width: 5)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityLabel("音量")
    }
}

struct SettingCard<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

struct LiveTranscript: View {
    @EnvironmentObject var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("实时转写", systemImage: "text.bubble")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(session.lines.count) 段").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(session.lines) { l in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(Clock.short(l.time))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                                Text(l.text).textSelection(.enabled)
                            }
                        }
                        if !session.volatileText.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("…").frame(width: 44, alignment: .trailing).foregroundStyle(.tertiary)
                                Text(session.volatileText).foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: session.lines.count) { withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: session.volatileText) { proxy.scrollTo("bottom") }
            }
            if session.lines.isEmpty && session.volatileText.isEmpty && session.isRecording {
                Text("等待声音… 开始播放课程后，文字会出现在这里")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 20)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
