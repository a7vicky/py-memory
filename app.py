import asyncio
import json
import os
import random
import re
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from fastapi import FastAPI

app = FastAPI(title="glibc malloc fragmentation reproducer")

executor = ThreadPoolExecutor(max_workers=40)


def _allocate_and_churn():
    """Simulate LangGraph-style alloc/free churn in a thread.

    Allocates variable-sized buffers, does work (JSON encode, string concat),
    then lets them go out of scope. Leaves small residual objects scattered
    across glibc arenas to pin pages — exactly what happens in production
    with LLM request processing.
    """
    residuals = []
    for _ in range(80):
        size = random.randint(4096, 2 * 1024 * 1024)
        buf = bytearray(size)
        buf[:128] = b"x" * 128
        payload = {"data": buf[:512].hex(), "size": size, "nested": {"keys": list(range(50))}}
        serialized = json.dumps(payload)
        _ = json.loads(serialized)
        small_bufs = [bytearray(random.randint(64, 4096)) for _ in range(10)]
        del small_bufs
        if random.random() < 0.08:
            residuals.append(bytearray(random.randint(64, 2048)))
    return len(residuals)


@app.get("/churn")
async def churn():
    loop = asyncio.get_event_loop()
    futs = [loop.run_in_executor(executor, _allocate_and_churn) for _ in range(20)]
    results = await asyncio.gather(*futs)
    return {"threads": len(results), "residuals": sum(results)}


@app.get("/metrics")
async def metrics():
    info = {}
    status = Path("/proc/self/status").read_text()
    for key in ("VmPeak", "VmSize", "VmRSS", "VmData", "RssAnon", "RssFile", "VmStk", "Threads"):
        m = re.search(rf"^{key}:\s+(\d+)\s+kB", status, re.MULTILINE)
        if m:
            info[key + "_MiB"] = round(int(m.group(1)) / 1024, 1)
        elif key == "Threads":
            m = re.search(rf"^{key}:\s+(\d+)", status, re.MULTILINE)
            if m:
                info[key] = int(m.group(1))

    try:
        smaps = Path("/proc/self/smaps_rollup").read_text()
        for key in ("Private_Dirty", "AnonHugePages", "Shared_Clean"):
            m = re.search(rf"^{key}:\s+(\d+)\s+kB", smaps, re.MULTILINE)
            if m:
                info[key + "_MiB"] = round(int(m.group(1)) / 1024, 1)
    except (PermissionError, FileNotFoundError):
        info["smaps_rollup"] = "unavailable (needs SYS_PTRACE)"

    info["allocator"] = "jemalloc" if os.environ.get("LD_PRELOAD", "").find("jemalloc") >= 0 else "glibc"
    info["MALLOC_CONF"] = os.environ.get("MALLOC_CONF", "not set")
    return info


@app.get("/health")
async def health():
    return {"status": "ok"}
