# 🦉 optica-bot-stack — Owly, a WhatsApp assistant for an optical shop

[🇪🇸 Español](README.md) · **🇬🇧 English**

> ℹ️ Client details (business name, address, phone number and staff) have been **anonymized** in this documentation. The architecture, the code and the lessons are the real ones.

A **production** WhatsApp bot for a real optical shop in Colombia. It serves patients on the **company's official phone number** through **Coexistence** (the WhatsApp Business app and the Cloud API share the same number): the human team answers from the app during business hours, and **Owly** 🦉 —the AI assistant— takes over when the shop is closed.

> A real project, with a real client, running 24/7 on the AWS free tier. This README documents the architecture, the design decisions and —above all— the **war log of real problems** found and fixed on the way to production.

---

## Architecture

```
Patient (WhatsApp) ⇄ Meta Cloud API
                          │  webhooks (direct, Webhook Override)
                          ▼
      Caddy (HTTPS, sslip.io) ─→ n8n (workflow "optica-faq-bot")
                                      │
              ┌───────────────────────┼──────────────────────────┐
              ▼                       ▼                          ▼
      Postgres (pgvector)      Claude Haiku 4.5           Telegram Bot API
      · chat memory            (Anthropic API)            (team alerts)
      · session state          conversational brain
      · staff list
                          outbound replies
                                      │
                                      ▼
                     Dualhook (BSP · api.dualhook.com) ─→ Meta ─→ Patient
```

