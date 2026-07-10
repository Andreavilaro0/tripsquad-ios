# Boceto del diseño — pantallas exportadas de Pencil

Export estático del tablero maestro (`pencil-new.pen`, 2026-07-10, cierre F0–F5).
**Esto es el PLANO, no el resultado final:** el movimiento (springs, split-flap,
confetti, fly-to, shimmer, foil del sello), el liquid glass real (`.glassEffect`
iOS 26), la interacción y las fotos/tipografía finales solo se ven en los
prototipos HTML y, definitivamente, en el simulador. Leer `../../DESIGN.md` antes
de tocar nada.

| # | Pantalla | Fase |
|---|----------|------|
| 01–06 | Inicio por nº de viajes (sin/uno/varios/bandas/pasados) + estados | F1 |
| 07–11 | Crear (sheet + a mano) · Brújula agente · Paywall · Bloqueada | F2 |
| 12–15 | Hub · Planes · Mapa fly-to · Día X (Live Activity) | F3a |
| 16–20 | Votación mazo · Liquidar+cierre · Gastos · Chat (Text Blast) · Fotos | F3b |
| 21–26 | Transición · Invitar · Perfil · Avisos · Ajustes (viaje/app) | F4 |

Bienvenida (5 escenas + loops): `../bienvenida/`.
