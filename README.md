# 👓 Óptica WhatsApp FAQ Bot

Bot de WhatsApp que responde las preguntas frecuentes de los pacientes de una óptica
(horarios, precios, marcas de monturas) usando IA con RAG, autoalojado en AWS.
Diseñado con una regla innegociable: **nunca da consejo clínico** — cualquier consulta
médica se deriva al optómetra.

> Estado: 🟢 Infraestructura montada y funcionando · 🟡 Lógica del bot en construcción

---

## 🎯 Qué hace (y qué no)

- ✅ Responde FAQ: horarios, precios del examen visual, marcas disponibles.
- ✅ Deriva al optómetra ante cualquier síntoma o consulta clínica (guardrail de seguridad).
- ❌ No agenda citas ni consulta inventario (fuera del alcance del MVP).
- ❌ No diagnostica ni da recomendaciones médicas.

## 🏗️ Arquitectura

```
Paciente (WhatsApp)
      │
      ▼
WhatsApp Cloud API (Meta)
      │
      ▼
Caddy (HTTPS automático, Let's Encrypt)
      │
      ▼
n8n (orquestador)  ──►  RAG sobre pgvector (base de conocimiento de la óptica)
      │                        + guardrail clínico
      ▼
Claude (Anthropic API) redacta la respuesta
```

Todo corre en una sola instancia EC2 con Docker Compose.

## 🧰 Stack tecnológico

