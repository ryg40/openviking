#!/usr/bin/env python3
"""Check a started OpenViking server from outside. See docs/operations.md.

Usage: scripts/verify.py BASE_URL [--timeout SECONDS]

1. GET BASE_URL/health until it returns 200 with "healthy": true, or until
   the timeout ends. Print the version.
2. GET BASE_URL/api/v1/system/status without a key. Only 401 or 403 pass:
   the server must refuse an unauthenticated request.

The script never sends an API key and never reads .env. Python 3 standard
library only.

Exit status: 0 pass, 1 fail, 2 usage error.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REQUEST_TIMEOUT = 5.0
RETRY_INTERVAL = 3.0


def get(url, timeout):
    """GET url without credentials; return (status, body). Status 0 is no answer."""
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")
    except (OSError, ValueError) as error:
        return 0, str(error)


def check_health(base_url, timeout):
    """Return (ok, message) for /health, retrying until timeout seconds pass."""
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        status, body = get(base_url + "/health", max(1.0, min(REQUEST_TIMEOUT, remaining)))
        if status == 200:
            try:
                data = json.loads(body)
            except ValueError:
                data = None
            if isinstance(data, dict) and data.get("healthy") is True:
                return True, "version %s" % data.get("version", "(not reported)")
        if time.monotonic() + RETRY_INTERVAL > deadline:
            return False, "status %s: %s" % (status, body[:200].strip())
        time.sleep(RETRY_INTERVAL)


def main(argv):
    parser = argparse.ArgumentParser(
        description="Check /health and that an unauthenticated API call is refused."
    )
    parser.add_argument("base_url", help="server base URL, for example http://127.0.0.1:1933")
    parser.add_argument(
        "--timeout",
        type=float,
        default=10.0,
        help="seconds to wait for a healthy /health answer (default 10)",
    )
    args = parser.parse_args(argv)

    base_url = args.base_url.rstrip("/")
    parts = urllib.parse.urlsplit(base_url)
    if parts.scheme not in ("http", "https") or not parts.netloc:
        parser.error("BASE_URL must be an http or https URL with a host")
    if parts.username or parts.password or parts.query or parts.fragment:
        parser.error("BASE_URL must not hold credentials, a query or a fragment")
    if args.timeout <= 0:
        parser.error("--timeout must be greater than 0")

    failures = 0
    ok, message = check_health(base_url, args.timeout)
    if ok:
        print("ok - /health returns 200 with healthy true, %s" % message)
    else:
        print("not ok - /health is not healthy: %s" % message)
        failures += 1

    status, _ = get(base_url + "/api/v1/system/status", REQUEST_TIMEOUT)
    if status in (401, 403):
        print("ok - /api/v1/system/status without a key gives %d" % status)
    else:
        print("not ok - /api/v1/system/status without a key gives %d, expected 401 or 403" % status)
        failures += 1

    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
