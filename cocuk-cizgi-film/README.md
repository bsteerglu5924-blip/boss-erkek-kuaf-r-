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
1. Görsel/ses/video servislerini seç ve `render()` içine bağla.
2. YouTube kanalı + API yetkisi; yüklemede "çocuklara özel" ve "yapay zekayla üretildi" işaretle.
3. Günlük zamanlama (GitHub Actions / cron).
4. Vercel yayını ve alan adı.
