#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
course_notes.py — 小鹅通（及任意网课）笔记助手（macOS）

链路：BlackHole 抓系统音频 → SenseVoice 本地转写 → 大模型每 N 分钟提炼要点
     → 自动识别下课 → 课后总结（带 ⭐Highlight 第几分钟）→ 导出 Word
可选：定时截取小鹅通窗口 + Apple Vision OCR，把 PPT 文字并入笔记
模型和 key 在 config.json 里配置（见 config.example.json），可随时切换。

用法：
  python course_notes.py --title "第3课 定价策略"          # 直播 / 回放，自动识别下课
  python course_notes.py --title "第3课" --file 录音.m4a   # 处理已有录音或视频
  python course_notes.py --summarize ~/CourseNotes/xxx    # 对某节课重新生成总结
  python course_notes.py --llm deepseek ...               # 临时换模型配置
  python course_notes.py --list-devices / --list-windows / --check
"""
from __future__ import annotations

import argparse
import datetime as dt
import difflib
import os
import queue
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import wave
from math import gcd
from pathlib import Path

import numpy as np

from llm import ask, load_config, make_llm

ASR_SR = 16000

# 结束语：命中后再录 grace 秒确认；期间老师又大段讲课就当误报
END_RE = re.compile("|".join([
    r"下课",
    r"今天(的课|的直播|的分享|的内容)?(就|先)?(讲|聊|上|分享)?到这",
    r"(今天|这节课|本节课|这次)(就)?(先)?(到这里|到此)",
    r"下(节|次|期|堂)(课)?(再)?见",
    r"我们下(次|回)(再)?见",
    r"(下午|晚上|明天)(再)?见",
    r"感谢(大家|各位|同学们)的?(收看|聆听|参与|陪伴|观看)",
    r"拜拜|再见|bye",
]), re.IGNORECASE)


# ───────────────────────── 通用 ─────────────────────────
def hms(sec: float) -> str:
    sec = int(sec)
    return f"{sec // 3600:02d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


def log(msg: str) -> None:
    print(f"[{dt.datetime.now():%H:%M:%S}] {msg}", flush=True)


def append(path: Path, text: str) -> None:
    with path.open("a", encoding="utf-8") as f:
        f.write(text)


def safe_name(s: str) -> str:
    return re.sub(r'[\\/:*?"<>|\s]+', "_", s).strip("_") or "course"


# ───────────────────────── 会话状态 ─────────────────────────
class Session:
    def __init__(self, args, finish: threading.Event):
        self.args = args
        self.t0 = time.time()
        stamp = dt.datetime.now().strftime("%Y-%m-%d_%H%M")
        self.dir = Path(args.out).expanduser() / f"{stamp}_{safe_name(args.title)}"
        (self.dir / "slides").mkdir(parents=True, exist_ok=True)
        self.transcript_path = self.dir / "transcript.md"
        self.notes_path = self.dir / "notes.md"
        self.slides_path = self.dir / "slides.md"

        self.lock = threading.Lock()
        self.transcript: list[tuple[float, str]] = []  # (开课后秒数, 文本)
        self.slides: list[tuple[float, str]] = []
        self.notes: list[str] = []
        self.summarized_upto = 0
        self.summarized_slides = 0
        self.stop = threading.Event()
        self.finish = finish  # 自动判定下课、直播结束或收到停止信号

        # 下课检测状态
        self.end_at: float | None = None  # 命中结束语时的开课后秒数
        self.end_chars = 0
        self.last_speech = 0.0  # 最近一次转写出有效讲话的时间（开课后秒数）

        head = f"# {args.title}\n\n开始时间：{dt.datetime.now():%Y-%m-%d %H:%M}\n\n"
        for p in (self.transcript_path, self.notes_path, self.slides_path):
            p.write_text(head, encoding="utf-8")

    def elapsed(self) -> float:
        return time.time() - self.t0

    def on_text(self, start: float, text: str) -> None:
        """每段转写完成后调用：检测结束语，处理误报。"""
        if len(re.findall(r"\w", text)) >= 6:  # 噪音偶尔会被识别成一两个字，不算讲话
            self.last_speech = start
        if self.args.no_autostop or self.finish.is_set():
            return
        a = self.args
        if self.end_at is None:
            m = END_RE.search(text)
            if m:
                self.end_at, self.end_chars = start, 0
                ctx = text[max(0, m.start() - 15): m.end() + 15]
                log(f"🔔 听到结束语「{m.group(0)}」：…{ctx}… 再录 {a.grace:.0f} 秒确认")
        else:
            self.end_chars += len(text)
            if self.end_chars > a.cancel_chars:
                log(f"↩️  结束语之后又讲了 {self.end_chars} 字，判定为误报，继续录")
                self.end_at = None

    def check_stop(self, now: float) -> None:
        """主循环定期调用：结束语确认期满或持续静音 → 自动收尾。"""
        if self.args.no_autostop or self.finish.is_set():
            return
        if self.end_at is not None and now - self.end_at >= self.args.grace:
            log("⏹  确认下课，自动停止")
            self.finish.set()
        elif now - self.last_speech >= self.args.silence_min * 60:
            log(f"⏹  已经 {(now - self.last_speech) / 60:.0f} 分钟没人讲话，判定直播/回放已结束")
            self.finish.set()


# ───────────────────────── 音频分段 ─────────────────────────
class Segmenter:
    """按停顿切段：至少 min_s 秒后遇到 ~0.6 秒停顿就切，最长 max_s 秒强制切。"""

    def __init__(self, sr: int, min_s: float = 15, max_s: float = 30, block_s: float = 0.1):
        self.sr = sr
        self.min_len, self.max_len = int(sr * min_s), int(sr * max_s)
        self.tail_blocks = max(1, int(0.6 / block_s))
        self.up, self.down = ASR_SR // gcd(ASR_SR, sr), sr // gcd(ASR_SR, sr)
        self.total = 0
        self._reset(0.0)

    def _reset(self, start: float) -> None:
        self.buf: list[np.ndarray] = []
        self.rms: list[float] = []
        self.buf_len = 0
        self.seg_start = start

    def push(self, mono: np.ndarray) -> list[tuple[float, np.ndarray]]:
        self.buf.append(mono)
        self.rms.append(float(np.sqrt(np.mean(mono ** 2))) if len(mono) else 0.0)
        self.buf_len += len(mono)
        self.total += len(mono)
        if self.buf_len >= self.max_len:
            return self.flush()
        if self.buf_len >= self.min_len:
            thr = max(0.15 * float(np.median(self.rms)), 1e-3)
            if max(self.rms[-self.tail_blocks:]) < thr:
                return self.flush()
        return []

    def flush(self) -> list[tuple[float, np.ndarray]]:
        out = []
        if self.buf_len:
            audio = np.concatenate(self.buf)
            if np.sqrt(np.mean(audio ** 2)) > 1e-4:  # 整段静音（课间）直接丢掉
                if self.up != self.down:
                    from scipy.signal import resample_poly

                    audio = resample_poly(audio, self.up, self.down)
                out.append((self.seg_start, audio.astype(np.float32)))
        self._reset(self.total / self.sr)
        return out


def find_input_device(sd, keyword: str):
    devices = sd.query_devices()
    for i, d in enumerate(devices):
        if keyword.lower() in d["name"].lower() and d["max_input_channels"] > 0:
            return i, d
    idx = sd.default.device[0]
    if idx is None or idx < 0:
        raise SystemExit(f"找不到 '{keyword}'，也没有默认麦克风；先运行 --list-devices 看看")
    log(f"⚠️  没找到 '{keyword}'（BlackHole 没装或没配好），改用默认麦克风：{devices[idx]['name']}")
    log("    麦克风模式下请用外放、别戴耳机，房间尽量安静")
    return idx, devices[idx]


def audio_worker(sess: Session, seg_q: queue.Queue) -> None:
    import sounddevice as sd

    idx, info = find_input_device(sd, sess.args.device)
    sr = int(info["default_samplerate"])
    ch = min(2, int(info["max_input_channels"]))
    raw_q: queue.Queue = queue.Queue()

    def cb(indata, frames, t, status):  # noqa: ARG001
        raw_q.put(indata.copy())

    seg = Segmenter(sr)
    window_peak = 0.0
    last_check = time.time()
    warned = False

    def handle(block: np.ndarray) -> None:
        nonlocal window_peak
        mono = block.mean(axis=1).astype(np.float32)
        if len(mono):
            window_peak = max(window_peak, float(np.abs(mono).max()))
        for item in seg.push(mono):
            seg_q.put(item)

    with sd.InputStream(device=idx, channels=ch, samplerate=sr, dtype="float32",
                        blocksize=int(sr * 0.1), callback=cb):
        log(f"🎙  正在录制：{info['name']}（{sr} Hz）")
        while not sess.stop.is_set():
            try:
                handle(raw_q.get(timeout=0.5))
            except queue.Empty:
                pass
            if time.time() - last_check > 30:
                quiet = window_peak < 1e-4  # BlackHole 没信号时是纯数字静音
                if quiet and not warned:
                    log("⚠️  30 秒内没收到声音：确认系统输出是「多输出设备」、播放器没静音、老师在说话")
                    warned = True
                elif not quiet:
                    warned = False
                window_peak = 0.0
                last_check = time.time()
    while not raw_q.empty():
        handle(raw_q.get_nowait())
    for item in seg.flush():
        seg_q.put(item)


def file_worker(sess: Session, seg_q: queue.Queue, path: str) -> None:
    """把已有的音频/视频文件按同样的方式切段，时间点就是文件里的位置。"""
    log(f"📼 读取文件：{path}")
    r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-vn", "-ac", "1",
                        "-ar", str(ASR_SR), "-f", "f32le", "-"], capture_output=True)
    if r.returncode != 0:
        raise SystemExit(f"ffmpeg 读取失败：{r.stderr.decode(errors='ignore')[:300]}")
    audio = np.frombuffer(r.stdout, dtype=np.float32)
    log(f"   时长 {hms(len(audio) / ASR_SR)}，开始转写")
    seg = Segmenter(ASR_SR)
    block = int(ASR_SR * 0.1)
    for i in range(0, len(audio), block):
        for item in seg.push(audio[i:i + block]):
            seg_q.put(item)
    for item in seg.flush():
        seg_q.put(item)


# ───────────────────────── 转写 ─────────────────────────
def load_asr(args):
    from funasr import AutoModel

    model_id = "iic/SenseVoiceSmall" if args.hub == "ms" else "FunAudioLLM/SenseVoiceSmall"
    log("加载 SenseVoice 模型（第一次会下载约 900MB）…")
    return AutoModel(model=model_id, hub=args.hub, device="cpu", disable_update=True)


def write_wav(path: str, audio: np.ndarray) -> None:
    pcm = (np.clip(audio, -1, 1) * 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(ASR_SR)
        w.writeframes(pcm.tobytes())


def asr_worker(sess: Session, model, seg_q: queue.Queue) -> None:
    tmp = tempfile.mkdtemp(prefix="course_notes_")
    path = os.path.join(tmp, "seg.wav")
    while True:
        item = seg_q.get()
        if item is None:
            break
        start, audio = item
        if sess.args.file and sess.finish.is_set():
            continue  # 处理文件时按了 Ctrl+C：剩下的段不转了，直接用已转写部分总结
        try:
            write_wav(path, audio)
            res = model.generate(input=path, cache={}, language=sess.args.lang,
                                 use_itn=True, batch_size_s=60, disable_pbar=True)
            text = re.sub(r"<\|[^|]*\|>", "", res[0]["text"]).strip() if res else ""
        except Exception as e:  # 单段失败不影响整体
            log(f"转写失败：{e}")
            continue
        if not re.search(r"\w", text):  # 只有标点（静音段）
            continue
        with sess.lock:
            sess.transcript.append((start, text))
        append(sess.transcript_path, f"[{hms(start)}] {text}\n\n")
        if not sess.args.quiet:
            print(f"  \033[2m[{hms(start)}] {text}\033[0m", flush=True)
        if not sess.args.file:
            sess.on_text(start, text)
    shutil.rmtree(tmp, ignore_errors=True)


# ───────────────────────── PPT 截图 + OCR ─────────────────────────
def list_windows() -> None:
    import Quartz

    wins = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID) or []
    seen = set()
    for w in wins:
        b = w.get("kCGWindowBounds", {})
        if w.get("kCGWindowLayer", 0) == 0 and float(b.get("Width", 0)) > 300:
            seen.add(str(w.get("kCGWindowOwnerName", "")))
    print("当前有窗口的 App：")
    for name in sorted(seen):
        print("  ", name)


def find_window_id(keywords: list[str]) -> int | None:
    import Quartz

    best, best_area = None, 0.0
    wins = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID) or []
    for w in wins:
        owner = str(w.get("kCGWindowOwnerName", ""))
        if w.get("kCGWindowLayer", 0) != 0:
            continue
        if not any(k.lower() in owner.lower() for k in keywords):
            continue
        b = w.get("kCGWindowBounds", {})
        area = float(b.get("Width", 0)) * float(b.get("Height", 0))
        if area > best_area:
            best, best_area = int(w["kCGWindowNumber"]), area
    return best


def ocr_image(path: str, crop: tuple[float, float, float, float] | None) -> str:
    from ocrmac import ocrmac
    from PIL import Image

    img = Image.open(path)
    if crop:
        W, H = img.size
        x, y, w, h = crop
        img = img.crop((int(x * W), int(y * H), int((x + w) * W), int((y + h) * H)))
    anns = ocrmac.OCR(img, language_preference=["zh-Hans", "en-US"],
                      recognition_level="accurate").recognize()
    anns = [a for a in anns if a[1] >= 0.3]
    anns.sort(key=lambda a: (-round(a[2][1], 2), a[2][0]))  # Vision 坐标原点在左下：从上到下、从左到右
    return "\n".join(a[0] for a in anns).strip()


def slides_worker(sess: Session) -> None:
    keywords = [k.strip() for k in sess.args.app.split(",") if k.strip()]
    tmp = tempfile.mkdtemp(prefix="course_slides_")
    shot = os.path.join(tmp, "shot.png")
    last_text, empty_count = "", 0
    while not sess.stop.wait(sess.args.slide_every):
        wid = find_window_id(keywords)
        if wid is None:
            log(f"⚠️  没找到 App 名含 {keywords} 的窗口，用 --list-windows 查准名字后传 --app")
            continue
        r = subprocess.run(["screencapture", "-x", "-o", "-l", str(wid), shot], capture_output=True)
        if r.returncode != 0 or not os.path.exists(shot):
            log("⚠️  截图失败：系统设置 → 隐私与安全性 → 屏幕与系统录音，给终端打开权限")
            continue
        try:
            text = ocr_image(shot, sess.args.crop)
        except Exception as e:
            log(f"OCR 失败：{e}")
            continue
        if len(text) < 15:
            empty_count += 1
            if empty_count == 5:
                log("⚠️  连续截不到文字：可能没有屏幕录制权限（截出来是空白），或画面里没有 PPT")
            continue
        empty_count = 0
        if last_text and difflib.SequenceMatcher(None, last_text, text).ratio() >= sess.args.slide_threshold:
            continue  # 和上一页差不多，算同一页
        last_text = text
        t = sess.elapsed()
        name = f"slide_{hms(t).replace(':', '')}.png"
        shutil.copy(shot, sess.dir / "slides" / name)
        with sess.lock:
            sess.slides.append((t, text))
        append(sess.slides_path, f"## [{hms(t)}]\n\n![](slides/{name})\n\n{text}\n\n")
        log(f"🖼  新的一页 PPT（{len(text)} 字）")
    shutil.rmtree(tmp, ignore_errors=True)


# ───────────────────────── 大模型提炼 ─────────────────────────
SYSTEM = """你是一名课堂速记员，负责把网课整理成学习笔记。
输入是语音识别转写稿（有同音错字、口语、重复），请按上下文纠正术语；忽略寒暄、催互动、卖课广告等无关内容。
只根据课程内容提炼，不要补充课上没讲的知识，不确定的放进“待查”。直接输出 Markdown，不要任何开场白。"""

SEG_PROMPT = """课程：{title}

