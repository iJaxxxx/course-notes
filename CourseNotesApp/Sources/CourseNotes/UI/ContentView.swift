import SwiftUI

struct ContentView: View {
    @EnvironmentObject var session: RecordingSession
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            if let id = session.selection, let record = session.records.first(where: { $0.id == id }) {
                ClassDetailView(record: record)
                    .id(record.id)
            } else {
                RecorderView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    ImportPanel.run(session)
                } label: {
                    Label("导入录音", systemImage: "square.and.arrow.down")
                }
                .help("导入已有的录音或视频，自动转写并总结")
                .disabled(session.isBusy)

                Button {
                    try? FileManager.default.createDirectory(at: settings.outputURL, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(settings.outputURL)
                } label: {
                    Label("打开课程文件夹", systemImage: "folder")
                }
                .help("在 Finder 中打开保存课程的文件夹")
            }
        }
        .onChange(of: settings.outputDir) { session.refresh() }
    }
}

struct Sidebar: View {
    @EnvironmentObject var session: RecordingSession

    var body: some View {
        List(selection: $session.selection) {
            Button {
                session.selection = nil
            } label: {
                Label {
                    Text(session.isRecording ? "正在录制" : "新录制")
                        .fontWeight(.medium)
                } icon: {
                    Image(systemName: session.isRecording ? "record.circle.fill" : "plus.circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: session.isRecording)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Section("课程") {
                if session.records.isEmpty {
                    Text("录完的课程会出现在这里")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(session.records) { r in
                    RecordRow(record: r, busy: session.busyRecordID == r.id)
                        .tag(r.id)
                        .contextMenu {
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([r.folder]) }
                            Divider()
                            Button("移到废纸篓", role: .destructive) { session.delete(r) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct RecordRow: View {
    let record: ClassRecord
    let busy: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.hasSummary ? "doc.text.fill" : "waveform")
                .foregroundStyle(record.hasSummary ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).lineLimit(1)
                Text(record.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 2)
    }
}
