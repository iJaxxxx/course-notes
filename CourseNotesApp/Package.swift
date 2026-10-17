// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CourseNotes",
    platforms: [.macOS("26.0")],  // SpeechTranscriber（系统自带的长语音转写）从 macOS 26 开始提供
    targets: [
        .executableTarget(
            name: "CourseNotes",
            path: "Sources/CourseNotes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
