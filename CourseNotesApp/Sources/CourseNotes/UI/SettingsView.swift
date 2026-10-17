import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ModelSettings()
                .tabItem { Label("模型", systemImage: "sparkles") }
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
        }
        .frame(width: 680, height: 470)
    }
}

// MARK: - 模型和 API Key

struct ModelSettings: View {
    @EnvironmentObject var settings: AppSettings
    @State private var editing: LLMProfile.ID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $editing) {
                    ForEach(settings.profiles) { p in
                        HStack {
                            Image(systemName: settings.isReady(p) ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(settings.isReady(p) ? .green : .secondary)
                            Text(p.name)
                            Spacer()
                            if settings.selectedProfileID == p.id {
                                Text("使用中").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(p.id)
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    Menu {
                        ForEach(LLMProfile.presets, id: \.name) { preset in
                            Button(preset.name) { add(preset) }
                        }
                        Divider()
                        Button("自定义（OpenAI 兼容）") {
                            add(LLMProfile(name: "自定义模型", provider: .openAICompatible, baseURL: "https://", model: ""))
                        }
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Button {
                        if let id = editing { remove(id) }
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(editing == nil || settings.profiles.count <= 1)
                    Spacer()
                }
                .padding(4)
            }
            .frame(width: 210)
            Divider()
            if let idx = settings.profiles.firstIndex(where: { $0.id == editing }) {
                ProfileEditor(profile: $settings.profiles[idx])
                    .id(settings.profiles[idx].id)
            } else {
                ContentUnavailableView("选择一个模型", systemImage: "sparkles",
                                       description: Text("左边选一个服务商，填上 API Key 就能用"))
            }
        }
        .onAppear { editing = editing ?? settings.selectedProfileID }
    }

    private func add(_ preset: LLMProfile) {
        var p = preset
        p.id = UUID()
        settings.profiles.append(p)
        editing = p.id
    }

    private func remove(_ id: UUID) {
        Keychain.set("", for: id)
        settings.profiles.removeAll { $0.id == id }
        if settings.selectedProfileID == id { settings.selectedProfileID = settings.profiles.first?.id }
        editing = settings.profiles.first?.id
    }
}

struct ProfileEditor: View {
    @EnvironmentObject var settings: AppSettings
    @Binding var profile: LLMProfile
    @State private var key = ""
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $profile.name)
                Picker("接口类型", selection: $profile.provider) {
                    ForEach(Provider.allCases) { Text($0.label).tag($0) }
                }
                TextField("接口地址", text: $profile.baseURL, prompt: Text("https://api.example.com/v1"))
                TextField("模型名", text: $profile.model, prompt: Text("填服务商控制台里的模型名"))
                SecureField("API Key", text: $key, prompt: Text("粘贴 API Key"))
                    .onChange(of: key) { Keychain.set(key, for: profile.id); result = nil }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key 只保存在这台 Mac 的钥匙串里，不会写进任何文件。")
                    if !profile.keyURL.isEmpty, let url = URL(string: profile.keyURL) {
                        Link("去 \(url.host() ?? profile.keyURL) 申请 API Key →", destination: url)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button(settings.selectedProfileID == profile.id ? "正在使用" : "设为默认") {
                        settings.selectedProfileID = profile.id
                    }
                    .disabled(settings.selectedProfileID == profile.id)
                    Spacer()
                    if let result {
                        Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.ok ? .green : .red)
                            .font(.callout)
                            .lineLimit(2)
                    }
                    Button {
                        Task { await test() }
                    } label: {
                        if testing { ProgressView().controlSize(.small) } else { Text("测试连接") }
                    }
                    .disabled(testing || key.isEmpty || profile.model.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { key = Keychain.get(profile.id) ?? "" }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let reply = try await LLMClient(profile: profile).test()
            result = (true, "可用：\(reply.prefix(20))")
        } catch {
            result = (false, error.localizedDescription)
        }
    }
}

// MARK: - 通用

struct GeneralSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("保存位置") {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    Text(settings.outputDir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("更改…") { choose() }
                }
                Text("每节课一个文件夹：录音.m4a、transcript.md（转写稿）、summary.md、课程总结.docx")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("自动识别下课并结束录制", isOn: $settings.autoStop)
                Stepper(value: $settings.graceSec, in: 30...600, step: 30) {
                    LabeledContent("听到结束语后再录", value: "\(Int(settings.graceSec)) 秒")
                }
                .disabled(!settings.autoStop)
                Stepper(value: $settings.silenceMin, in: 2...30, step: 1) {
                    LabeledContent("持续没人讲话自动结束", value: "\(Int(settings.silenceMin)) 分钟")
                }
                .disabled(!settings.autoStop)
            } header: {
                Text("下课检测")
            } footer: {
                Text("识别「下课」「今天就到这里」「下节课见」「拜拜」等。结束语之后如果老师又讲了不少内容，会当作误报继续录。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("专有名词", text: $settings.glossary, prompt: Text("例如：Claude, Gemini, 全栈, token"), axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text("专有名词")
            } footer: {
                Text("课程里常出现的英文产品名、术语，用逗号隔开。会提示语音识别和总结模型按正确写法纠正。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.outputURL
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { settings.outputDir = url.path }
    }
}
