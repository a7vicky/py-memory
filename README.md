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

### Podman (local containers)

```bash
bash loadtest.sh
```

Builds both images, runs a load test, and prints a comparison table.

### Kubernetes (kind + Prometheus)

```bash
# Create kind cluster
export KIND_EXPERIMENTAL_PROVIDER=podman
kind create cluster --config kind-config.yaml

# Load images
podman save py-memory-glibc:latest | kind load image-archive /dev/stdin --name py-memory
podman save py-memory-jemalloc:latest | kind load image-archive /dev/stdin --name py-memory

# Install Prometheus operator
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.service.type=NodePort \
  --set prometheus.service.nodePort=30090 \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30300 \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait

# Deploy apps
kubectl apply -f k8s/

# Access points:
#   glibc app:    http://127.0.0.1:30080
#   jemalloc app: http://127.0.0.1:30081
#   Prometheus:   http://127.0.0.1:30090
#   Grafana:      http://127.0.0.1:30300
```

## Files

| File | Description |
|------|-------------|
| `app.py` | FastAPI app with `/churn`, `/metrics`, `/prom-metrics`, `/health` |
| `Dockerfile.glibc` | Baseline — UBI9 Python 3.12, glibc malloc |
| `Dockerfile.jemalloc` | Fix — same image + jemalloc with decay settings |
| `loadtest.sh` | Builds, runs, loads, measures, compares |
| `kind-config.yaml` | Kind cluster with NodePort mappings |
| `k8s/` | Namespace, Deployments, Services, ServiceMonitor |

## Expected results

```
Allocator    Baseline       Peak   After 60s
--------------------------------------------
glibc            ~47       ~181       ~181    ← RSS stays at peak (fragmentation)
jemalloc         ~49        ~95        ~95    ← ~50% less RSS under same load
```

## Prometheus metrics

| Metric | Description |
|--------|-------------|
| `py_memory_vm_rss_bytes{allocator}` | Resident Set Size (physical RAM) |
| `py_memory_rss_anon_bytes{allocator}` | Anonymous heap RSS |
| `py_memory_private_dirty_bytes{allocator}` | True dirty memory footprint |
| `py_memory_vm_data_bytes{allocator}` | Virtual heap size (arena sprawl) |
| `py_memory_threads{allocator}` | Thread count |
| `py_memory_churn_requests_total{allocator}` | Churn request counter |

---

## Memory concepts explained

### Virtual memory vs RSS

Every process has two views of memory:

- **Virtual memory** (`VmSize`, `VmData`) — the address space the process has reserved. The OS maps pages but doesn't allocate physical RAM until the process writes to them.
- **RSS** (Resident Set Size, `VmRSS`) — the physical RAM actually occupied right now. This is what matters for cluster capacity.

```
Virtual Address Space (4 GiB):
┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
│ Used │ │ Free │ │ Used │ │ Free │   ← Process sees all of this
└──────┘ └──────┘ └──────┘ └──────┘

Physical RAM (RSS = 1.6 GiB):
┌──────┐            ┌──────┐
│ Used │            │ Used │            ← Only these are in RAM
└──────┘            └──────┘
```

The gap between `VmData` and `VmRSS` represents virtual space that was used, freed by the app, but the allocator is still holding onto.

### Key `/proc` metrics

| Metric | What it means |
|--------|---------------|
| `VmRSS` | Physical RAM used right now |
| `VmData` | Total heap virtual space mapped |
| `VmPeak` | Highest virtual memory ever reached |
| `RssAnon` | RSS from anonymous (heap) pages — not files |
| `RssFile` | RSS from file-backed pages (shared libs) |
| `Private_Dirty` | Memory written by this process only (truest footprint) |
| `AnonHugePages` | Portion locked in 2 MiB THP pages |

### How glibc malloc works

When Python calls `malloc(size)`, glibc doesn't go to the kernel every time. It maintains a user-space heap manager with free lists:

```
Application
    │
    ▼
┌─────────────────────────────────┐
│  glibc malloc (user space)       │
│  ┌───────────────────────────┐  │
│  │ Arena 1                   │  │
│  │ ┌───┬────┬───┬────┬───┐  │  │
│  │ │ A │free│ B │free│ C │  │  │   ← Chunks: allocated and free
│  │ └───┴────┴───┴────┴───┘  │  │
│  └───────────────────────────┘  │
│  ┌───────────────────────────┐  │
│  │ Arena 2                   │  │
│  │ ┌────┬───┬────┬───┐      │  │
│  │ │free│ D │free│ E │      │  │
│  │ └────┴───┴────┴───┘      │  │
│  └───────────────────────────┘  │
└─────────────────────────────────┘
    │
    ▼ (only when it needs MORE memory)
  Linux Kernel (mmap/brk)
```

