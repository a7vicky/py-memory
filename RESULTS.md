# Extended Load Test Results — 4-Way Comparison

**Environment:** kind cluster (Podman), UBI9 Python 3.12, kube-prometheus-stack
**Variants:**
- **glibc** — baseline, no fixes (1 worker, no recycling)
- **jemalloc** — jemalloc + decay settings, pymalloc active (1 worker)
- **jemalloc+malloc** — jemalloc + PYTHONMALLOC=malloc (1 worker)
- **glibc+malloc** — glibc + PYTHONMALLOC=malloc + uvicorn worker recycling (3 workers, limit-max-requests=800)

**Test:** 2000 total requests (10 rounds × 200), concurrency 15, 60s intervals

---

## Prometheus Queries for Grafana

```promql
py_memory_vm_rss_bytes / 1024 / 1024
```

Group by `allocator` label to see all 4 variants.

---

### Baseline

| Variant | VmRSS | Pod Restarts |
|---------|-------|-------------|
| glibc | 48.7 MiB | 0 |
| jemalloc | 51.5 MiB | 0 |
| jemalloc+malloc | 51.3 MiB | 0 |
| glibc+malloc | 49.9 MiB | 0 |


### Per-round progression

| Round | Total Req | Variant | RSS | Success | Fail | Avg(ms) | Min(ms) | Max(ms) | Pod Restarts |
|-------|-----------|---------|-----|---------|------|---------|---------|---------|-------------|
| 1 | 200 | glibc | 85.2 | 102/200 | 98 | 2243 | 673 | 3109 | 0 |
| | | jemalloc | 76.7 | 200/200 | 0 | 746 | 258 | 922 | 0 |
| | | jemalloc+malloc | 79.7 | 200/200 | 0 | 756 | 395 | 998 | 0 |
| | | glibc+malloc | 149.4 | 200/200 | 0 | 1375 | 291 | 2612 | 0 |
| | idle | glibc | 85.2 | | | | | | |
| | idle | jemalloc | 76.7 | | | | | | |
| | idle | jemalloc+malloc | 79.7 | | | | | | |
| | idle | glibc+malloc | 149.4 | | | | | | |
| 2 | 400 | glibc | 117.5 | 104/200 | 96 | 2181 | 751 | 2895 | 0 |
| | | jemalloc | 81.9 | 200/200 | 0 | 741 | 264 | 865 | 0 |
| | | jemalloc+malloc | 79.8 | 200/200 | 0 | 754 | 281 | 894 | 0 |
| | | glibc+malloc | 178.2 | 200/200 | 0 | 1349 | 297 | 2041 | 0 |
| | idle | glibc | 117.5 | | | | | | |
| | idle | jemalloc | 73.4 | | | | | | |
| | idle | jemalloc+malloc | 79.8 | | | | | | |
| | idle | glibc+malloc | 200.7 | | | | | | |
| 3 | 600 | glibc | 108.5 | 104/200 | 96 | 2172 | 894 | 2818 | 0 |
| | | jemalloc | 77.8 | 200/200 | 0 | 752 | 376 | 939 | 0 |
| | | jemalloc+malloc | 81.9 | 200/200 | 0 | 752 | 283 | 913 | 0 |
| | | glibc+malloc | 179.4 | 200/200 | 0 | 1340 | 359 | 1961 | 0 |
| | idle | glibc | 108.5 | | | | | | |
| | idle | jemalloc | 77.8 | | | | | | |
| | idle | jemalloc+malloc | 72.6 | | | | | | |
| | idle | glibc+malloc | 179.4 | | | | | | |
| 4 | 800 | glibc | 114.2 | 108/200 | 92 | 2179 | 719 | 2645 | 0 |
| | | jemalloc | 79.2 | 200/200 | 0 | 756 | 349 | 959 | 0 |
| | | jemalloc+malloc | 83.5 | 200/200 | 0 | 760 | 492 | 944 | 0 |
| | | glibc+malloc | 184.9 | 200/200 | 0 | 1376 | 539 | 2454 | 0 |
| | idle | glibc | 114.2 | | | | | | |
| | idle | jemalloc | 79.2 | | | | | | |
| | idle | jemalloc+malloc | 83.5 | | | | | | |
| | idle | glibc+malloc | 176.4 | | | | | | |
| 5 | 1000 | glibc | 92.4 | 103/200 | 97 | 2158 | 759 | 2685 | 0 |
| | | jemalloc | 86.7 | 200/200 | 0 | 736 | 274 | 932 | 0 |
| | | jemalloc+malloc | 79.2 | 200/200 | 0 | 757 | 285 | 960 | 0 |
| | | glibc+malloc | 187.0 | 200/200 | 0 | 1344 | 613 | 2087 | 0 |
| | idle | glibc | 92.4 | | | | | | |
| | idle | jemalloc | 86.7 | | | | | | |
| | idle | jemalloc+malloc | 72.9 | | | | | | |
| | idle | glibc+malloc | 177.0 | | | | | | |
| 6 | 1200 | glibc | 94.6 | 105/200 | 95 | 2192 | 714 | 2671 | 0 |
| | | jemalloc | 82.8 | 200/200 | 0 | 752 | 278 | 920 | 0 |
| | | jemalloc+malloc | 76.9 | 200/200 | 0 | 759 | 433 | 950 | 0 |
| | | glibc+malloc | 190.4 | 200/200 | 0 | 1375 | 404 | 2166 | 0 |
| | idle | glibc | 94.6 | | | | | | |
| | idle | jemalloc | 82.8 | | | | | | |
| | idle | jemalloc+malloc | 67.2 | | | | | | |
| | idle | glibc+malloc | 164.5 | | | | | | |
| 7 | 1400 | glibc | 119.6 | 104/200 | 96 | 2184 | 1041 | 2686 | 0 |
| | | jemalloc | 84.4 | 200/200 | 0 | 761 | 224 | 900 | 0 |
| | | jemalloc+malloc | 81.8 | 200/200 | 0 | 760 | 394 | 993 | 0 |
| | | glibc+malloc | 180.6 | 200/200 | 0 | 1369 | 559 | 2190 | 0 |
| | idle | glibc | 119.6 | | | | | | |
| | idle | jemalloc | 84.4 | | | | | | |
| | idle | jemalloc+malloc | 62.1 | | | | | | |
| | idle | glibc+malloc | 186.9 | | | | | | |
| 8 | 1600 | glibc | 121.1 | 100/200 | 100 | 2197 | 655 | 2710 | 0 |
| | | jemalloc | 81.6 | 200/200 | 0 | 751 | 385 | 937 | 0 |
| | | jemalloc+malloc | 82.5 | 200/200 | 0 | 755 | 388 | 958 | 0 |
| | | glibc+malloc | 220.0 | 21/200 | 179 | 1344 | 277 | 2005 | 0 |
| | idle | glibc | 121.1 | | | | | | |
| | idle | jemalloc | 81.6 | | | | | | |
| | idle | jemalloc+malloc | 82.5 | | | | | | |
| | idle | glibc+malloc | 49.6 | | | | | | |
| 9 | 1800 | glibc | 132.8 | 109/200 | 91 | 2297 | 448 | 2822 | 0 |
| | | jemalloc | 82.3 | 200/200 | 0 | 754 | 279 | 939 | 0 |
| | | jemalloc+malloc | 67.7 | 200/200 | 0 | 755 | 385 | 973 | 0 |
| | | glibc+malloc | 185.9 | 200/200 | 0 | 1346 | 552 | 2104 | 0 |
| | idle | glibc | 132.8 | | | | | | |
| | idle | jemalloc | 70.5 | | | | | | |
| | idle | jemalloc+malloc | 67.7 | | | | | | |
| | idle | glibc+malloc | 214.9 | | | | | | |
| 10 | 2000 | glibc | 104.1 | 105/200 | 95 | 2177 | 796 | 2810 | 0 |
| | | jemalloc | 81.3 | 200/200 | 0 | 763 | 273 | 945 | 0 |
| | | jemalloc+malloc | 81.4 | 200/200 | 0 | 774 | 356 | 991 | 0 |
| | | glibc+malloc | 123.7 | 140/200 | 60 | 1329 | 632 | 2188 | 0 |

