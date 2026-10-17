import Foundation

/// 自动识别下课：听到结束语后再录 grace 秒确认；期间老师又大段讲课就当误报。
/// 另外，连续 silenceMin 分钟没人讲话（直播/回放已结束）也会停止。
struct EndDetector {
    static let pattern = try! NSRegularExpression(pattern: [
        "下课",
        "今天(的课|的直播|的分享|的内容)?(就|先)?(讲|聊|上|分享)?到这",
        "(今天|这节课|本节课|这次)(就)?(先)?(到这里|到此)",
        "下(节|次|期|堂)(课)?(再)?见",
        "我们下(次|回)(再)?见",
        "(下午|晚上|明天)(再)?见",
        "感谢(大家|各位|同学们)的?(收看|聆听|参与|陪伴|观看)",
        "拜拜|再见|bye",
    ].joined(separator: "|"), options: [.caseInsensitive])

    var graceSec: Double
    var cancelChars: Int
    var silenceMin: Double

    private(set) var triggeredAt: Date?
    private(set) var keyword: String?
    private var charsSince = 0
    private(set) var lastSpeech = Date()

    init(graceSec: Double, cancelChars: Int, silenceMin: Double) {
        self.graceSec = graceSec
        self.cancelChars = cancelChars
        self.silenceMin = silenceMin
    }

    enum Event { case none, triggered(String), cancelled }

    mutating func feed(_ text: String, now: Date = Date()) -> Event {
        let wordChars = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        if wordChars >= 6 { lastSpeech = now }  // 噪音偶尔被识别成一两个字，不算讲话
        if triggeredAt == nil {
            let range = NSRange(text.startIndex..., in: text)
            if let m = Self.pattern.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                triggeredAt = now
                keyword = String(text[r])
                charsSince = 0
                return .triggered(keyword!)
            }
        } else {
            charsSince += text.count
            if charsSince > cancelChars {
                dismiss()
                return .cancelled
            }
        }
        return .none
    }

    /// 用户点了「继续录制」，或判定为误报
    mutating func dismiss() {
        triggeredAt = nil
        keyword = nil
        charsSince = 0
    }

    func remaining(now: Date = Date()) -> Double? {
        triggeredAt.map { max(0, graceSec - now.timeIntervalSince($0)) }
    }

    enum Stop { case keyword(String), silence }

    func shouldStop(now: Date = Date()) -> Stop? {
        if let t = triggeredAt, now.timeIntervalSince(t) >= graceSec { return .keyword(keyword ?? "") }
        if now.timeIntervalSince(lastSpeech) >= silenceMin * 60 { return .silence }
        return nil
    }
}