【之前已整理的笔记（用于避免重复，不要再输出）】
{prev}

【这段时间新出现的 PPT 文字】
{slides}

【新的转写稿 {start} – {end}】
{text}

请只输出这一段的笔记，严格按下面的 Markdown 格式（没有内容的条目省略）：
### {start} – {end}｜<本段主题，10 字内>
- <要点，3–6 条，每条一句话，具体到概念/数字/方法>
- ⭐ 老师强调：<明确说“重点/一定要/记住/考”或反复讲的内容>
- 💡 方法/例子：<可以直接用的步骤、公式、案例>
- ❓ 待查：<没听清、转写不确定、值得课后查证的点>
如果这段基本是闲聊或广告，只输出：### {start} – {end}｜（无实质内容）"""

FINAL_PROMPT = """课程：{title}（时长约 {dur}）

【分段笔记】
{notes}

【PPT 文字（按时间）】
{slides}

【完整转写稿（[时:分:秒] 是从开始录制算起的时间）】
{transcript}

请生成课后总结，严格按下面的 Markdown 结构：
# {title}｜课程总结
（标题下用 - 列表写：录制信息、时间说明“第 N 分钟从开始录制算起”、转写纠错说明）

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
要求：只根据课程内容；转写错字按上下文纠正；不要编造；没有内容的小节写“无”。"""


