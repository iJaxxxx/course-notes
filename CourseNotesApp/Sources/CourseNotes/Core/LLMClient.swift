import Foundation

enum LLMError: LocalizedError {
    case noKey(String), noModel(String), badURL, http(Int, String), refusal, empty, network(Error)

    var errorDescription: String? {
        switch self {
        case .noKey(let n): return "「\(n)」还没有填 API Key"
        case .noModel(let n): return "「\(n)」还没有填模型名"
        case .badURL: return "接口地址（Base URL）格式不对"
        case .http(let code, let body):
            let hint: String
            switch code {
            case 401: hint = "API Key 无效"
            case 402, 403: hint = "没有权限或余额不足"
            case 404: hint = "模型名或接口地址不对"
            case 429: hint = "请求太频繁或额度用完"
            case 400: hint = "请求参数不被接受"
            default: hint = code >= 500 ? "服务商暂时出错，稍后重试" : "请求失败"
            }
            return "\(hint)（HTTP \(code)）\(body.isEmpty ? "" : "：" + String(body.prefix(200)))"
        case .refusal: return "模型拒绝了这次请求，可以换一个模型重试"
        case .empty: return "模型没有返回内容"
        case .network(let e): return "网络错误：\(e.localizedDescription)"
        }
    }

    var retryable: Bool {
        switch self {
        case .http(let code, _): return code == 429 || code >= 500
        case .network: return true
        default: return false
        }
    }
}

/// 调用总结模型：OpenAI 兼容接口（DeepSeek、通义、智谱、豆包、Kimi…）或 Anthropic Messages API。
struct LLMClient {
    let profile: LLMProfile
    let apiKey: String

    /// Claude Opus 5.5 / Sonnet 5.5 被安全分类器拒答时，让服务端自动换模型重试
    private static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-opus-5"]

    init(profile: LLMProfile) throws {
        guard !profile.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw LLMError.noModel(profile.name) }
        guard let key = Keychain.get(profile.id) else { throw LLMError.noKey(profile.name) }
        self.profile = profile
        self.apiKey = key
    }

    func complete(system: String, prompt: String, maxTokens: Int) async throws -> String {
        var lastError: Error = LLMError.empty
        for attempt in 0..<3 {
            do {
                return try await once(system: system, prompt: prompt, maxTokens: maxTokens)
            } catch let e as LLMError where e.retryable {
                lastError = e
                try await Task.sleep(for: .seconds(Double(5 * (attempt + 1))))
            }
        }
        throw lastError
    }

    private func once(system: String, prompt: String, maxTokens: Int) async throws -> String {
        let base = profile.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let model = profile.model.trimmingCharacters(in: .whitespaces)
        var req: URLRequest
        var body: [String: Any]

        switch profile.provider {
        case .openAICompatible:
            guard let url = URL(string: base + "/chat/completions") else { throw LLMError.badURL }
            req = URLRequest(url: url)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "max_tokens": maxTokens,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
        case .anthropic:
            let root = base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
            guard let url = URL(string: root + "/v1/messages") else { throw LLMError.badURL }
            req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": maxTokens, "system": system,
                    "messages": [["role": "user", "content": prompt]]]
            if Self.fallbackModels.contains(model) {
                req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw LLMError.network(error) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(code) else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw LLMError.http(code, msg)
        }

        switch profile.provider {
        case .openAICompatible:
            let choice = (json?["choices"] as? [[String: Any]])?.first
            let text = ((choice?["message"] as? [String: Any])?["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LLMError.empty }
            return text
        case .anthropic:
            if json?["stop_reason"] as? String == "refusal" { throw LLMError.refusal }
            let blocks = json?["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LLMError.empty }
            return text
        }
    }

    /// 设置页「测试连接」
    func test() async throws -> String {
        try await once(system: "你是测试助手。", prompt: "只回复两个字：可用", maxTokens: 50)
    }
}
