#!/usr/bin/env python3
"""Report GitHub issues/PRs in a JSON watchlist that closed within a window.

Usage: check-closed-issues.py WATCHLIST.json SINCE_ISO8601 [--self-test]
Exits 1 when any watched item closed after SINCE (so RWX's run-result
notification fires); exits 0 otherwise.  Public repos only (unauthenticated).
"""
import json
import sys
import urllib.request
from datetime import datetime


def parse(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def fetch(repo, number):
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/issues/{number}",
        headers={"Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def newly_closed(data, since):
    if data.get("state") == "closed" and data.get("closed_at"):
        return parse(data["closed_at"]) > since
    return False


def main(argv):
    if "--self-test" in argv:
        s = parse("2026-01-02T00:00:00Z")
        assert newly_closed({"state": "closed", "closed_at": "2026-01-02T01:00:00Z"}, s)
        assert not newly_closed({"state": "closed", "closed_at": "2026-01-01T01:00:00Z"}, s)
        assert not newly_closed({"state": "open"}, s)
        print("self-test ok")
        return 0
    items = json.load(open(argv[1]))["items"]
    since = parse(argv[2])
    hits, errors = [], []
    for it in items:
        try:
            d = fetch(it["repo"], it["number"])
        except Exception as e:  # keep checking the rest
            errors.append(f"{it['repo']}#{it['number']}: {e}")
            continue
        kind = "PR" if "pull_request" in d else "issue"
        if newly_closed(d, since):
            hits.append(f"CLOSED {kind} {it['repo']}#{it['number']}: {d['title']} {d['html_url']}")
        else:
            print(f"still {d['state']}: {it['repo']}#{it['number']}")
    for e in errors:
        print(f"ERROR {e}")
    for h in hits:
        print(h)
    return 1 if hits or errors else 0


sys.exit(main(sys.argv))
