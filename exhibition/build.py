"""Собирает contacts.xlsx из contacts.json (контакты с выставки, сгруппированы по странам).

Запуск: python build.py [папка выставки] [--simple] — по умолчанию папка самого скрипта.
--simple — короткая таблица только с контактами (подробности и фото идут в PDF, см. build_pdf.py).
--date=ГГГГ-ММ-ДД — только контакты за этот день; --out=путь — куда сохранить (по умолчанию contacts.xlsx).
"""
import io
import json
import sys
from pathlib import Path

from openpyxl import Workbook
from openpyxl.drawing.image import Image as XLImage
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from PIL import Image as PILImage, ImageOps

SIMPLE = "--simple" in sys.argv
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
HERE = Path(ARGS[0]).resolve() if ARGS else Path(__file__).parent
OPTS = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
OUT = HERE / OPTS.get("out", "contacts.xlsx")
COLUMNS = [
    ("country", "Страна производства", 14),
    ("category", "Тип компании", 18),
    ("city", "Город / регион", 22),
    ("company", "Компания", 24),
    ("booth", "Выставка / стенд", 20),
    ("website", "Сайт", 18),
    ("catalog", "Каталог", 28),
    ("profile", "Что производят", 45),
    ("contact_name", "Контакт (по визитке)", 18),
    ("introduced_as", "Как представился", 18),
    ("position", "Должность", 18),
    ("email", "Email", 24),
    ("phone", "Телефон", 16),
    ("address", "Адрес / офисы", 36),
    ("card_notes", "Пометки на визитке", 22),
    ("discussed", "Что обсуждали / интерес", 30),
    ("web_info", "Найдено в интернете", 50),
    ("sources", "Источники", 30),
    ("next_step", "Следующий шаг", 32),
    ("priority", "Приоритет", 11),
    ("date", "Дата", 11),
    ("photo", "Фото", 18),
]
if SIMPLE:
    keep = ["company", "category", "country", "contact_name", "position", "email", "phone", "website", "address"]
    COLUMNS = [next(c for c in COLUMNS if c[0] == k) for k in keep]
FONT = "Arial"
HEADER_FILL = PatternFill("solid", fgColor="1F4E78")
COUNTRY_FILL = PatternFill("solid", fgColor="DDEBF7")
THIN = Side(style="thin", color="BFBFBF")
BORDER = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)
THUMB_PX = 150  # сторона миниатюры; сами фото лежат в photos/ в полном размере
IMAGE_EXT = {".jpg", ".jpeg", ".png"}


def thumbnail(path):
    """Уменьшенная копия фото для вставки в ячейку."""
    im = ImageOps.exif_transpose(PILImage.open(path)).convert("RGB")
    im.thumbnail((THUMB_PX, THUMB_PX))
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=60)
    buf.seek(0)
    return XLImage(buf)


def add_thumbnails(ws, rows):
    """Колонки «Миниатюра N» справа от таблицы: по одной на каждое фото контакта."""
    photos = [
        [p for p in (x.strip() for x in r.get("photo", "").split(";"))
         if p and Path(p).suffix.lower() in IMAGE_EXT and (HERE / p).exists()]
        for r in rows
    ]
    first = len(COLUMNS) + 2
    for n in range(max(map(len, photos), default=0)):
        col = get_column_letter(first + n)
        head = ws.cell(row=1, column=first + n, value=f"Миниатюра {n + 1}")
        head.font = Font(name=FONT, bold=True, color="FFFFFF")
        head.fill = HEADER_FILL
        head.alignment = Alignment(wrap_text=True, vertical="center", horizontal="center")
        head.border = BORDER
        ws.column_dimensions[col].width = THUMB_PX / 7 + 1
    for i, paths in enumerate(photos, 2):
        for n, p in enumerate(paths):
            ws.add_image(thumbnail(HERE / p), f"{get_column_letter(first + n)}{i}")
        if paths:
            ws.row_dimensions[i].height = max(THUMB_PX * 0.75 + 4, ws.row_dimensions[i].height or 0)


