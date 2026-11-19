#!/usr/bin/env python3
"""Fake `curl` for test_strata_pod.sh. Never touches the network.

Reads routes from $STUB/routes.json: {"METHOD url-substring": [resp, resp, ...]} where each resp is
{"code": 200, "body": {...} | "text"}. Responses are used in order; the last one repeats.
Every call is appended to $STUB/calls.log as one JSON line {method, url, data, headers}.
Supports the flags strata-pod uses: -s -S -N -f --max-time N -X M -H H --data-binary @file|str -w FMT -o FILE.
"""
import json, os, sys

stub = os.environ["STUB"]
args = sys.argv[1:]
method, url, data, headers, wfmt, outfile = "GET", None, None, [], None, None
i = 0
while i < len(args):
    a = args[i]
    if a in ("-X", "--request"):
        method = args[i + 1]; i += 2; continue
    if a in ("-H", "--header"):
        headers.append(args[i + 1]); i += 2; continue
    if a in ("--data-binary", "-d", "--data"):
        d = args[i + 1]
        data = open(d[1:]).read() if d.startswith("@") else d
        if method == "GET":
            method = "POST"
        i += 2; continue
    if a in ("-w", "--write-out"):
        wfmt = args[i + 1]; i += 2; continue
    if a in ("-o", "--output"):
        outfile = args[i + 1]; i += 2; continue
    if a in ("--max-time", "-m", "--connect-timeout"):
        i += 2; continue
    if a.startswith("-"):
        i += 1; continue
    url = a; i += 1

with open(os.path.join(stub, "calls.log"), "a") as f:
    f.write(json.dumps({"method": method, "url": url, "data": data, "headers": headers}) + "\n")

routes = json.load(open(os.path.join(stub, "routes.json")))
counts_path = os.path.join(stub, "counts.json")
counts = json.load(open(counts_path)) if os.path.exists(counts_path) else {}
match = None
for key in sorted(routes, key=len, reverse=True):      # longest pattern wins
    m, sub = key.split(" ", 1)
    if m == method and sub in (url or ""):
        match = key
        break
if match is None:
    resp = {"code": 404, "body": {"error": f"no stub route for {method} {url}"}}
else:
    n = counts.get(match, 0)
    seq = routes[match]
    resp = seq[min(n, len(seq) - 1)]
    counts[match] = n + 1
    json.dump(counts, open(counts_path, "w"))

body = resp.get("body", "")
text = body if isinstance(body, str) else json.dumps(body)
code = resp.get("code", 200)
if outfile:
    open(outfile, "w").write(text)
else:
    sys.stdout.write(text)
if wfmt:
    sys.stdout.write(wfmt.replace("\\n", "\n").replace("%{http_code}", str(code)))
if code == 0:          # simulate a connection failure
    sys.exit(7)
