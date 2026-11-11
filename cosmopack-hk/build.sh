#!/bin/sh
# Пересобирает оба файла Cosmopack: короткую таблицу контактов и PDF с карточками и фото.
cd "$(dirname "$0")/.." || exit 1
python3 exhibition/build.py cosmopack-hk --simple &&
python3 exhibition/build_pdf.py cosmopack-hk "Cosmopack Asia 2026, Гонконг — контакты"
