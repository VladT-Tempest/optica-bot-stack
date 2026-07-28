#!/usr/bin/env bash
# export-workflows.sh — Exporta TODOS los workflows de n8n a JSON y revisa secretos
# Uso (en el EC2): ./export-workflows.sh [carpeta_destino]
set -euo pipefail

CONTAINER="optica-bot-stack-n8n-1"
DEST="${1:-/home/ubuntu/optica-bot-stack/workflows}"
TMP_IN_CONTAINER="/home/node/.n8n/exports"

mkdir -p "$DEST"

echo "==> Exportando workflows desde n8n ..."
docker exec "$CONTAINER" rm -rf "$TMP_IN_CONTAINER" || true
docker exec "$CONTAINER" n8n export:workflow --all --separate --pretty --output="$TMP_IN_CONTAINER"

echo "==> Copiando a ${DEST} ..."
docker cp "${CONTAINER}:${TMP_IN_CONTAINER}/." "$DEST/"
docker exec "$CONTAINER" rm -rf "$TMP_IN_CONTAINER" || true

echo "==> Archivos exportados:"
ls -1 "$DEST"

echo ""
echo "==> 🔍 Revisión de secretos (debe salir vacío o solo el número público del negocio):"
grep -nEi 'dh_live|Bearer|sk-ant|EAA[A-Za-z0-9]{20}|cef886|[0-9]{8,10}:AA[A-Za-z0-9_-]{20}|573[0-9]{9}|api[_-]?key|password|secret|verify' "$DEST"/*.json || echo "   ✅ Sin coincidencias."

echo ""
echo "NOTA: n8n NO exporta los valores de las credenciales (viven cifradas en la BD)."
echo "      Lo que SÍ viaja es lo pegado directo en parámetros de nodos: revisa los hits de arriba."
echo "      NUNCA uses 'n8n export:credentials --decrypted' hacia el repo."
