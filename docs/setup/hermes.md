# Hermes (LLM local vía Ollama)

Modelo open-weight local. Instalado a petición de Andrea (ver ADR-0002). Es más débil que
Claude/Codex/Gemini; su valor es ser local, gratis y privado. No es el revisor principal.

## Qué está instalado
- **Runtime:** Ollama (`brew install ollama`, binario en `/opt/homebrew/opt/ollama/bin/ollama`).
- **Modelo:** `hermes3:8b` (Nous Hermes 3, 8B, ~4.7 GB). Es lo que cabe cómodo en 16 GB de RAM.
  El 35B/405B NO cabe en esta máquina.
- **Almacenamiento:** `/Volumes/DiscoAndrea/ollama-models` (disco externo — el interno va justo).

## ⚠️ Importante
El modelo vive en el disco externo. **Ollama solo funciona con DiscoAndrea montado.** Si arrancas
Ollama sin el disco montado, no encontrará el modelo (y podría intentar escribir en el interno).
Usa siempre el launcher, que lo comprueba.

## Cómo usarlo
Arrancar el servidor (comprueba el disco):
```bash
./scripts/hermes-serve.sh          # déjalo corriendo en una terminal
```
Chatear / probar:
```bash
ollama run hermes3:8b "Hola, ¿funcionas?"
ollama list                        # ver modelos instalados
```

## Enchufarlo a Codex (usarlo como modelo local en el flujo)
Codex CLI puede usar Ollama como proveedor local:
```bash
codex --oss --local-provider ollama exec "..."   # usa el modelo local en vez de la nube
```
Así Hermes queda dentro del flujo, no suelto. (Para auditoría en serio, los revisores fuertes
siguen siendo Codex y Gemini; Hermes es la opción local/gratis.)

## Bajar otro tamaño
```bash
ollama pull hermes3:3b    # más ligero (~2 GB)
```
Hermes 4 no está en el registro simple de Ollama; si se quiere, se importa desde GGUF de
HuggingFace más adelante.
