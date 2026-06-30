# Constitution de TripSquad — principios inmutables

Idea de GitHub Spec Kit: reglas de alto nivel que aplican a todo cambio, en toda sesión.
Cambiar un principio de aquí exige un ADR explícito en `docs/decisions/`.

1. **Una marca: TripSquad.** (ADR-0001)
2. **Design-first.** Ninguna pantalla se codifica sin diseño + spec aprobados.
3. **Decidido > perfecto, con fecha.** Toda fase es timeboxed. El enemigo no es equivocarse;
   es no decidir y dar vueltas.
4. **Decisiones append-only.** Se registran como ADR. No se editan ni borran las aceptadas;
   se reemplazan con un ADR nuevo que las supersede. El historial del pensamiento queda intacto.
5. **Clean Architecture** (Presentation / Domain / Data / Infra) cuando exista código.
6. **Anti-alucinación:** ningún API se usa sin su doc real vía Context7. Versiones fijadas.
7. **Separar escritor de validador:** el que escribe código nunca se autorevisa; revisa otro
   modelo (Codex/Gemini) y firma Andrea.
8. **Seguridad no opcional:** todo código pasa gitleaks + semgrep antes de "hecho".
9. **Higiene de contexto:** sesiones bajo ~60% de la ventana; context-save antes de compactar.
10. **El proceso sirve para enviar.** El método no es el producto. No sobre-construir el sistema.
