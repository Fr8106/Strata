#!/usr/bin/env python3
"""Regression test for the 2026-10-07 verify-timeout failure: a 127K-token prompt against
strata on 8088.  With --kv-resident 131072 the whole prompt fits the VRAM-resident KV window,
so no PCIe streaming and no verify-graph stall (the old 32768 setting streamed ~95K cells
and the saturated GPU missed the verify window's 5 s deadline)."""
import json, random, sys, time, urllib.request

BASE = "http://127.0.0.1:8088"
MODEL = json.load(open("/home/ai/Strata/strata-iq3_s.json"))["model_name"]

rng = random.Random(7)
vocab = ("the of and a in that it was to be is are for with as his they had i he she you "
         "not have at from by one this we but what their all when who they can there "
         "will would could should each some than which or if into about out off over "
         "under again then so both up down out now no yes maybe often always never "
         "new old good big small large first last next right left time day year "
         "work home school money power water earth light sound music color name word "
         "story problem question answer thought feeling moment way world life people").split()
# ~127K tokens: ~4 chars/token
text = " ".join(rng.choice(vocab) for _ in range(127000))
body = json.dumps({"model": MODEL,
                  "messages": [{"role": "user", "content": text}],
                  "max_tokens": 32}).encode()
print(f"sending {len(text)//4} prompt tokens ({len(text)//1024} KiB)", flush=True)
t0 = time.time()
r = urllib.request.Request(BASE + "/v1/chat/completions", data=body,
                           headers={"Content-Type": "application/json",
                                    "Authorization": "Bearer ninfer-local"})
try:
    with urllib.request.urlopen(r, timeout=600) as f:
        data = json.loads(f.read().decode())
    u = data.get("usage", {})
    print(f"OK in {time.time()-t0:.1f}s: usage={u}, "
          f"reply={data['choices'][0]['message']['content'][:60]!r}")
except Exception as e:
    print(f"FAILED after {time.time()-t0:.1f}s: {e}")
    sys.exit(1)
