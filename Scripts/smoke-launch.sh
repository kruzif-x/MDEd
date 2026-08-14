#!/bin/bash
#
# smoke-launch.sh — does the app actually open a document without dying?
#
# This exists because two consecutive changes shipped an app that crashed on
# every document open while reporting success. The crash was an uncaught
# NSException thrown from inside AppKit's own layout pass, so it surfaced as
# neither a build failure nor a test failure — nothing short of launching the
# real app and looking would have caught it.
#
#   Usage: Scripts/smoke-launch.sh [path/to/MDEd.app] [path/to/document.md]
#
# Exits 0 if the instance it launched is still alive after the settle period and
# left no crash report; non-zero otherwise, printing what it can about the crash.
#
# Everything here is scoped to the single process this script starts. It does not
# kill other MDEd instances and does not attribute anyone else's crash reports to
# itself — an earlier version did both, and produced a false failure the moment
# another session was exercising the app at the same time.
#
# One unavoidable global side effect: it resets the app's preferences domain, so
# the launch is a genuine cold start. Stale preferences or saved window state can
# mask a crash that only reproduces on first launch, which is precisely how the
# container-width crash survived review.

set -uo pipefail

BUNDLE_ID="com.mded.MDEd"
SETTLE_SECONDS="${SETTLE_SECONDS:-6}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_PATH="${1:-}"
DOC_PATH="${2:-$REPO_ROOT/Samples/kitchen-sink.md}"

if [ -z "$APP_PATH" ]; then
  APP_PATH="$(find "${DERIVED_DATA:-/tmp/mded-dd}" -name 'MDEd.app' -maxdepth 6 2>/dev/null | head -1)"
fi

if [ ! -d "$APP_PATH" ]; then
  echo "smoke: no app bundle found (looked for '${APP_PATH:-nothing}')" >&2
  echo "smoke: build first — xcodebuild -scheme MDEd -derivedDataPath /tmp/mded-dd build" >&2
  exit 2
fi
if [ ! -f "$DOC_PATH" ]; then
  echo "smoke: no document at '$DOC_PATH'" >&2
  exit 2
fi

APP_BIN="$APP_PATH/Contents/MacOS/MDEd"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
LAUNCHED_PID=""

cleanup() {
  # Only ever our own instance.
  [ -n "$LAUNCHED_PID" ] && kill "$LAUNCHED_PID" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

echo "smoke: app      $APP_PATH"
echo "smoke: document $DOC_PATH"

# Cold start, so first-launch-only failures are in scope.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1
rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" >/dev/null 2>&1

PIDS_BEFORE="$(pgrep -f "$APP_BIN" 2>/dev/null | sort -u)"

open -a "$APP_PATH" "$DOC_PATH" || { echo "smoke: FAIL — 'open' refused to launch the app" >&2; exit 1; }

# Identify the instance we just started, ignoring any already running.
for _ in $(seq 1 24); do
  sleep 0.25
  PIDS_AFTER="$(pgrep -f "$APP_BIN" 2>/dev/null | sort -u)"
  LAUNCHED_PID="$(comm -13 <(echo "$PIDS_BEFORE") <(echo "$PIDS_AFTER") 2>/dev/null | head -1)"
  [ -n "$LAUNCHED_PID" ] && break
done

if [ -z "$LAUNCHED_PID" ]; then
  echo "smoke: FAIL — no new MDEd process appeared after 'open'" >&2
  exit 1
fi
echo "smoke: pid      $LAUNCHED_PID"

sleep "$SETTLE_SECONDS"

FAILED=0
if kill -0 "$LAUNCHED_PID" >/dev/null 2>&1; then
  echo "smoke: PASS — pid $LAUNCHED_PID alive after ${SETTLE_SECONDS}s"
else
  echo "smoke: FAIL — pid $LAUNCHED_PID died while opening the document" >&2
  FAILED=1
fi

# Attribute crash reports by pid, never by recency.
REPORT="$(
  python3 - "$CRASH_DIR" "$LAUNCHED_PID" <<'PY'
import glob, json, os, sys
crash_dir, want = sys.argv[1], int(sys.argv[2])
for path in sorted(glob.glob(os.path.join(crash_dir, "MDEd-*.ips")),
                   key=os.path.getmtime, reverse=True)[:25]:
    try:
        body = json.loads(open(path).read().split("\n", 1)[1])
    except Exception:
        continue
    if body.get("pid") != want:
        continue
    exc = body.get("exception", {}) or {}
    print(path)
    print(f"exception {exc.get('type','?')} ({exc.get('signal','?')})")
    imgs = body.get("usedImages", []) or []
    frames = (body.get("threads") or [{}])[0].get("frames", []) or []
    for f in frames[:8]:
        i = f.get("imageIndex", 0)
        name = imgs[i].get("name", "?") if i < len(imgs) else "?"
        print(f"  {name:24s} {f.get('symbol','?')}")
    break
PY
)"

if [ -n "$REPORT" ]; then
  echo "smoke: FAIL — pid $LAUNCHED_PID wrote a crash report" >&2
  printf 'smoke: %s\n' "$REPORT" | sed 's/^smoke: /smoke:   /' >&2
  echo "smoke: for the exception reason, rerun under lldb breaking on objc_exception_throw" >&2
  FAILED=1
fi

[ "$FAILED" -eq 0 ] && echo "smoke: ok"
exit "$FAILED"
