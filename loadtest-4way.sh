#!/usr/bin/env bash
set -uo pipefail

GLIBC_PORT=30080
JEMALLOC_PORT=30081
PROD_PORT=30082
GLIBCM_PORT=30083
REQUESTS_PER_ROUND=200
CONCURRENCY=15
ROUNDS=10
INTERVAL=60
RESULTS_FILE="RESULTS.md"
TOTAL=$((REQUESTS_PER_ROUND * ROUNDS))

start_port_forwards() {
    pkill -f "port-forward.*py-memory" 2>/dev/null || true
    sleep 1
    nohup kubectl port-forward svc/py-memory-production -n py-memory ${PROD_PORT}:8000 </dev/null >/dev/null 2>&1 &
    nohup kubectl port-forward svc/py-memory-glibc-malloc -n py-memory ${GLIBCM_PORT}:8000 </dev/null >/dev/null 2>&1 &
    sleep 3
}

ensure_pf() {
    for port in $PROD_PORT $GLIBCM_PORT; do
        if ! curl -sf --max-time 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
            start_port_forwards
            return
        fi
    done
}

get_rss() {
    curl -sf --max-time 5 "http://127.0.0.1:$1/metrics" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('VmRSS_MiB','N/A'))" 2>/dev/null || echo "N/A"
}

get_threads() {
    curl -sf --max-time 5 "http://127.0.0.1:$1/metrics" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('Threads','?'))" 2>/dev/null || echo "?"
}

