# /// script
# requires-python = ">=3.11"
# dependencies = ["mlx-whisper==0.4.3", "sounddevice", "numpy"]
# [tool.uv]
# exclude-newer = "2026-10-22T00:00:00Z"
# ///
"""Диктовка в буфер обмена. Whisper работает локально на Mac с M-чипом, без интернета.

Запуск в Терминале:  dictate          (английский текст: dictate en)
Enter начинает запись, Enter останавливает. Пока говоришь, буфер обмена уже
наполняется по фразам, после стопа там весь текст, вставлять Cmd+V.
Ctrl+C выход.

Слова, которые Whisper путает, дописывать в словарь.txt рядом с программой.
Каждая диктовка сохраняется в История/ГГГГ-ММ-ДД.md.

Служебное:  --prepare  скачать модель и выйти
            --file x.wav  расшифровать файл тем же путём, что и микрофон (проверка)
"""

import os
import queue
import re
import subprocess
import sys
import threading
import time
import wave
from datetime import datetime
from pathlib import Path

import numpy as np

MODEL = "mlx-community/whisper-large-v3-turbo"
SR = 16000                  # Whisper ждёт 16 кГц
MIN_S, MAX_S = 4, 25        # фразу режем на паузе не раньше 4 с, принудительно на 25 с
PAUSE_S = 0.5

JUNK = re.compile(
    r"субтитр|DimaTorzok|продолжение следует|спасибо за просмотр|редактор|корректор|"
    r"подписывайтесь|ставьте лайк|amara\.org",
    re.IGNORECASE,
)

HERE = Path(__file__).resolve().parent
HIST = HERE / "История"
DICT = HERE / "словарь.txt"


def model_path() -> str:
    """Локальная папка модели. Если её нет, один раз скачивает с Hugging Face."""
    from huggingface_hub import snapshot_download

    try:
        return snapshot_download(MODEL, local_files_only=True)
    except Exception:
        print("Первый запуск: скачиваю модель распознавания (1,6 ГБ), это один раз", flush=True)
        return snapshot_download(MODEL)


def load_words() -> list:
    words = []
    if DICT.exists():
        for line in DICT.read_text(encoding="utf-8").splitlines():
            line = line.split("#")[0]
            words += [w.strip() for w in line.split(",") if w.strip()]
    return words


def make_prompt(words: list) -> str:
    prompt = "Диктовка текста, с запятыми и точками."
    return prompt + (" " + ", ".join(words) + "." if words else "")


def clean(text: str, words: list) -> str:
    text = text.replace(" — это", " это").replace(" – это", " это")
    text = re.sub(r"\s[—–]\s", ", ", text)
    text = text.replace("—", "-").replace("–", "-").strip()
    for w in words:  # написание из словаря: oklch → OKLCH, pixso → Pixso, большая буква в начале остаётся
        text = re.sub(rf"(?<!\w){re.escape(w)}(?!\w)",
                      lambda m, w=w: w[0].upper() + w[1:] if m.group(0)[0].isupper() else w,
                      text, flags=re.IGNORECASE)
    return text


def copy(text: str):
    subprocess.run(["pbcopy"], input=text.encode("utf-8"), env={**os.environ, "LANG": "en_US.UTF-8"})


def save(text: str):
    HIST.mkdir(exist_ok=True)
    now = datetime.now()
    with open(HIST / f"{now:%Y-%m-%d}.md", "a", encoding="utf-8") as f:
        f.write(f"[{now:%H:%M}] {text}\n\n")


def frame_rms(a: np.ndarray, frame: int) -> np.ndarray:
    n = len(a) // frame
    if n == 0:
        return np.zeros(0)
    return np.sqrt((a[: n * frame].reshape(n, frame) ** 2).mean(axis=1))


