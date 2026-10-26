# Inventario de credenciales — Óptica Dra. Milena Hurtado

> **Este archivo es el MAPA, no la caja fuerte.**
> Aquí se documenta *qué* credenciales existen, *para qué* sirven y *dónde* se usan.
> **Nunca** se escriben aquí contraseñas, tokens, API keys, hashes, usuarios de acceso,
> nombres de buckets ni IDs de cuenta (el repo es público).
> El valor de cada secreto vive en el gestor de contraseñas, en la entrada indicada en la columna "Entrada en el gestor".

Última revisión: 26/10/2026 · Leyenda: ✅ confirmado · ❓ por completar

---

## Convención (XYborg)

**Nombre de la entrada en el gestor:** `CLIENTE · SERVICIO · PARA QUÉ`
Ejemplo: `OPTICA · Caddy basic auth · Candado del editor n8n`

**Carpeta en el gestor:** una por cliente (`OPTICA`, `XYBORG-INTERNO`, `PERSONAL`, …)

**Nota obligatoria en cada entrada (3 líneas):**
1. *Qué protege / para qué sirve*
2. *Dónde vive* (archivo, variable de entorno, credencial de n8n, consola)
3. *Creada: fecha · Cómo rotarla*

**Al crear o rotar un secreto:** actualizar la entrada del gestor **y** la fila de este archivo (fecha de última revisión).

---

## 1. Servidor (AWS EC2 + Docker Compose)

El archivo `.env` del stack concentra los secretos del servidor. Nunca va al repo
(`.gitignore`), tiene permisos `600` (solo su dueño lo lee) y viaja dentro de
`stack.tar.gz` en el backup diario. La plantilla sin valores es `.env.example`.

| Credencial | Para qué sirve | Dónde vive el secreto | Entrada en el gestor | Estado |
|---|---|---|---|---|
| Cuenta root de AWS | Solo emergencias (facturación, recuperación). No se usa en el día a día | Correo administrativo del dominio XYborg (inicio de sesión con Google) | `XYBORG-INTERNO · AWS root · Emergencias` | ✅ |
| Usuario IAM de administración | Uso diario de la consola AWS. Sin access keys | Consola AWS | `XYBORG-INTERNO · AWS IAM · Consola diaria` | ✅ |
| Acceso a la EC2 | Shell en el servidor vía SSM Session Manager (sin SSH) con `conectar.sh` | Hereda del usuario IAM | — (no tiene secreto propio) | ✅ |
| Caddy basic auth | Candado delante del editor de n8n en ambos dominios. Quedan públicos: `/webhook/*`, `/mcp-server/*`, `/rest/push*`, `/healthz`, `/rest/telemetry/*` | `.env` → `N8N_EDITOR_USER` / `N8N_EDITOR_HASH` (cada `$` del hash bcrypt va duplicado: `$$`) | `OPTICA · Caddy basic auth · Candado del editor n8n` | ✅ creada 22/10/2026 |
| Cuenta propietaria de n8n | Login del editor de n8n | Base de datos de n8n | `OPTICA · n8n · Login del editor` | ❓ confirmar nombre de la entrada |
| Clave de cifrado de n8n | Cifra las credenciales guardadas en n8n. **Si se pierde, todas las credenciales de n8n quedan ilegibles. No rotar a la ligera** (obliga a recrear todas las credenciales) | `.env` (`N8N_ENCRYPTION_KEY`), coincide con `/home/node/.n8n/config` en el volumen de n8n. Copia fuera de AWS en el gestor | `OPTICA · n8n · Encryption key` | ✅ respaldada 22/10/2026 |
| Contraseña de Postgres | Base de datos de Owly (pgvector) | `.env` (`POSTGRES_PASSWORD`) | `OPTICA · Postgres · Base de Owly` | ❓ |
| Respaldos diarios a S3 | `/etc/cron.d/optica-backup` → `/usr/local/bin/backup-optica.sh` a las 02:00 Bogotá (07:00 UTC); log en `/var/log/backup-optica.log`. Bucket privado, cifrado, con versionado y ciclo de vida | Sin access keys: usa el rol IAM de la instancia. El nombre del bucket vive en `.env` (`BACKUP_BUCKET`) desde el 26/10/2026 | — (no tiene secreto propio) | ✅ probado 26/10/2026 |
| Latido del backup | Webhook de n8n que avisa al watchdog que el backup corrió | `.env` (`BACKUP_HEARTBEAT_URL`). No es una clave, pero el endpoint no exige autenticación: no publicarlo | — | ✅ |
| API de n8n / MCP | Conector MCP de n8n usado por Claude | Configuración de n8n (token MCP) | `OPTICA · n8n MCP · Conector Claude` | ❓ |

## 2. Credenciales guardadas en n8n