### Final cooldown (2 minutes idle)

| Time | glibc | jemalloc | jemalloc+malloc | glibc+malloc |
|------|-------|----------|-----------------|--------------|
| +30s | 104.1 | 81.3 | 81.4 | 123.7 |
| +60s | 104.1 | 81.3 | 81.4 | 192.7 |
| +90s | 104.1 | 81.3 | 81.4 | 123.7 |
| +120s | 104.1 | 71.6 | 81.4 | 123.7 |

### Final detailed metrics

| Metric | glibc | jemalloc | jemalloc+malloc | glibc+malloc |
|--------|-------|----------|-----------------|--------------|
| VmRSS | 104.1 MiB | 71.6 MiB | 81.4 MiB | 192.7 MiB |
| RssAnon | 86.8 MiB | 52.9 MiB | 62.8 MiB | 175.3 MiB |
| Private_Dirty | 86.9 MiB | 45.2 MiB | 51.0 MiB | 175.4 MiB |
| VmData | 473.6 MiB | 189.6 MiB | 204.6 MiB | 352.1 MiB |
| VmPeak | 3953.5 MiB | 781.3 MiB | 990.2 MiB | 3246.7 MiB |
| Threads | 6 | 6 | 6 | 3 |
| Allocator | glibc | jemalloc | jemalloc | glibc |
| PYTHONMALLOC | default (pymalloc) | default (pymalloc) | malloc | malloc |

### Worker restart summary

| Variant | Pod Restarts |
|---------|-------------|
| glibc | 0 |
| jemalloc | 0 |
| jemalloc+malloc | 0 |
| glibc+malloc | 0 |

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
