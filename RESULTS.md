# Load Test Results — Kind Cluster with Prometheus

**Environment:** kind cluster (Podman), UBI9 Python 3.12, kube-prometheus-stack
**Test:** 1000 total requests (5 rounds × 200 requests) at concurrency 15 per allocator
**Prometheus scrape interval:** 10s

---

### Baseline (idle, before load)

| Metric | glibc | jemalloc |
|--------|-------|----------|
| vm_rss | 48.6 MiB | 51.6 MiB |
| rss_anon | 31.5 MiB | 32.9 MiB |
| private_dirty | 31.5 MiB | 32.9 MiB |
| vm_data | 64.2 MiB | 80.0 MiB |
| threads | 6 | 6 |


### Per-round RSS progression

| Round | Requests (cumulative) | glibc RSS | jemalloc RSS |
|-------|-----------------------|-----------|--------------|
| 1 | 200 | 103.4 MiB | 82.1 MiB |
| 2 | 400 | 97.0 MiB | 84.6 MiB |
| 3 | 600 | 102.5 MiB | 81.5 MiB |
| 4 | 800 | 112.1 MiB | 79.3 MiB |
| 5 | 1000 | 100.8 MiB | 82.6 MiB |

### After load (1000 requests each)

| Metric | glibc | jemalloc |
|--------|-------|----------|
| vm_rss | 100.8 MiB | 82.6 MiB |
| rss_anon | 83.6 MiB | 63.9 MiB |
| private_dirty | 83.7 MiB | 51.0 MiB |
| vm_data | 386.9 MiB | 183.6 MiB |
| threads | 6 | 6 |


### Cooldown RSS progression

| Time | glibc RSS | jemalloc RSS |
|------|-----------|--------------|
| +15s | 100.8 MiB | 82.6 MiB |
| +30s | 100.8 MiB | 82.6 MiB |
| +45s | 100.8 MiB | 82.6 MiB |
| +60s | 100.8 MiB | 82.6 MiB |

### After 60s cooldown (idle)

| Metric | glibc | jemalloc |
|--------|-------|----------|
| vm_rss | 100.8 MiB | 82.6 MiB |
| rss_anon | 83.6 MiB | 63.9 MiB |
| private_dirty | 83.7 MiB | 51.0 MiB |
| vm_data | 386.9 MiB | 183.6 MiB |
| threads | 6 | 6 |

---

## Interpretation

- **glibc RSS stays at peak** after load and never drops during cooldown — freed memory is trapped in fragmented arenas
- **jemalloc RSS is significantly lower** under identical load — active page decay returns freed pages to the OS
- **Private_Dirty** for jemalloc is lower than RssAnon, confirming jemalloc is actively cleaning dirty pages
- **VmData** shows glibc's arena sprawl (much higher virtual mapping than jemalloc)
- Neither allocator returns fully to baseline — this is expected due to Python runtime caches (interned strings, module caches, pymalloc free lists) that grow during request handling and are never released by CPython

## Prometheus Queries

```promql
py_memory_vm_rss_bytes{allocator="glibc"}
py_memory_vm_rss_bytes{allocator="jemalloc"}
py_memory_rss_anon_bytes
py_memory_private_dirty_bytes
py_memory_vm_data_bytes
py_memory_threads
```

Access Prometheus at `http://127.0.0.1:30090` to graph these over time.