| Nombre en n8n | Tipo | Para qué sirve | Origen del secreto | Entrada en el gestor | Estado |
|---|---|---|---|---|---|
| WhatsApp account | WhatsApp API | Owly envía mensajes (Cloud API) | Token **permanente** del usuario del sistema `bot-optica` (Meta Business) | `OPTICA · Meta bot-optica · Token WhatsApp Owly` | ✅ |
| WhatsApp OAuth account | WhatsApp Trigger | Trigger de WhatsApp | App `optica-faq-bot` (App ID / App Secret) | `OPTICA · Meta app optica-faq-bot · App secret` | ❓ confirmar si se usa |
| Meta Graph API - bot-opticasocial | Facebook Graph API | Publicación automática en Facebook e Instagram | Token del usuario del sistema `bot-opticasocial` | `OPTICA · Meta bot-opticasocial · Token publicación` | ✅ |
| DualHook Outbound | Header Auth | Salida hacia Dualhook | Panel de Dualhook | `OPTICA · Dualhook · Header outbound` | ❓ |
| Anthropic account | Anthropic API | Owly (Haiku) y generación de copy | Consola de Anthropic | `XYBORG-INTERNO · Anthropic · API key óptica` | ❓ |
| Google Gemini - optica-imagenes | Gemini API | Generación de imágenes (Nano Banana) | Google AI Studio / Cloud | `OPTICA · Gemini · Imágenes` | ❓ |
| AWS S3 - optica-social-media | AWS | Subir imágenes públicas para Instagram | ❓ access keys de un usuario IAM dedicado | `OPTICA · AWS S3 · Imágenes redes` | ❓ confirmar usuario IAM y permisos mínimos |
| Postgres account | Postgres | Memoria y registros de Owly | Misma contraseña que `.env` | ver sección 1 | ✅ |
| Telegram account | Telegram API | Avisos a la óptica, revisión de borradores y alertas | Token del bot (BotFather) | `OPTICA · Telegram · Bot avisos` | ❓ confirmar nombre del bot |
| Notion account | Notion API | Banco de Contenido | Integración interna de Notion | `OPTICA · Notion · Integración Banco de Contenido` | ❓ |

## 3. Meta Business (portafolio "Óptica Dra. Milena Hurtado")

| Activo | Para qué sirve | Acceso | Notas | Estado |
|---|---|---|---|---|
| Usuario del sistema `bot-optica` | Token de Owly (WhatsApp Cloud API) | Admin (se podría bajar a Employee) | Activos: app `optica-faq-bot`, WhatsApp account del número de la óptica | ✅ |
| Usuario del sistema `bot-opticasocial` | Token de publicación en redes | Employee | Activos: página de Facebook, app `optica-social-publisher`, Instagram (Contenido y Estadísticas) | ✅ |
| Messaging account "Mensajería Owly – Producción" | Lado Cloud API (Owly) | — | Sin método de pago (necesario para plantillas en Fase 3) | ✅ |
| Messaging account "Óptica Dra Milena Hurtado" | Lado App de WhatsApp Business (celular) | — | Con método de pago | ✅ |
| Administrador del portafolio | Gestión de Meta Business | ❓ cuentas personales con rol admin | Documentar quién es admin además de Vladt | ❓ |

## 4. Sitio web y presencia

| Credencial | Para qué sirve | Dónde | Entrada en el gestor | Estado |
|---|---|---|---|---|
| Panel del hosting | SSL y archivos del sitio (hosting gratuito incluido en el plan de internet Claro de la óptica) | ❓ | `OPTICA · Hosting Claro · Panel` | ❓ **pendiente ubicar** |
| WordPress (`/wp-admin`) | Editar contenido del sitio | `opticamilenahurtado.com/wp-admin` | `OPTICA · WordPress · Admin sitio` | ❓ **pendiente ubicar** |
| DNS / registrador del dominio | Registros DNS de `opticamilenahurtado.com` | ❓ | `OPTICA · Dominio · DNS` | ❓ |
| DNS de `xyborgautomation.com` | Registro de `bot.xyborgautomation.com` | ❓ | `XYBORG-INTERNO · Dominio · DNS` | ❓ |
| Google Business | Horario oficial y ficha de la óptica | Google | ❓ | ❓ |
| Monitor externo del healthcheck | Vigila el healthcheck del bot | ❓ | ❓ | ❓ |
| GitHub `optica-bot-stack` | Código del stack | GitHub | `XYBORG-INTERNO · GitHub · Cuenta` | ✅ |

---

## Pendientes de este inventario

- [ ] Completar los ❓
- [x] Respaldar `N8N_ENCRYPTION_KEY` fuera del servidor (22/10/2026)
- [ ] Revisar si `bot-optica` puede bajar de Admin a Employee
- [ ] Revisar permisos mínimos del usuario IAM de S3 de imágenes
- [ ] Probar una restauración real desde el backup de S3