When `free(ptr)` is called, glibc marks the chunk as free **in its own bookkeeping** but does **NOT** return the page to the OS. The freed memory sits in the free list, ready for the next `malloc`.

### Arenas and threading

In multi-threaded programs, glibc creates multiple arenas (up to `8 × CPU cores`) to reduce lock contention:

```
Thread 1 ──→ Arena 0   (no lock contention)
Thread 2 ──→ Arena 1
Thread 3 ──→ Arena 2
...
Thread 40 ──→ Arena N
```

Each arena maintains its own free list **independently**. Memory freed in Arena 1 cannot be reused by Arena 2:

```
Arena 0: [████░░░░████]    ← 50% free, scattered
Arena 1: [██░░██░░░░██]    ← 60% free, scattered
Arena 2: [░░░░░░░░░░░░]    ← 100% free, but glibc keeps the mapping
Arena 3: [████████░░░░]    ← 25% free

░ = freed but NOT returned to OS
█ = in use
```

### Memory fragmentation

Fragmentation means free memory is scattered in small pieces between allocated chunks. The OS works in pages (4 KiB) and can only reclaim a page if the **entire page** is free:

```
One 4 KiB page:
┌────────────────────────────────────┐
│ obj1(free) │ obj2(USED) │ obj3(free) │   ← Can't release! One object pins 4096 bytes
└────────────────────────────────────┘
```

In a FastAPI/LangGraph workload, each request allocates and frees across multiple arenas. Over thousands of requests, small live objects scatter across arenas, pinning pages permanently.

### Transparent Huge Pages (THP)

The kernel can promote frequently-used 4 KiB pages into 2 MiB "huge pages" for TLB efficiency. But this makes reclamation granularity 512× worse:

```
Without THP:  Can release individual 4 KiB pages    → fine-grained reclaim
With THP:     Must release entire 2 MiB huge page    → one 40-byte object pins 2 MiB
```

From production: `AnonHugePages: ~1,100 MiB` — over a gigabyte locked in huge pages that can't be partially released.

### Why jemalloc fixes this

jemalloc replaces glibc's malloc entirely via `LD_PRELOAD`:

| Feature | glibc malloc | jemalloc |
|---------|-------------|----------|
| Arena count | Up to 8×cores (unbounded) | Controllable (`narenas:2`) |
| Returning memory to OS | Almost never | Active decay on a timer |
| Fragmentation | Free lists, no compaction | Size-class slabs, much less fragmentation |

The jemalloc decay timeline:

```
t=0s    App frees memory → page marked "dirty"
t=5s    dirty_decay_ms → page moved to "muzzy" (kernel can reuse)
t=10s   muzzy_decay_ms → page fully unmapped → OS reclaims RAM → RSS drops
```

### The `malloc_trim(0)` stopgap

`malloc_trim(0)` forces glibc to return free pages **at the top of the heap** to the OS. But it only helps with contiguous free space at the end — it can't fix fragmentation in the middle of arenas. It's a stopgap, not a solution.

### The full picture

```
FastAPI + LangGraph (40+ threads, heavy alloc/free churn)
         │
         ▼
glibc malloc creates ~30+ arenas (8 × cores)
         │
         ▼
Memory fragments across arenas (small live objects pin pages)
         │
         ▼
THP promotes heap to 2 MiB pages (can't partially release)
         │
         ▼
free() returns memory to glibc, NOT to the OS
         │
         ▼
RSS grows to 1.8 GiB and never shrinks, even at idle
         │
         ▼
20 pods × ~1.2 GiB wasted ≈ 15 GiB cluster waste
```

**jemalloc breaks this cycle** by actively decaying freed pages back to the OS on a timer, with controlled arena count to minimize fragmentation.

## References

- [DW-2723](https://redhat.atlassian.net/browse/DW-2723) — SA 2.0 Pod RSS memory not releasing back to OS
- [jemalloc tuning](https://jemalloc.net/jemalloc.3.html) — `dirty_decay_ms`, `muzzy_decay_ms`, `narenas`
- [glibc malloc internals](https://sourceware.org/glibc/wiki/MallocInternals) — arena design, threading model
- [THP documentation](https://www.kernel.org/doc/html/latest/admin-guide/mm/transhuge.html) — Transparent Huge Pages
