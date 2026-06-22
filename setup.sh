#!/usr/bin/env bash
# Genera el archivo .env con secretos aleatorios fuertes.
# Uso:  bash setup.sh
set -euo pipefail

if [ -f .env ]; then
  echo "⚠️  Ya existe un .env — no lo sobreescribo para no perder tus secretos."
  echo "    Si quieres regenerarlo, borra/renombra el .env actual primero."
  exit 0
fi

read -rp "Dominio que apunta a tu EC2 (ej. bot.tuoptica.com): " DOMAIN_INPUT

if [ -z "${DOMAIN_INPUT}" ]; then
  echo "❌  Necesitas un dominio. Abortando."
  exit 1
fi

cp .env.example .env

PG_PASS="$(openssl rand -hex 24)"
ENC_KEY="$(openssl rand -hex 24)"

# Reemplazos seguros (usamos | como separador para no chocar con barras)
sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN_INPUT}|"               .env
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PG_PASS}|" .env
sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=${ENC_KEY}|" .env

echo "✅  .env generado con secretos aleatorios."
echo "    Dominio: ${DOMAIN_INPUT}"
echo "    Guarda una copia segura de N8N_ENCRYPTION_KEY (no la cambies nunca)."
