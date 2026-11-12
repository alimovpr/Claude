#!/bin/sh
# Пересобирает файлы Cosmopack: по каждому дню выставки отдельно (day1/, day2/, day3/)
# и общие contacts.xlsx / contacts.pdf по всем дням.
cd "$(dirname "$0")/.." || exit 1
n=1
for d in 2026-11-11 2026-11-12 2026-11-13; do
  if grep -q "\"date\": \"$d\"" cosmopack-hk/contacts.json; then
    python3 exhibition/build.py cosmopack-hk --simple --date=$d --out="day$n/Cosmopack_HK_день${n}_контакты.xlsx" &&
    python3 exhibition/build_pdf.py cosmopack-hk "Cosmopack Asia 2026, Гонконг — контакты, день $n" \
      --date=$d --out="day$n/Cosmopack_HK_день${n}_карточки.pdf" || exit 1
  fi
  n=$((n + 1))
done
python3 exhibition/build.py cosmopack-hk --simple &&
python3 exhibition/build_pdf.py cosmopack-hk "Cosmopack Asia 2026, Гонконг — все контакты"
