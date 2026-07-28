#!/usr/bin/env bash
# backup-db.sh — Respaldo diario de Postgres (n8n + datos del bot)
# Uso: ./backup-db.sh    |    Cron sugerido: 0 3 * * *
set -euo pipefail

CONTAINER="optica-bot-stack-postgres-1"
DB_USER="n8n"
DB_NAME="n8n"
BACKUP_DIR="/home/ubuntu/backups"
RETENTION_DAYS=14
STAMP="$(date +%Y%m%d_%H%M)"
FILE="${BACKUP_DIR}/n8n_${STAMP}.dump"

mkdir -p "$BACKUP_DIR"

echo "==> Respaldando ${DB_NAME} ..."
# --format=custom permite restaurar tablas sueltas y comprime
docker exec -i "$CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" --format=custom > "$FILE"

# Falla ruidosamente si el dump quedó vacío o minúsculo (backup silencioso = no backup)
SIZE=$(stat -c%s "$FILE")
if [ "$SIZE" -lt 10000 ]; then
  echo "!! ERROR: el respaldo pesa ${SIZE} bytes. Revisar." >&2
  exit 1
fi

echo "==> OK: $FILE ($(du -h "$FILE" | cut -f1))"

# Rotación: borra respaldos más viejos que RETENTION_DAYS
find "$BACKUP_DIR" -name 'n8n_*.dump' -mtime +${RETENTION_DAYS} -delete
echo "==> Respaldos actuales:"
ls -1t "$BACKUP_DIR"/n8n_*.dump | head -5

# --- OPCIONAL: copia fuera de la instancia (muy recomendado) ---
# Un respaldo que vive en el mismo disco que la base NO es un respaldo.
# Descomenta tras crear el bucket y dar permisos S3 al rol de la EC2:
# aws s3 cp "$FILE" "s3://TU-BUCKET/optica-bot/" --storage-class STANDARD_IA

# --- CÓMO RESTAURAR (probar al menos una vez!) ---
# docker exec -i optica-bot-stack-postgres-1 pg_restore -U n8n -d n8n --clean --if-exists < archivo.dump
