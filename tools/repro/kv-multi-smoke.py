#!/usr/bin/env python3
"""A' control workload: N large conversations, R rounds; each round sends all N IN PARALLEL.

Trigger model (handoff 2026-10-07): the failing quantity is the total live KV of the
concurrently active large conversations.  With --kv-resident 131072 (131K cells) and
--conversation-cache-mib 6144, two ~120K conversations can be live at once (240K > window)
-> per-request PCIe KV streaming -> GPU saturation -> the concurrent verify graph starves
past its 5 s/layer deadline -> "verify: timed out".  At 3072 only one ~120K conversation
fits, so live KV stays inside the window and the timeout should not occur.

Round 2 re-sends the same texts, so the conversation cache restores the parked
conversations (a cheap stand-in for the multi-turn re-query that triggered the failures
in real use).

First run (2026-10-07 23:43, 2 x 100K, 2 rounds, 16 out tokens): 4/4 OK, 0 timeouts at
BOTH 6144 and 3072, streaming only ~110-140 MiB per request.  The real failures streamed
200-465 MiB -> this workload is too mild to reproduce; use bigger conversations / longer
generations (e.g. SIZES=160000,130000,100000 MAXTOK=512).

usage: kv-multi-smoke.py [SIZES=100000,100000] [ROUNDS=2] [PORT=8090] [MAXTOK=16] [LABEL=workload]
  SIZES: comma-separated word counts (~1 token per word), one per conversation
  TIMEOUT env var (seconds, default 900): per-request client timeout - keep it short when
  the point is "does it still finish promptly", not "how long does it grind".
exit 0 iff every request completed.
"""
import concurrent.futures, json, os, random, sys, time, urllib.request, urllib.error

SIZES  = [int(x) for x in (sys.argv[1] if len(sys.argv) > 1 else "100000,100000").split(",")]
ROUNDS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
PORT   = int(sys.argv[3]) if len(sys.argv) > 3 else 8088
MAXTOK = int(sys.argv[4]) if len(sys.argv) > 4 else 16
LABEL  = sys.argv[5] if len(sys.argv) > 5 else "workload"
TIMEOUT = int(os.environ.get("TIMEOUT", "900"))
N      = len(SIZES)
BASE   = f"http://127.0.0.1:{PORT}"
MODEL  = json.load(open("/home/ai/Strata/strata-iq3_s.json"))["model_name"]

vocab = ("the of and a in that it was to be is are for with as his they had i he she you "
         "not have at from by one this we but what their all when who they can there "
         "will would could should each some than which or if into about out off over "
         "under again then so both up down out now no yes maybe often always never "
         "new old good big small large first last next right left time day year "
         "work home school money power water earth light sound music color name word "
         "story problem question answer thought feeling moment way world life people").split()

def make_text(seed, words):
    rng = random.Random(seed)
    return " ".join(rng.choice(vocab) for _ in range(words))

def ask(conv, rnd):
    text = make_text(100 + conv, SIZES[conv])   # same text every round -> the parked conversation is restored
    body = json.dumps({"model": MODEL,
                       "messages": [{"role": "user", "content": text}],
                       "max_tokens": MAXTOK}).encode()
    r = urllib.request.Request(BASE + "/v1/chat/completions", data=body,
                               headers={"Content-Type": "application/json",
                                        "Authorization": "Bearer ninfer-local"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(r, timeout=TIMEOUT) as f:
            d = json.loads(f.read().decode())
        return f"{LABEL} r{rnd} conv{conv}: OK in {time.time()-t0:.1f}s usage={d.get('usage', {})}"
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:160]
        return f"{LABEL} r{rnd} conv{conv}: HTTP {e.code} after {time.time()-t0:.1f}s: {body}"
    except Exception as e:
        return f"{LABEL} r{rnd} conv{conv}: FAILED after {time.time()-t0:.1f}s: {e}"

lines = []
for rnd in range(ROUNDS):
    with concurrent.futures.ThreadPoolExecutor(max_workers=N) as ex:
        lines += list(ex.map(lambda i: ask(i, rnd), range(N)))
    for l in lines[-N:]:
        print(l, flush=True)
fails = sum("FAILED" in l for l in lines)
print(f"{LABEL}: {len(lines)-fails}/{len(lines)} requests completed")
sys.exit(1 if fails else 0)
