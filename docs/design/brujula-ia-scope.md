# M8 — Brújula IA — Scope (BLOQUEADO: gasto en API de pago)

> PROPUESTA. **NO construido en autónomo**: usa una **API de LLM de pago** — gasto que la
> constitución marca como high-risk (decisión de Andrea) — y "ningún API se usa sin traer su doc
> real vía Context7". Aquí queda el diseño.

## Idea
Asistente de viaje del squad: responde preguntas y sugiere cosas usando el **contexto del
viaje** (gastos, itinerario, votaciones, chat). "¿Cuánto llevamos gastado?", "propón plan para
el sábado", "¿quién debe a quién?".

## MURO DURO — decisión de Andrea
- **Proveedor + modelo:** por las guías del repo, **Claude (últimos modelos: Opus 4.8 /
  Sonnet 5 / Haiku 4.5)** vía la API de Anthropic. Confirmar cuenta/clave y **presupuesto**
  (gasto por consulta, límites). No se puede activar en autónomo.
- Traer la doc real de la API vía **Context7** antes de codificar el cliente (anti-alucinación).

## Arquitectura (Clean, provider-agnóstica)
- Puerto `AsistenteIA { func responder(prompt: String, contexto: ContextoViaje) async throws -> String }`.
- Adaptador real `AsistenteAnthropic` (cuando se decida) + **stub determinista** para tests.
- **Ensamblado de contexto (RAG ligero):** el caso de uso reúne del viaje solo lo relevante
  (saldos actuales, próximas actividades, votaciones abiertas, últimos N mensajes) y lo mete en
  el prompt. NO manda datos de OTROS viajes (aislamiento multi-tenant).
- **Autorización:** solo miembros del viaje consultan la Brújula (403 sin fuga).

## Seguridad / coste (a resolver en el diseño detallado)
- **Prompt injection:** el contenido del viaje (chat/notas) es input no confiable → nunca darle
  autoridad de "instrucción de sistema"; el system prompt fija el rol y prohíbe acciones.
- **Rate limiting / presupuesto:** límite de consultas por usuario/viaje/día para acotar gasto.
- **Privacidad:** los datos del viaje salen a un tercero (Anthropic) → decisión de producto +
  aviso a usuarios (RGPD); no incluir PII innecesaria en el prompt.
- **No acciones destructivas:** la Brújula SUGIERE; no ejecuta escrituras (no crea gastos/borra
  nada por su cuenta) en el MVP.

## Endpoint (propuesta)
- `POST /trips/:tripId/brujula` {query} → 200 `{answer}`. Solo miembros. Rate-limited.

## Qué SÍ se podría adelantar sin activar la API (si Andrea quiere)
- El puerto `AsistenteIA` + stub, el **ensamblado de contexto** (RAG del viaje) y el endpoint con
  el stub, dejando el adaptador Anthropic real para cuando haya cuenta/presupuesto y doc vía
  Context7. Es andamiaje reutilizable, sin gasto. No lo hice por prudencia (sin la decisión de
  gasto/proveedor, el andamiaje queda a medias); dilo y lo adelanto.