- **Infrastructure:** AWS EC2 t3.micro · Docker Compose (Caddy + n8n + Postgres/pgvector) · Elastic IP · sslip.io domain · SSM Session Manager access (no SSH).
- **Coexistence:** [Dualhook](https://dualhook.com) (Meta Tech Partner) enables Embedded Signup and **Webhook Override**: inbound messages go **straight from Meta to n8n** (Dualhook never stores message content); outbound goes through Dualhook's API with a connection-scoped key.
- **Free inbound:** the bot only replies inside Meta's 24-hour customer service window (patient-initiated conversations) → messaging cost ≈ $0 at this volume.

## What the bot does

| Area | Detail |
|---|---|
| **Identity** | Always introduces itself as *Owly, the virtual assistant* — never pretends to be a human or a clinical professional. |
| **FAQ** | Hours, prices, brands, payment methods, location — strictly from a curated knowledge base (no hallucinated facts). |
| **Clinical guardrail** | Unbreakable rule: never diagnoses or comments on symptoms; always refers to an in-person consultation. |
| **Appointments** | Validates date/time against real slots (including the midday closure and the "last appointment one hour before closing" rule, with the current date injected in `America/Bogota`). **It does not book**: it registers the request and a human agent confirms. |
| **Data capture** | Booking form with a **link to the privacy policy BEFORE asking for any data** (Colombian Law 1581). Distinguishes new vs. existing patients. No sensitive health data over chat (e.g. blood type → collected in person). |
| **Per-patient memory** | History in Postgres keyed by phone number, with **expiring sessions**: `new` / `returning` / `continuing` (session-key rotation → a patient returning months later doesn't drag stale context). |
| **Human handoff** | Escalates on: media (prescriptions, payment receipts), an explicit request for a human, or status questions only the team can answer (a `##HANDOFF##` marker emitted by the LLM and detected in n8n). Alerts via **Telegram** and pauses the bot for 24 h **for that patient only**. |
| **Anti-collision (echo pause)** | If a human replies from the app, the echo webhook pauses the bot for 2 h for that patient. Bot and agent never talk over each other. |
| **Business-hours gate** | The bot only converses **outside business hours**; during business hours the team answers from the app (Telegram alerts stay on at all times). |
| **Automatic public holidays** | Colombia's 18 public holidays sync themselves from the public **Nager.Date** API (including the Ley Emiliani shifts). A holiday counts as a closed day: the bot **does answer** (the team isn't there) and **never books** appointments on that date. Zero manual upkeep. |
| **Inactivity close-out** | Scheduled workflow: after an hour with no reply it sends a graceful goodbye and closes the session (respecting Meta's 24-hour window). |
| **Internal staff** | Team phone numbers live in an `optica_staff` table (Postgres, **kept out of the repo** for privacy) → the bot ignores them entirely. |
| **WhatsApp formatting** | Style rule plus a programmatic `**`→`*` sanitizer so bold renders correctly in WhatsApp. |

## Data model (Postgres)

```sql
optica_chat_history   -- conversational memory (n8n Postgres Chat Memory), keyed by the rotating session key "wa_id:N"
optica_sessions       -- per-patient state: first_seen, last_seen, visit_count, current_session, mode (bot|human), handoff_until, farewell_at
optica_staff          -- internal numbers the bot ignores (privacy: they live in the DB, not in the workflow or the repo)
optica_festivos       -- Colombian public holidays (date PK, name); auto-populated from Nager.Date
```

`SessionCheck` is a single query that does all the state work: session upsert, `new/returning/continuing` detection, session-key rotation, `human_active`, `es_festivo` and the list of upcoming holidays. One source of truth for both the gates and the prompt.

## n8n workflows

1. **`optica-faq-bot`** (main): Webhook (GET verification + POST messages) → filter (real message + not an echo + not staff) → `SessionCheck` → human-mode gate → text/non-text gate → business-hours gate → **AI Agent** (Claude Haiku 4.5 + Postgres Chat Memory) → `##HANDOFF##` detection → send via Dualhook. Parallel branches: media escalation and echo pause.
2. **`optica-cierre-inactividad`**: Schedule every 15 min → goodbye message to bot sessions idle ≥ 1 h (once only, inside the 24-hour window).
3. **`optica-sync-festivos`**: Monthly schedule → Code (current year + next) → HTTP Request to `date.nager.at` → idempotent upsert into `optica_festivos`. Monthly rather than yearly on purpose: if one run fails, it self-heals the following month.

### Canvas screenshots

| Workflow | View |
|---|---|
| `optica-faq-bot` | ![Main workflow canvas](docs/optica-faq-bot.png) |
| `optica-cierre-inactividad` | ![Inactivity close-out canvas](docs/optica-cierre-inactividad.png) |
| `optica-sync-festivos` | ![Holiday sync canvas](docs/optica-sync-festivos.png) |

## What's (and isn't) in this repository

This repository is **architecture documentation**, not a ready-to-run deployment.

**It includes:** this README, an example version of the system prompt (`docs/system_prompt_bot.example.md`), the infrastructure config (`docker-compose.yml`, `Caddyfile`), the database migrations and screenshots of the workflows.

**It deliberately does not include:** the workflow JSONs with real configuration, credentials, tokens, phone numbers or the client's knowledge base. Those live in a private repository and on the server. This public repo **is not a backup**: backups are EBS snapshots and Postgres dumps kept outside Git.

## Security and privacy

- **Permanent** Meta System User token (no more 24-hour tokens).
- The LLM **never writes SQL**: every query goes through parameterized Postgres nodes.
- Public privacy policy (HTTPS via GitHub Pages) compliant with **Colombian Law 1581 of 2012** and Decree 1377: identified data controller, sensitive data, minors, response deadlines for requests and complaints. Informed consent **before** any data capture.
- Dualhook runs a **zero message storage** architecture (webhooks routed directly from Meta to our own server).
- Staff numbers and credentials stay out of the repository (DB + n8n credentials).
- A deliberate split between **portfolio** (this public, anonymized repo) and **operations** (private repo + server). One artifact cannot be both a showcase and a backup.

---

## 🪖 War log: real problems and how they were fixed

Documenting what went wrong is worth more than documenting what went right. All of this actually happened.

### Phase 1 — Infrastructure and Cloud API
| Problem | Root cause | Fix |
|---|---|---|
| Let's Encrypt failing with DuckDNS | Inconsistent global DNS resolution | Move to **sslip.io** (always resolves to the embedded IP) |
| Disk full during `docker pull` on t3.micro | 8 GB default volume + heavy images | `growpart` + `resize2fs` to 30 GB + a 2 GB swapfile |
| n8n webhook wouldn't self-register | Auto-registration is unreliable | **Two manual webhook nodes** (GET verification + POST messages) sharing the same path |
| Meta wasn't delivering messages to the webhook | The WABA was subscribed to Meta's internal app, not ours | Manual `POST` to `subscribed_apps` with the correct app |
| Persistent "Prompt required" error in n8n | The prompt field requires picking "Define below" before it accepts expressions | Select the field mode **before** pasting the expression |
| The bot died every 24 hours | Meta temporary token | **System User** with a non-expiring token (does not require business verification) |

### Phase 2 — Memory and intelligence
| Problem | Root cause | Fix |
|---|---|---|
| Basic LLM Chain doesn't support memory | By design: "None of the chain nodes support memory" (n8n docs) | Migrate to the **AI Agent** node + **Postgres Chat Memory** sub-node |
| `localhost` in the Postgres credential wouldn't connect | Inside the container, localhost = n8n itself | Use the compose **service name** (`postgres`) as the host |
| Outbound message went empty after moving to AI Agent | The chain returns `text`; the Agent returns `output` | Update the reference in the send node |
| Repeated greetings / stale context from months ago | Flat memory keyed only by phone number | **Expiring sessions** with session-key rotation (`wa_id:N`) + new/returning/continuing states |
| The bot accepted appointments at 1:00 p.m. | It knew neither today's date nor the midday closure | Inject `$now` in the Bogotá timezone into the prompt + explicit valid start-time ranges |
| Patients thought they were talking to the eye-care professional | The bot never identified itself | Mandatory **Owly** identity in greetings + never impersonate a human |
| "An agent will reply *right away*" (false after hours) | Over-optimistic prompt wording | Rule: never promise a response time; fixed phrasing "as soon as possible" |
| The bot said "I'll book you in" (it can't book) | Ambiguous prompt | Rule: the bot **only registers the request**; a human agent confirms availability and books |

### Phase 3 — Coexistence (the saga)
| Problem | Root cause | Fix |
|---|---|---|
| Coexistence isn't available in Meta's panel for first-party apps | Meta gates it behind a **BSP/Tech Partner Embedded Signup** | Evaluate BSPs → pick **Dualhook** ($12/mo, webhook override, no message storage, cancel anytime) |
| "Add phone number" in the developer panel asked for an OTP | That flow is **migration** (it removes the number from the app), not coexistence | Abort and use only the BSP's Embedded Signup |
| Meta's popup completed but Dualhook showed "0 connections" (×2) | The browser blocked the *handoff* back from the popup to the original tab | See next row 👇 |
| Retry failed with `#2388002` (eligibility) | The number was left **half-connected** from the previous attempt | **Disconnect the platform connection in the app** → wait 15 min → retry |
| The handoff still failed in a "clean" Firefox | Firefox's **Total Cookie Protection** breaks cross-site OAuth even with the shield off for the site | **Chromium browser (Edge)** + **McAfee WebAdvisor disabled** + third-party cookies + popups allowed + original tab left open → ✅ on the third attempt |
| BSP websites appearing "down" only on this PC | McAfee (WebAdvisor/VPN) blocking the domains | Diagnose with a clean hosts file + an external check; disable/restart. *Moral: verify from another network before writing off a vendor* |
| The bot received but didn't reply (post-migration) | The HTTP Request JSON field got a JS object → `[object Object]` | Wrap the body in **`JSON.stringify(...)`** |
| Still not valid JSON | A stray `=` at the start of the expression (the field was already in expression mode) | Remove the literal `=` |
| The bot was replying to the human agent | **Echoes** (messages sent by the business itself) arrived as inbound messages | Filter `from ≠ business number` + a separate echo branch |
| `EchoPausa` failed with "no parameter $1" | `statuses` events (with no phone number) also reached that branch | An `EsEcho` gate (`Array.isArray(value.message_echoes)`) before the UPDATE |
| Meta health showed "BLOCKED" for sending | A payment-method error on the WABA (blocks only **business-initiated templates**) | Doesn't affect service replies (the current use case); payment method added later |

### Phase 4 — Refinement under real usage
| Problem | Root cause | Fix |
|---|---|---|
| Bot and human agent colliding in the same conversation | Both active at once | **Business-hours gate** (bot only while the shop is closed) + a 2 h **echo pause** per patient |
| Bold text showing literal asterisks (`*text*`) | The LLM emitted Markdown `**`, which WhatsApp doesn't render | WhatsApp formatting rule in the prompt + `replace(/\*\*/g,'*')` sanitizer on send |
| The bot replied to the shop's own staff | Their personal numbers looked like any patient's | **`optica_staff`** table in Postgres (numbers out of the repo) + a gate at the very start of the flow |
| Conversations stayed "open" forever | No close-out policy | **Goodbye-after-one-hour-of-inactivity** workflow (once only, tracked via `farewell_at`) |
| Risk of leaking personal phone numbers in the repo | Numbers hardcoded in workflow conditions | Move the list to the DB; add a secret-scanning checklist before publishing the JSON |
| **Public holidays: the worst kind of silent failure** | The hours gate only looked at weekday and time → a holiday was treated as a working day: the bot stayed silent **and** the team wasn't there → the patient got no answer at all | `optica_festivos` table + `es_festivo` in `SessionCheck` + `&& !es_festivo` in both gates |
| Owly didn't announce the holiday even after the gate worked | It was handed a *list* of dates and expected to work out whether today was in it (date arithmetic = fragile). On top of that, the test holiday was literally named "TEST — delete" and the model dismissed it as an artifact | Inject an **explicit flag** `IS TODAY A HOLIDAY?: YES/No` from the DB boolean + instruct the model to trust it even if the name looks like a test |
| Yearly holiday maintenance (easy to forget) | Manually curated list, year after year | Sync workflow using **Nager.Date** (public API, no auth) → self-feeding forever |
| Suspected bug when the flow died at "Bot silent" | Gates run in series: the first one that applies short-circuits the flow (a per-patient pause wins before the hours gate is even evaluated) | Not a bug — defense in depth. The `human_active` value in `SessionCheck`'s output explains every path |

---

## Lessons learned (the big ones)

1. **Coexistence requires a BSP.** There is no self-service button on the direct Cloud API. Picking a BSP with *webhook override* preserves your own architecture (payloads stay in Meta's format → minimal rework).
2. **The browser matters in Meta's OAuth flows.** Antivirus "web protection", VPNs, Total Cookie Protection and blocked popups break Embedded Signup in silent ways. Clean Chromium + third-party cookies + original tab kept open.
3. **A bot with memory needs a session policy.** "Remember everything per phone number" produces stale context; session-key rotation with new/returning/continuing states solves it with a single table.
4. **The LLM must not promise what the system doesn't do.** "I'll book you in" and "right away" are product bugs, not model bugs: fix them with explicit role and language rules.
5. **Humans are part of the architecture.** The hours gate, echo pause, staff list and handoff turn a chatbot into a **hybrid human+AI system** that a real business can actually operate.
6. **Decide in code, not in the prompt.** When the system already knows something for certain (is today a holiday? are we open?), hand the LLM an **explicit boolean**, not raw data to reason over. Every calculation delegated to the model is a latent bug.
7. **Local calendars are requirements, not details.** Public holidays, midday closures and time zones are first-class business rules: if the bot doesn't know them, it fails on exactly the days when it's most visible.

## Roadmap

- [x] Payment method configured on the WABA (unlocks templates whenever they're needed).
- [x] Bilingual README (ES/EN) for international portfolio reach.
- [ ] Restore the `whatsapp_business_management` scope on the token (requires re-running Embedded Signup; **deliberately deferred**: it adds nothing to the current scope and the number is live in production).
- [ ] Evaluate **Meta Business Agent** once it reaches Colombia (a possible BSP replacement).
- [ ] HTTPS for the shop's main domain (Cloudflare).
- [ ] WhatsApp Flows for structured booking data capture.
- [ ] **Multi-tenant** refactor (a single workflow + a `tenants` table) to serve several businesses.

### Dropped (and why)

- **Automated appointment reminders via the Softix API** (the shop's clinical records software). Technically feasible —the API exposes appointments, patients and inventory— and Meta's messaging cost was negligible (~$0.17 USD/month for 8 appointments a day in Colombia). It was dropped because **Softix charges for API access at a price the use case doesn't justify**: today a human agent sends the reminders manually without friction. *Lesson: check the cost of the client's software API BEFORE promising integrations.*

---

*Built with n8n, Claude (Anthropic), Postgres and patience. Owly 🦉 answers while the shop sleeps.*