| Capa | Tecnología |
|------|-----------|
| Orquestación | n8n (self-hosted) |
| RAG / Vector store | pgvector sobre PostgreSQL |
| Modelo de lenguaje | Claude (Anthropic API) |
| Canal | WhatsApp Cloud API |
| Reverse proxy / TLS | Caddy (Let's Encrypt automático) |
| DNS (MVP) | sslip.io (gratis, sobre Elastic IP fija) |
| Infraestructura | AWS EC2 (`t3.micro`) + EBS + Elastic IP |
| Acceso seguro | AWS Systems Manager (SSM) Session Manager — sin puerto 22 |
| Contenedores | Docker + Docker Compose |

## ✅ Requisitos previos

- Cuenta de AWS con una instancia EC2 (Ubuntu) y una Elastic IP asociada.
- Docker y Docker Compose en la instancia.
- Un dominio que resuelva a la IP (para el MVP usamos `<IP>.sslip.io`, gratis).
- Acceso a la instancia vía SSM Session Manager.

## 🚀 Despliegue (resumen)

```bash
# 1. Clona el repo en la instancia
git clone <URL-del-repo> optica-bot-stack && cd optica-bot-stack

# 2. Genera el .env con secretos aleatorios (te pide el dominio)
bash setup.sh

# 3. Levanta el stack
docker compose up -d

# 4. Verifica
docker compose ps
docker compose logs -f caddy   # espera "certificate obtained successfully"
```

Luego abre `https://<tu-dominio>` y crea la cuenta de dueño de n8n.

## 🔐 Seguridad

- **Sin puerto 22 abierto:** el acceso es por SSM Session Manager (agente saliente, sin puertos de entrada).
- **Mínimo privilegio:** usuario IAM acotado solo a las acciones SSM necesarias.
- **Secretos fuera del repo:** `.env`, llaves y tokens están en `.gitignore`. Solo se versiona `.env.example`.
- **HTTPS obligatorio:** Caddy gestiona el certificado TLS automáticamente.

## 📁 Estructura del repo

```
.
├── docker-compose.yml   # n8n + Postgres/pgvector + Caddy
├── Caddyfile            # reverse proxy + HTTPS automático
├── .env.example         # plantilla de variables (sin secretos)
├── setup.sh             # genera .env con secretos aleatorios
├── .gitignore           # protege secretos y datos de runtime
└── README.md
```

---

## 🐞 Gotchas & Lecciones aprendidas

Registro honesto de los obstáculos al montar la infraestructura y cómo se resolvieron.
La parte más valiosa del proyecto para entender *cómo se debuggea* infra real.

### Acceso y conexión

**EC2 Instance Connect / SSH fallaban.** La regla del puerto 22 estaba atada a "My IP",
pero el navegador conecta desde el rango de AWS, y mi IP residencial es dinámica (apago el
router cada noche). → Migrado a **SSM Session Manager** y puerto 22 cerrado.
*Lección: con IP dinámica, usa un agente saliente (SSM) en vez de pelear con reglas de IP entrante.*

**AWS CLI v2 — efecto dominó.** `unzip` no estaba instalado en WSL; al fallar la
descompresión, todos los pasos siguientes cayeron en cadena.
*Lección: lee el log de arriba abajo e identifica el primer error real.*

**El plugin de Session Manager es aparte.** `aws ssm start-session` falla aunque el CLI esté
instalado, si falta el `session-manager-plugin`.

### IAM y permisos

**Access Keys ≠ contraseña de la consola.** Son credenciales de máquina que se generan en
IAM. → Usuario dedicado (`vladt-cli`) con permisos acotados; nunca las llaves de root.

**⭐ El gotcha estrella — campo de cuenta en ARNs de documentos SSM.** Los documentos
gestionados por AWS (prefijo `AWS-`, ej. `AWS-StartSSHSession`) usan el campo de cuenta
**vacío** en el ARN (`...ssm:us-east-1::document/...`). Los creados en tu cuenta
(prefijo `SSM-`) **sí** llevan el account ID. Confundir esto causó dos `AccessDenied`
opuestos. *Lección: el prefijo del documento te dice si el ARN lleva account ID o no.*

**Un usuario acotado no puede leerse a sí mismo.** `aws iam list-attached-user-policies` dio
`AccessDenied` — comportamiento correcto del mínimo privilegio, no un error.

**`scp` sobre SSM necesita permiso extra.** Usa el documento `AWS-StartSSHSession`, distinto
del de las sesiones interactivas.

### Llaves SSH y entornos

**`Permission denied (publickey)`.** La llave pública nunca había quedado en el
`authorized_keys` de la instancia (un `echo` se ejecutó por error en WSL en vez de en el
servidor). *Lección: el prompt es la brújula — `vladt@VladtTempest` = local,
`ubuntu@ip-...` = servidor. Míralo antes de cada comando con efectos.*

**`ssh-keygen` ofreciendo sobreescribir.** Responder `n`: nunca sobreescribas una llave
existente sin saber que nadie la usa.

### Almacenamiento y costos

**Disco lleno al bajar n8n** (`no space left on device`). El EBS por defecto (8 GB) es
insuficiente. → `Modify volume` a 30 GB + `growpart` + `resize2fs` (en caliente).
*Lección: agrandar el volumen en AWS no expande el filesystem solo.*

**Elastic IP huérfana = cobro silencioso.** AWS cobra las Elastic IP no asociadas a una
instancia corriendo. → Liberar las que no se usen.

**Swap en `t3.micro`.** 1 GB de RAM es justo; un swapfile de 2 GB amortigua los picos sin
caídas por OOM.

### DNS y certificados

**⭐ El boss final — Caddy + Let's Encrypt + DuckDNS.** El certificado no se emitía:
`During secondary validation: DNS problem: query timed out`. Let's Encrypt valida desde
múltiples perspectivas globales, y los nameservers gratuitos de DuckDNS respondían de forma
inconsistente (reproducido con `dig @1.1.1.1` ✅ vs `dig @8.8.8.8` ❌). → Migrado a
**sslip.io**; certificado emitido al primer intento.
*Lección: si LE falla por "secondary validation DNS timeout" pero tu servidor es alcanzable,
sospecha del proveedor de DNS. Verifícalo con `dig` contra varios resolvedores públicos.*

**`502 connection refused` tras emitir el certificado.** Caddy ya estaba listo, pero n8n aún
arrancaba (creando tablas en Postgres). Transitorio, no un error de config.

---

## 🗺️ Roadmap

- [x] Infraestructura: EC2 + SSM + Docker + HTTPS
- [ ] Conectar WhatsApp Cloud API a n8n
- [ ] RAG sobre pgvector con las FAQ reales de la óptica
- [ ] Guardrail clínico (derivar consultas médicas al optómetra)
- [ ] Conectar Claude como modelo de respuesta
- [ ] CI/CD: GitHub Actions + SSM SendCommand para auto-deploy
- [ ] Migrar de sslip.io a un dominio propio (una línea: variable `DOMAIN`)

## 📄 Licencia

Por definir.