def summarize_increment(sess: Session, llm, force: bool = False) -> None:
    with sess.lock:
        new = sess.transcript[sess.summarized_upto:]
        new_slides = sess.slides[sess.summarized_slides:]
        prev = "\n\n".join(sess.notes)[-6000:] or "（暂无）"
    chars = sum(len(s) for _, s in new)
    if not new or (chars < 150 and not force):
        return
    start, end = hms(new[0][0]), hms(new[-1][0] + 30)
    prompt = SEG_PROMPT.format(
        title=sess.args.title, prev=prev, start=start, end=end,
        slides="\n---\n".join(f"[{hms(t)}]\n{s}" for t, s in new_slides) or "（无）",
        text="\n".join(f"[{hms(t)}] {s}" for t, s in new),
    )
    note = ask(llm, SYSTEM, prompt, 2000, log)
    if not note:
        return  # 失败就留给下一轮一起处理
    with sess.lock:
        sess.notes.append(note)
        sess.summarized_upto += len(new)
        sess.summarized_slides += len(new_slides)
    append(sess.notes_path, note + "\n\n")
    print("\n\033[1;36m" + note + "\033[0m\n", flush=True)


def summarizer_worker(sess: Session, llm) -> None:
    interval = sess.args.interval * 60
    next_t = time.time() + interval
    while not sess.stop.wait(5):
        if time.time() >= next_t:
            summarize_increment(sess, llm)
            next_t = time.time() + interval


