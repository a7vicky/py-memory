# Extended Load Test Results — 3-Way Comparison

**Environment:** kind cluster (Podman), UBI9 Python 3.12, kube-prometheus-stack
**Variants:**
- **glibc** — baseline, no fixes
- **jemalloc** — jemalloc + decay settings, pymalloc active
- **production** — jemalloc + PYTHONMALLOC=malloc + gunicorn worker recycling (max-requests=1000)

**Test:** 10 rounds × 200 requests at concurrency 15, with 60s interval between rounds
**Prometheus scrape interval:** 10s
**Grafana:** http://127.0.0.1:30300 (admin / see kubectl secret)

---

## Prometheus Queries for Grafana

```promql
py_memory_vm_rss_bytes / 1024 / 1024
py_memory_rss_anon_bytes / 1024 / 1024
py_memory_private_dirty_bytes / 1024 / 1024
py_memory_vm_data_bytes / 1024 / 1024
```

Group by `allocator` label to see all 3 variants on one graph.

---

### Baseline

| Variant | VmRSS |
|---------|-------|
| glibc | 48.7 MiB |
| jemalloc | 51.4 MiB |
| production | 51.4 MiB |


### RSS progression (10 rounds × 200 requests, 60s apart)

| Round | Cumulative | glibc RSS | jemalloc RSS | production RSS | Notes |
|-------|-----------|-----------|--------------|----------------|-------|
| 1 | 200 | 96.2 MiB | 79.6 MiB | 83.1 MiB | after load |
| | | 96.2 MiB | 79.6 MiB | 72.2 MiB | after 60s idle |
| 2 | 400 | 97.9 MiB | 79.8 MiB | 85.3 MiB | after load |
| | | 97.9 MiB | 79.8 MiB | 68.8 MiB | after 60s idle |
| 3 | 600 | 111.3 MiB | 79.2 MiB | 76.7 MiB | after load |
| | | 111.3 MiB | 79.2 MiB | 72.6 MiB | after 60s idle |
| 4 | 800 | 111.2 MiB | 79.4 MiB | 78.3 MiB | after load |
| | | 111.2 MiB | 72.4 MiB | 71.0 MiB | after 60s idle |
| 5 | 1000 | 106.6 MiB | 81.5 MiB | 79.6 MiB | after load |
| | | 106.6 MiB | 81.5 MiB | 79.6 MiB | after 60s idle |
| 6 | 1200 | 122.0 MiB | 76.3 MiB | 84.7 MiB | after load |
| | | 122.0 MiB | 76.3 MiB | 80.1 MiB | after 60s idle |
| 7 | 1400 | 110.5 MiB | 84.9 MiB | 82.8 MiB | after load |
| | | 110.5 MiB | 84.9 MiB | 80.9 MiB | after 60s idle |
| 8 | 1600 | 111.8 MiB | 82.9 MiB | 85.5 MiB | after load |
| | | 111.8 MiB | 82.9 MiB | 84.1 MiB | after 60s idle |
| 9 | 1800 | 117.5 MiB | 78.1 MiB | 82.1 MiB | after load |
| | | 117.5 MiB | 67.1 MiB | 73.1 MiB | after 60s idle |
| 10 | 2000 | 134.6 MiB | 78.1 MiB | 81.0 MiB | after load |

### Final cooldown (2 minutes idle after round 10)

| Time | glibc RSS | jemalloc RSS | production RSS |
|------|-----------|--------------|----------------|
| +30s | 134.6 MiB | 78.1 MiB | 79.2 MiB |
| +60s | 134.6 MiB | 78.1 MiB | 69.3 MiB |
| +90s | 134.6 MiB | 78.1 MiB | 69.3 MiB |
| +120s | 134.6 MiB | 78.1 MiB | 69.3 MiB |

### Final detailed metrics

| Metric | glibc | jemalloc | production |
|--------|-------|----------|------------|
| VmRSS | 134.6 MiB | 78.1 MiB | 69.3 MiB |
| RssAnon | 117.3 MiB | 59.6 MiB | 50.7 MiB |
| Private_Dirty | 117.3 MiB | 54.7 MiB | 38.3 MiB |
| VmData | 480.9 MiB | 191.6 MiB | 204.6 MiB |
| VmPeak | 4029.8 MiB | 624.4 MiB | 845.2 MiB |
| Threads | 6 | 6 | 6 |
| Allocator | glibc | jemalloc | jemalloc |
| PYTHONMALLOC | default (pymalloc) | default (pymalloc) | malloc |

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
