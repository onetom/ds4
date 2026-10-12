#!/bin/sh
# Find the concurrency a running server can actually serve, and the point where
# it stops being able to.
#
# serve_concurrency_bench.py measures one closed-loop concurrency per run.  This
# walks a list of them against the same running server and prints one line per
# step, because the shape of the curve is the result: aggregate output tokens per
# second keeps rising while the batch has room, then the step after the last good
# one fails outright rather than getting slower.
#
# That cliff is a resource limit, not a throughput number, and it depends on what
# is resident at the moment rather than on a fixed row count.  On an M4 Max with
# 128 GiB and Qwen3.8 Q4 at --ctx 131072 --batched-session 8, eight simultaneous
# requests died three times out of three runs: the driver returned
# `kIOGPUCommandBufferCallbackErrorOutOfMemory` for the speculative (MTP) batch,
# which sizes its scratch for two rows per session, so eight sessions ask for
# sixteen rows.  The server reports the failure per job as `finish_reason=error`
# / `metal speculative batch failed`, and because one failed row aborts the whole
# decode round, every stream in the batch fails together at the same instant.
# The same eight rows passed later on the same server with less else resident, so
# treat the sweep as the measurement and --batched-session as the setting it has
# to stay under, not as a constant of the model.
#
# Run it against a server nothing else is using.  A second client shows up as
# time-to-first-token climbing with concurrency (queueing in front of busy slots)
# and drags every aggregate down; a sweep taken that way is not comparable with
# one taken on an idle server.
#
# usage: speed-bench/serve_batch_ceiling.sh [extra serve_concurrency_bench.py options]
#
#   CONCURRENCY="1 2 4 8" MAX_TOKENS=64 REQUESTS_PER_STEP=2 \
#     speed-bench/serve_batch_ceiling.sh --base-url http://127.0.0.1:8001
#
# BASE_URL, CONCURRENCY, MAX_TOKENS and REQUESTS_PER_STEP come from the
# environment; --base-url and anything else on the command line is forwarded to
# the bench verbatim, and a forwarded --base-url wins over the environment.
#
# Steps stop at the first one where any request fails, and the script exits 1
# there.  Requests are closed-loop and greedy, and every step asks for the same
# number of decoded tokens per stream.
#
# Do not add --ignore-eos here even though it makes output lengths exact: the
# batched decode path only takes the speculative (MTP) route when ignore_eos is
# unset, so --ignore-eos silently measures the slower fallback and would hide the
# ceiling this script looks for.  Measured on the same server, same prompt, one
# stream: TPOT 24.5 ms with --ignore-eos, 19.0 ms without it.  --no-think is
# likewise left off, because the failure this finds happens on the thinking path
# real traffic uses.
#
# Memory is not reset between steps, and neither is the machine: a step that
# fails leaves its sessions allocated, so sweep upward from low concurrency and
# treat the first failing step as the ceiling, not the last one that worked after
# it.  Restart the server before a sweep whose numbers you intend to keep.
set -u

BENCH=speed-bench/serve_concurrency_bench.py
CONCURRENCY=${CONCURRENCY:-"1 2 3 4 5 6 7 8 9 10 11 12"}
MAX_TOKENS=${MAX_TOKENS:-128}
REQUESTS_PER_STEP=${REQUESTS_PER_STEP:-2}
BASE_URL=${BASE_URL:-http://127.0.0.1:8000}

if [ ! -f "$BENCH" ]; then
    echo "serve-batch-ceiling: run it from the repository root (no $BENCH)" >&2
    exit 2
fi

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM
last_ok=0
echo "concurrency ceiling sweep: $CONCURRENCY (max_tokens=$MAX_TOKENS, $REQUESTS_PER_STEP requests per stream)"

for conc in $CONCURRENCY; do
    requests=$((conc * REQUESTS_PER_STEP))
    json=$tmp/serve-$conc.json
    if python3 "$BENCH" --base-url "$BASE_URL" --concurrency "$conc" \
        --requests "$requests" --max-tokens "$MAX_TOKENS" \
        --prompt-tokens 0 --temperature 0 \
        --label "concurrency $conc" --json "$json" "$@" >/dev/null 2>"$tmp/err-$conc"; then
        rc=0
    else
        rc=1
    fi
    # The bench prints the full report; only the ceiling line is wanted here.
    python3 - "$json" "$conc" "$rc" "$tmp/err-$conc" <<'PY'
import json, sys
path, conc, rc, errfile = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
try:
    with open(path) as fp:
        s = json.load(fp)
except (OSError, ValueError):
    print(f"  conc {int(conc):>3}  no report written")
    err = open(errfile).read().strip().splitlines()
    if err:
        print(f"       {err[0]}")
    sys.exit(1)
done, failed = s["completed"], s["failed"]
agg = s["output_throughput"]
per = agg / int(conc) if int(conc) else agg
ttft = s["ttft_ms"]["p95"]
status = "ok" if rc == 0 and failed == 0 else "FAILED"
print(f"  conc {int(conc):>3}  {status:<7} {done:>3}/{done + failed}  "
      f"aggregate {agg:6.1f} tok/s   per-stream {per:6.1f}   ttft p95 {ttft:7.0f} ms")
if status == "FAILED":
    sys.exit(1)
PY
    [ "$rc" -eq 0 ] || {
        echo "ceiling: $last_ok concurrent requests; $conc failed. Keep --batched-session at or below $last_ok."
        exit 1
    }
    last_ok=$conc
done

echo "no failure through $last_ok concurrent requests; the limit is above the sweep, or it is memory pressure and not the batch"
exit 0
