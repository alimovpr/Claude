#!/bin/sh
# Пересобирает файлы по Гонконгу: Cosmopack по дням (day1/, day2/, day3/),
# Cosmoprof отдельно (cosmoprof/) и общие contacts.xlsx / contacts.pdf по всему.
cd "$(dirname "$0")/.." || exit 1
n=1
for d in 2026-11-11 2026-11-12; do
  python3 exhibition/build.py cosmopack-hk --simple --show=Cosmopack --date=$d --out="day$n/Cosmopack_HK_день${n}_контакты.xlsx" &&
  python3 exhibition/build_pdf.py cosmopack-hk "Cosmopack Asia 2026, Гонконг — контакты, день $n" \
    --show=Cosmopack --date=$d --out="day$n/Cosmopack_HK_день${n}_карточки.pdf" || exit 1
  n=$((n + 1))
done
if grep -q '"show": "Cosmoprof"' cosmopack-hk/contacts.json; then
  python3 exhibition/build.py cosmopack-hk --simple --show=Cosmoprof --out="cosmoprof/Cosmoprof_HK_контакты.xlsx" &&
  python3 exhibition/build_pdf.py cosmopack-hk "Cosmoprof Asia 2026, Гонконг (HKCEC) — контакты" \
    --show=Cosmoprof --out="cosmoprof/Cosmoprof_HK_карточки.pdf" || exit 1
fi
python3 exhibition/build.py cosmopack-hk --simple &&
python3 exhibition/build_pdf.py cosmopack-hk "Cosmopack + Cosmoprof Asia 2026, Гонконг — все контакты"
