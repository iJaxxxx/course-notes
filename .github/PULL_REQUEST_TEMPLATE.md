## 改了什么

<!-- 一两句话说明改动和原因；关联 Issue 写 Closes #编号 -->

## 涉及范围

- [ ] macOS App 版
- [ ] Python 命令行版
- [ ] 改了下课检测正则、总结提示词或 Word 导出（两个版本各有一份，说明另一边是否需要同步）

## 怎么测的

<!-- 比如：用电脑声音录了 30 分钟，DeepSeek 生成总结，Word 用 Pages 打开正常 -->

## 检查

- [ ] `swift build`（App 版）或 `python3 -m py_compile course_notes.py llm.py md2docx.py`（Python 版）能通过
- [ ] 没有提交 API Key、`config.json`、课程录音或转写内容
