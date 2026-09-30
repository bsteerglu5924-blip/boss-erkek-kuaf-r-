"""Gerçek servis sağlayıcıları: tek Google (Gemini) API anahtarıyla görsel + ses.

Ortam değişkenleri:
  GEMINI_API_KEY      (zorunlu)
  GEMINI_IMAGE_MODEL  (varsayılan: gemini-2.5-flash-image)
  GEMINI_TTS_MODEL    (varsayılan: gemini-2.5-flash-preview-tts)
  GEMINI_TTS_VOICE    (varsayılan: Kore)
Model adları Google tarafında değişebilir; değişirse sadece bu değişkenleri güncelle.
"""
import base64, json, os, pathlib, urllib.request, wave
from render import ImageProvider, VoiceProvider

API = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
ROOT = pathlib.Path(__file__).parent
STYLE = ("Children's picture-book illustration for ages 3-6, soft pastel colors, rounded friendly shapes, "
         "bright and calm, no text, no scary elements, 16:9. ")


def _post(model, body):
    req = urllib.request.Request(API.format(model=model), data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "x-goog-api-key": os.environ["GEMINI_API_KEY"]})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def _inline(resp):
    for part in resp["candidates"][0]["content"]["parts"]:
        if "inlineData" in part:
            return base64.b64decode(part["inlineData"]["data"])
    raise RuntimeError(f"Yanıtta medya yok: {str(resp)[:300]}")


class GeminiImage(ImageProvider):
    """Karakter tutarlılığı: pipeline/characters_ref/*.png varsa her isteğe referans olarak eklenir."""
    def make(self, scene, idx, path):
        model = os.environ.get("GEMINI_IMAGE_MODEL", "gemini-2.5-flash-image")
        parts = [{"text": STYLE + scene["visual"]}]
        for ref in sorted((ROOT / "characters_ref").glob("*.png")):
            parts.append({"inlineData": {"mime_type": "image/png", "data": base64.b64encode(ref.read_bytes()).decode()}})
        data = _inline(_post(model, {"contents": [{"parts": parts}],
                                     "generationConfig": {"responseModalities": ["IMAGE"]}}))
        path.write_bytes(data)


def pcm_to_wav(pcm: bytes, path, rate=24000):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(pcm)
    return len(pcm) / 2 / rate


class GeminiVoice(VoiceProvider):
    def make(self, text, lang, path):
        model = os.environ.get("GEMINI_TTS_MODEL", "gemini-2.5-flash-preview-tts")
        voice = os.environ.get("GEMINI_TTS_VOICE", "Kore")
        prompt = ("Say warmly, slowly and cheerfully, like a kind storyteller for small children: " + text)
        body = {"contents": [{"parts": [{"text": prompt}]}],
                "generationConfig": {"responseModalities": ["AUDIO"],
                    "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}}}}
        return pcm_to_wav(_inline(_post(model, body)), path)


def get_providers():
    """Anahtar varsa gerçek servisler, yoksa yer tutucular (hat yine de çalışır)."""
    if os.environ.get("GEMINI_API_KEY"):
        return GeminiImage(), GeminiVoice()
    print("Uyarı: GEMINI_API_KEY yok, yer tutucu görsel/ses kullanılıyor")
    return None, None
