#!/usr/bin/env python3
"""Günlük bölüm üretim hattı (iskelet).

Aşamalar:
  1. konu seç      (curriculum.json, daha önce işlenenleri atla)
  2. senaryo yaz   (TR + EN, sabit karakterler)
  3. güvenlik kontrolü (ikinci bir model çağrısı; geçmezse dur)
  4. görsel/ses/video üretimi  -> render() içinde bağlanacak (servis seçimi bekliyor)
  5. taslak olarak site/episodes.json'a ekle (status=draft)
Yayın: bir insan status'u "published" yapar ve youtube_id'yi girer.
"""
import datetime, json, pathlib, random, sys
import anthropic
from render import render as render_video

ROOT = pathlib.Path(__file__).parent
EPISODES = ROOT.parent / "site" / "episodes.json"
MODEL = "claude-sonnet-5-5"
client = anthropic.Anthropic()  # ANTHROPIC_API_KEY ortam değişkeninden

def ask(system, user):
    r = client.messages.create(model=MODEL, max_tokens=4000, system=system,
                               messages=[{"role": "user", "content": user}])
    return r.content[0].text

def pick_topic(data):
    done = {e["topic"] for e in data["episodes"]}
    plan = json.loads((ROOT / "curriculum.json").read_text(encoding="utf-8"))
    options = [(a, t) for a, ts in plan.items() for t in ts if t not in done]
    return random.choice(options or [(a, t) for a, ts in plan.items() for t in ts])

def write_script(age, topic):
    cast = (ROOT / "characters.json").read_text(encoding="utf-8")
    system = ("Sen 3-6 yaş çocuklar için eğitici çizgi film senaristisin. Kurallar: korku, şiddet, "
              "tehlikeli davranış, marka, reklam, gerçek kişi YOK. Sakin tempo, tekrar, net öğrenme hedefi. "
              "Sadece verilen karakterleri kullan. Çıktı: geçerli JSON.")
    user = (f"Yaş: {age}. Konu: {topic}.\nKarakterler: {cast}\n"
            'JSON alanları: title{tr,en}, summary{tr,en}, learning{tr,en}, scenes[{narration_tr, narration_en, visual}] (6-10 sahne, ~2-3 dk).')
    return json.loads(ask(system, user))

def safety_check(script):
    verdict = ask("Çocuk içeriği güvenlik denetçisisin. Yaş 3-6 için uygunluğu sıkı denetle: korku, şiddet, "
                  "tehlikeli taklit edilebilir davranış, yanlış bilgi, marka/reklam, karakter dışı öğe. "
                  'Sadece JSON dön: {"safe": true|false, "reasons": []}', json.dumps(script, ensure_ascii=False))
    return json.loads(verdict)

def render_all(script, out):
    """Her dil için video üretir. Sağlayıcılar render.py içinde; gerçek servisler burada verilecek."""
    for lang in ("tr", "en"):
        render_video(script, out, lang=lang)

def main():
    data = json.loads(EPISODES.read_text(encoding="utf-8"))
    age, topic = pick_topic(data)
    script = write_script(age, topic)
    check = safety_check(script)
    if not check["safe"]:
        sys.exit(f"Güvenlik kontrolünden geçmedi, bölüm atlandı: {check['reasons']}")
    today = datetime.date.today().isoformat()
    out = ROOT / "out" / today
    out.mkdir(parents=True, exist_ok=True)
    (out / "script.json").write_text(json.dumps(script, ensure_ascii=False, indent=2), encoding="utf-8")
    render_all(script, out)
    data["episodes"].append({"id": f"{today}-{topic}", "date": today, "age": age, "topic": topic,
        "status": "draft", "youtube_id": "", "title": script["title"], "summary": script["summary"],
        "learning": script["learning"]})
    EPISODES.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Taslak hazır: {out}. İncele, onayla: status -> published")

if __name__ == "__main__":
    main()
