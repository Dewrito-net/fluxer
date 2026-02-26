#!/usr/bin/env bash
set -euo pipefail

# Echowire Rolling Deploy Script
# Builds Docker image locally, transfers to both nodes, does rolling restart.
# Usage: ./deploy.sh

NC_HOST="root@100.70.10.204"
MI_HOST="root@100.70.49.120"
COMPOSE_DIR="/opt/echowire"
IMAGE_NAME="fluxer-server:latest"
IMAGE_FILE="/tmp/fluxer-server-latest.tar.gz"
HEALTH_URL="/_health"
HEALTH_TIMEOUT=120  # seconds to wait for healthy
HEALTH_INTERVAL=5   # seconds between checks

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[deploy]${NC} $1"; }
warn() { echo -e "${YELLOW}[deploy]${NC} $1"; }
err()  { echo -e "${RED}[deploy]${NC} $1"; exit 1; }

wait_healthy() {
    local host=$1
    local label=$2
    local elapsed=0

    log "Waiting for $label to become healthy..."
    while [ $elapsed -lt $HEALTH_TIMEOUT ]; do
        if ssh "$host" "curl -fsS http://localhost:8080${HEALTH_URL}" &>/dev/null; then
            log "$label is healthy (${elapsed}s)"
            return 0
        fi
        sleep $HEALTH_INTERVAL
        elapsed=$((elapsed + HEALTH_INTERVAL))
    done
    err "$label failed to become healthy after ${HEALTH_TIMEOUT}s"
}

# Step 1: Build Docker image
BUILD_SHA=$(git rev-parse --short HEAD)
BUILD_NUMBER=$(git rev-list --count HEAD)
BUILD_TIMESTAMP=$(date +%s)
log "Building Docker image (SHA: $BUILD_SHA, Build: $BUILD_NUMBER)..."
docker build -t "$IMAGE_NAME" -f fluxer_server/Dockerfile \
	--build-arg BUILD_SHA="$BUILD_SHA" \
	--build-arg BUILD_NUMBER="$BUILD_NUMBER" \
	--build-arg BUILD_TIMESTAMP="$BUILD_TIMESTAMP" \
	. 2>&1 | tail -5
log "Image built successfully"

# Step 2: Save image
log "Saving image to $IMAGE_FILE..."
docker save "$IMAGE_NAME" | gzip > "$IMAGE_FILE"
IMAGE_SIZE=$(du -h "$IMAGE_FILE" | cut -f1)
log "Image saved ($IMAGE_SIZE)"

# Step 3: Transfer to both nodes in parallel
log "Transferring image to both nodes..."
scp "$IMAGE_FILE" "$MI_HOST:/tmp/" &
MI_PID=$!
scp "$IMAGE_FILE" "$NC_HOST:/tmp/" &
NC_PID=$!
wait $MI_PID || err "Failed to transfer to MI"
wait $NC_PID || err "Failed to transfer to NC"
log "Image transferred to both nodes"

# Step 4: Load image on MI
log "Loading image on MI..."
ssh "$MI_HOST" "docker load < $IMAGE_FILE && rm $IMAGE_FILE"

# Step 5: Rolling restart — MI first (NC handles all traffic)
log "=== Rolling restart: MI first ==="
warn "MI going down — NC handling all traffic"
ssh "$MI_HOST" "cd $COMPOSE_DIR && docker compose stop fluxer_server && docker compose rm -f fluxer_server && docker compose up -d fluxer_server"
wait_healthy "$MI_HOST" "MI"
log "Restarting MI gateway (Erlang RPC reconnect)..."
ssh "$MI_HOST" "cd $COMPOSE_DIR && docker compose restart gateway"

# Step 6: Load image on NC
log "Loading image on NC..."
ssh "$NC_HOST" "docker load < $IMAGE_FILE && rm $IMAGE_FILE"

# Step 7: Rolling restart — NC (MI handles all traffic)
log "=== Rolling restart: NC ==="
warn "NC going down — MI handling all traffic"
ssh "$NC_HOST" "cd $COMPOSE_DIR && docker compose stop fluxer_server && docker compose rm -f fluxer_server && docker compose up -d fluxer_server"
wait_healthy "$NC_HOST" "NC"
log "Restarting NC gateway (Erlang RPC reconnect)..."
ssh "$NC_HOST" "cd $COMPOSE_DIR && docker compose restart gateway"

# Step 8: Verify
log "=== Verifying ==="
NC_KEYS=$(ssh "$NC_HOST" "docker exec valkey keydb-cli dbsize" 2>/dev/null || echo "unknown")
MI_KEYS=$(ssh "$MI_HOST" "docker exec valkey keydb-cli dbsize" 2>/dev/null || echo "unknown")
log "KeyDB — NC: $NC_KEYS, MI: $MI_KEYS"

SITE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://echowire.org/_health)
if [ "$SITE_STATUS" = "200" ]; then
    log "Site is live (200 OK)"
else
    warn "Site returned $SITE_STATUS (may still be starting)"
fi

# Cleanup
rm -f "$IMAGE_FILE"

log "=== Deploy complete ==="
