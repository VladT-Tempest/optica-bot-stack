#!/usr/bin/env bash
# sanitize-workflows.sh — Reemplaza datos reales por marcadores en los workflows exportados
#
# Uso:
#   1. Crea un archivo .sanitize.env (NO lo subas al repo) con tus valores reales.
#   2. ./sanitize-workflows.sh workflows/            → sanea los .json en sitio (hace .bak)
#
# Los valores reales viven SOLO en .sanitize.env (gitignored), nunca en este script.
set -euo pipefail

DIR="${1:-workflows}"
ENV_FILE="${SANITIZE_ENV:-.sanitize.env}"

if [ ! -f "$ENV_FILE" ]; then
  cat <<'EOF'
No se encontró .sanitize.env. Créalo con este contenido (con TUS valores reales):

  BUSINESS_PHONE=57XXXXXXXXXX
  PHONE_NUMBER_ID=0000000000000000
  WABA_ID=0000000000000000
  BUSINESS_ID=0000000000000000
  TELEGRAM_CHAT_ID=0000000000
  VERIFY_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxx
  WEBHOOK_HOST=mi-host.sslip.io
  BUSINESS_NAME=Nombre Comercial Real
  BUSINESS_DOMAIN=midominio.com
  PRIVACY_URL=https://midominio.com/privacidad

Y agrégalo a .gitignore:  echo ".sanitize.env" >> .gitignore
EOF
  exit 1
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

echo "==> Saneando JSON en: $DIR"

for f in "$DIR"/*.json; do
  [ -e "$f" ] || { echo "No hay .json en $DIR"; exit 1; }
  cp "$f" "$f.bak"

  sed -i \
    -e "s|${PRIVACY_URL}|https://ejemplo.com/privacidad|g" \
    -e "s|${BUSINESS_DOMAIN}|ejemplo.com|g" \
    -e "s|${WEBHOOK_HOST}|<WEBHOOK_HOST>|g" \
    -e "s|${BUSINESS_NAME}|Óptica Visión Clara|g" \
    -e "s|${BUSINESS_PHONE}|<BUSINESS_PHONE>|g" \
    -e "s|${PHONE_NUMBER_ID}|<PHONE_NUMBER_ID>|g" \
    -e "s|${WABA_ID}|<WABA_ID>|g" \
    -e "s|${BUSINESS_ID}|<BUSINESS_ID>|g" \
    -e "s|${TELEGRAM_CHAT_ID}|<TELEGRAM_CHAT_ID>|g" \
    -e "s|${VERIFY_TOKEN}|<VERIFY_TOKEN>|g" \
    "$f"

  echo "   ✔ $(basename "$f")"
done

echo ""
echo "==> 🔍 Revisión final (debe salir vacío):"
grep -nEi "dh_live|Bearer |sk-ant|EAA[A-Za-z0-9]{20}|57[0-9]{10}|${VERIFY_TOKEN:0:8}|${BUSINESS_NAME}" "$DIR"/*.json \
  || echo "   ✅ Sin datos sensibles."

echo ""
echo "NOTA: el System Message del AI Agent sigue conteniendo la base de conocimiento real."
echo "      Reemplázalo por el contenido de system_prompt_bot.example.md antes de publicar,"
echo "      o déjalo apuntando a ese archivo. Los .bak quedan por si necesitas revertir."
