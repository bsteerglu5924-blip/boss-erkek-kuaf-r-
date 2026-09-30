#!/usr/bin/env python3
"""Üretilen bölümü YouTube'a YÜKLER (varsayılan: özel/private). Yayını insan açar.

Ortam değişkenleri: YT_CLIENT_ID, YT_CLIENT_SECRET, YT_REFRESH_TOKEN
Kullanım: python3 pipeline/upload_youtube.py pipeline/out/2026-09-30 tr
"""
import json, os, pathlib, sys
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

def main(out_dir, lang):
    out = pathlib.Path(out_dir)
    script = json.loads((out / "script.json").read_text(encoding="utf-8"))
    creds = Credentials(None, refresh_token=os.environ["YT_REFRESH_TOKEN"],
        token_uri="https://oauth2.googleapis.com/token",
        client_id=os.environ["YT_CLIENT_ID"], client_secret=os.environ["YT_CLIENT_SECRET"])
    yt = build("youtube", "v3", credentials=creds)
    body = {
        "snippet": {"title": script["title"][lang][:100],
                    "description": script["summary"][lang] + "\n\n" + script["learning"][lang]
                                   + "\n\nThis video was created with AI. / Bu video yapay zeka ile hazırlanmıştır.",
                    "categoryId": "27",  # Eğitim
                    "defaultLanguage": lang},
        "status": {"privacyStatus": "private",          # insan izleyip yayına alır
                   "selfDeclaredMadeForKids": True,      # çocuklara özel
                   "containsSyntheticMedia": True},      # yapay zeka ile üretildi
    }
    media = MediaFileUpload(str(out / f"episode_{lang}.mp4"), resumable=True)
    resp = yt.videos().insert(part="snippet,status", body=body, media_body=media).execute()
    print("Yüklendi (özel):", resp["id"], "→ site/episodes.json içindeki youtube_id'ye yaz, YouTube'da yayına al.")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
