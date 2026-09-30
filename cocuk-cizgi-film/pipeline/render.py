"""Sahneleri videoya çevirir (Yol A: sabit karakter görseli + yavaş hareket + seslendirme).

Servisten bağımsızdır. Gerçek servisler `ImageProvider` / `VoiceProvider` arayüzlerine takılır;
şimdilik yer tutucu sağlayıcılar var, hat baştan sona çalışır.
"""
import pathlib, subprocess
from PIL import Image, ImageDraw, ImageFont

W, H, FPS = 1280, 720, 25
COLORS = ["#ffd166", "#8ecae6", "#b5e48c", "#ffadad", "#cdb4db", "#a0e7e5"]


class ImageProvider:
    def make(self, scene, idx, path: pathlib.Path): raise NotImplementedError


class VoiceProvider:
    def make(self, text, lang, path: pathlib.Path) -> float:
        """Ses dosyasını yazar, süreyi (sn) döndürür."""
        raise NotImplementedError


class PlaceholderImage(ImageProvider):
    def make(self, scene, idx, path):
        img = Image.new("RGB", (W, H), COLORS[idx % len(COLORS)])
        d = ImageDraw.Draw(img)
        text = scene.get("visual", "")[:160]
        try:
            font = ImageFont.truetype("DejaVuSans.ttf", 34)
        except OSError:
            font = ImageFont.load_default()
        words, lines, cur = text.split(), [], ""
        for w in words:
            if len(cur) + len(w) > 44: lines.append(cur); cur = w
            else: cur = f"{cur} {w}".strip()
        lines.append(cur)
        d.multiline_text((60, 60), "\n".join(lines), fill="#2b2b45", font=font, spacing=10)
        img.save(path)


class PlaceholderVoice(VoiceProvider):
    """Sessiz parça; süre ≈ kelime sayısı. Gerçek TTS/insan sesiyle değiştirilecek."""
    def make(self, text, lang, path):
        dur = max(3.0, len(text.split()) * 0.45)
        run(["ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", f"{dur:.2f}", str(path)])
        return dur


def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def srt_time(t):
    ms = int(t * 1000)
    return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}"


def render(script, out_dir: pathlib.Path, images: ImageProvider = None, voice: VoiceProvider = None, lang="tr"):
    images, voice = images or PlaceholderImage(), voice or PlaceholderVoice()
    out_dir = pathlib.Path(out_dir)
    tmp = out_dir / "tmp"; tmp.mkdir(parents=True, exist_ok=True)
    clips, srt, t = [], [], 0.0
    for i, sc in enumerate(script["scenes"]):
        text = sc[f"narration_{lang}"]
        png, wav, mp4 = tmp / f"s{i}.png", tmp / f"s{i}.wav", tmp / f"s{i}.mp4"
        images.make(sc, i, png)
        dur = voice.make(text, lang, wav)
        frames = int(dur * FPS) + FPS // 2
        zoom = f"zoompan=z='min(zoom+0.0006,1.12)':d={frames}:s={W}x{H}:fps={FPS}"
        run(["ffmpeg", "-y", "-loop", "1", "-i", str(png), "-i", str(wav),
             "-vf", f"scale=2560:-1,{zoom},format=yuv420p", "-t", f"{dur + 0.5:.2f}",
             "-c:v", "libx264", "-c:a", "aac", "-shortest", str(mp4)])
        clips.append(mp4)
        srt.append(f"{i + 1}\n{srt_time(t)} --> {srt_time(t + dur)}\n{text}\n")
        t += dur + 0.5
    lst = tmp / "list.txt"
    lst.write_text("".join(f"file '{c.name}'\n" for c in clips))
    final = out_dir / f"episode_{lang}.mp4"
    run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(lst), "-c", "copy", str(final)])
    (out_dir / f"episode_{lang}.srt").write_text("\n".join(srt), encoding="utf-8")
    return final
