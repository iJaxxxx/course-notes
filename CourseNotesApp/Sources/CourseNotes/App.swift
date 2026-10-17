import SwiftUI

@main
struct CourseNotesApp: App {
    @StateObject private var session = RecordingSession()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup("课程笔记") {
            ContentView()
                .environmentObject(session)
                .environmentObject(settings)
                .frame(minWidth: 860, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入录音…") { ImportPanel.run(session) }
                    .keyboardShortcut("o")
                    .disabled(session.isBusy)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
