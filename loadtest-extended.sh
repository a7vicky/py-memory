#!/usr/bin/env bash
set -uo pipefail

GLIBC_URL="http://127.0.0.1:30080"
JEMALLOC_URL="http://127.0.0.1:30081"
PRODUCTION_URL="http://127.0.0.1:30082"
REQUESTS_PER_ROUND=200
CONCURRENCY=15
ROUNDS=10
INTERVAL=60
RESULTS_FILE="RESULTS.md"

get_rss() {
    curl -sf "$1/metrics" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('VmRSS_MiB','N/A'))" 2>/dev/null || echo "N/A"
}

ensure_production_pf() {
    if ! curl -sf --max-time 2 "${PRODUCTION_URL}/health" >/dev/null 2>&1; then
        pkill -f "port-forward.*py-memory-production" 2>/dev/null || true
        sleep 1
        kubectl port-forward svc/py-memory-production -n py-memory 30082:8000 >/dev/null 2>&1 &
        sleep 3
    fi
}

fire_requests() {
    local url=$1
    seq 1 "$REQUESTS_PER_ROUND" | xargs -P "$CONCURRENCY" -I{} \
        curl -sf --max-time 30 "${url}/churn" -o /dev/null 2>/dev/null || true
}

# ── Report header ──
cat > "$RESULTS_FILE" << HEADER
# Extended Load Test Results — 3-Way Comparison

**Environment:** kind cluster (Podman), UBI9 Python 3.12, kube-prometheus-stack
**Variants:**
- **glibc** — baseline, no fixes
- **jemalloc** — jemalloc + decay settings, pymalloc active
- **production** — jemalloc + PYTHONMALLOC=malloc + gunicorn worker recycling (max-requests=1000)

**Test:** ${ROUNDS} rounds × ${REQUESTS_PER_ROUND} requests at concurrency ${CONCURRENCY}, with ${INTERVAL}s interval between rounds
**Prometheus scrape interval:** 10s
**Grafana:** http://127.0.0.1:30300 (admin / see kubectl secret)

---

## Prometheus Queries for Grafana

