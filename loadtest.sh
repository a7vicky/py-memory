#!/usr/bin/env bash
set -euo pipefail

GLIBC_IMAGE="py-memory-glibc"
JEMALLOC_IMAGE="py-memory-jemalloc"
GLIBC_CONTAINER="mem-test-glibc"
JEMALLOC_CONTAINER="mem-test-jemalloc"
GLIBC_PORT=8081
JEMALLOC_PORT=8082
REQUESTS=300
CONCURRENCY=15

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

cleanup() {
    echo -e "\n${CYAN}Cleaning up containers...${NC}"
    podman rm -f "$GLIBC_CONTAINER" "$JEMALLOC_CONTAINER" 2>/dev/null || true
}
trap cleanup EXIT

wait_for_ready() {
    local port=$1 name=$2
    echo -n "  Waiting for $name to be ready"
    for i in $(seq 1 30); do
        if curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
            echo -e " ${GREEN}OK${NC}"
            return 0
        fi
        echo -n "."
        sleep 1
    done
    echo -e " ${RED}FAILED${NC}"
    return 1
}

get_rss() {
    local port=$1
    curl -sf "http://127.0.0.1:${port}/metrics" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(json.dumps(d, indent=2))
" 2>/dev/null || echo '{"error": "unavailable"}'
}

get_rss_mib() {
    local port=$1
    curl -sf "http://127.0.0.1:${port}/metrics" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('VmRSS_MiB', 'N/A'))
" 2>/dev/null || echo "N/A"
}

fire_requests() {
    local port=$1 count=$2 concurrency=$3
    seq 1 "$count" | xargs -P "$concurrency" -I{} \
        curl -sf "http://127.0.0.1:${port}/churn" -o /dev/null 2>/dev/null
}

echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}  glibc vs jemalloc Memory Comparison Test  ${NC}"
echo -e "${BOLD}============================================${NC}"

# ── Build ──
echo -e "\n${YELLOW}[1/6] Building images...${NC}"
podman build -f Dockerfile.glibc -t "$GLIBC_IMAGE" .
podman build -f Dockerfile.jemalloc -t "$JEMALLOC_IMAGE" .
echo -e "${GREEN}Both images built successfully.${NC}"

# ── Start containers ──
echo -e "\n${YELLOW}[2/6] Starting containers...${NC}"
podman rm -f "$GLIBC_CONTAINER" "$JEMALLOC_CONTAINER" 2>/dev/null || true

podman run -d --name "$GLIBC_CONTAINER" \
    -p "${GLIBC_PORT}:8000" \
    --security-opt label=disable \
    "$GLIBC_IMAGE"

podman run -d --name "$JEMALLOC_CONTAINER" \
    -p "${JEMALLOC_PORT}:8000" \
    --security-opt label=disable \
    "$JEMALLOC_IMAGE"

wait_for_ready "$GLIBC_PORT" "glibc"
wait_for_ready "$JEMALLOC_PORT" "jemalloc"

# ── Baseline ──
echo -e "\n${YELLOW}[3/6] Capturing baseline RSS...${NC}"
GLIBC_BEFORE=$(get_rss_mib $GLIBC_PORT)
JEMALLOC_BEFORE=$(get_rss_mib $JEMALLOC_PORT)
echo -e "  glibc   baseline: ${BOLD}${GLIBC_BEFORE} MiB${NC}"
echo -e "  jemalloc baseline: ${BOLD}${JEMALLOC_BEFORE} MiB${NC}"

echo -e "\n  ${CYAN}Full baseline metrics (glibc):${NC}"
get_rss $GLIBC_PORT
echo -e "\n  ${CYAN}Full baseline metrics (jemalloc):${NC}"
get_rss $JEMALLOC_PORT

# ── Load test ──
echo -e "\n${YELLOW}[4/6] Firing ${REQUESTS} requests (concurrency=${CONCURRENCY}) at each container...${NC}"

echo -e "  ${CYAN}Loading glibc container...${NC}"
fire_requests $GLIBC_PORT $REQUESTS $CONCURRENCY
GLIBC_PEAK=$(get_rss_mib $GLIBC_PORT)
echo -e "  glibc   after load: ${RED}${GLIBC_PEAK} MiB${NC}"

echo -e "  ${CYAN}Loading jemalloc container...${NC}"
fire_requests $JEMALLOC_PORT $REQUESTS $CONCURRENCY
JEMALLOC_PEAK=$(get_rss_mib $JEMALLOC_PORT)
echo -e "  jemalloc after load: ${RED}${JEMALLOC_PEAK} MiB${NC}"

# ── Cooldown ──
echo -e "\n${YELLOW}[5/6] Cooling down (60 seconds idle)...${NC}"
for i in 15 30 45 60; do
    sleep 15
    G=$(get_rss_mib $GLIBC_PORT)
    J=$(get_rss_mib $JEMALLOC_PORT)
    echo -e "  +${i}s  glibc=${BOLD}${G} MiB${NC}  jemalloc=${BOLD}${J} MiB${NC}"
done
GLIBC_AFTER=$(get_rss_mib $GLIBC_PORT)
JEMALLOC_AFTER=$(get_rss_mib $JEMALLOC_PORT)

# ── Full post-cooldown metrics ──
echo -e "\n  ${CYAN}Post-cooldown metrics (glibc):${NC}"
get_rss $GLIBC_PORT
echo -e "\n  ${CYAN}Post-cooldown metrics (jemalloc):${NC}"
get_rss $JEMALLOC_PORT

# ── Results ──
echo -e "\n${YELLOW}[6/6] Results${NC}"
echo -e "${BOLD}============================================${NC}"
printf "${BOLD}%-12s %10s %10s %10s${NC}\n" "Allocator" "Baseline" "Peak" "After 60s"
echo "--------------------------------------------"
printf "%-12s %8s %8s %10s\n" "glibc" "${GLIBC_BEFORE}" "${GLIBC_PEAK}" "${GLIBC_AFTER}"
printf "%-12s %8s %8s %10s\n" "jemalloc" "${JEMALLOC_BEFORE}" "${JEMALLOC_PEAK}" "${JEMALLOC_AFTER}"
echo -e "${BOLD}============================================${NC}"

echo -e "\n${BOLD}Interpretation:${NC}"
echo -e "  - If glibc 'After 60s' stays near Peak → ${RED}fragmentation confirmed${NC}"
echo -e "  - If jemalloc 'After 60s' drops toward Baseline → ${GREEN}jemalloc fix works${NC}"
echo -e "\nDone."