def final_summary(folder: Path, title: str, llm, max_tokens: int) -> Path | None:
    def body(name: str) -> str:
        p = folder / name
        if not p.exists():
            return ""
        lines = p.read_text(encoding="utf-8").splitlines()
        return "\n".join(lines[3:]).strip()  # 去掉文件头

    transcript = body("transcript.md")
    if not transcript:
        log("没有转写内容，跳过总结")
        return None
    stamps = re.findall(r"\[(\d\d):(\d\d):(\d\d)\]", transcript)
    dur = hms(int(stamps[-1][0]) * 3600 + int(stamps[-1][1]) * 60 + int(stamps[-1][2])) if stamps else "未知"
    slides = re.sub(r"!\[\]\(slides/[^)]+\)\n*", "", body("slides.md"))
    prompt = FINAL_PROMPT.format(title=title, dur=dur, notes=body("notes.md") or "（无）",
                                 slides=slides or "（无）", transcript=transcript)
    log(f"📝 正在用 {llm.describe()} 生成课后总结…")
    out = ask(llm, SYSTEM, prompt, max_tokens, log)
    if not out:
        log("总结生成失败，稍后可以用 --summarize 重试")
        return None
    out = re.sub(r"^```(?:markdown)?\s*|\s*```$", "", out.strip())  # 去掉模型偶尔包的代码块
    path = folder / "summary.md"
    path.write_text(out + "\n", encoding="utf-8")
    return path


