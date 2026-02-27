#!/bin/bash
set -uo pipefail

# ── Atualizar Baileys (WhatsApp Web client) ──────────────────────────────────
# Roda DENTRO do container limpvix-canary-wa1.
# Escreve progresso em $STATUS_FILE (JSON) para o backend fazer polling.
#
# Environment (set by docker-compose):
#   STATUS_FILE        - Path para escrever status JSON (ex: /status/status.json)
#   CONTAINER_TARGET   - Nome do container Evolution API (ex: limpvix-evolutionapi)
#   COMPOSE_PROJECT_DIR - Path do backend (para docker compose commands)
#
# Estrategia:
#   Checkout commit seguro fa2a837a4a (antes do whatsapp-rust-bridge ESM)
#   + cherry-pick b02390123a (identity key fix #2307)
#   + versao WA mais recente do master HEAD
# ─────────────────────────────────────────────────────────────────────────────

STATUS_FILE="${STATUS_FILE:-/status/status.json}"
CONTAINER="${CONTAINER_TARGET:-limpvix-evolutionapi}"
COMPOSE_DIR="${COMPOSE_PROJECT_DIR:-/backend}"

BAILEYS_TMP="/tmp/baileys-update-$$"
SAFE_COMMIT="fa2a837a4a"
IDENTITY_FIX="b02390123a"

# ── Steps ──
STEPS=("clone" "checkout" "cherry_pick" "update_version" "npm_install" "build" "verify" "copy" "restart" "confirm")
STEP_LABELS=(
    "Clonando repositorio Baileys"
    "Checkout commit seguro"
    "Cherry-pick identity key fix"
    "Atualizando versao WhatsApp"
    "Instalando dependencias (npm)"
    "Compilando TypeScript"
    "Verificando build"
    "Copiando lib/ para container"
    "Reiniciando Evolution API"
    "Verificando container ativo"
)

