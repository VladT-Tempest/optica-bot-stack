# Operación del servidor — tareas programadas

Este documento lista **todo lo que corre solo** en la EC2 del stack, fuera de n8n.
Si mañana hay que reconstruir el servidor, aquí está qué reinstalar y cómo verificarlo.

Última revisión: 26/10/2026

> **Zona horaria del servidor: UTC.** Los cron usan la zona del sistema, así que todos
> los horarios de abajo están en UTC. Bogotá = UTC − 5.

---

## Resumen

| Tarea | Archivo en `/etc/cron.d/` | Cuándo (UTC) | Cuándo (Bogotá) | Qué hace | Fuente en el repo |
|---|---|---|---|---|---|
| Backup diario | `optica-backup` | Diario 07:00 | Diario 02:00 | Sube a S3 la base de datos, el stack y los volúmenes | `optica-backup.cron`, `backup-optica.sh` |
| Reinicio por parches | `reinicio-dominical` | Domingo 09:00 | Domingo 04:00 | Reinicia **solo si** Ubuntu dejó parches pendientes | `ops/reinicio-dominical` |
| Muestra de memoria | `muestra-memoria` | Cada hora, en punto | Cada hora | Registra el uso de memoria en un CSV | `ops/muestra-memoria`, `ops/muestra-memoria.sh` |

Los horarios están escalonados a propósito: el reinicio del domingo cae dos horas
después del backup, así que nunca se pisan.

---

## 1. Backup diario a S3

- **Cron:** `/etc/cron.d/optica-backup` → `/usr/local/bin/backup-optica.sh`
- **Log:** `/var/log/backup-optica.log`
- **Configuración:** lee `BACKUP_BUCKET` y `BACKUP_HEARTBEAT_URL` del `.env` del stack
  (el repo es público, así que esos datos no van en el script).
- **Credenciales AWS:** ninguna en disco; usa el rol IAM de la instancia.
- **Supervisión:** al terminar envía un latido a n8n; el workflow `optica-backup-watchdog`
  avisa si el latido no llega.
- **Reinstalar:** `sudo bash install-backup.sh` (desde la carpeta del stack).
- **Probar a mano:** `sudo /usr/local/bin/backup-optica.sh` → debe terminar en `OK <fecha>`
  y sin `AVISO: latido no enviado`.
- Última corrida manual verificada: 26/10/2026.

## 2. Reinicio dominical por parches

```
0 9 * * 0 root [ -f /var/run/reboot-required ] && logger -t reinicio-dominical "..." && shutdown -r now
```

- **Por qué existe:** Ubuntu instala parches de seguridad solo, pero algunos (kernel,
  librerías base) no aplican hasta reiniciar. Ubuntu lo señala creando
  `/var/run/reboot-required`. Si ese archivo no existe, el cron no hace nada.
- **Impacto:** caída de ~2 minutos. Docker arranca con el sistema (`systemctl is-enabled docker`
  → `enabled`) y los contenedores vuelven solos por `restart: unless-stopped`.
- **Historial:** reinició una vez, el 11/10/2026 a las 09:00 UTC; el servidor volvió en menos de 2 minutos.
- **Ver si ha reiniciado:** `journalctl -t reinicio-dominical` y `journalctl --list-boots`.
- ❓ Por confirmar: si un mensaje de WhatsApp que llega justo durante esos 2 minutos se
  reintenta (Meta / Dualhook) o se pierde.

## 3. Muestra de memoria (monitoreo de capacidad)

- **Cron:** `/etc/cron.d/muestra-memoria` → `/usr/local/bin/muestra-memoria.sh`, cada hora.
- **Salida:** `/var/log/memoria-optica.csv`, separado por `;`, con columnas
  `fecha; mem_used_mb; mem_available_mb; swap_used_mb; contenedores`
  (la última trae la memoria de cada contenedor).
- **Por qué existe:** nació el 07/09/2026 para medir si la t4g.small (2 GB) alcanza.
  Se conserva como base para decidir cuándo crecer la instancia.
- **Costo:** crece unos 300 bytes por hora (~2–3 MB al año). No necesita rotación por ahora.
- **Ver las últimas muestras:** `tail -24 /var/log/memoria-optica.csv`
- **Dato al 26/10/2026:** 622 MB disponibles y 196 MB de swap en uso (el 07/09 eran 293 MB y 0 de swap).
  Vale la pena vigilar la tendencia del swap.
- **Si algún día se retira:** borrar `/etc/cron.d/muestra-memoria` y el script, y anotarlo aquí.

---

## Reinstalar las tareas en un servidor nuevo

Desde la carpeta del stack, después de restaurar `stack.tar.gz`:

```bash
# Backup diario
sudo bash install-backup.sh

# Reinicio dominical y muestra de memoria
sudo install -o root -g root -m 644 ops/reinicio-dominical /etc/cron.d/reinicio-dominical
sudo install -o root -g root -m 644 ops/muestra-memoria    /etc/cron.d/muestra-memoria
sudo install -o root -g root -m 755 ops/muestra-memoria.sh /usr/local/bin/muestra-memoria.sh
sudo systemctl restart cron
```

**Verificar:**

```bash
ls -l /etc/cron.d/
timedatectl | grep -i 'time zone'     # debe decir Etc/UTC; si no, los horarios cambian
systemctl is-enabled docker           # debe decir enabled
```

> Ojo: los archivos de `/etc/cron.d/` no pueden tener puntos en el nombre (cron los ignora)
> y deben ser de `root` con permisos `644`.