def export_docx(summary: Path, docx_dir: str, title: str) -> Path | None:
    from md2docx import convert

    date = summary.parent.name[:10] if re.match(r"\d{4}-\d\d-\d\d", summary.parent.name) else f"{dt.date.today()}"
    try:
        return convert(summary, Path(docx_dir).expanduser() / f"{date}_{safe_name(title)}_课程总结.docx")
    except Exception as e:
        log(f"导出 Word 失败：{e}（summary.md 已保存）")
        return None


def finish_up(folder: Path, title: str, llm, args) -> None:
    path = final_summary(folder, title, llm, args.max_tokens)
    if not path:
        return
    log(f"✅ 课后总结：{path}")
    docx = export_docx(path, args.docx_dir, title)
    if docx:
        log(f"📄 Word 文档：{docx}")
        subprocess.run(["open", "-R", str(docx)], check=False)


# ───────────────────────── 主流程 ─────────────────────────
def parse_args():
    cfg = load_config()
    out, audio = cfg.get("output", {}), cfg.get("audio", {})
    end, summ = cfg.get("end_detect", {}), cfg.get("summary", {})

    p = argparse.ArgumentParser(description="网课笔记助手：录音 → 本地转写 → 大模型总结 → Word")
    p.add_argument("--title", default="网课", help="课程名，用于文件夹、标题和 Word 文件名")
    p.add_argument("--file", help="处理已有的音频/视频文件，而不是实时录音")
    p.add_argument("--llm", help="用 config.json 里的哪个模型配置（默认取 config 的 llm 字段）")
    p.add_argument("--out", default=out.get("notes_dir", "~/CourseNotes"), help="笔记工作目录")
    p.add_argument("--docx-dir", default=out.get("docx_dir", "~/Desktop/CourseNotes"), help="Word 文档输出目录")
    p.add_argument("--device", default=audio.get("device", "BlackHole"), help="音频输入设备名关键词")
    p.add_argument("--lang", default="auto", help="auto / zh / en / yue …")
    p.add_argument("--hub", default="ms", choices=["ms", "hf"], help="模型下载源：ms=ModelScope，hf=HuggingFace")
    p.add_argument("--interval", type=float, default=summ.get("interval_min", 8), help="每隔几分钟提炼一次要点")
    p.add_argument("--max-tokens", type=int, default=summ.get("max_tokens", 8000), help="课后总结最多输出多少 token")
    p.add_argument("--grace", type=float, default=end.get("grace_sec", 180), help="听到结束语后再录多少秒")
    p.add_argument("--cancel-chars", type=int, default=end.get("cancel_chars", 450), help="结束语后又讲了多少字算误报")
    p.add_argument("--silence-min", type=float, default=end.get("silence_min", 8), help="多少分钟没人讲话就自动停止")
    p.add_argument("--no-autostop", action="store_true", help="不自动识别下课，只能手动 Ctrl+C")
    p.add_argument("--slides", action="store_true", help="开启 PPT 截图 + OCR")
    p.add_argument("--app", default="小鹅通,xiaoe,Xiaoe", help="小鹅通窗口所属 App 名关键词，逗号分隔")
    p.add_argument("--slide-every", type=float, default=20, help="截图间隔（秒）")
    p.add_argument("--slide-threshold", type=float, default=0.7, help="与上一页文字相似度 ≥ 此值视为同一页")
    p.add_argument("--crop", default=None, help="只 OCR 窗口的一部分，比例 x,y,w,h，如 0,0.08,0.72,0.85（去掉聊天区）")
    p.add_argument("--quiet", action="store_true", help="终端不打印逐句转写")
    p.add_argument("--list-devices", action="store_true")
    p.add_argument("--list-windows", action="store_true")
    p.add_argument("--check", action="store_true", help="检查模型配置能不能用（会发一次很短的请求）")
    p.add_argument("--summarize", metavar="DIR", help="对已有课程文件夹重新生成 summary.md 和 Word")
    a = p.parse_args()
    if a.crop:
        a.crop = tuple(float(v) for v in a.crop.split(","))
        assert len(a.crop) == 4, "--crop 需要 4 个数：x,y,w,h"
    return a


