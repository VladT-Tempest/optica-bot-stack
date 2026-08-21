# 🦉 optica-bot-stack — Owly, asistente de WhatsApp para una óptica

**🇪🇸 Español** · [🇬🇧 English](README.en.md)

> ℹ️ Los datos del cliente (nombre comercial, dirección, teléfono y personal) se han **anonimizado** en esta documentación. La arquitectura, el código y los aprendizajes son los reales.

Bot de WhatsApp en **producción** para una óptica real en Colombia. Atiende pacientes por el **número oficial del negocio** mediante **coexistencia** (la app de WhatsApp Business y la Cloud API conviven en el mismo número): el equipo humano atiende en horario laboral desde la app, y **Owly** 🦉 —el asistente virtual con IA— atiende cuando la óptica está cerrada.

> Proyecto real, con cliente real, corriendo 24/7 sobre una sola instancia EC2 ARM. Este README documenta la arquitectura, las decisiones de diseño y —sobre todo— la **bitácora de problemas reales** encontrados y resueltos en el camino a producción.

---

## Arquitectura

```
Paciente (WhatsApp) ⇄ Meta Cloud API
                          │  webhooks (directo, Webhook Override)
                          ▼
      Caddy (HTTPS, dominio propio) ─→ n8n (4 workflows)
                                      │
              ┌───────────────────────┼──────────────────────────┐
              ▼                       ▼                          ▼
      Postgres (pgvector)      Claude Haiku 4.5           Telegram Bot API
      · memoria de chat        (Anthropic API)            · handoff a humano
      · sesiones/estado        cerebro conversacional     · paciente sin atender
      · lista de personal                                 · fallos de workflow
      · festivos oficiales
                          envío de respuestas
                                      │
                                      ▼
                     Dualhook (BSP · api.dualhook.com) ─→ Meta ─→ Paciente
```

