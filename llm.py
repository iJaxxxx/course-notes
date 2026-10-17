# -*- coding: utf-8 -*-
"""
llm.py — 可切换的大模型接口，模型和 key 都从 config.json / 环境变量读取

支持三种 provider：
  openai_compatible  DeepSeek、智谱 GLM、通义千问、豆包、Kimi 等（OpenAI 兼容接口）
  anthropic          Claude 官方 API
  claude_cli         本机已登录的 Claude Code（`claude -p`），不需要 key

优先级（高 → 低）：命令行 --llm 选 profile > 环境变量 COURSE_LLM_* > config.json
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG_PATH = Path(os.environ.get("COURSE_NOTES_CONFIG", HERE / "config.json"))

# Claude Opus 5.5 / Sonnet 5.5 被安全分类器拒答时，服务端自动换模型重试
FALLBACK_MODELS = {"claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-opus-5"}


class LLMError(RuntimeError):
    pass


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        raise SystemExit(f"找不到配置文件 {CONFIG_PATH}\n先执行：cp config.example.json config.json，再填模型和 key")
    try:
        return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise SystemExit(f"config.json 格式不对（第 {e.lineno} 行）：{e.msg}")


def resolve_profile(cfg: dict, name: str | None = None) -> tuple[str, dict]:
    """选出要用的模型配置，并叠加 COURSE_LLM_* 环境变量。"""
    profiles = cfg.get("profiles", {})
    name = name or os.environ.get("COURSE_LLM") or cfg.get("llm")
    if not name or name not in profiles:
        raise SystemExit(f"config.json 里没有名为 '{name}' 的模型配置，可选：{', '.join(profiles) or '（空）'}")
    p = {k: v for k, v in profiles[name].items() if not k.startswith("_")}
    for key in ("provider", "model", "base_url", "api_key"):
        env = os.environ.get(f"COURSE_LLM_{key.upper()}")
        if env:
            p[key] = env
    return name, p


def _api_key(p: dict) -> str:
    key = p.get("api_key") or (os.environ.get(p["api_key_env"]) if p.get("api_key_env") else None)
    if not key:
        where = f"环境变量 {p['api_key_env']}" if p.get("api_key_env") else "config.json 的 api_key"
        raise SystemExit(f"没有找到 API key：请设置 {where}")
    return key


class LLM:
    def __init__(self, profile_name: str, p: dict):
        self.name = profile_name
        self.provider = p.get("provider", "")
        self.model = p.get("model", "")
        self.p = p
        if self.provider == "openai_compatible":
            try:
                from openai import OpenAI
            except ImportError:
                raise SystemExit("缺少 openai 包：.venv/bin/pip install openai")
            if not p.get("base_url") or not self.model:
                raise SystemExit(f"模型配置 '{profile_name}' 需要填 base_url 和 model")
            self.client = OpenAI(api_key=_api_key(p), base_url=p["base_url"], timeout=600)
        elif self.provider == "anthropic":
            try:
                import anthropic
            except ImportError:
                raise SystemExit("缺少 anthropic 包：.venv/bin/pip install anthropic")
            kwargs = {"api_key": _api_key(p), "timeout": 600}
            if p.get("base_url"):
                kwargs["base_url"] = p["base_url"]
            self.client = anthropic.Anthropic(**kwargs)
            self.model = self.model or "claude-opus-5-5"
        elif self.provider == "claude_cli":
            self.bin = shutil.which(p.get("bin", "claude")) or os.path.expanduser("~/.local/bin/claude")
            if not os.path.exists(self.bin):
                raise SystemExit("找不到 claude 命令行：先安装并登录 Claude Code，或换一个模型配置")
        else:
            raise SystemExit(f"不支持的 provider：'{self.provider}'（可选 openai_compatible / anthropic / claude_cli）")

    def describe(self) -> str:
        return f"{self.name}（{self.provider}{' · ' + self.model if self.model else ''}）"

    def complete(self, system: str, prompt: str, max_tokens: int) -> str:
        if self.provider == "openai_compatible":
            r = self.client.chat.completions.create(
                model=self.model, max_tokens=max_tokens,
                messages=[{"role": "system", "content": system}, {"role": "user", "content": prompt}],
            )
            text = (r.choices[0].message.content or "").strip()
            if r.choices[0].finish_reason == "length":
                text += "\n\n（输出被截断：可在 config.json 调大 max_tokens）"
            return text

        if self.provider == "anthropic":
            kwargs = dict(model=self.model, max_tokens=max_tokens, system=system,
                          messages=[{"role": "user", "content": prompt}])
            if self.model in FALLBACK_MODELS:
                stream = self.client.beta.messages.stream(
                    betas=["server-side-fallback-2026-07-01"], extra_body={"fallbacks": "default"}, **kwargs)
            else:
                stream = self.client.messages.stream(**kwargs)
            with stream as s:
                msg = s.get_final_message()
            if msg.stop_reason == "refusal":
                raise LLMError("模型拒绝了这次请求（refusal），可以换一个模型配置重试")
            return "".join(b.text for b in msg.content if b.type == "text").strip()

        # claude_cli：把系统提示和正文一起从 stdin 传给 `claude -p`
        cmd = [self.bin, "-p", "--output-format", "text"]
        if self.model:
            cmd += ["--model", self.model]
        r = subprocess.run(cmd, input=f"{system}\n\n{prompt}", capture_output=True, text=True,
                           cwd=str(HERE), timeout=900)
        if r.returncode != 0:
            raise LLMError(f"claude 命令行失败：{(r.stderr or r.stdout).strip()[:300]}")
        return r.stdout.strip()


def make_llm(name: str | None = None) -> LLM:
    cfg = load_config()
    profile_name, p = resolve_profile(cfg, name)
    return LLM(profile_name, p)


def ask(llm: LLM, system: str, prompt: str, max_tokens: int, log=print) -> str | None:
    for attempt in range(3):
        try:
            return llm.complete(system, prompt, max_tokens)
        except LLMError as e:
            log(str(e))
            return None
        except Exception as e:  # 网络、限流、5xx：退避重试
            status = getattr(e, "status_code", None)
            if status in (400, 401, 403, 404):  # key、权限、模型名错了，重试没用
                hint = {401: "key 无效", 403: "没有权限或余额不足", 404: "model 名或 base_url 不对", 400: "请求参数不对"}[status]
                log(f"调用 {llm.describe()} 失败（{status}，{hint}）：{str(e)[:200]}")
                return None
            log(f"调用 {llm.describe()} 失败（{attempt + 1}/3）：{type(e).__name__}: {str(e)[:200]}")
            time.sleep(5 * (attempt + 1))
    return None