fire_requests() {
    local port=$1 tmpdir
    tmpdir=$(mktemp -d)
    seq 1 "$REQUESTS_PER_ROUND" | xargs -P "$CONCURRENCY" -I{} \
        bash -c "
            start=\$(date +%s%N)
            code=\$(curl -sf --max-time 30 -o /dev/null -w '%{http_code}' http://127.0.0.1:${port}/churn 2>/dev/null || echo 000)
            end=\$(date +%s%N)
            ms=\$(( (end - start) / 1000000 ))
            echo \"\${code} \${ms}\" >> ${tmpdir}/results.txt
        " 2>/dev/null || true

    local total=0 success=0 fail=0 total_ms=0 min_ms=999999 max_ms=0
    if [ -f "${tmpdir}/results.txt" ]; then
        while read -r code ms; do
            total=$((total + 1))
            if [ "$code" = "200" ]; then
                success=$((success + 1))
                total_ms=$((total_ms + ms))
                [ "$ms" -lt "$min_ms" ] 2>/dev/null && min_ms=$ms
                [ "$ms" -gt "$max_ms" ] 2>/dev/null && max_ms=$ms
            else
                fail=$((fail + 1))
            fi
        done < "${tmpdir}/results.txt"
    fi

    local avg_ms=0
    [ "$success" -gt 0 ] && avg_ms=$((total_ms / success))
    rm -rf "$tmpdir"
    echo "${success}/${total} ${fail} ${avg_ms} ${min_ms} ${max_ms}"
}

get_worker_restarts() {
    local pod
    pod=$(kubectl get pods -n py-memory -l allocator="$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$pod" ]; then
        kubectl get pod "$pod" -n py-memory -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?"
    else
        echo "?"
    fi
}

start_port_forwards

cat > "$RESULTS_FILE" << HEADER
# Extended Load Test Results — 4-Way Comparison

**Environment:** kind cluster (Podman), UBI9 Python 3.12, kube-prometheus-stack
**Variants:**
- **glibc** — baseline, no fixes (1 worker, no recycling)
- **jemalloc** — jemalloc + decay settings, pymalloc active (1 worker)
- **jemalloc+malloc** — jemalloc + PYTHONMALLOC=malloc (1 worker)
- **glibc+malloc** — glibc + PYTHONMALLOC=malloc + uvicorn worker recycling (3 workers, limit-max-requests=800)

**Test:** ${TOTAL} total requests (${ROUNDS} rounds × ${REQUESTS_PER_ROUND}), concurrency ${CONCURRENCY}, ${INTERVAL}s intervals

---

## Prometheus Queries for Grafana

\`\`\`promql
py_memory_vm_rss_bytes / 1024 / 1024
\`\`\`

Group by \`allocator\` label to see all 4 variants.

---

HEADER

echo "================================================================"
echo "  4-Way Load Test: ${ROUNDS} rounds, ${INTERVAL}s intervals"
echo "  glibc | jemalloc | jemalloc+malloc | glibc+malloc+recycling"
echo "================================================================"

# ── Baseline ──
echo ""
echo "[BASELINE]"
ensure_pf
g=$(get_rss $GLIBC_PORT); j=$(get_rss $JEMALLOC_PORT); p=$(get_rss $PROD_PORT); m=$(get_rss $GLIBCM_PORT)
echo "  glibc=${g}  jemalloc=${j}  jemalloc+malloc=${p}  glibc+malloc=${m}"

gr=$(get_worker_restarts glibc); jr=$(get_worker_restarts jemalloc); pr=$(get_worker_restarts production); mr=$(get_worker_restarts glibc-malloc)

echo "### Baseline" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"
echo "| Variant | VmRSS | Pod Restarts |" >> "$RESULTS_FILE"
echo "|---------|-------|-------------|" >> "$RESULTS_FILE"
echo "| glibc | ${g} MiB | ${gr} |" >> "$RESULTS_FILE"
echo "| jemalloc | ${j} MiB | ${jr} |" >> "$RESULTS_FILE"
echo "| jemalloc+malloc | ${p} MiB | ${pr} |" >> "$RESULTS_FILE"
echo "| glibc+malloc | ${m} MiB | ${mr} |" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

echo "" >> "$RESULTS_FILE"
echo "### Per-round progression" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"
echo "| Round | Total Req | Variant | RSS | Success | Fail | Avg(ms) | Min(ms) | Max(ms) | Pod Restarts |" >> "$RESULTS_FILE"
echo "|-------|-----------|---------|-----|---------|------|---------|---------|---------|-------------|" >> "$RESULTS_FILE"

for round in $(seq 1 "$ROUNDS"); do
    echo ""
    echo "[ROUND ${round}/${ROUNDS}] Firing ${REQUESTS_PER_ROUND} requests..."
    cumulative=$((round * REQUESTS_PER_ROUND))

    ensure_pf

    echo -n "  glibc..."
    g_stats=$(fire_requests $GLIBC_PORT)
    echo -n " jemalloc..."
    j_stats=$(fire_requests $JEMALLOC_PORT)
    ensure_pf
    echo -n " jemalloc+malloc..."
    p_stats=$(fire_requests $PROD_PORT)
    echo -n " glibc+malloc..."
    m_stats=$(fire_requests $GLIBCM_PORT)
    echo ""

    ensure_pf
    g=$(get_rss $GLIBC_PORT); j=$(get_rss $JEMALLOC_PORT); p=$(get_rss $PROD_PORT); m=$(get_rss $GLIBCM_PORT)
    gr=$(get_worker_restarts glibc); jr=$(get_worker_restarts jemalloc); pr=$(get_worker_restarts production); mr=$(get_worker_restarts glibc-malloc)

    read g_ok g_fail g_avg g_min g_max <<< "$g_stats"
    read j_ok j_fail j_avg j_min j_max <<< "$j_stats"
    read p_ok p_fail p_avg p_min p_max <<< "$p_stats"
    read m_ok m_fail m_avg m_min m_max <<< "$m_stats"

    echo "  glibc:          RSS=${g} ok=${g_ok} fail=${g_fail} avg=${g_avg}ms restarts=${gr}"
    echo "  jemalloc:       RSS=${j} ok=${j_ok} fail=${j_fail} avg=${j_avg}ms restarts=${jr}"
    echo "  jemalloc+malloc:RSS=${p} ok=${p_ok} fail=${p_fail} avg=${p_avg}ms restarts=${pr}"
    echo "  glibc+malloc:   RSS=${m} ok=${m_ok} fail=${m_fail} avg=${m_avg}ms restarts=${mr}"

    echo "| ${round} | ${cumulative} | glibc | ${g} | ${g_ok} | ${g_fail} | ${g_avg} | ${g_min} | ${g_max} | ${gr} |" >> "$RESULTS_FILE"
    echo "| | | jemalloc | ${j} | ${j_ok} | ${j_fail} | ${j_avg} | ${j_min} | ${j_max} | ${jr} |" >> "$RESULTS_FILE"
    echo "| | | jemalloc+malloc | ${p} | ${p_ok} | ${p_fail} | ${p_avg} | ${p_min} | ${p_max} | ${pr} |" >> "$RESULTS_FILE"
    echo "| | | glibc+malloc | ${m} | ${m_ok} | ${m_fail} | ${m_avg} | ${m_min} | ${m_max} | ${mr} |" >> "$RESULTS_FILE"

    if [ "$round" -lt "$ROUNDS" ]; then
        echo "  Waiting ${INTERVAL}s..."
        sleep "$INTERVAL"
        ensure_pf
        g2=$(get_rss $GLIBC_PORT); j2=$(get_rss $JEMALLOC_PORT); p2=$(get_rss $PROD_PORT); m2=$(get_rss $GLIBCM_PORT)
        echo "  After idle: glibc=${g2}  jemalloc=${j2}  jemalloc+malloc=${p2}  glibc+malloc=${m2}"
        echo "| | idle | glibc | ${g2} | | | | | | |" >> "$RESULTS_FILE"
        echo "| | idle | jemalloc | ${j2} | | | | | | |" >> "$RESULTS_FILE"
        echo "| | idle | jemalloc+malloc | ${p2} | | | | | | |" >> "$RESULTS_FILE"
        echo "| | idle | glibc+malloc | ${m2} | | | | | | |" >> "$RESULTS_FILE"
    fi
done

echo "" >> "$RESULTS_FILE"
echo "### Final cooldown (2 minutes idle)" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"
echo "| Time | glibc | jemalloc | jemalloc+malloc | glibc+malloc |" >> "$RESULTS_FILE"
echo "|------|-------|----------|-----------------|--------------|" >> "$RESULTS_FILE"

echo ""
echo "[FINAL COOLDOWN] 2 minutes..."
for t in 30 60 90 120; do
    sleep 30
    ensure_pf
    g=$(get_rss $GLIBC_PORT); j=$(get_rss $JEMALLOC_PORT); p=$(get_rss $PROD_PORT); m=$(get_rss $GLIBCM_PORT)
    echo "  +${t}s: glibc=${g}  jemalloc=${j}  jemalloc+malloc=${p}  glibc+malloc=${m}"
    echo "| +${t}s | ${g} | ${j} | ${p} | ${m} |" >> "$RESULTS_FILE"
done

echo "" >> "$RESULTS_FILE"
echo "### Final detailed metrics" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"
echo "| Metric | glibc | jemalloc | jemalloc+malloc | glibc+malloc |" >> "$RESULTS_FILE"
echo "|--------|-------|----------|-----------------|--------------|" >> "$RESULTS_FILE"

ensure_pf
python3 << 'PYEOF' >> "$RESULTS_FILE"
import json, urllib.request
variants = [("30080","glibc"), ("30081","jemalloc"), ("30082","jemalloc+malloc"), ("30083","glibc+malloc")]
data = {}
for port, label in variants:
    try:
        raw = urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=5).read()
        data[label] = json.loads(raw)
    except Exception:
        data[label] = {}
g, j, p, m = data["glibc"], data["jemalloc"], data["jemalloc+malloc"], data["glibc+malloc"]
for key in ["VmRSS_MiB", "RssAnon_MiB", "Private_Dirty_MiB", "VmData_MiB", "VmPeak_MiB"]:
    name = key.replace("_MiB","")
    print(f"| {name} | {g.get(key,'?')} MiB | {j.get(key,'?')} MiB | {p.get(key,'?')} MiB | {m.get(key,'?')} MiB |")
print(f"| Threads | {g.get('Threads','?')} | {j.get('Threads','?')} | {p.get('Threads','?')} | {m.get('Threads','?')} |")
print(f"| Allocator | {g.get('allocator','?')} | {j.get('allocator','?')} | {p.get('allocator','?')} | {m.get('allocator','?')} |")
print(f"| PYTHONMALLOC | {g.get('PYTHONMALLOC','?')} | {j.get('PYTHONMALLOC','?')} | {p.get('PYTHONMALLOC','?')} | {m.get('PYTHONMALLOC','?')} |")
PYEOF

# Worker restart summary
echo "" >> "$RESULTS_FILE"
echo "### Worker restart summary" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"
gr=$(get_worker_restarts glibc); jr=$(get_worker_restarts jemalloc); pr=$(get_worker_restarts production); mr=$(get_worker_restarts glibc-malloc)
echo "| Variant | Pod Restarts |" >> "$RESULTS_FILE"
echo "|---------|-------------|" >> "$RESULTS_FILE"
echo "| glibc | ${gr} |" >> "$RESULTS_FILE"
echo "| jemalloc | ${jr} |" >> "$RESULTS_FILE"
echo "| jemalloc+malloc | ${pr} |" >> "$RESULTS_FILE"
echo "| glibc+malloc | ${mr} |" >> "$RESULTS_FILE"

cat >> "$RESULTS_FILE" << 'EOF'

---

## Interpretation

- **glibc**: RSS grows with each round, never reclaims — arena fragmentation accumulates
- **jemalloc**: RSS stabilizes lower than glibc, jemalloc decay returns freed heap pages
- **jemalloc+malloc**: Lowest RSS — PYTHONMALLOC=malloc lets jemalloc reclaim pymalloc caches too
- **glibc+malloc** (worker recycling): glibc still fragments within each worker lifecycle, but `--limit-max-requests 800` kills and replaces workers after 800 requests. RSS drops at recycle boundaries then re-grows. Check the "Fail" column — some requests may fail during worker restarts.

## Grafana

Open http://127.0.0.1:30300 → Explore → Prometheus:

```promql
py_memory_vm_rss_bytes / 1024 / 1024
```

Legend: `{{allocator}}` — shows all 4 variants on one graph.
EOF

echo ""
echo "================================================================"
echo "  Results written to ${RESULTS_FILE}"
echo "================================================================"
echo ""
cat "$RESULTS_FILE"
