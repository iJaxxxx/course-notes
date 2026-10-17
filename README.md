# 网课笔记助手（macOS）

小鹅通等网课的自动笔记工具：**录音 → 本地转写 → 大模型总结 → Word 文档**。

- 转写在本机完成（SenseVoice），不联网，不用登录任何账号
- 总结用你自己选的大模型：DeepSeek、通义、智谱、豆包、Kimi、Claude 都行，在 `config.json` 里切换
- 自动识别下课：听到“下课 / 今天就到这 / 下节课见 / 拜拜”等，再录 3 分钟确认后自动收尾；连续 8 分钟没人讲话也会自动结束
- 输出 Word：大纲、⭐ Highlight 知识点（标注第几分钟）、核心重点、课后待办、待查证

## 一次性准备（约 20 分钟）

```bash
cd course-notes
./setup.sh        # 国内网络建议用：./setup.sh --cn
```

脚本会依次完成下面几步：
1. 安装 ffmpeg 和 BlackHole 虚拟声卡（会让你输入一次开机密码）
2. 安装 Python 依赖
3. 下载本地转写模型（约 900MB）
4. 让你选总结用的模型并粘贴 API key（存进 `~/.zshrc`，不会写进项目文件）

最后**手动做一次声音设置**，脚本结束时也会提示：
- 打开「音频 MIDI 设置」→ 左下角 `+` → 创建多输出设备，勾选耳机/扬声器和 BlackHole 2ch
- 系统设置 → 声音 → 输出，选这个「多输出设备」
- 想静音后台录：输出直接选 BlackHole 2ch。你自己听不到，但能正常录

没装 BlackHole 也能用：脚本会自动改用麦克风。这时要用外放、别戴耳机，环境尽量安静。

## 每节课

```bash
./run.sh "第3课 定价策略"
```

- **提前一分钟运行**：首次加载转写模型要 40 秒左右，屏幕出现「🎙 正在录制」才算开始。录音期间 Mac 不会休眠，锁屏没关系
- 每 8 分钟在终端里出一段要点
- 下课后自动结束，也可以随时按 Ctrl+C 手动结束
- Word 文档自动生成到 `config.json` 里 `docx_dir` 指定的目录

**录回放：** 把回放调到 1.5–2 倍速播放即可。注意文档里的“第几分钟”是按录制时间算的。

**处理已有录音或视频**（手机录的、别人发的）：
```bash
./run.sh "第3课" --file ~/Downloads/录音.m4a
```

**重新生成某节课的总结**（比如换了模型）：
```bash
.venv/bin/python course_notes.py --summarize ~/CourseNotes/2026-10-17_1543_第3课 --llm qwen
```

## 换模型 / 换 key

`config.json` 里的 `llm` 字段决定默认用哪个模型，`profiles` 里列出了所有可选配置：

| 配置名 | 服务商 | 去哪申请 key | key 放在哪个环境变量 |
|---|---|---|---|
| `deepseek` | DeepSeek（便宜，推荐） | platform.deepseek.com | `DEEPSEEK_API_KEY` |
| `qwen` | 阿里通义千问 | 阿里云百炼 | `DASHSCOPE_API_KEY` |
| `glm` | 智谱 GLM | open.bigmodel.cn | `ZHIPU_API_KEY` |
| `doubao` | 字节豆包 | 火山方舟 | `ARK_API_KEY` |
| `kimi` | 月之暗面 Kimi | platform.moonshot.cn | `MOONSHOT_API_KEY` |
| `claude` | Anthropic Claude（国内需海外网络和支付方式） | console.anthropic.com | `ANTHROPIC_API_KEY` |
| `claude_cli` | 本机已登录的 Claude Code | 不需要 key | — |

- **glm / doubao / kimi 的 `model` 默认是空的**：要先填上控制台里的模型名才能用
- **临时换模型**：加 `--llm qwen`
- **加一个新服务商**：在 `profiles` 里新增一项，`provider` 填 `openai_compatible`，再填 `base_url`、`model` 和 `api_key_env`。只要服务商兼容 OpenAI 接口就能用
- **不改文件、只用环境变量覆盖**：可以设置 `COURSE_LLM`（选哪个配置）、`COURSE_LLM_MODEL`、`COURSE_LLM_BASE_URL`、`COURSE_LLM_API_KEY`
- **检查配置能不能用**：运行 `.venv/bin/python course_notes.py --check`，会发一次很短的请求

一节 1 小时的课大约用 4 万输入 token、8 千输出 token。用 DeepSeek 或 GLM 这类便宜模型，花费不到 ¥0.1。

## 其他设置（config.json）

| 字段 | 作用 |
|---|---|
| `glossary` | 课程里常出现的英文产品名或术语，比如 `["Claude", "Gemini"]`。本地转写对英文专有名词不准，填了之后模型会按它纠正 |
| `output.notes_dir` | 转写稿、分段笔记等工作文件放在哪 |
| `output.docx_dir` | Word 文档放在哪 |
| `end_detect` | 自动下课检测：`grace_sec` 是听到结束语后再录几秒；`cancel_chars` 是结束语后又讲了多少字就算误报；`silence_min` 是几分钟没人讲话就自动停止 |
| `summary.interval_min` | 每几分钟出一次分段要点 |

## 输出文件

每节课一个文件夹，位于 `~/CourseNotes/日期_课程名/`：
- `transcript.md`：带时间戳的完整转写
- `notes.md`：课中每段要点
- `summary.md`：课后总结的原文，Word 文档就是由它生成的
- 另外，Word 文档在 `docx_dir` 里，文件名是 `日期_课程名_课程总结.docx`

## 常见问题

- **「30 秒内没收到声音」**：系统输出没选多输出设备，或者播放器被静音了
- **总结失败**：先运行 `--check`。常见原因是 key 没设、余额不足，或 model 名填错了。转写稿不会丢，修好后用 `--summarize` 重新生成即可
- **pip 下载很慢**：用 `./setup.sh --cn`
- **误判下课**：调大 `end_detect.cancel_chars` 或 `grace_sec`；也可以加 `--no-autostop`，只用 Ctrl+C 手动结束
- **想同时抓 PPT 文字**：加 `--slides`，第一次需要在「隐私与安全性 → 屏幕录制」里给终端授权

只用于个人学习笔记，请勿对外分发课程内容。

## 参与贡献与许可证

欢迎提 Issue 和 PR，参与方式见 [CONTRIBUTING.md](CONTRIBUTING.md)。代码按 [MIT 许可证](LICENSE) 开源。

本仓库只包含工具代码，不接收任何课程录音、转写稿或课程总结。