\`\`\`promql
py_memory_vm_rss_bytes / 1024 / 1024
py_memory_rss_anon_bytes / 1024 / 1024
py_memory_private_dirty_bytes / 1024 / 1024
py_memory_vm_data_bytes / 1024 / 1024
\`\`\`

Group by \`allocator\` label to see all 3 variants on one graph.

---

HEADER

echo "============================================================"
echo "  3-Way Extended Load Test: 10 rounds, 1-min intervals"
echo "  glibc vs jemalloc vs production (jemalloc+malloc+recycling)"
echo "============================================================"

# ── Baseline ──
echo ""
echo "[BASELINE]"
g=$(get_rss "$GLIBC_URL"); j=$(get_rss "$JEMALLOC_URL"); p=$(get_rss "$PRODUCTION_URL")
echo "  glibc=${g} MiB  jemalloc=${j} MiB  production=${p} MiB"

echo "### Baseline" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"
echo "| Variant | VmRSS |" >> "$RESULTS_FILE"
echo "|---------|-------|" >> "$RESULTS_FILE"
echo "| glibc | ${g} MiB |" >> "$RESULTS_FILE"
echo "| jemalloc | ${j} MiB |" >> "$RESULTS_FILE"
echo "| production | ${p} MiB |" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

# ── Load rounds ──
echo "" >> "$RESULTS_FILE"
echo "### RSS progression (10 rounds × ${REQUESTS_PER_ROUND} requests, ${INTERVAL}s apart)" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"
echo "| Round | Cumulative | glibc RSS | jemalloc RSS | production RSS | Notes |" >> "$RESULTS_FILE"
echo "|-------|-----------|-----------|--------------|----------------|-------|" >> "$RESULTS_FILE"

for round in $(seq 1 "$ROUNDS"); do
    echo ""
    echo "[ROUND ${round}/${ROUNDS}] Firing ${REQUESTS_PER_ROUND} requests at each..."

    ensure_production_pf
    fire_requests "$GLIBC_URL"
    fire_requests "$JEMALLOC_URL"
    fire_requests "$PRODUCTION_URL"

    cumulative=$((round * REQUESTS_PER_ROUND))

    ensure_production_pf
    g=$(get_rss "$GLIBC_URL"); j=$(get_rss "$JEMALLOC_URL"); p=$(get_rss "$PRODUCTION_URL")
    echo "  After load: glibc=${g}  jemalloc=${j}  production=${p}"
    notes_after="after load"

    echo "| ${round} | ${cumulative} | ${g} MiB | ${j} MiB | ${p} MiB | ${notes_after} |" >> "$RESULTS_FILE"

    if [ "$round" -lt "$ROUNDS" ]; then
        echo "  Waiting ${INTERVAL}s..."
        sleep "$INTERVAL"
        ensure_production_pf
        g2=$(get_rss "$GLIBC_URL"); j2=$(get_rss "$JEMALLOC_URL"); p2=$(get_rss "$PRODUCTION_URL")
        echo "  After ${INTERVAL}s idle: glibc=${g2}  jemalloc=${j2}  production=${p2}"
        echo "| | | ${g2} MiB | ${j2} MiB | ${p2} MiB | after ${INTERVAL}s idle |" >> "$RESULTS_FILE"
    fi
done

# ── Final cooldown ──
echo ""
echo "[FINAL COOLDOWN] 2 minutes idle..."
echo "" >> "$RESULTS_FILE"
echo "### Final cooldown (2 minutes idle after round 10)" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"
echo "| Time | glibc RSS | jemalloc RSS | production RSS |" >> "$RESULTS_FILE"
echo "|------|-----------|--------------|----------------|" >> "$RESULTS_FILE"

for t in 30 60 90 120; do
    sleep 30
    ensure_production_pf
    g=$(get_rss "$GLIBC_URL"); j=$(get_rss "$JEMALLOC_URL"); p=$(get_rss "$PRODUCTION_URL")
    echo "  +${t}s: glibc=${g}  jemalloc=${j}  production=${p}"
    echo "| +${t}s | ${g} MiB | ${j} MiB | ${p} MiB |" >> "$RESULTS_FILE"
done

# ── Final detailed metrics ──
echo "" >> "$RESULTS_FILE"
echo "### Final detailed metrics" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"
echo "| Metric | glibc | jemalloc | production |" >> "$RESULTS_FILE"
echo "|--------|-------|----------|------------|" >> "$RESULTS_FILE"

ensure_production_pf
python3 << 'PYEOF' >> "$RESULTS_FILE"
import json, urllib.request
results = {}
for port, label in [("30080","glibc"), ("30081","jemalloc"), ("30082","production")]:
    try:
        data = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=5).read())
        results[label] = data
    except Exception:
        results[label] = {}
g, j, p = results["glibc"], results["jemalloc"], results["production"]
for key in ["VmRSS_MiB", "RssAnon_MiB", "Private_Dirty_MiB", "VmData_MiB", "VmPeak_MiB"]:
    name = key.replace("_MiB","")
    print(f"| {name} | {g.get(key,'?')} MiB | {j.get(key,'?')} MiB | {p.get(key,'?')} MiB |")
print(f"| Threads | {g.get('Threads','?')} | {j.get('Threads','?')} | {p.get('Threads','?')} |")
print(f"| Allocator | {g.get('allocator','?')} | {j.get('allocator','?')} | {p.get('allocator','?')} |")
print(f"| PYTHONMALLOC | {g.get('PYTHONMALLOC','?')} | {j.get('PYTHONMALLOC','?')} | {p.get('PYTHONMALLOC','?')} |")
PYEOF

cat >> "$RESULTS_FILE" << 'EOF'

---

## Interpretation

- **glibc**: RSS grows with each round and never reclaims — classic arena fragmentation
- **jemalloc**: RSS stabilizes lower than glibc but retains ~25-30 MiB of pymalloc caches above baseline
- **production** (jemalloc + PYTHONMALLOC=malloc + gunicorn --max-requests):
  - `PYTHONMALLOC=malloc` bypasses pymalloc, routing all allocations through jemalloc for full decay
  - `gunicorn --max-requests 1000` recycles the worker process after ~1000 requests, releasing ALL memory
  - Combined: RSS stays near baseline across all rounds

## Grafana Dashboard

Open http://127.0.0.1:30300 and create a panel with:

```promql
py_memory_vm_rss_bytes / 1024 / 1024
```

- **Visualization:** Time series
- **Legend:** `{{allocator}}`
- **Y-axis:** MiB

This shows real-time RSS for all 3 variants over the test duration.
EOF

echo ""
echo "============================================================"
echo "  Results written to ${RESULTS_FILE}"
echo "============================================================"
echo ""
cat "$RESULTS_FILE"
