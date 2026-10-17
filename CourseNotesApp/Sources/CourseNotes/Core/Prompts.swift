import Foundation

enum Prompts {
    static func system(glossary: [String]) -> String {
        var s = """
        你是一名课堂速记员，负责把网课整理成学习笔记。
        输入是语音识别转写稿（有同音错字、口语、重复），请按上下文纠正术语；忽略寒暄、催互动、卖课广告等无关内容。
        只根据课程内容提炼，不要补充课上没讲的知识，不确定的放进“待查证”。直接输出 Markdown，不要任何开场白。
        """
        if !glossary.isEmpty {
            s += "\n课程里常出现这些专有名词，转写中发音相近的词请按它们纠正：\(glossary.joined(separator: ", "))"
        }
        return s
    }

    static func final(title: String, startedAt: Date, duration: TimeInterval, transcript: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return """
        课程：\(title)（\(f.string(from: startedAt)) 开始录制，时长约 \(Clock.hms(duration))）

        【完整转写稿（[时:分:秒] 是从开始录制算起的时间）】
        \(transcript)

        请生成课后总结，严格按下面的 Markdown 结构：
        # \(title)｜课程总结
        （标题下用 - 列表写：录制时间和时长、时间说明“第 N 分钟从开始录制算起”、转写纠错说明）

        ## ⭐ Highlight 知识点速查
        | 时间 | 知识点 |
        |---|---|
        | **第 N 分钟**（HH:MM:SS） | ⭐ 一句话知识点 |
        （8–15 行，按时间顺序；第 N 分钟 = 时间戳的分钟数，跨多分钟写“第 3–4 分钟”；老师强调过的加 ⭐）

        ## 一句话概括
        ## 课程大纲
        （按讲课逻辑重组的层级大纲：1. 一级用编号，二级用缩进三个空格的 - ；每条末尾标 [HH:MM:SS]）
        ## 核心重点
        （5–10 条，老师强调过的优先并标 ⭐）
        ## 可执行的方法 / 结论
        ## 关键术语
        （术语：一句话解释，只收课上讲到的）
        ## 课后待办
        （用 - [ ] 列出作业、要准备的东西、下节课安排）
        ## 待查证
        （没听清、转写可能有误、需要回看确认的点，带时间戳）
        要求：只根据课程内容；转写错字按上下文纠正；不要编造；没有内容的小节写“无”。
        """
    }
}

enum Clock {
    static func hms(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    static func short(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? hms(t) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
