import AVKit
import SwiftUI
import WebKit

struct ClassDetailView: View {
    @EnvironmentObject var session: RecordingSession
    @EnvironmentObject var settings: AppSettings
    let record: ClassRecord
    @State private var tab = 0
    @State private var player: AVPlayer?

    private var busy: Bool { session.busyRecordID == record.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let player {
                AudioBar(player: player)
                Divider()
            }
            content
        }
        .navigationTitle(record.title)
        .onAppear {
            tab = record.hasSummary ? 0 : 1
            if let a = record.audioURL { player = AVPlayer(url: a) }
        }
        .onDisappear { player?.pause() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).font(.title2.weight(.semibold)).lineLimit(1)
                Text(record.date, format: .dateTime.year().month().day().hour().minute())
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $tab) {
                Text("总结").tag(0)
                Text("转写稿").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            if let docx = record.docxURL {
                Button {
                    NSWorkspace.shared.open(docx)
                } label: {
                    Label("打开 Word", systemImage: "doc.richtext")
                }
            }
            Button {
                Task { await session.summarize(record) }
            } label: {
                if busy { ProgressView().controlSize(.small) } else {
                    Label(record.hasSummary ? "重新生成" : "生成总结", systemImage: "sparkles")
                }
            }
            .disabled(session.isBusy || busy)
            .help("用当前选择的模型（\(settings.selectedProfile?.name ?? "未选择")）生成总结")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([record.folder])
            } label: {
                Image(systemName: "folder")
            }
            .help("在 Finder 中显示")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var content: some View {
        if tab == 0 {
            if let md = record.summary {
                HTMLView(html: Self.page(MarkdownHTML.render(md)))
            } else {
                ContentUnavailableView {
                    Label("还没有总结", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(session.notice ?? "录音和转写已保存。选择好模型后点「生成总结」。")
                } actions: {
                    Button("生成总结") { Task { await session.summarize(record) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isBusy || busy)
                }
            }
        } else {
            ScrollView {
                Text(ClassStore.transcriptBody(record.transcriptURL).isEmpty ? "（没有转写内容）"
                     : ClassStore.transcriptBody(record.transcriptURL))
                    .textSelection(.enabled)
                    .font(.body)
                    .lineSpacing(5)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 应用内预览用的样式：跟随系统深浅色
    static func page(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; --accent: #0A66C2; --line: rgba(128,128,128,.28); --head: rgba(10,102,194,.10); }
        @media (prefers-color-scheme: dark) { :root { --accent: #5AA9FF; --head: rgba(90,169,255,.14); } }
        body { font: 14px/1.65 -apple-system, "PingFang SC", sans-serif; max-width: 780px; margin: 28px auto; padding: 0 28px; }
        h1 { font-size: 24px; margin: 0 0 14px; }
        h2 { font-size: 18px; margin: 28px 0 10px; color: var(--accent); }
        h3 { font-size: 15px; margin: 18px 0 6px; }
        ul, ol { padding-left: 22px; } li { margin: 3px 0; }
        table { border-collapse: collapse; width: 100%; margin: 8px 0 14px; font-size: 13px; }
        th, td { border: 1px solid var(--line); padding: 7px 10px; text-align: left; vertical-align: top; }
        th { background: var(--head); }
        td:first-child { white-space: nowrap; }
        blockquote { margin: 8px 0; padding-left: 12px; border-left: 3px solid var(--accent); opacity: .8; }
        code { font: 12px Menlo, monospace; }
        a { color: var(--accent); }
        p.todo { margin: 4px 0 4px 4px; }
        </style></head><body>\(body)</body></html>
        """
    }
}

struct AudioBar: View {
    let player: AVPlayer
    @State private var playing = false
    @State private var time: Double = 0
    @State private var duration: Double = 1
    @State private var observer: Any?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                playing ? player.pause() : player.play()
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .buttonStyle(.borderless)
            Text(Clock.short(time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { time }, set: { v in
                time = v
                player.seek(to: CMTime(seconds: v, preferredTimescale: 600))
            }), in: 0...max(duration, 1))
            Text(Clock.short(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Label("录音", systemImage: "waveform").labelStyle(.iconOnly).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .task {
            if let d = try? await player.currentItem?.asset.load(.duration) { duration = max(d.seconds, 1) }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { t in
                time = t.seconds
                if time >= duration - 0.2 { playing = false }
            }
        }
        .onDisappear { if let observer { player.removeTimeObserver(observer) } }
    }
}

struct HTMLView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.setValue(false, forKey: "drawsBackground")
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {
        v.loadHTMLString(html, baseURL: nil)
    }
}