def main():
    rows = json.loads((HERE / "contacts.json").read_text(encoding="utf-8"))
    if "date" in OPTS:
        rows = [r for r in rows if r.get("date") == OPTS["date"]]
    rows.sort(key=lambda r: (r["country"], r["company"]))

    wb = Workbook()
    ws = wb.active
    ws.title = "Контакты"
    ws.append(["№"] + [c[1] for c in COLUMNS])
    for i, r in enumerate(rows, 1):
        ws.append([i] + [r.get(c[0], "") for c in COLUMNS])

    for cell in ws[1]:
        cell.font = Font(name=FONT, bold=True, color="FFFFFF")
        cell.fill = HEADER_FILL
        cell.alignment = Alignment(wrap_text=True, vertical="center", horizontal="center")
        cell.border = BORDER
    for row in ws.iter_rows(min_row=2):
        for cell in row:
            cell.font = Font(name=FONT, size=10)
            cell.alignment = Alignment(wrap_text=True, vertical="top")
            cell.border = BORDER
        for key in (k for k in ("website", "catalog") if k in [c[0] for c in COLUMNS]):
            cell = row[1 + [c[0] for c in COLUMNS].index(key)]
            url = str(cell.value or "").split(" ")[0]
            if url.startswith("http") or url.startswith("www."):
                cell.hyperlink = url if url.startswith("http") else "https://" + url
                cell.font = Font(name=FONT, size=10, color="0563C1", underline="single")
        row[1].fill = COUNTRY_FILL
        row[1].font = Font(name=FONT, size=10, bold=True)
    ws.column_dimensions["A"].width = 5
    for idx, (_, _, width) in enumerate(COLUMNS, 2):
        ws.column_dimensions[get_column_letter(idx)].width = width
    ws.freeze_panes = "C2" if SIMPLE else "D2"
    ws.auto_filter.ref = ws.dimensions
    if SIMPLE:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        wb.save(OUT)
        return
    add_thumbnails(ws, rows)

    # Сводка по странам — считается формулами от листа «Контакты»
    sm = wb.create_sheet("По странам")
    sm.append(["Страна производства", "Компаний", "Высокий приоритет"])
    last = len(rows) + 1
    pr = get_column_letter(2 + [c[0] for c in COLUMNS].index("priority"))
    for country in sorted({r["country"] for r in rows}):
        n = sm.max_row + 1
        sm.append([
            country,
            f"=COUNTIF(Контакты!$B$2:$B${last},A{n})",
            f"=COUNTIFS(Контакты!$B$2:$B${last},A{n},Контакты!${pr}$2:${pr}${last},\"Высокий\")",
        ])
    total = sm.max_row + 1
    sm.append(["Итого", f"=SUM(B2:B{total - 1})", f"=SUM(C2:C{total - 1})"])

    # Сводка по типу компании
    sm.append([])
    cat_header = sm.max_row + 1
    sm.append(["Тип компании", "Компаний"])
    for category in sorted({r["category"] for r in rows}):
        n = sm.max_row + 1
        sm.append([category, f"=COUNTIF(Контакты!$C$2:$C${last},A{n})"])
    for row in sm.iter_rows(min_row=2):
        for cell in row:
            cell.font = Font(name=FONT, size=10, bold=row[0].row == total)
    for header_row in (1, cat_header):
        for cell in sm[header_row]:
            if cell.value:
                cell.font = Font(name=FONT, bold=True, color="FFFFFF")
                cell.fill = HEADER_FILL
    for col, width in zip("ABC", (28, 12, 20)):
        sm.column_dimensions[col].width = width

    # Компании со стенда INPD (китайская зона) — кто производит на заказ, кто бренд
    wall = HERE / "inpd_wall.json"
    if wall.exists():
        iw = wb.create_sheet("Стенд INPD (Китай)")
        iw.append(["Компания", "Тип", "Комментарий", "Проверка"])
        for r in json.loads(wall.read_text(encoding="utf-8")):
            iw.append([r["company"], r["type"], r["note"], r["check"]])
        for cell in iw[1]:
            cell.font = Font(name=FONT, bold=True, color="FFFFFF")
            cell.fill = HEADER_FILL
        for row in iw.iter_rows(min_row=2):
            for cell in row:
                cell.font = Font(name=FONT, size=10)
                cell.alignment = Alignment(wrap_text=True, vertical="top")
        for col, width in zip("ABCD", (32, 26, 70, 16)):
            iw.column_dimensions[col].width = width
        iw.freeze_panes = "A2"
        iw.auto_filter.ref = iw.dimensions

    OUT.parent.mkdir(parents=True, exist_ok=True)
    wb.save(OUT)


if __name__ == "__main__":
    main()
