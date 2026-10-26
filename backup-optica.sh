#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ubuntu/optica-bot-stack"
ENV_FILE="$STACK_DIR/.env"
VOL_ROOT="/var/lib/docker/volumes"
PG_CONTAINER="optica-bot-stack-postgres-1"
PG_USER="n8n"
PG_DB="n8n"

# Datos de infraestructura fuera del repo (es público): se leen del .env del stack,
# que viaja dentro de stack.tar.gz y se restaura junto con todo.
# Se usa grep y no `source` porque el .env tiene hashes con $$ que bash interpretaría.
leer_env() {
  { grep -E "^$1=" "$ENV_FILE" || true; } | tail -n1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//"
}
BUCKET="$(leer_env BACKUP_BUCKET)"
HOOK="$(leer_env BACKUP_HEARTBEAT_URL)"
: "${BUCKET:?Falta BACKUP_BUCKET en $ENV_FILE}"
: "${HOOK:?Falta BACKUP_HEARTBEAT_URL en $ENV_FILE}"

STAMP="$(date +%Y-%m-%d_%H%M)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

docker exec -i "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" | gzip > "$WORK/postgres.sql.gz"

tar czf "$WORK/stack.tar.gz" -C "$(dirname "$STACK_DIR")" "$(basename "$STACK_DIR")"
tar czf "$WORK/n8n_data.tar.gz" -C "$VOL_ROOT/optica-bot-stack_n8n_data" _data
tar czf "$WORK/caddy_data.tar.gz" -C "$VOL_ROOT/optica-bot-stack_caddy_data" _data
tar czf "$WORK/caddy_config.tar.gz" -C "$VOL_ROOT/optica-bot-stack_caddy_config" _data

for f in postgres.sql.gz stack.tar.gz n8n_data.tar.gz caddy_data.tar.gz caddy_config.tar.gz; do
  aws s3 cp "$WORK/$f" "s3://$BUCKET/$STAMP/$f" --only-show-errors
done

curl -fsS -m 15 -X POST -H "Content-Type: application/json" -d "{\"stamp\":\"$STAMP\"}" "$HOOK" > /dev/null || echo "AVISO: latido no enviado"

echo "OK $STAMP"
du -sh "$WORK"/*.gz
