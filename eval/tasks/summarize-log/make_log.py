#!/usr/bin/python3 -I
"""Generates input/logs/server.log: one day of a web service with three incidents hidden in noise.

Deterministic (fixed seed), so every run sees the same file. Incidents (the reference for check.py and the judge):
1. 02:14–02:31 DB connection pool exhausted while the nightly-export job holds connections → API 503s.
2. 08:00–08:47 TLS certificate of payments.internal expired (warned from 06:00) → every payment fails.
3. worker-3 killed by OOM three times (04:10, 11:25, 18:40) after its memory grows during image-resize tasks.
"""
import random
import sys
from datetime import datetime, timedelta
from pathlib import Path

random.seed(20261029)
day = datetime(2026, 10, 28)
events = []


def log(t, level, source, message):
    events.append((t, f"{t.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3]}Z {level:<5} [{source}] {message}"))


paths = ["/api/notes", "/api/notes/{id}", "/api/search", "/api/sync", "/api/auth/refresh", "/api/attachments", "/health"]
for i in range(1900):
    t = day + timedelta(seconds=random.randint(0, 86399))
    path = random.choice(paths).replace("{id}", str(random.randint(1000, 9999)))
    method = "POST" if path.endswith("sync") else "GET"
    log(t, "INFO", "api", f"{method} {path} 200 {random.randint(4, 180)}ms req={random.getrandbits(32):08x}")
for i in range(120):
    t = day + timedelta(seconds=random.randint(0, 86399))
    log(t, "INFO", "cache", f"hit ratio {random.uniform(0.82, 0.97):.2f} size={random.randint(180, 260)}MB")
for i in range(40):
    t = day + timedelta(seconds=random.randint(0, 86399))
    log(t, "WARN", "db", f"slow query {random.uniform(1.0, 1.9):.2f}s: SELECT * FROM notes WHERE owner_id = $1 ORDER BY updated_at DESC")
for h in range(0, 24, 2):
    log(day + timedelta(hours=h, minutes=5), "INFO", "jobs", "cleanup-sessions finished removed=%d" % random.randint(10, 400))

# 1. pula połączeń
start = day + timedelta(hours=2, minutes=13, seconds=58)
log(start, "INFO", "jobs", "nightly-export started batch_size=5000 workers=40")
t = start + timedelta(seconds=9)
while t < day + timedelta(hours=2, minutes=31, seconds=40):
    log(t, "WARN", "db", "pool: waiting for connection in_use=50/50 waiters=%d" % random.randint(3, 60))
    if random.random() < 0.7:
        log(t + timedelta(milliseconds=300), "ERROR", "api", f"GET /api/notes 503 5003ms error=TimeoutError: acquiring connection from pool req={random.getrandbits(32):08x}")
    t += timedelta(seconds=random.randint(4, 15))
log(day + timedelta(hours=2, minutes=31, seconds=41), "INFO", "jobs", "nightly-export finished rows=1840213 duration=17m43s")
log(day + timedelta(hours=2, minutes=31, seconds=45), "INFO", "db", "pool: in_use=7/50 waiters=0")

# 2. certyfikat
for m in range(0, 120, 30):
    left = 120 - m
    log(day + timedelta(hours=6, minutes=m), "WARN", "tls", f"certificate for payments.internal expires in {left} min (not after 2026-10-28T08:00:00Z)")
t = day + timedelta(hours=8)
while t < day + timedelta(hours=8, minutes=47):
    log(t, "ERROR", "payments", f"charge failed customer=cus_{random.getrandbits(24):06x}: TLS handshake failed: x509: certificate has expired")
    t += timedelta(seconds=random.randint(20, 90))
log(day + timedelta(hours=8, minutes=47, seconds=12), "INFO", "tls", "certificate for payments.internal renewed, not after 2027-01-26T08:47:00Z")
log(day + timedelta(hours=8, minutes=48), "INFO", "payments", "charge ok customer=cus_4f21aa amount=89.99 PLN")

# 3. worker-3 OOM
for kill in [(4, 10), (11, 25), (18, 40)]:
    end = day + timedelta(hours=kill[0], minutes=kill[1])
    for k in range(12):
        t = end - timedelta(minutes=60 - k * 5)
        log(t, "INFO", "worker-3", f"task image-resize done items={random.randint(20, 80)}")
        log(t + timedelta(seconds=2), "WARN" if k > 7 else "INFO", "worker-3", f"rss={1.2 + k * 0.25:.2f}GB")
    log(end, "ERROR", "supervisor", "worker-3 killed: out of memory (rss=4.00GB limit=4GB)")
    log(end + timedelta(seconds=3), "INFO", "supervisor", "worker-3 restarted pid=%d" % random.randint(20000, 60000))

events.sort()
out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "input/logs/server.log"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("\n".join(line for _, line in events) + "\n")
print(f"{len(events)} lines → {out}")