- **Infraestructura:** AWS EC2 **t4g.small (ARM/Graviton, 2 GiB)** · Ubuntu arm64 · Docker Compose (Caddy + n8n + Postgres/pgvector) · volumen gp3 de 30 GB · **dominio propio** con TLS automático (migrado desde sslip.io sin downtime, ver bitácora) · acceso por SSM Session Manager (sin SSH). El proyecto arrancó en una t3.micro; la migración a ARM está en la Fase 5.
- **Coexistencia:** [Dualhook](https://dualhook.com) (Meta Tech Partner) habilita el Embedded Signup y el **Webhook Override**: los mensajes entrantes van **directo de Meta a n8n** (Dualhook no almacena mensajes); el envío sale por la API de Dualhook con una key propia.
- **Recepción gratuita:** el bot solo responde dentro de la ventana de servicio de 24 h de Meta (conversaciones iniciadas por el paciente) → costo de mensajería ≈ $0 a este volumen.

## Funcionalidades del bot

| Área | Detalle |
|---|---|
| **Identidad** | Se presenta siempre como *Owly, el asistente virtual* — nunca se hace pasar por humano ni por personal clínico. |
| **FAQ** | Horarios, precios, marcas, medios de pago, ubicación — solo desde una base de conocimiento curada (cero invención). |
| **Guardrail clínico** | Regla inquebrantable: no diagnostica ni opina sobre síntomas; deriva a consulta presencial. |
| **Citas** | Valida fecha/hora contra franjas reales (incluye cierre de mediodía y última cita 1 h antes del cierre, con fecha actual inyectada en zona `America/Bogota`). **No agenda**: registra la solicitud y un asesor confirma. |
| **Captura de datos** | Plantilla de agendamiento con **enlace a la política de privacidad ANTES de pedir datos** (Ley 1581). Distingue paciente nuevo vs. existente. Sin datos sensibles por chat (p. ej. grupo sanguíneo → se toma presencial). |
| **Memoria por paciente** | Historial en Postgres por número, con **sesiones con caducidad**: `new` / `returning` / `continuing` (rotación de session key → un paciente que vuelve meses después no arrastra contexto viejo). |
| **Handoff a humano** | Escala por: multimedia (fórmulas, comprobantes), petición explícita de asesor, o consultas de estado que solo el equipo conoce (marcador `##HANDOFF##` emitido por el LLM y detectado en n8n). Alerta por **Telegram** y pausa el bot 24 h **por paciente**. |
| **Anti-cruce (echo-pausa)** | Si un humano responde desde la app, el webhook echo pausa al bot 2 h para ese paciente. Bot y asesor nunca se pisan. |
| **Gate de horario** | El bot solo conversa **fuera del horario de atención**; en horario, el equipo atiende desde la app (alertas de Telegram activas siempre). |
| **Festivos automáticos** | Los 18 festivos colombianos se sincronizan solos desde la API pública **Nager.Date**, con los traslados de la Ley Emiliani ya aplicados (verificado en producción: la Asunción de 2026 llegó como lunes 17 de agosto, no como sábado 15). Un festivo cuenta como día cerrado: el bot **sí atiende** (el equipo no está) y **nunca agenda** citas en esa fecha. Cero mantenimiento manual. |
| **De quién es el turno** | Cada 15 min, un workflow mira `last_seen` vs. `last_outbound_at` y decide: si la pelota es **nuestra** y lleva 30 min parada, alerta al equipo por Telegram; si la pelota es **del paciente** y lleva 6 h, envía la despedida y cierra la sesión. Una sola consulta decide ambos caminos. |
| **Alertas de fallo** | Un *Error Workflow* central recoge cualquier excepción de los tres workflows productivos y la manda por Telegram con el nodo que falló, el mensaje y el enlace directo a la ejecución. Antes, un cron roto se descubría por casualidad. |
| **Personal interno** | Números del equipo en tabla `optica_staff` (Postgres, **fuera del repo** por privacidad) → el bot los ignora por completo. |
| **Formato WhatsApp** | Regla de estilo + saneo programático `**`→`*` para que la negrita renderice bien en WhatsApp. |

## Modelo de datos (Postgres)

```sql
optica_chat_history   -- memoria conversacional (Postgres Chat Memory de n8n), indexada por session key rotativa "wa_id:N"
optica_sessions       -- estado por paciente: first_seen, last_seen, last_outbound_at, visit_count, current_session,
                      --   mode (bot|human), handoff_until, alerted_at, farewell_at, wa_user_id (BSUID de Meta)
optica_staff          -- números internos que el bot ignora (privacidad: viven en BD, no en el workflow ni el repo)
optica_festivos       -- festivos oficiales de Colombia (fecha PK, nombre); poblada automáticamente desde Nager.Date
```

`SessionCheck` es una sola consulta que hace todo el trabajo de estado: upsert de la sesión, cálculo de `new/returning/continuing`, rotación de session key, `human_active`, `es_festivo` y la lista de festivos próximos. Una fuente de verdad para los gates y para el prompt.

## Workflows n8n

1. **`optica-faq-bot`** (principal): Webhook (GET verificación + POST mensajes) → filtro (mensaje real + no-echo + no-staff) → `SessionCheck` (upsert de sesión + detección new/returning/continuing + `human_active`) → gate modo-humano → gate texto/no-texto → gate de horario → **AI Agent** (Claude Haiku 4.5 + Postgres Chat Memory) → detección `##HANDOFF##` → envío vía Dualhook. Ramas paralelas: escalamiento multimedia y echo-pausa.
2. **`optica-cierre-inactividad`**: Schedule cada 15 min → una consulta que clasifica cada sesión en `alertar` o `cerrar` → `Switch` → Telegram (paciente sin atender hace 30 min) o despedida vía Dualhook (paciente sin responder hace 6 h). Los dos umbrales miden cosas distintas a propósito; ver la Fase 5 de la bitácora.
3. **`optica-sync-festivos`**: Schedule mensual → Code (año actual + siguiente) → HTTP Request a `date.nager.at` → upsert idempotente en `optica_festivos`. Mensual y no anual a propósito: si una corrida falla, se recupera sola al mes siguiente.
4. **`optica-error-handler`**: `Error Trigger` → Telegram. No tiene disparador propio: n8n lo invoca cuando cualquiera de los tres workflows anteriores lanza una excepción (Settings → Error Workflow). Es la única razón por la que un fallo nocturno se entera alguien.

Los cuatro llevan **sticky notes en el propio lienzo** con la lógica de cada rama y las trampas conocidas: el manual de operación no siempre está a mano cuando algo se rompe a las 2 a. m.

### Capturas del canvas

| Workflow | Vista |
|---|---|
| `optica-faq-bot` | ![Canvas del workflow principal](docs/optica-faq-bot.png) |
| `optica-cierre-inactividad` | ![Canvas del cierre por inactividad](docs/optica-cierre-inactividad.png) |
| `optica-sync-festivos` | ![Canvas de la sincronización de festivos](docs/optica-sync-festivos.png) |
| `optica-error-handler` | ![Canvas del manejador de errores](docs/optica-error-handler.png) |

## Qué hay (y qué no) en este repositorio

Este repositorio es **documentación de arquitectura**, no un despliegue listo para ejecutar.

**Incluye:** este README, el prompt del sistema en versión de ejemplo (`docs/system_prompt_bot.example.md`), la configuración de infraestructura (`docker-compose.yml`, `Caddyfile`), las migraciones de base de datos y las capturas de los workflows.

**No incluye —a propósito—:** los JSON de los workflows con la configuración real, credenciales, tokens, números de teléfono ni la base de conocimiento del cliente. Esos viven en un repositorio privado y en el servidor. El repositorio público **no es un respaldo**: los respaldos son snapshots de EBS y dumps de Postgres fuera de Git.

## Seguridad y privacidad

- Token **permanente** de Usuario del Sistema de Meta (nada de tokens de 24 h).
- El LLM **no escribe SQL**: toda consulta va por nodos Postgres parametrizados.
- Política de privacidad pública (HTTPS vía GitHub Pages) conforme a **Ley 1581 de 2012** y Decreto 1377: responsable identificado, datos sensibles, menores, plazos de consulta/reclamo. Consentimiento informado **antes** de la captura de datos.
- Dualhook con arquitectura de **cero almacenamiento de mensajes** (webhooks directos Meta→servidor propio).
- Números del personal y credenciales fuera del repositorio (BD + credenciales de n8n).
- Separación deliberada entre **portafolio** (este repo, público y anonimizado) y **operación** (repo privado + servidor). Un mismo artefacto no puede ser a la vez vitrina y respaldo.

---

## 🪖 Bitácora de guerra: problemas reales y sus soluciones

Documentar lo que salió mal vale más que lo que salió bien. Todo esto pasó de verdad.

### Fase 1 — Infraestructura y Cloud API
| Problema | Causa raíz | Solución |
|---|---|---|
| Let's Encrypt fallaba con DuckDNS | Resolución DNS global inconsistente | Migrar a **sslip.io** (resuelve siempre a la IP embebida) |
| Disco lleno al hacer `docker pull` en t3.micro | 8 GB por defecto + imágenes pesadas | `growpart` + `resize2fs` a 30 GB + swapfile de 2 GB |
| Webhook de n8n no se registraba solo | Auto-registro poco confiable | **Dos nodos webhook manuales** (GET verificación + POST mensajes) con el mismo path |
| Meta no entregaba mensajes al webhook | WABA suscrita a la app interna de Meta, no a la propia | `POST` manual a `subscribed_apps` con la app correcta |
| "Prompt required" persistente en n8n | El campo de prompt requiere elegir "Define below" antes de aceptar expresiones | Seleccionar el modo del campo **antes** de pegar la expresión |
| El bot moría cada 24 h | Token temporal de Meta | **Usuario del Sistema** con token sin expiración (no requiere verificación del negocio) |

### Fase 2 — Memoria e inteligencia
| Problema | Causa raíz | Solución |
|---|---|---|
| Basic LLM Chain no soporta memoria | Por diseño: "None of the chain nodes support memory" (docs n8n) | Migrar a **AI Agent** + sub-nodo **Postgres Chat Memory** |
| `localhost` en la credencial Postgres no conectaba | Dentro del contenedor, localhost = el propio n8n | Usar el **nombre del servicio** del compose (`postgres`) como host |
| El envío quedó vacío tras migrar a AI Agent | El chain devuelve `text`; el Agent devuelve `output` | Actualizar la referencia en el nodo de envío |
| Saludo repetido / contexto rancio de hace meses | Memoria plana por número | **Sesiones con caducidad** y rotación de session key (`wa_id:N`) + estados new/returning/continuing |
| El bot aceptaba citas a la 1:00 p. m. | No sabía la fecha actual ni el cierre de mediodía | Inyectar `$now` en zona Bogotá al prompt + franjas de inicio válidas explícitas |
| Pacientes creían hablar con la profesional de la salud visual | El bot no se identificaba | Identidad **Owly** obligatoria en saludos + prohibido hacerse pasar por humano |
| "Un asesor te responde *enseguida*" (falso fuera de horario) | Redacción optimista del prompt | Regla: prohibido prometer tiempos; fórmula fija "tan pronto como le sea posible" |
| El bot decía "te agendo" (no puede agendar) | Prompt ambiguo | Regla: el bot **solo registra la solicitud**; el asesor confirma disponibilidad y agenda |

### Fase 3 — Coexistencia (la saga)
| Problema | Causa raíz | Solución |
|---|---|---|
| La coexistencia no aparece en el panel de Meta para apps propias | Meta la reserva al **Embedded Signup de un BSP/Tech Partner** | Evaluar BSPs → elegir **Dualhook** ($12/mes, webhook override, sin almacenar mensajes, cancelable) |
| "Agregar número" en el panel de developers pedía OTP | Ese flujo es **migración** (saca el número de la app), no coexistencia | Abortar y usar solo el Embedded Signup del BSP |
| El popup de Meta terminaba pero Dualhook mostraba "0 connections" (×2) | El *handoff* de regreso del popup al tab original era bloqueado por el navegador | Ver fila siguiente 👇 |
| Retry fallaba con `#2388002` (eligibility) | El número quedó **medio-conectado** del intento anterior | **Desconectar la conexión de plataforma en la app** → esperar 15 min → reintentar |
| El handoff seguía fallando en Firefox "limpio" | **Total Cookie Protection** de Firefox rompe el OAuth cross-site incluso con el escudo apagado | Navegador **Chromium (Edge)** + **McAfee WebAdvisor desactivado** + cookies de terceros + popups permitidos + pestaña original abierta → ✅ a la tercera |
| Sitios de BSPs "caídos" solo en el PC | McAfee (WebAdvisor/VPN) bloqueando dominios | Diagnóstico con hosts limpio + prueba externa; desactivar/reiniciar. *Moraleja: verificar desde otra red antes de descartar un proveedor* |
| El bot recibía pero no respondía (post-migración) | El campo JSON del HTTP Request recibía un objeto JS → `[object Object]` | Envolver el body en **`JSON.stringify(...)`** |
| Seguía sin ser JSON válido | Un `=` sobrante al inicio de la expresión (el campo ya estaba en modo expresión) | Quitar el `=` literal |
| El bot le respondía al asesor | Los **echoes** (mensajes del propio negocio) entraban como mensajes | Filtro `from ≠ número del negocio` + rama echo separada |
| `EchoPausa` fallaba con "no parameter $1" | A esa rama también llegaban eventos `statuses` sin número | Gate `EsEcho` (`Array.isArray(value.message_echoes)`) antes del UPDATE |
| Salud de Meta en "BLOCKED" para envíos | Método de pago con error en la WABA (bloquea solo **plantillas** iniciadas por el negocio) | No afecta respuestas de servicio (el caso de uso actual); corregir método de pago cuando se activen recordatorios |

### Fase 4 — Refinamiento con uso real
| Problema | Causa raíz | Solución |
|---|---|---|
| Bot y asesor se cruzaban en una misma conversación | Ambos activos a la vez | **Gate de horario** (bot solo con la óptica cerrada) + **echo-pausa** de 2 h por paciente |
| Negrita con asteriscos visibles (`*texto*`) | El LLM emitía Markdown `**` que WhatsApp no renderiza | Regla de formato WhatsApp en el prompt + saneo `replace(/\*\*/g,'*')` en el envío |
| El bot le respondía al propio personal de la óptica | Sus números personales no se distinguían de los de un paciente | Tabla **`optica_staff`** en Postgres (números fuera del repo) + gate al inicio del flujo |
| Conversaciones quedaban "abiertas" para siempre | Sin política de cierre | Workflow de **despedida a la hora de inactividad** (una vez, `farewell_at`). *Rediseñado en la Fase 5: una hora sin distinguir de quién era el turno resultó ser el problema siguiente* |
| Riesgo de exponer números personales en el repo | Condiciones hardcodeadas en el workflow | Mover la lista a la BD; checklist de saneo del JSON antes de publicar |
| **Festivos: el peor escenario silencioso** | El gate de horario solo miraba día y hora → un festivo se trataba como día laboral: el bot callaba **y** el equipo no estaba → paciente sin respuesta de nadie | Tabla `optica_festivos` + `es_festivo` en `SessionCheck` + `&& !es_festivo` en ambos gates |
| Owly no avisaba del festivo aunque el gate ya funcionaba | Se le pasaba una *lista* de fechas y se esperaba que él dedujera si hoy estaba incluida (aritmética de fechas = frágil). Además, el festivo de prueba se llamaba "PRUEBA — borrar" y el modelo lo descartó como artefacto | Inyectar un **indicador explícito** `¿HOY ES FESTIVO?: SÍ/No` desde el booleano de la BD + instrucción de confiar en él aunque el nombre parezca de prueba |
| Mantenimiento anual de festivos (fácil de olvidar) | Lista manual año a año | Workflow de sync con **Nager.Date** (API pública, sin auth) → se auto-alimenta para siempre |
| Sospecha de bug al ver el flujo morir en "Bot en silencio" | Los gates están en serie: el primero que aplica corta el flujo (una pausa por-paciente gana antes de evaluar el horario) | No es bug: es defensa en profundidad. El `human_active` visible en el output de `SessionCheck` explica cada camino |

### Fase 5 — Auditoría y observabilidad (agosto 2026)

La fase en la que dejamos de arreglar lo que fallaba y empezamos a buscar lo que fallaba **en silencio**.

| Problema | Causa raíz | Solución |
|---|---|---|
| **El anti-cruce nunca funcionó en producción.** Cada vez que un asesor respondía desde la app, Owly seguía contestando en paralelo | Meta está migrando a **Business-Scoped User IDs**: el payload del echo trae `to_user_id` y el teléfono (`to`) puede no venir. El `UPDATE` emparejaba solo por teléfono → afectaba **0 filas, sin lanzar error** | Columna `wa_user_id` + emparejar por BSUID con el teléfono como respaldo: `WHERE wa_user_id = $1 OR ($2 != '' AND wa_id = $2)`. Confirmado después con 6 ejecuciones reales (1 fila afectada en todas) |
| Tres nodos más tenían la misma exposición y nadie lo sabía | El patrón se había corregido **dos veces de forma reactiva**: solo el nodo que reventó cada vez | Exportar todos los workflows (`n8n export:workflow --all`) y revisar con `jq` **todos** los nodos Postgres, no solo los sospechosos. Aparecieron 3 más sin tocar |
| 🔴 **Una query se ejecutaba distinta de como se veía en el editor** | Algo entre el editor de n8n y la ejecución aplica un limpiador de etiquetas HTML (un `<[^>]*>` de manual) y **borra todo lo que haya entre un `<` y el siguiente `>`**. El editor sigue mostrando el texto íntegro | Reescribir las queries **sin ningún `<`** (`a < b` ≡ `b > a`). En SQL eso obliga además a usar `!=` en vez del `<>` natural, que empieza por `<` y se lo comería entero |
| "Voltear todos los `<`" casi borra medio `SessionCheck` | El limpiador necesita un **par**: un `<` de apertura y un `>` de cierre. Una query con `<` y sin ningún `>` posterior es inofensiva — y añadir un `>=` "por seguridad" le da justo el cierre que le faltaba | La regla no es *voltea los `<`*, es **que no exista un par `<…>`**. Contar `<` y `>` en orden de aparición antes de tocar un nodo. *Una mitigación aplicada sin entender el mecanismo puede activar justo lo que pretendía evitar* |
| Una expresión editada quedó corrupta sin lanzar ningún error | Pegar `={{ ... }}` en un campo que la UI ya tiene en modo *Expression* deja ese `=` como carácter literal, y n8n añade el suyo al guardar → el JSON exportado dice `"=={{ ... }}"` | Re-exportar y comparar el JSON contra un nodo de referencia después de cada edición. *"Se ve bien en el editor" no es una verificación* |
| El cierre por inactividad despedía a pacientes que estaban esperando respuesta | El umbral de 1 h medía "no pasó nada", sin distinguir **de quién era el turno** | Rediseño de dos caminos sobre una sola consulta: `alertar` a los 30 min si la pelota es nuestra, `cerrar` a las 6 h si es del paciente |
| Una caída de 25 min se detectó porque alguien estaba mirando la pantalla en ese momento | n8n no avisa por defecto cuando un workflow falla | **Error Workflow** central → Telegram con el workflow, el nodo que falló, el mensaje, la hora en Bogotá y el enlace directo a la ejecución |
| El Error Workflow "no servía": se probaba y no llegaba nada | Las ejecuciones manuales (`Execute step`, `Test workflow`) **no lo disparan**. Solo una ejecución real vía el disparador propio del workflow, estando *Published* | Probarlo con un workflow desechable de un nodo (`Code` con `throw new Error(...)`) disparado desde su **URL de producción**, no desde el editor |
| Migrar de máquina con el hostname en `sslip.io` era una ruleta | Let's Encrypt no puede validar el hostname nuevo hasta que la IP ya apunte ahí, y el límite de 5 certificados por hostname cada 168 h puede dejar el bot caído una semana | Mover a **dominio propio antes de necesitarlo**: registro A (en *DNS only*, el proxy rompe el reto HTTP-01) + bloque adicional en el `Caddyfile` → los dos dominios sirven a la vez y el cutover ocurre cuando el tráfico real ya lo confirmó |
| La t3.micro se quedó corta con **un solo cliente** | 605 MB de RAM usados sobre 909 MB disponibles y 542 MB en swap: el conjunto de trabajo rondaba 1,15 GB contra 1 GiB físico | Migrar a **t4g.small (ARM/Graviton, 2 GiB)**. Se descartó a propósito el `stop → change type → start` a una t3.small, que habría costado 5 minutos en vez de una tarde — ver la fila siguiente 👇 |
| Los backups corrían desde hacía meses y **nunca se había restaurado ninguno** | Se veían tres artefactos en S3 cada noche. Nadie había reconstruido nada a partir de ellos: un backup no verificado es una hipótesis, no un respaldo | Se eligió el camino largo (instancia nueva + restauración completa) precisamente para **forzar esa verificación** mientras el único cliente es de la casa. Primera restauración comprobada en la historia del proyecto |
| 🔴 Tres permisos IAM rotos, descubiertos el mismo día | Los tres del mismo patrón: configurados de forma **reactiva**, solo para el caso de uso que existía en ese momento. La política de SSM atada por ARN a la instancia vieja; el role de S3 con permiso de escritura pero sin `s3:GetObject`; la política de SSM sin el documento `AWS-StartPortForwardingSession` | Ninguno era un agujero de seguridad —el mínimo privilegio hacía exactamente su trabajo— pero sí un **riesgo de disponibilidad invisible hasta que hizo falta**. Solo aparecen al ejercitar rutas nuevas |
| El certificado TLS podía dejar el bot caído una semana en mitad de la migración | Let's Encrypt + hostname atado a la IP (ver dos filas arriba) | Evitado **de raíz**: el dominio propio ya se había migrado el día anterior. La Fase 0 existía precisamente para que este paso resultara aburrido |
| 🔴 La migración terminó "bien" y dejó una bomba de relojería | El cutover apuntó el registro A a la **IP auto-asignada** de la instancia nueva, y la Elastic IP se quedó olvidada en la máquina vieja apagada. Correcto para el *momento* del cutover — el dominio propio existía justamente para eso — pero equivocado como *estado permanente* | Un `stop → change type → start` (el camino de crecimiento a t4g.medium documentado en el propio runbook) habría cambiado la IP y tumbado el bot sin aviso. Se reasoció la Elastic IP a la instancia productiva y se repuntó el DNS: ~2 min de caída, hecho al cierre y con Meta reintentando los webhooks |
| Owly respondió una hora con ~2 h de desfase | Sin diagnosticar. La fecha y el festivo del mismo mensaje salieron correctos, así que parece acotado a la hora | **Abierto.** El nodo `AI Agent` es el único que no ha pasado por la auditoría que sí se hizo a los nodos Postgres |

---

## Lecciones aprendidas (las grandes)

1. **La coexistencia requiere un BSP.** No hay botón self-service en la Cloud API directa. Elegir un BSP con *webhook override* preserva la arquitectura propia (los payloads siguen en formato Meta → rework mínimo).
2. **El navegador importa en los flujos OAuth de Meta.** Antivirus con "web protection", VPNs, Total Cookie Protection y popups bloqueados rompen el Embedded Signup de formas silenciosas. Chromium limpio + cookies de terceros + pestaña original abierta.
3. **Un bot con memoria necesita política de sesiones.** "Recordar todo por número" produce contextos rancios; la rotación de session key con estados new/returning/continuing lo resuelve con una sola tabla.
4. **El LLM no debe prometer lo que el sistema no hace.** "Te agendo" y "enseguida" son bugs de producto, no de modelo: se corrigen con reglas explícitas de rol y de lenguaje.
5. **Los humanos son parte de la arquitectura.** Gate de horario, echo-pausa, staff-list y handoff convierten un chatbot en un **sistema híbrido humano+IA** operable en un negocio real.
6. **Decide en el código, no en el prompt.** Cuando el sistema ya sabe algo con certeza (¿hoy es festivo? ¿está en horario?), pásale al LLM un **booleano explícito**, no datos para que los deduzca. Cada cálculo que se le delega al modelo es un bug latente.
7. **Los calendarios locales son requisitos, no detalles.** Festivos, cierres de mediodía y zonas horarias son reglas de negocio de primera clase: si el bot no las conoce, falla justo los días en que más se nota.
8. **Lo que no avisa, no existe.** Un sistema sin alertas de fallo no es estable: es un sistema donde nadie se entera. La automatización que más valor dio en agosto no la ve ningún paciente — son dos nodos que mandan un mensaje de Telegram cuando algo revienta.
9. **Un fix reactivo no es una auditoría.** Corregir el nodo que falló deja intactos los que van a fallar igual. Cuando aparece un patrón de bug, toca buscarlo en todo el sistema, no solo donde dolió.
10. **Un `UPDATE` que afecta cero filas no es un error.** Los fallos ruidosos se arreglan solos porque alguien los ve. Los caros son los que devuelven éxito: durante semanas el anti-cruce "funcionaba" y no hacía nada.
11. **Un backup no verificado es una hipótesis.** La migración a ARM se hizo por el camino largo —instancia nueva y restauración completa— en vez del `change type` de cinco minutos, justamente para comprobar por primera vez que los backups servían. Elegir el ejercicio difícil mientras el cliente es de la casa vale más que el tiempo que ahorra el atajo.
12. **"Verificado" no es lo mismo que "estable".** La migración a ARM pasó las nueve verificaciones de su runbook, incluida una conversación real de WhatsApp, y aun así dejó producción colgando de una IP efímera. Las pruebas de punta a punta certifican el presente; las dependencias ocultas se cobran la próxima vez que alguien reinicie algo.
13. **Los permisos configurados de forma reactiva caducan en silencio.** Las tres políticas IAM rotas de agosto llevaban meses "funcionando": nadie había ejercitado una instancia nueva, una descarga de S3 ni un port-forwarding. El mínimo privilegio es correcto, pero cada permiso concedido a un recurso concreto es una dependencia oculta que solo se descubre el día que hace falta.

## Roadmap

- [x] Método de pago configurado en la WABA (habilita plantillas cuando se necesiten).
- [x] README bilingüe (ES/EN) para alcance internacional del portafolio.
- [x] **Dominio propio con TLS automático**, migrado desde `sslip.io` sin downtime.
- [x] **Error Workflow** con alertas por Telegram sobre los tres workflows productivos.
- [x] Sticky notes de documentación en el lienzo de los cuatro workflows.
- [x] **Migración a t4g.small (ARM)** con restauración completa verificada; la instancia anterior queda apagada como plan de retorno.
- [ ] Evaluar un swap file en la instancia nueva (la vieja tenía 2 GB; la nueva arrancó sin ninguno).
- [ ] Migrar la lógica de `optica-cierre-inactividad` a una **función de Postgres**: hoy la query sobrevive gracias a la convención "cero `<`", y una convención frágil es deuda, no diseño.
- [ ] Unificar las dos ventanas de handoff (2 h por echo del asesor vs. 24 h por `##HANDOFF##` del modelo).
- [ ] Auditar el nodo `AI Agent` (desfase horario detectado, ver Fase 5).
- [ ] Recuperar el permiso `whatsapp_business_management` en el token (requiere re-correr el Embedded Signup; **aplazado a propósito**: no aporta al alcance actual y el número está en producción).
- [ ] Evaluar **Meta Business Agent** cuando llegue a Colombia (posible reemplazo del BSP).
- [ ] HTTPS para el dominio principal de la óptica (Cloudflare).
- [ ] WhatsApp Flows para captura estructurada de datos de agendamiento.
- [ ] Refactor **multi-tenant** (un solo workflow + tabla `tenants`) para atender varios negocios.

### Descartado (y por qué)

- **Recordatorios automáticos de cita vía la API de Softix** (el software de historias clínicas de la óptica). Técnicamente viable —la API expone citas, pacientes e inventario— y el costo de mensajería de Meta era irrisorio (~$0.17 USD/mes para 8 citas diarias en Colombia). Se descartó porque **el acceso a la API de Softix tiene un costo que no justifica el caso de uso**: hoy el asesor envía los recordatorios manualmente sin fricción. *Lección: verificar el costo de la API del software del cliente ANTES de prometer integraciones.*

---

*Construido con n8n, Claude (Anthropic), Postgres y paciencia. Owly 🦉 atiende cuando la óptica duerme.*
