# ADR-0007 — Clientes: nativo ×2 escalonado (iOS primero) + API contract-first

- **Fecha:** 2026-07-11
- **Estado:** accepted
- **Dueña:** Andrea

## Contexto

Andrea quiere TripSquad también en Android, además del iOS ya diseñado (dirección
UX/UI v7 cerrada, ADR-0005). Se investigó el panorama multiplataforma a julio de
2026 con fuentes verificadas: Skip es gratis/OSS desde enero 2026 (SwiftUI→Compose,
vendor pequeño, poco corpus en los agentes de IA); el Swift SDK oficial de Android
llegó en Swift 6.3 (marzo 2026, lenguaje sin UI); Compose Multiplatform en iOS es
estable pero imita iOS (sin liquid glass real); Flutter no tiene liquid glass
(issue más votado de su repo); React Native/Expo puede dar liquid glass real vía
wrappers pero no suma al aprendizaje Swift de Andrea. Dato que cambia el cálculo:
con agentes de IA escribiendo ~90% del código, el coste de dos apps nativas ya no
es escribirlas — es QA y evitar drift de features.

## Decisión

1. **iOS primero, en SwiftUI puro** — fidelidad total al diseño v7 (liquid glass),
   máximo aprendizaje Swift, cero dependencias de terceros en el cliente.
2. **Android después, nativo en Kotlin/Jetpack Compose** — cuando iOS esté
   shippeada y estable; los agentes portan ADAPTANDO a Material 3, no clonando
   el look iOS.
3. **El backend nace contract-first**: el contrato OpenAPI es la fuente única de
   verdad; los clientes Swift y Kotlin se GENERAN del contrato, nunca a mano.
   Esta es la decisión que hace reversibles a las otras dos.

## Alternativas consideradas

- **Skip (Swift único → ambas plataformas)** — gratis/OSS y conceptualmente
  perfecto, pero cobertura SwiftUI incompleta, vendor pequeño y fricción esperada
  con agentes de IA (poco corpus). Queda como experimento barato post-v1: el
  SwiftUI escrito sería en gran parte reutilizable.
- **Kotlin Multiplatform (lógica compartida + 2 UIs nativas)** — el estándar de
  industria 2026 con respaldo de Google, pero añade toolchain Gradle↔Xcode para
  compartir la parte pequeña del trabajo de esta app. Reconsiderar solo si la
  lógica compartida de cliente crece hasta doler.
- **React Native/Expo (TypeScript)** — capaz de liquid glass real en 2026 y lo
  más cómodo para los agentes, pero no suma Swift, el premium iOS va siempre un
  paso por detrás de Apple, y no da Material puro en Android.
- **Flutter / Compose-UI-en-iOS** — descartados por fidelidad: el norte de
  TripSquad es estética iOS 26 premium y ambos la imitan en vez de usarla.

## Consecuencias

- El diseño v7 se implementa sin traducción ni compromiso — SwiftUI habla el
  idioma en que fue diseñado.
- Android llega después de iOS, no a la vez. El coste real del segundo cliente
  será QA + specs de paridad (los agentes escriben el código).
- El backend (F3) queda obligado a: OpenAPI versionado en el repo como artefacto
  maestro, generación de clientes en CI, y API agnóstica de plataforma (nada
  Apple-specific en el contrato).
- Un solo dominio de bugs de modelo: los tipos del cliente iOS provienen del
  mismo contrato que servirá a Android.
- Si esta decisión se revisa (p. ej. Skip madura), el contrato la hace barata de
  cambiar: los clientes son generados, no artesanales.
