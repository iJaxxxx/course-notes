#!/bin/bash
# run.sh — 开始记一节课
# 用法：./run.sh "课程名" [其他参数，如 --file 录音.m4a / --llm deepseek / --slides]
cd "$(dirname "$0")"
[[ -d .venv ]] || { echo "先运行 ./setup.sh 安装"; exit 1; }
TITLE="${1:-网课}"
shift || true
# caffeinate 盯着本进程：上课期间 Mac 不休眠（锁屏没关系），脚本结束它也跟着退出
caffeinate -i -w $$ &
exec .venv/bin/python course_notes.py --title "$TITLE" "$@"
