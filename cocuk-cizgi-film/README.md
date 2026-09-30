# Minik Dünya – Çocuklar için Günlük Yapay Zeka Çizgi Film

3-6 yaş, Türkçe + İngilizce, reklamsız ve hesapsız.

- `site/` – statik site (Vercel'e olduğu gibi yayınlanır). Bölümler `site/episodes.json` içinde.
- `pipeline/` – günlük üretim hattı: konu → senaryo → güvenlik kontrolü → (görsel/ses/video) → **taslak**.
- Yayın akışı: hat taslak üretir, insan izler ve onaylar (`status: published`, `youtube_id` eklenir).

## Yerelde deneme
    cd site && python3 -m http.server 8000

## Bölüm üretimi
    pip install -r pipeline/requirements.txt
    ANTHROPIC_API_KEY=... python3 pipeline/generate_episode.py

## Yapılacaklar
1. Servisler: `pipeline/providers.py` (tek Google `GEMINI_API_KEY` ile görsel + ses) hazır ama henüz gerçek anahtarla denenmedi. Anahtar gelince `ANTHROPIC_API_KEY` + `GEMINI_API_KEY` ile çalıştır; karakter referans görselleri `pipeline/characters_ref/` içine konur.
2. YouTube kanalı + API yetkisi; yüklemede "çocuklara özel" ve "yapay zekayla üretildi" işaretle.
3. Günlük zamanlama (GitHub Actions / cron).
4. Vercel yayını ve alan adı.