# ── Status writer (atomic via mv) ──
write_status() {
    local current_step="$1"
    local state="$2"
    local message="${3:-}"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local steps_json="["
    local i
    for i in "${!STEPS[@]}"; do
        local step_state="pending"
        if [ "$i" -lt "$current_step" ]; then
            step_state="done"
        elif [ "$i" -eq "$current_step" ]; then
            if [ "$state" = "error" ]; then
                step_state="error"
            else
                step_state="running"
            fi
        fi

        [ "$i" -gt 0 ] && steps_json="${steps_json},"
        steps_json="${steps_json}{\"id\":\"${STEPS[$i]}\",\"label\":\"${STEP_LABELS[$i]}\",\"state\":\"${step_state}\"}"
    done
    steps_json="${steps_json}]"

    local overall="running"
    if [ "$state" = "done" ] && [ "$current_step" -ge "${#STEPS[@]}" ]; then
        overall="done"
    elif [ "$state" = "error" ]; then
        overall="error"
    fi

    cat > "${STATUS_FILE}.tmp" <<EOJSON
{"status":"${overall}","current_step":${current_step},"total_steps":${#STEPS[@]},"message":"${message}","updated_at":"${ts}","steps":${steps_json}}
EOJSON
    mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

cleanup() { rm -rf "$BAILEYS_TMP"; }
trap cleanup EXIT

fail() {
    local step="$1"
    local msg="$2"
    log "ERRO: $msg"
    write_status "$step" "error" "$msg"
    exit 1
}

# ── Init ──
mkdir -p "$(dirname "$STATUS_FILE")"
write_status 0 "running" "Iniciando atualizacao..."
log "=== Atualizando Baileys ==="

# ── Step 0: Clone ──
write_status 0 "running" "Clonando repositorio..."
log "Clonando Baileys..."
rm -rf "$BAILEYS_TMP"
git clone --quiet https://github.com/WhiskeySockets/Baileys.git "$BAILEYS_TMP" \
    || fail 0 "Falha ao clonar repositorio Baileys"

cd "$BAILEYS_TMP"

# ── Step 1: Checkout ──
write_status 1 "running" "Checkout commit seguro..."
LATEST_VERSION=$(grep -o 'const version = \[.*\]' src/Defaults/index.ts | head -1)
[ -z "$LATEST_VERSION" ] && fail 1 "Nao foi possivel extrair versao WA do master"
log "Versao WA do master: $LATEST_VERSION"

log "Checkout $SAFE_COMMIT..."
git checkout --quiet "$SAFE_COMMIT" || fail 1 "Falha no checkout $SAFE_COMMIT"

# ── Step 2: Cherry-pick ──
write_status 2 "running" "Aplicando cherry-pick #2307..."
log "Cherry-pick #2307 (identity key fix)..."
if ! git cherry-pick --no-commit "$IDENTITY_FIX" 2>/dev/null; then
    log "AVISO: Cherry-pick falhou (pode ja estar incluido). Continuando..."
    git checkout -- . 2>/dev/null || true
fi

# ── Step 3: Update WA version ──
write_status 3 "running" "Atualizando versao WA..."
log "Atualizando versao WhatsApp Web..."
sed -i "s/const version = \[.*\]/$LATEST_VERSION/" src/Defaults/index.ts

# ── Step 4: npm install ──
write_status 4 "running" "Instalando dependencias (~1-2 min)..."
log "Instalando dependencias..."
npm install --silent 2>&1 | tail -5 || fail 4 "npm install falhou"

# ── Step 5: Build ──
write_status 5 "running" "Compilando TypeScript (~30s)..."
log "Compilando..."
npm run build 2>&1 | tail -5 || fail 5 "npm run build falhou"

# ── Step 6: Verify ──
write_status 6 "running" "Verificando integridade do build..."
log "Verificando build..."

[ ! -f "lib/Socket/messages-recv.js" ] && fail 6 "Build falhou: lib/Socket/messages-recv.js nao encontrado"

IDENTITY_COUNT=$(grep -c "identityAssertDebounce" lib/Socket/messages-recv.js || true)
RUST_COUNT=$(grep -rc "whatsapp-rust-bridge" lib/ || true)
log "Verificacao: identityAssertDebounce=$IDENTITY_COUNT, whatsapp-rust-bridge=$RUST_COUNT"

[ "$RUST_COUNT" -gt 0 ] && fail 6 "whatsapp-rust-bridge detectado — build inseguro"

# ── Step 7: Copy to container ──
write_status 7 "running" "Copiando lib/ para Evolution API..."
log "Copiando lib/ para container $CONTAINER..."

docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$" \
    || fail 7 "Container $CONTAINER nao esta rodando"

docker cp "$BAILEYS_TMP/lib/." "$CONTAINER:/evolution/node_modules/baileys/lib/" \
    || fail 7 "Falha ao copiar lib/ para container"
docker cp "$BAILEYS_TMP/package.json" "$CONTAINER:/evolution/node_modules/baileys/package.json" \
    || fail 7 "Falha ao copiar package.json para container"

# ── Step 8: Restart ──
write_status 8 "running" "Reiniciando Evolution API..."
log "Reiniciando container..."
cd "$COMPOSE_DIR"
docker compose restart limpvix-evolutionapi || fail 8 "Falha ao reiniciar container"

# ── Step 9: Confirm ──
write_status 9 "running" "Aguardando startup (15s)..."
log "Aguardando startup (15s)..."
sleep 15

STATUS=$(docker compose ps limpvix-evolutionapi --format '{{.Status}}' 2>/dev/null || echo "unknown")
if echo "$STATUS" | grep -q "Up"; then
    log "=== Baileys atualizado com sucesso! Container: $STATUS ==="
    write_status 10 "done" "Baileys atualizado com sucesso!"
    exit 0
else
    fail 9 "Container nao esta Up apos restart: $STATUS"
fi
