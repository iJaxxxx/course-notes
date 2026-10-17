#!/bin/bash
# setup.sh — 网课笔记助手一键安装（macOS）
# 用法：./setup.sh          默认从 PyPI 下载
#       ./setup.sh --cn     国内网络用阿里云镜像，下载快很多
set -e
cd "$(dirname "$0")"

say()  { printf "\n\033[1;36m▶ %s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }

PIP_ARGS=()
if [[ "$1" == "--cn" ]]; then
  PIP_ARGS=(-i https://mirrors.aliyun.com/pypi/simple/)
  ok "使用阿里云 PyPI 镜像"
fi

# ── 1. Homebrew + ffmpeg ──────────────────────────────
say "1/5 检查 Homebrew 和 ffmpeg"
if ! command -v brew >/dev/null; then
  warn "没装 Homebrew。先在终端执行下面这行，装完重新运行 ./setup.sh："
  echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  exit 1
fi
ok "Homebrew 已安装"
if command -v ffmpeg >/dev/null; then ok "ffmpeg 已安装"; else brew install ffmpeg; fi

# ── 2. BlackHole 虚拟声卡 ─────────────────────────────
say "2/5 BlackHole 虚拟声卡（录电脑内部声音，可以戴耳机或静音后台跑）"
if system_profiler SPAudioDataType 2>/dev/null | grep -q "BlackHole"; then
  ok "BlackHole 已安装"
else
  warn "接下来会让你输入一次电脑开机密码（安装声卡驱动需要）"
  brew install --cask blackhole-2ch
  warn "如果声音设置里看不到 BlackHole，重启一次电脑"
fi

# ── 3. Python 环境 ────────────────────────────────────
say "3/5 Python 环境和依赖（torch 较大，首次约 5–30 分钟，看网速）"
PY=""
for c in python3.12 python3.11 python3.10 python3; do
  if command -v "$c" >/dev/null; then PY="$(command -v "$c")"; break; fi
done
[[ -z "$PY" ]] && { warn "没找到 python3，执行 xcode-select --install 后重试"; exit 1; }
[[ -d .venv ]] || "$PY" -m venv .venv
.venv/bin/pip install -q --upgrade pip "${PIP_ARGS[@]}"
.venv/bin/pip install -q -r requirements.txt "${PIP_ARGS[@]}"
ok "依赖安装完成（$("$PY" --version)）"

# ── 4. 本地转写模型 ───────────────────────────────────
say "4/5 下载本地转写模型 SenseVoice（约 900MB，只需一次）"
.venv/bin/python - <<'EOF' 2>/dev/null | tail -1
from funasr import AutoModel
AutoModel(model="iic/SenseVoiceSmall", hub="ms", device="cpu", disable_update=True)
print("  ✓ 模型已就绪")
EOF

# ── 5. 选择总结模型 + key ─────────────────────────────
say "5/5 配置总结用的大模型"
[[ -f config.json ]] || cp config.example.json config.json
PROFILES=$(.venv/bin/python -c "import json;print(' '.join(json.load(open('config.json'))['profiles']))")
CURRENT=$(.venv/bin/python -c "import json;print(json.load(open('config.json'))['llm'])")
echo "  可选：$PROFILES"
read -r -p "  用哪个？（回车保持 $CURRENT）" CHOICE
CHOICE=${CHOICE:-$CURRENT}
.venv/bin/python - "$CHOICE" <<'EOF'
import json, sys
c = json.load(open("config.json"))
if sys.argv[1] not in c["profiles"]:
    sys.exit(f"  没有 {sys.argv[1]} 这个配置")
c["llm"] = sys.argv[1]
json.dump(c, open("config.json", "w"), ensure_ascii=False, indent=2)
EOF
ENV_NAME=$(.venv/bin/python -c "import json,sys;print(json.load(open('config.json'))['profiles'][sys.argv[1]].get('api_key_env',''))" "$CHOICE")
if [[ -n "$ENV_NAME" && -z "${!ENV_NAME}" ]]; then
  read -r -s -p "  粘贴 $ENV_NAME（输入不显示，回车跳过）：" KEY; echo
  if [[ -n "$KEY" ]]; then
    printf '\nexport %s=%q\n' "$ENV_NAME" "$KEY" >> ~/.zshrc
    export "$ENV_NAME=$KEY"
    ok "已写入 ~/.zshrc（新开的终端自动生效）"
  else
    warn "跳过。之后在 ~/.zshrc 里加：export $ENV_NAME=你的key"
  fi
fi
MODEL=$(.venv/bin/python -c "import json,sys;print(json.load(open('config.json'))['profiles'][sys.argv[1]].get('model','-'))" "$CHOICE")
[[ -z "$MODEL" ]] && warn "config.json 里 $CHOICE 的 model 还是空的，填上服务商控制台里的模型名再用"
.venv/bin/python course_notes.py --check 2>/dev/null | tail -1 || true

cat <<'EOF'

────────────────────────────────────────────────────────
还差最后一步（只做一次）：让电脑声音同时进耳机和 BlackHole
  1. 打开「音频 MIDI 设置」（聚焦搜索 Audio MIDI Setup）
  2. 左下角 + → 创建多输出设备，勾选耳机/扬声器 和 BlackHole 2ch
     主设备选耳机/扬声器，BlackHole 那行勾「漂移校正」
  3. 系统设置 → 声音 → 输出 → 选这个「多输出设备」
  想静音后台录：输出直接选 BlackHole 2ch（自己听不到，但能录）

上课：./run.sh "第3课 定价策略"
处理录音文件：./run.sh "第3课" --file 录音.m4a
────────────────────────────────────────────────────────
EOF
