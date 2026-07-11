# Fábrica TripSquad — gates de calidad
# verify v0 (F0-core): gitleaks + semgrep. El build se añade cuando exista stack (F3).

.PHONY: verify verify-secrets verify-sast

verify: verify-secrets verify-sast
	@echo "✅ verify: todos los gates en verde"

verify-secrets:
	@echo "→ gitleaks (secretos)..."
	@gitleaks git --no-banner --redact .
	@gitleaks dir --no-banner --redact .

verify-sast:
	@echo "→ semgrep (SAST)..."
	@semgrep scan --config p/ci --error --quiet --metrics=off .