def main() -> None:
    args = parse_args()

    if args.list_devices:
        import sounddevice as sd

        print(sd.query_devices())
        return
    if args.list_windows:
        list_windows()
        return

    global SYSTEM
    glossary = [w for w in load_config().get("glossary", []) if w]
    if glossary:  # 本地转写对英文专有名词不准，告诉模型正确写法
        SYSTEM += f"\n课程里常出现这些专有名词，转写中发音相近的词请按它们纠正：{', '.join(glossary)}"

    llm = make_llm(args.llm)
    log(f"🤖 总结模型：{llm.describe()}")
    if args.check:
        reply = ask(llm, "你是测试助手。", "只回复两个字：可用", 50, log)
        log(f"✅ 模型可用，回复：{reply}" if reply else "❌ 模型不可用，检查 key / base_url / model")
        return

    if args.summarize:
        folder = Path(args.summarize).expanduser()
        first = (folder / "transcript.md").read_text(encoding="utf-8").splitlines()[0]
        title = first.lstrip("# ").strip() or args.title
        finish_up(folder, title, llm, args)
        return

    # Ctrl+C / kill 都走正常收尾；收尾期间再按也不会打断
    finish = threading.Event()

    def request_stop(signum, frame):  # noqa: ARG001
        if not finish.is_set():
            log("收到停止信号")
            finish.set()
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    model = load_asr(args)  # 先加载模型，避免开录后积压
    if finish.is_set():
        log("还没开始录就停止了，退出")
        return
    sess = Session(args, finish)
    log(f"📂 笔记目录：{sess.dir}")

    seg_q: queue.Queue = queue.Queue()
    if args.file:
        source = threading.Thread(target=file_worker, args=(sess, seg_q, args.file), daemon=True)
    else:
        source = threading.Thread(target=audio_worker, args=(sess, seg_q), daemon=True)
    threads = {
        "source": source,
        "asr": threading.Thread(target=asr_worker, args=(sess, model, seg_q), daemon=True),
    }
    if not args.file:  # 处理文件很快，分段要点没意义，课后总结直接读完整转写
        threads["sum"] = threading.Thread(target=summarizer_worker, args=(sess, llm), daemon=True)
    if args.slides and not args.file:
        threads["slides"] = threading.Thread(target=slides_worker, args=(sess,), daemon=True)
    for t in threads.values():
        t.start()

    if args.file:
        log("处理中…（Ctrl+C 可中途结束并用已转写部分生成总结）")
    else:
        auto = "听到下课/拜拜或长时间无声会自动结束，" if not args.no_autostop else ""
        log(f"开始记录。每 {args.interval:g} 分钟出一次要点；{auto}也可以按 Ctrl+C 手动下课。")
    while source.is_alive() and not sess.finish.is_set():
        time.sleep(1)
        sess.check_stop(sess.elapsed())

    log("⏹  收尾中…")
    sess.stop.set()
    source.join()
    seg_q.put(None)
    threads["asr"].join()
    for name in ("sum", "slides"):
        if name in threads:
            threads[name].join()

    if not args.file:
        summarize_increment(sess, llm, force=True)
    finish_up(sess.dir, args.title, llm, args)
    log(f"全部文件在：{sess.dir}")


if __name__ == "__main__":
    main()
