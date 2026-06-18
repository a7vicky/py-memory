# py-memory: glibc malloc fragmentation reproducer

Demonstrates glibc malloc arena fragmentation in a multi-threaded Python (FastAPI) workload on UBI9, and validates that **jemalloc** fixes the memory retention issue.

## Problem

Python apps using FastAPI/LangGraph on UBI9 (glibc) grow RSS under load and **never release memory back to the OS**, even when idle. This is caused by:

- **glibc malloc arenas** — up to `8 × cores` independent heaps; freed memory in one arena can't be reused by another
- **Fragmentation** — small live objects scattered across pages prevent whole-page reclamation
- **Transparent Huge Pages (THP)** — 2 MiB pages can't be partially released, amplifying retention

## Fix

Replace glibc malloc with **jemalloc** via `LD_PRELOAD`. jemalloc actively decays freed pages back to the OS on a timer and limits arena count.

```
LD_PRELOAD=/usr/lib64/libjemalloc.so.2
MALLOC_CONF=dirty_decay_ms:5000,muzzy_decay_ms:10000,narenas:2
```

## Quick start

```bash
bash loadtest.sh
```

This builds both images, runs a load test, and prints a comparison table.

## Files

| File | Description |
|------|-------------|
| `app.py` | FastAPI app with `/churn` (memory stress), `/metrics` (RSS reporting), `/health` |
| `Dockerfile.glibc` | Baseline — UBI9 Python 3.12, glibc malloc (broken) |
| `Dockerfile.jemalloc` | Fix — same image + jemalloc with decay settings |
| `loadtest.sh` | Builds, runs, loads, measures, compares |

## Expected results

```
Allocator    Baseline       Peak   After 45s
--------------------------------------------
glibc            ~50       ~500       ~480    ← RSS stays high (fragmentation)
jemalloc         ~50       ~500       ~80     ← RSS drops back (jemalloc decay)
```

Exact numbers depend on host resources, but the pattern is consistent: glibc retains, jemalloc releases.

## References

- [DW-2723](https://redhat.atlassian.net/browse/DW-2723) — SA 2.0 Pod RSS memory not releasing back to OS
- [jemalloc tuning](https://jemalloc.net/jemalloc.3.html) — `dirty_decay_ms`, `muzzy_decay_ms`, `narenas`
