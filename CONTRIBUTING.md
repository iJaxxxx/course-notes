# 参与贡献

欢迎提 Issue 和 PR。这个项目有两套实现，改之前先确认你要动的是哪一套：

| | 目录 | 运行环境 |
|---|---|---|
| Python 命令行版 | 根目录：`course_notes.py`、`llm.py`、`md2docx.py` | macOS，Python 3.9+，ffmpeg，可选 BlackHole |
| macOS App 版 | `CourseNotesApp/` | macOS 26 及以上，Apple 芯片，Xcode 26 或对应的 Command Line Tools |

两套代码里有几处逻辑是各写一份的：**下课检测的正则、总结提示词、Word 导出**。改其中一边时，请在 PR 里说明另一边要不要同步改，能一起改最好。

## 本地跑起来

**App 版**

```bash
cd CourseNotesApp
swift build                 # 调试编译
swift run                   # 直接运行（不是 .app，系统通知不可用）
scripts/build_dmg.sh        # 打包成 dist/课程笔记.app 和 DMG
```

ad-hoc 签名每次编译都会变，所以每次重新编译后，「屏幕与系统录音」权限要重新授权，钥匙串里的 API Key 也可能要重新粘贴。这是正常现象。

**Python 版**

```bash
./setup.sh                  # 国内网络用 ./setup.sh --cn
.venv/bin/python course_notes.py --check     # 检查模型配置能不能用
./run.sh "测试课" --file 一段录音.m4a         # 不用真的上课，拿一段录音测试
```

## 提交 PR

1. Fork 本仓库，从 `main` 拉一个新分支，名字说明改了什么，比如 `fix/transcript-lost-on-quit`。
2. 一个 PR 只做一件事。顺手发现的其他问题，另开 Issue 或 PR。
3. 代码风格跟周围保持一致：注释用中文，只写「为什么」，不重复代码本身在做什么。
4. 用户能看到的文字（界面、报错、README）用简体中文，说清楚出了什么问题、用户该怎么做。
5. 提交前确认能编译通过：App 版跑 `swift build`，Python 版至少跑 `python3 -m py_compile course_notes.py llm.py md2docx.py`。CI 会在 PR 上自动检查这两项。
6. 改了录音、转写、下课检测或总结流程的，请在 PR 里写清楚你实际怎么测的（录了多长、哪种录制来源、用的哪个模型）。

## 反馈问题

用 Issue 模板填写，尽量附上：macOS 版本、芯片、用的是 App 版还是 Python 版、录制来源、总结模型，以及报错截图或日志。

## 请不要提交

- **API Key、`config.json`**：`config.json` 已在 `.gitignore` 里，贴日志和截图前也请检查有没有带上 Key。
- **课程录音、转写稿、课程总结**：这些内容的版权属于课程方。复现问题时，请用你自己录的测试音频，或者把内容替换成无关文字。

## 许可证

提交 PR 即表示你同意你的贡献按本仓库的 [MIT 许可证](LICENSE) 发布。
