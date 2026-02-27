#!/bin/bash
set -euo pipefail

# ── Atualizar Baileys (WhatsApp Web client) ──────────────────────────────────
# Executar NO HOST (precisa de git, Node.js 20+, npm, docker CLI).
#
# Estratégia:
#   1. Clona Baileys do GitHub
#   2. Checkout commit seguro (antes do whatsapp-rust-bridge ESM)
#   3. Cherry-pick identity key fix (#2307)
#   4. Copia versão WA mais recente do master
#   5. Compila (npm install + npm run build)
#   6. Copia lib/ para o container via docker cp
#   7. Restart container
#
# Por que NÃO usar master HEAD:
#   PR #2315 adicionou whatsapp-rust-bridge (ESM-only com top-level await).
#   Evolution API compila como CJS → require() falha com ERR_REQUIRE_ASYNC_MODULE.
# ─────────────────────────────────────────────────────────────────────────────

BAILEYS_TMP="/tmp/baileys-update-$$"
CONTAINER="limpvix-evolutionapi"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVOLUTION_DIR="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="$(dirname "$EVOLUTION_DIR")/backend"

# Commit seguro: após #2182 (race condition) + #2316 (DB cache), antes de #2315 (Rust WASM ESM)
SAFE_COMMIT="fa2a837a4a"
# Cherry-pick: #2307 (identity key fix)
IDENTITY_FIX="b02390123a"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

cleanup() {
    rm -rf "$BAILEYS_TMP"
}
trap cleanup EXIT

log "=== Atualizando Baileys ==="

# Verificar dependências
for cmd in git node npm docker; do
    if ! command -v "$cmd" &>/dev/null; then
        log "ERRO: '$cmd' não encontrado. Instale antes de continuar."
        exit 1
    fi
done

# 1. Clonar
log "Clonando Baileys..."
rm -rf "$BAILEYS_TMP"
git clone --quiet https://github.com/WhiskeySockets/Baileys.git "$BAILEYS_TMP"

cd "$BAILEYS_TMP"

# 2. Capturar versão WA mais recente do master ANTES do checkout
LATEST_VERSION=$(grep -o 'const version = \[.*\]' src/Defaults/index.ts | head -1)
if [ -z "$LATEST_VERSION" ]; then
    log "ERRO: Não foi possível extrair versão WA do master"
    exit 1
fi
log "Versão WA do master: $LATEST_VERSION"

# 3. Checkout commit seguro (sem whatsapp-rust-bridge)
log "Checkout $SAFE_COMMIT..."
git checkout --quiet "$SAFE_COMMIT"

# 4. Cherry-pick identity key fix
log "Cherry-pick #2307 (identity key fix)..."
if ! git cherry-pick --no-commit "$IDENTITY_FIX" 2>/dev/null; then
    log "AVISO: Cherry-pick falhou (pode já estar incluído). Continuando..."
    git checkout -- . 2>/dev/null || true
fi

# 5. Atualizar versão WA
log "Atualizando versão WhatsApp Web..."
sed -i "s/const version = \[.*\]/$LATEST_VERSION/" src/Defaults/index.ts

# 6. Instalar e compilar
log "Instalando dependências..."
npm install --silent 2>&1 | tail -5

log "Compilando..."
npm run build 2>&1 | tail -5

# 7. Verificar build
if [ ! -f "lib/Socket/messages-recv.js" ]; then
    log "ERRO: Build falhou — lib/Socket/messages-recv.js não encontrado"
    exit 1
fi

IDENTITY_COUNT=$(grep -c "identityAssertDebounce" lib/Socket/messages-recv.js || true)
RUST_COUNT=$(grep -rc "whatsapp-rust-bridge" lib/ || true)

log "Verificação: identityAssertDebounce=$IDENTITY_COUNT, whatsapp-rust-bridge=$RUST_COUNT"

if [ "$IDENTITY_COUNT" -lt 1 ]; then
    log "AVISO: Identity key fix pode não estar presente"
fi
if [ "$RUST_COUNT" -gt 0 ]; then
    log "ERRO: whatsapp-rust-bridge detectado — abortando (causaria ESM error)"
    exit 1
fi

# 8. Verificar container rodando
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    log "ERRO: Container '$CONTAINER' não está rodando"
    exit 1
fi

# 9. Copiar para container
log "Copiando lib/ para container $CONTAINER..."
docker cp "$BAILEYS_TMP/lib/." "$CONTAINER:/evolution/node_modules/baileys/lib/"
docker cp "$BAILEYS_TMP/package.json" "$CONTAINER:/evolution/node_modules/baileys/package.json"

# 10. Restart
log "Reiniciando container..."
cd "$BACKEND_DIR"
docker compose restart limpvix-evolutionapi

# 11. Aguardar startup
log "Aguardando startup (15s)..."
sleep 15

# 12. Verificar
STATUS=$(docker compose ps limpvix-evolutionapi --format '{{.Status}}' 2>/dev/null || echo "unknown")
if echo "$STATUS" | grep -q "Up"; then
    log "=== Baileys atualizado com sucesso! Container: $STATUS ==="
    exit 0
else
    log "ERRO: Container não está Up: $STATUS"
    log "Verifique: docker compose logs limpvix-evolutionapi --tail=30"
    exit 1
fi
