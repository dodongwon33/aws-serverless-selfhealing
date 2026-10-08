#!/usr/bin/env python3
"""저율 부하 생성기 (표준 라이브러리만 사용). 카나리 검증·장애 시연용.

  python scripts/load.py --url https://xxx.execute-api.ap-northeast-2.amazonaws.com/v1 --key $API_KEY \
      --rps 3 --duration 600 --watch-function selfheal-dev-api
"""

import argparse
import collections
import json
import subprocess
import time
import urllib.error
import urllib.request


def request(url, key, method="GET", body=None):
    req = urllib.request.Request(url, data=body, method=method, headers={"x-api-key": key})
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except (urllib.error.URLError, TimeoutError):
        return "timeout"


def live_version(function):
    out = subprocess.run(
        [
            "aws",
            "lambda",
            "get-alias",
            "--function-name",
            function,
            "--name",
            "live",
            "--query",
            "FunctionVersion",
            "--output",
            "text",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    return out.stdout.strip() or "?"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--rps", type=float, default=2)
    ap.add_argument("--duration", type=int, default=300, help="seconds")
    ap.add_argument("--watch-function", help="30초마다 alias live 버전 출력")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if args.rps > 5:
        ap.error("rps는 5 이하 (API 스로틀/쿼터와 예산 보호)")

    base = args.url.rstrip("/")
    interval = 1 / args.rps
    counts = collections.Counter()
    start = last_report = time.monotonic()
    i = 0
    while time.monotonic() - start < args.duration:
        tick = time.monotonic()
        if i % 5 == 4:
            status = request(f"{base}/items", args.key, "POST", json.dumps({"payload": {"n": i}}).encode())
        else:
            status = request(f"{base}/health", args.key)
        counts[status] += 1
        i += 1
        if not args.quiet and time.monotonic() - last_report >= 30:
            line = f"[{int(time.monotonic() - start):>4}s] {dict(counts)}"
            if args.watch_function:
                line += f"  live=v{live_version(args.watch_function)}"
            print(line, flush=True)
            counts.clear()
            last_report = time.monotonic()
        time.sleep(max(0, interval - (time.monotonic() - tick)))

    if not args.quiet:
        print(f"done: {dict(counts)}")


if __name__ == "__main__":
    main()
