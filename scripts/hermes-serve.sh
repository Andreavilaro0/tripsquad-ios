#!/usr/bin/env bash
# Arranca Ollama guardando los modelos en el disco externo (DiscoAndrea).
# Protege el disco interno: si DiscoAndrea no está montado, aborta en vez de
# escribir gigas de modelo en el disco del sistema (que va muy justo).
set -euo pipefail

MODELS="/Volumes/DiscoAndrea/ollama-models"
OLLAMA_BIN="/opt/homebrew/opt/ollama/bin/ollama"

if [ ! -d "/Volumes/DiscoAndrea" ]; then
  echo "ERROR: DiscoAndrea no está montado. Abortando para no llenar el disco interno." >&2
  echo "Monta el disco externo y vuelve a ejecutar." >&2
  exit 1
fi

mkdir -p "$MODELS"
echo "Ollama sirviendo con modelos en: $MODELS"
exec env OLLAMA_MODELS="$MODELS" OLLAMA_FLASH_ATTENTION="1" "$OLLAMA_BIN" serve
