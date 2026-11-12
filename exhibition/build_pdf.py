"""Собирает contacts.pdf — карточки контактов с фото, чтобы смотреть с телефона.

Запуск: python build_pdf.py [папка выставки] — по умолчанию папка самого скрипта.
Нужен node с playwright (печать HTML в PDF через Chromium).
"""
import base64
import html
import io
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageOps

HERE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).parent
THUMB_PX = 420
IMAGE_EXT = {".jpg", ".jpeg", ".png"}
FIELDS = [
    ("profile", "Что производят"),
    ("contact_name", "Контакт"),
    ("position", "Должность"),
    ("email", "Email"),
    ("phone", "Телефон"),
    ("website", "Сайт"),
    ("address", "Адрес"),
    ("card_notes", "Пометки"),
    ("discussed", "Что обсуждали"),
    ("web_info", "Из интернета"),
    ("next_step", "Следующий шаг"),
    ("priority", "Приоритет"),
]
CSS = """
@page { size: A4; margin: 12mm; }
body { font-family: "DejaVu Sans", "WenQuanYi Zen Hei", sans-serif; font-size: 10pt; color: #222; }
h1 { font-size: 15pt; margin: 0 0 4mm; }
.card { border: 1px solid #bfbfbf; border-radius: 6px; padding: 4mm; margin-bottom: 5mm; break-inside: avoid; }
.card h2 { font-size: 12.5pt; margin: 0 0 1mm; color: #1f4e78; }
.meta { color: #555; margin-bottom: 3mm; }
.photos { margin-bottom: 3mm; }
.photos img { height: 52mm; margin-right: 2mm; border-radius: 4px; break-inside: avoid; }
table { border-collapse: collapse; width: 100%; }
tr { break-inside: avoid; }
td { vertical-align: top; padding: 1mm 0; }
td.k { width: 32mm; color: #555; }
"""


def thumb(path):
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    im.thumbnail((THUMB_PX, THUMB_PX))
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=70)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()


def card(i, r):
    e = html.escape
    photos = [
        p for p in (x.strip() for x in r.get("photo", "").split(";"))
        if p and Path(p).suffix.lower() in IMAGE_EXT and (HERE / p).exists()
    ]
    imgs = "".join(f'<img src="{thumb(HERE / p)}">' for p in photos)
    rows = "".join(
        f'<tr><td class="k">{label}</td><td>{e(str(r[key]))}</td></tr>'
        for key, label in FIELDS if r.get(key)
    )
    meta = " · ".join(e(r[k]) for k in ("category", "country", "city", "date") if r.get(k))
    return (
        f'<div class="card"><h2>{i}. {e(r["company"])}</h2><div class="meta">{meta}</div>'
        f'<div class="photos">{imgs}</div><table>{rows}</table></div>'
    )


def main():
    rows = json.loads((HERE / "contacts.json").read_text(encoding="utf-8"))
    rows.sort(key=lambda r: (r["country"], r["company"]))
    title = sys.argv[2] if len(sys.argv) > 2 else "Контакты с выставки"
    page = (
        f'<!doctype html><html lang="ru"><meta charset="utf-8"><style>{CSS}</style>'
        f"<h1>{html.escape(title)}</h1>"
        + "".join(card(i, r) for i, r in enumerate(rows, 1))
    )
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "contacts.html"
        src.write_text(page, encoding="utf-8")
        js = (
            "const {chromium}=require('playwright');(async()=>{const b=await chromium.launch();"
            "const p=await b.newPage();await p.goto('file://'+process.argv[1]);"
            "await p.pdf({path:process.argv[2],format:'A4',printBackground:true});await b.close()})()"
        )
        subprocess.run(["node", "-e", js, str(src), str(HERE / "contacts.pdf")], check=True)


if __name__ == "__main__":
    main()
