# Operación del servidor — tareas programadas y restauración

Este documento lista **todo lo que corre solo** en la EC2 del stack, fuera de n8n,
y **cómo reconstruir el servidor desde el backup** (sección 4).

Última revisión: 24/11/2026

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
- ⚠️ **Un mensaje que llega mientras n8n se apaga se puede perder.** Visto el 24/11/2026 al
  recrear el contenedor de n8n: un mensaje entrante llegó a las 10:02:58 (Bogotá), la
  ejecución quedó como `crashed` y no hubo reintento. El mensaje igual llega a la app del
  celular por la coexistencia, pero Owly no lo procesa. A las 04:00 de un domingo el riesgo es
  mínimo; para reinicios **manuales**, preferir el horario de atención (cuando Owly calla) y
  evitar la pausa del almuerzo.

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

> ⚠️ **`ops/` y `docs/` NO viajan en el backup** (en producción no viven en la carpeta del stack).
> Se traen del repo antes de correr lo de abajo:
>
> ```bash
> git clone https://github.com/VladT-Tempest/optica-bot-stack.git /tmp/repo
> cp -r /tmp/repo/ops /tmp/repo/docs /home/ubuntu/optica-bot-stack/
> ```

Desde la carpeta del stack, después de restaurar `stack.tar.gz` (sección 4):

```bash
# Backup diario (el daemon-reload evita un aviso inofensivo en Ubuntu 26.04)
sudo systemctl daemon-reload
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

---

## 4. Restaurar el servidor desde el backup de S3

**Probado de punta a punta el 23/11/2026** en una EC2 temporal: el backup de ese día bastó
para reconstruir Owly con **10/10 credenciales de n8n descifradas**. El dump de Postgres
(~69 MB comprimido) se restauró en 11 segundos. El procedimiento completo toma alrededor
de una hora con calma.

Hay dos modos, y **la diferencia es de vida o muerte para producción**:

| | **DESASTRE** (producción se perdió) | **ENSAYO** (producción sigue viva) |
|---|---|---|
| Workflows | Activos | **Desactivados antes de arrancar n8n** (paso 7) |
| Red hacia Meta, Telegram, Anthropic… | Normal | **Bloqueada** con un override (paso 7) |
| Caddy | Se levanta | **No se levanta** |
| IP elástica | Se mueve a la instancia nueva | No se toca |
| Al final | `install-backup.sh` y tareas de `ops/` | Destruir la instancia y su grupo de seguridad |

> **Por qué los candados del ensayo no son opcionales:** un n8n restaurado con workflows
> activos registra los webhooks de Telegram (y al apagarse llama `deleteWebhook`, rompiendo
> las aprobaciones de producción), y `optica-cierre-inactividad` podría escribirles a
> pacientes reales.

### Lo que hay que saber antes de empezar

- **Rutas fijas:** `backup-optica.sh` asume que el stack vive en
  **`/home/ubuntu/optica-bot-stack`** y que el contenedor de Postgres se llama
  `optica-bot-stack-postgres-1`. Si se restaura en otra ruta, el backup del día siguiente falla.
- **Qué trae el backup** (una carpeta por día en el bucket, p. ej. `2026-11-23_0700`):
  `postgres.sql.gz`, `stack.tar.gz` (incluye el `.env`), `n8n_data.tar.gz`,
  `caddy_data.tar.gz` (certificados TLS y cuenta ACME) y `caddy_config.tar.gz`.
  **No trae** `ops/` ni `docs/`: salen del repo.
- **El nombre del bucket** está en el `.env` (`BACKUP_BUCKET`), que viene dentro del backup.
  En un desastre, sácalo de la consola de S3 de la cuenta de AWS de XYborg.
- **Acceso:** solo por Session Manager. Se entra como `ssm-user` en `sh`: escribe `bash` y,
  para trabajar con el stack, `sudo -iu ubuntu` (la carpeta de `ubuntu` está cerrada para otros).
- Al pegar varias líneas, si la primera abre un shell nuevo (`sudo -iu ubuntu`), las demás se
  pierden: pega esa primero y lo demás después.

### Paso a paso

**1. Lanzar la instancia.** t4g.small, Ubuntu 26.04 arm64 (la misma AMI que producción),
perfil de instancia `EC2-SSM-Role`, IMDSv2 obligatorio, disco gp3 de 20 GB.
- DESASTRE: el grupo de seguridad de producción (80/443).
- ENSAYO: un grupo de seguridad **nuevo y sin reglas de entrada**.

**2. Instalar lo necesario** (en Ubuntu 26.04 la AWS CLI no viene por apt):

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2
sudo snap install aws-cli --classic
sudo usermod -aG docker ubuntu     # luego salir y volver a entrar como ubuntu
```

**3. Bajar el backup a una carpeta privada y verificarlo:**

