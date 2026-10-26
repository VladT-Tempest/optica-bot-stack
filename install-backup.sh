#!/usr/bin/env bash
# Reinstala el backup diario en una instancia nueva.
# Correr DESPUES de restaurar stack.tar.gz:  sudo bash install-backup.sh
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
install -o root -g root -m 755 "$D/backup-optica.sh" /usr/local/bin/backup-optica.sh
install -o root -g root -m 644 "$D/optica-backup.cron" /etc/cron.d/optica-backup
systemctl restart cron
echo "Instalado. Probar con: sudo /usr/local/bin/backup-optica.sh"
