#!/usr/bin/env bash
# Verifica que las credenciales R2 + el bucket funcionan de punta a punta (PUT → GET →
# DELETE vía el protocolo S3, el mismo que usa el adaptador FotoStorageR2). NO prueba CORS
# (eso es cosa del navegador), pero confirma que account/token/bucket están bien antes de
# fiarte del despliegue en Render.
#
# Uso:
#   R2_ACCOUNT_ID=... R2_ACCESS_KEY=... R2_SECRET=... R2_BUCKET=tripsquad ./scripts/verify-r2.sh
# o exporta las 4 variables antes (las MISMAS que pondrás en Render). Requiere awscli
# (`brew install awscli`). El Secret NO se imprime.
set -euo pipefail

: "${R2_ACCOUNT_ID:?falta R2_ACCOUNT_ID}"
: "${R2_ACCESS_KEY:?falta R2_ACCESS_KEY}"
: "${R2_SECRET:?falta R2_SECRET}"
: "${R2_BUCKET:?falta R2_BUCKET}"
R2_REGION="${R2_REGION:-auto}"
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
KEY="_verify/tripsquad-$(date +%s 2>/dev/null || echo test).txt"

if ! command -v aws >/dev/null 2>&1; then
  echo "❌ Falta 'aws' (AWS CLI). Instálalo con: brew install awscli" >&2
  exit 1
fi

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET"
export AWS_DEFAULT_REGION="$R2_REGION"
S3=(aws s3api --endpoint-url "$ENDPOINT")

echo "→ Endpoint: $ENDPOINT"
echo "→ Bucket:   $R2_BUCKET"
echo "→ Región:   $R2_REGION"
echo

TMP="$(mktemp)"; echo "tripsquad r2 ok $(date 2>/dev/null || true)" > "$TMP"
trap 'rm -f "$TMP"' EXIT

echo "1/4 PUT  $KEY ..."
"${S3[@]}" put-object --bucket "$R2_BUCKET" --key "$KEY" --body "$TMP" \
  --content-type "text/plain" >/dev/null && echo "    ✅ subida OK"

echo "2/4 HEAD $KEY ..."
"${S3[@]}" head-object --bucket "$R2_BUCKET" --key "$KEY" >/dev/null && echo "    ✅ existe y es legible"

echo "3/4 GET  $KEY ..."
OUT="$(mktemp)"; "${S3[@]}" get-object --bucket "$R2_BUCKET" --key "$KEY" "$OUT" >/dev/null
if diff -q "$TMP" "$OUT" >/dev/null; then echo "    ✅ contenido íntegro"; else echo "    ❌ el contenido no coincide" >&2; rm -f "$OUT"; exit 1; fi
rm -f "$OUT"

echo "4/4 DELETE $KEY ..."
"${S3[@]}" delete-object --bucket "$R2_BUCKET" --key "$KEY" >/dev/null && echo "    ✅ borrado OK"

echo
echo "🎉 R2 verificado: account + token (Object Read & Write) + bucket funcionan."
echo "   Pon estas MISMAS 4 variables en Render y configura la CORS policy (PUT) para el navegador."