```bash
mkdir -m 700 ~/restore && cd ~/restore
aws s3 ls s3://<bucket>/                        # elegir la carpeta más reciente
aws s3 cp --recursive s3://<bucket>/<carpeta>/ .
for f in *.gz; do gzip -t "$f" && echo "OK $f"; done   # los 5 deben decir OK
```

**4. Extraer el stack en la ruta exacta:**

```bash
tar xzf ~/restore/stack.tar.gz -C /home/ubuntu
ls -la /home/ubuntu/optica-bot-stack/.env      # debe existir, con permisos 600
```

**5. Levantar solo Postgres** y esperar a que diga `healthy`:

```bash
cd ~/optica-bot-stack && docker compose up -d postgres && docker compose ps
```

**6. Restaurar la base** (se detiene ante el primer error):

```bash
zcat ~/restore/postgres.sql.gz | docker compose exec -T postgres \
  sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Si el contenedor no tiene `POSTGRES_USER` / `POSTGRES_DB` en su entorno, tomar los valores del `.env`.

**7. SOLO EN ENSAYO — poner los candados antes de arrancar n8n:**

```bash
docker compose exec -T postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "UPDATE workflow_entity SET active=false, \"activeVersionId\"=NULL;"'
```

(n8n 2.x usa las dos columnas; con solo una, los workflows vuelven a arrancar.)

Y un `docker-compose.restore.yml` que mande a `127.0.0.1` todo lo externo, para usarlo con
`docker compose -f docker-compose.yml -f docker-compose.restore.yml …` en los pasos 8 y 9:

```yaml
services:
  n8n:
    extra_hosts:
      - "bot.xyborgautomation.com:127.0.0.1"
      - "api.dualhook.com:127.0.0.1"
      - "api.telegram.org:127.0.0.1"
      - "api.anthropic.com:127.0.0.1"
      - "graph.facebook.com:127.0.0.1"
      - "graph.instagram.com:127.0.0.1"
      - "lookaside.fbsbx.com:127.0.0.1"
      - "api.notion.com:127.0.0.1"
      - "generativelanguage.googleapis.com:127.0.0.1"
      # + el host del bucket de imágenes de redes (ver la credencial de S3 en n8n)
```

Si se agrega una integración nueva (p. ej. Zernio), **su dominio va en esta lista**.

**8. Crear n8n sin arrancarlo y cargar su volumen:**

```bash
docker compose create n8n
sudo tar -xzpf ~/restore/n8n_data.tar.gz -C /var/lib/docker/volumes/optica-bot-stack_n8n_data
docker compose up -d n8n
docker compose logs n8n --since 2m | grep -iE "error|publish|activ"
```

En ENSAYO debe decir `0 published workflows`.

**9. Verificar que la llave de cifrado abre las credenciales:**

```bash
docker compose exec n8n sh -c \
  'n8n export:credentials --all --decrypted --output=/tmp/c.json && echo DESCIFRADO-OK; rm -f /tmp/c.json'
```

Si falla, el `N8N_ENCRYPTION_KEY` del `.env` no coincide con el `config` del volumen: usar la
copia del gestor (`OPTICA · n8n · Encryption key`). **No seguir sin esto.**

**10. SOLO EN DESASTRE — volver a producción:**

```bash
docker compose create caddy
sudo tar -xzpf ~/restore/caddy_data.tar.gz   -C /var/lib/docker/volumes/optica-bot-stack_caddy_data
sudo tar -xzpf ~/restore/caddy_config.tar.gz -C /var/lib/docker/volumes/optica-bot-stack_caddy_config
docker compose up -d
```

- Asociar la **IP elástica** a la instancia nueva (el DNS de `bot.xyborgautomation.com` apunta
  a ella, así que no hay que tocar DNS ni el webhook del proveedor de WhatsApp).
- Reinstalar las tareas programadas (sección "Reinstalar las tareas", con `ops/` traído del repo).
- Verificar: la sonda `optica-healthcheck` responde `200`, un WhatsApp de prueba recibe
  respuesta fuera de horario, y al día siguiente `/var/log/backup-optica.log` termina en `OK`.

**11. SOLO EN ENSAYO — limpiar:** retirar el cron de backup de la temporal si se instaló,
terminar la instancia, borrar su grupo de seguridad y confirmar que no quedan discos sueltos.

### Pendientes conocidos del procedimiento

- Los volúmenes de producción se crearon fuera de Compose en la migración de agosto (por eso el
  aviso `already exists but was not created by Docker Compose`). En un servidor nuevo Compose los
  crea con los mismos nombres; no hace falta nada, pero no confundir el aviso con un error.
- Los pasos 2, 7 y 10 se reconstruyeron del informe del ensayo: validar los comandos exactos en
  el próximo ensayo y corregir aquí lo que cambie.