def find_cut(a: np.ndarray, sr: int):
    """Индекс сэмпла, где резать, или None, если ждём дальше. Кадр 50 мс."""
    frame, pause = sr // 20, int(PAUSE_S * 20)
    dur = len(a) / sr
    if dur < MIN_S:
        return None
    rms = frame_rms(a, frame)
    if len(rms) < pause + 1:
        return None
    win = np.convolve(rms, np.ones(pause) / pause, mode="valid")
    start = MIN_S * 20
    ref = np.percentile(rms, 90)
    quiet = np.where(win[start:] < max(0.2 * ref, 0.002))[0]
    if len(quiet):
        i = start + quiet[0]
    elif dur >= MAX_S:
        i = start + int(np.argmin(win[start:]))
    else:
        return None
    return (i + pause // 2) * frame


class Dictation:
    """Копит звук, режет на паузах, расшифровывает по фразам и держит буфер обмена полным."""

    def __init__(self, sr: int, model: str, words: list, lang: str):
        self.sr, self.model, self.words, self.lang = sr, model, words, lang
        self.prompt = make_prompt(words)
        self.pending = np.zeros(0, dtype=np.float32)
        self.parts = []

    def feed(self, chunk: np.ndarray):
        self.pending = np.concatenate([self.pending, chunk])
        cut = find_cut(self.pending, self.sr)
        if cut is not None:
            piece, self.pending = self.pending[:cut], self.pending[cut:]
            self._take(piece)

    def finish(self) -> str:
        self._take(self.pending)
        self.pending = np.zeros(0, dtype=np.float32)
        return " ".join(self.parts)

    def _take(self, piece: np.ndarray):
        text = self._transcribe(piece)
        if text:
            self.parts.append(text)
            copy(" ".join(self.parts))
            print("  " + text, flush=True)

    def _transcribe(self, audio: np.ndarray) -> str:
        if len(audio) < self.sr * 0.3:
            return ""
        if self.sr != SR:
            from scipy.signal import resample_poly
            audio = resample_poly(audio, SR, self.sr).astype(np.float32)
        if np.percentile(frame_rms(audio, SR // 20), 95) < 0.004:  # тишина
            return ""
        import mlx_whisper

        r = mlx_whisper.transcribe(
            audio, path_or_hf_repo=self.model, language=self.lang,
            condition_on_previous_text=False, initial_prompt=self.prompt,
            temperature=(0.0, 0.2, 0.4), verbose=None,
        )
        parts = []
        for seg in r.get("segments", []):
            txt = seg["text"].strip()
            if not txt or JUNK.search(txt) or txt in self.prompt:
                continue
            if seg.get("no_speech_prob", 0) > 0.6 and seg.get("avg_logprob", 0) < -0.8:
                continue
            if seg.get("compression_ratio", 0) > 2.4:
                continue
            parts.append(txt)
        return clean(" ".join(parts), self.words)


def pick_mic():
    """Встроенный микрофон MacBook, если есть: AirPods при записи переходят в режим звонка."""
    import sounddevice as sd

    devices = sd.query_devices()
    for i, d in enumerate(devices):
        if d["max_input_channels"] > 0 and "MacBook" in d["name"]:
            return i, d
    i = sd.default.device[0]
    return i, devices[i]


def record(d: Dictation, mic: int) -> str:
    import sounddevice as sd

    q = queue.Queue()
    stop = threading.Event()

    def wait_enter():
        try:
            input()
        except EOFError:
            pass
        stop.set()

    threading.Thread(target=wait_enter, daemon=True).start()
    loud, started = 0.0, time.time()
    warned = False
    with sd.InputStream(device=mic, samplerate=d.sr, channels=1, dtype="float32",
                        callback=lambda data, *_: q.put(data[:, 0].copy())):
        while not stop.is_set():
            time.sleep(0.2)
            while not q.empty():
                chunk = q.get()
                loud = max(loud, float(np.abs(chunk).max()))
                d.feed(chunk)
            if not warned and time.time() - started > 3 and loud < 1e-4:
                warned = True
                print("  Микрофон молчит. Системные настройки → Конфиденциальность и безопасность →"
                      " Микрофон → включить Терминал, потом перезапустить", flush=True)
    while not q.empty():
        d.feed(q.get())
    return d.finish()


def from_file(path: str, model: str, words: list, lang: str) -> str:
    with wave.open(path) as w:
        sr = w.getframerate()
        a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
        if w.getnchannels() > 1:
            a = a.reshape(-1, w.getnchannels())[:, 0]
    d = Dictation(sr, model, words, lang)
    step = sr // 5
    for i in range(0, len(a), step):
        d.feed(a[i:i + step])
    return d.finish()


def main():
    args = sys.argv[1:]
    lang = next((a for a in args if len(a) == 2 and a.isalpha()), "ru")

    print("Загружаю модель...", flush=True)
    model = model_path()
    if "--prepare" in args:
        import mlx_whisper  # noqa: F401  проверка, что пакеты встали
        print("Модель на месте, всё готово")
        return
    import mlx_whisper

    mlx_whisper.transcribe(np.zeros(SR, dtype=np.float32), path_or_hf_repo=model, language=lang, verbose=None)
    words = load_words()

    if "--file" in args:
        text = from_file(args[args.index("--file") + 1], model, words, lang)
        print(f"\nИтог: {text}")
        return

    mic, dev = pick_mic()
    sr = int(dev["default_samplerate"])
    print(f"Микрофон: {dev['name']}")
    print("\nEnter: начать запись.  Ctrl+C: выход", flush=True)
    try:
        while True:
            input()
            print("● Пишу, говори.  Enter: стоп", flush=True)
            d = Dictation(sr, model, words, lang)
            try:
                text = record(d, mic)
            except KeyboardInterrupt:
                text = " ".join(d.parts)
                if text:
                    save(text)
                    print("\nРасшифрованное до выхода уже в буфере обмена")
                raise
            if text:
                save(text)
                print("✓ В буфере обмена, вставляй Cmd+V")
            else:
                print("Текста нет, похоже, была тишина")
            print("\nEnter: новая запись.  Ctrl+C: выход", flush=True)
    except (KeyboardInterrupt, EOFError):
        print("\nВыход")


if __name__ == "__main__":
    main()
