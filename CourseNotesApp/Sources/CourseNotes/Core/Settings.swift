import Foundation
import SwiftUI

enum Provider: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "openai_compatible"
    case anthropic

    var id: String { rawValue }
    var label: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容接口"
        case .anthropic: return "Anthropic Claude"
        }
    }
}

/// 一个可选的总结模型。API Key 不在这里，存在钥匙串里（按 id 区分）。
struct LLMProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var provider: Provider
    var baseURL: String
    var model: String
    var keyURL: String = ""  // 去哪申请 key，仅用于提示

    static let presets: [LLMProfile] = [
        LLMProfile(name: "DeepSeek", provider: .openAICompatible, baseURL: "https://api.deepseek.com",
                   model: "deepseek-flash", keyURL: "https://platform.deepseek.com"),
        LLMProfile(name: "通义千问", provider: .openAICompatible, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                   model: "qwen-plus", keyURL: "https://bailian.console.aliyun.com"),
        LLMProfile(name: "智谱 GLM", provider: .openAICompatible, baseURL: "https://open.bigmodel.cn/api/paas/v4",
                   model: "", keyURL: "https://open.bigmodel.cn"),
        LLMProfile(name: "豆包", provider: .openAICompatible, baseURL: "https://ark.cn-beijing.volces.com/api/v3",
                   model: "", keyURL: "https://console.volcengine.com/ark"),
        LLMProfile(name: "Kimi", provider: .openAICompatible, baseURL: "https://api.moonshot.cn/v1",
                   model: "", keyURL: "https://platform.moonshot.cn"),
        LLMProfile(name: "Claude", provider: .anthropic, baseURL: "https://api.anthropic.com",
                   model: "claude-haiku-5-5", keyURL: "https://console.anthropic.com"),
    ]
}

enum AudioSource: String, Codable, CaseIterable, Identifiable {
    case system, microphone
    var id: String { rawValue }
    var label: String { self == .system ? "电脑声音" : "麦克风" }
    var symbol: String { self == .system ? "speaker.wave.2.fill" : "mic.fill" }
    var detail: String {
        self == .system ? "直接录制电脑播放的声音，可以戴耳机或静音" : "用麦克风收外放的声音，需要外放、环境安静"
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var profiles: [LLMProfile] { didSet { saveProfiles() } }
    @Published var selectedProfileID: UUID? { didSet { d.set(selectedProfileID?.uuidString, forKey: "selectedProfile") } }
    @Published var source: AudioSource { didSet { d.set(source.rawValue, forKey: "source") } }
    @Published var outputDir: String { didSet { d.set(outputDir, forKey: "outputDir") } }
    @Published var glossary: String { didSet { d.set(glossary, forKey: "glossary") } }
    @Published var autoStop: Bool { didSet { d.set(autoStop, forKey: "autoStop") } }
    @Published var graceSec: Double { didSet { d.set(graceSec, forKey: "graceSec") } }
    @Published var cancelChars: Int { didSet { d.set(cancelChars, forKey: "cancelChars") } }
    @Published var silenceMin: Double { didSet { d.set(silenceMin, forKey: "silenceMin") } }

    private init() {
        if let data = d.data(forKey: "profiles"), let p = try? JSONDecoder().decode([LLMProfile].self, from: data), !p.isEmpty {
            profiles = p
        } else {
            profiles = LLMProfile.presets
        }
        selectedProfileID = d.string(forKey: "selectedProfile").flatMap(UUID.init(uuidString:))
        source = AudioSource(rawValue: d.string(forKey: "source") ?? "") ?? .system
        outputDir = d.string(forKey: "outputDir")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/课程笔记").path
        glossary = d.string(forKey: "glossary") ?? ""
        autoStop = d.object(forKey: "autoStop") as? Bool ?? true
        graceSec = d.object(forKey: "graceSec") as? Double ?? 180
        cancelChars = d.object(forKey: "cancelChars") as? Int ?? 450
        silenceMin = d.object(forKey: "silenceMin") as? Double ?? 8
        if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = profiles.first?.id
        }
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { d.set(data, forKey: "profiles") }
    }

    var selectedProfile: LLMProfile? { profiles.first { $0.id == selectedProfileID } }
    var outputURL: URL { URL(fileURLWithPath: (outputDir as NSString).expandingTildeInPath) }
    var glossaryTerms: [String] {
        glossary.components(separatedBy: CharacterSet(charactersIn: ",，、\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func isReady(_ p: LLMProfile) -> Bool {
        !p.model.trimmingCharacters(in: .whitespaces).isEmpty && !p.baseURL.isEmpty && Keychain.get(p.id) != nil
    }
}
