#!/bin/bash
set -u

BASE="${1:-${DS4_BASE_URL:-http://127.0.0.1:8000}}"
BASE="${BASE%/}"
TIMEOUT="${QWEN38_SMOKE_TIMEOUT:-600}"
TOKENS="${QWEN38_SMOKE_TOKENS:-512}"
PROMPT="${QWEN38_SMOKE_PROMPT:-Reply with exactly: QWEN38 OK}"
pass=0
fail=0

ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
ko() {
    printf '  FAIL  %s\n' "$1"
    if [ $# -gt 1 ] && [ -n "${2:-}" ]; then
        printf '        %s\n' "$(printf '%s' "$2" | head -c 400)"
    fi
    fail=$((fail + 1))
}

get() { curl -sS --max-time "$TIMEOUT" "$BASE$1" 2>/dev/null; }
post() { curl -sS --max-time "$TIMEOUT" -H 'Content-Type: application/json' -d "$2" "$BASE$1" 2>/dev/null; }
jqr() { printf '%s' "$2" | jq -r "$1" 2>/dev/null; }
snip() { printf '%s' "$1" | head -c 300; }

payload_effort() {
    jq -nc --arg m "$1" --arg p "$PROMPT" --argjson n "$TOKENS" --arg e "$2" \
       '{model: $m, messages: [{role: "user", content: $p}], max_tokens: $n, reasoning_effort: $e}'
}
payload_plain() {
    jq -nc --arg m "$1" --arg p "$PROMPT" --argjson n "$TOKENS" \
       '{model: $m, messages: [{role: "user", content: $p}], max_tokens: $n}'
}

command -v jq >/dev/null 2>&1 || { echo "smoke-qwen38: jq is required" >&2; exit 2; }

printf 'smoke-qwen38: %s  (max_tokens=%s, timeout=%ss)\n' "$BASE" "$TOKENS" "$TIMEOUT"

models="$(get /v1/models)"
if [ -z "$models" ]; then
    printf '  FAIL  %s/v1/models unreachable\n' "$BASE"
    printf '        start it with: ~/bin/ds4-server-qwen38.sh\n'
    exit 2
fi

printf 'aliases\n'
for m in qwen3.8-flash-next qwen3.8-flash-next-chat qwen3.8-flash-next-reasoner; do
    if printf '%s' "$models" | jq -e --arg m "$m" '.data[]?.id | select(. == $m)' >/dev/null 2>&1; then
        ok "/v1/models lists $m"
    else
        ko "/v1/models missing $m" "$(snip "$models")"
    fi
done

printf 'thinking modes (/v1/chat/completions)\n'
body="$(post /v1/chat/completions "$(payload_effort qwen3.8-flash-next-reasoner low)")"
content="$(jqr '.choices[0].message.content // ""' "$body")"
reason="$(jqr '.choices[0].message.reasoning_content // ""' "$body")"
finish="$(jqr '.choices[0].finish_reason // ""' "$body")"
comp="$(jqr '.usage.completion_tokens // 0' "$body")"

if [ -n "$content" ]; then
    ok "reasoner answered: $(printf '%s' "$content" | head -c 60)"
else
    ko "reasoner returned empty content (finish=$finish)" "$(snip "$body")"
fi
if [ -n "$reason" ]; then
    ok "reasoner emits reasoning_content"
else
    ko "reasoner emitted no reasoning_content (alias should force thinking on)" "$(snip "$body")"
fi
if [ "$comp" -gt 0 ] 2>/dev/null; then
    ok "usage.completion_tokens=$comp"
else
    ko "usage.completion_tokens missing" "$(snip "$body")"
fi

body="$(post /v1/chat/completions "$(payload_plain qwen3.8-flash-next-chat)")"
content="$(jqr '.choices[0].message.content // ""' "$body")"
reason="$(jqr '.choices[0].message.reasoning_content // ""' "$body")"
if [ -n "$content" ]; then
    ok "-chat answered: $(printf '%s' "$content" | head -c 60)"
else
    ko "-chat returned empty content" "$(snip "$body")"
fi
if [ -z "$reason" ]; then
    ok "-chat stays in non-thinking mode"
else
    ko "-chat produced reasoning_content" "$(snip "$reason")"
fi

body="$(post /v1/chat/completions "$(payload_effort qwen3.8-flash-next none)")"
reason="$(jqr '.choices[0].message.reasoning_content // ""' "$body")"
if [ -z "$reason" ]; then
    ok "reasoning_effort=none disables thinking"
else
    ko "reasoning_effort=none still reasoned" "$(snip "$reason")"
fi

printf 'streaming\n'
stream="$(curl -sS -N --max-time "$TIMEOUT" -H 'Content-Type: application/json' \
    -d "$(payload_effort qwen3.8-flash-next-reasoner low | jq -c '. + {stream: true}')" \
    "$BASE/v1/chat/completions" 2>/dev/null)"
chunks="$(printf '%s' "$stream" | grep -c '^data: ')"
if [ "$chunks" -gt 2 ] 2>/dev/null; then
    ok "SSE emitted $chunks chunks"
else
    ko "SSE produced too few chunks ($chunks)" "$(snip "$stream")"
fi
if printf '%s' "$stream" | grep -q '\[DONE\]'; then
    ok "SSE terminated with [DONE]"
else
    ko "SSE missing [DONE]" "$(snip "$stream")"
fi
if printf '%s' "$stream" | grep -q '"reasoning_content"'; then
    ok "SSE carries reasoning deltas"
else
    ko "SSE carried no reasoning deltas"
fi

printf 'other endpoints\n'
body="$(post /v1/responses "$(jq -nc --arg m qwen3.8-flash-next --arg p "$PROMPT" --argjson n "$TOKENS" \
    '{model: $m, input: [{role: "user", content: [{type: "input_text", text: $p}]}], max_output_tokens: $n, reasoning: {effort: "low"}}')")"
rid="$(jqr '.id // ""' "$body")"
rtext="$(jqr '[.output[]?.content[]? | select(.type == "output_text") | .text] | join("")' "$body")"
case "$rid" in
    resp_*) ok "/v1/responses id=$rid" ;;
    *) ko "/v1/responses returned no resp_ id" "$(snip "$body")" ;;
esac
if [ -n "$rtext" ]; then
    ok "/v1/responses output_text: $(printf '%s' "$rtext" | head -c 60)"
else
    ko "/v1/responses empty output_text" "$(snip "$body")"
fi

body="$(post /v1/messages "$(jq -nc --arg m qwen3.8-flash-next-reasoner --arg p "$PROMPT" --argjson n "$TOKENS" \
    '{model: $m, max_tokens: $n, messages: [{role: "user", content: $p}]}')")"
atype="$(jqr '.type // ""' "$body")"
atext="$(jqr '[.content[]? | select(.type == "text") | .text] | join("")' "$body")"
athink="$(jqr '[.content[]? | select(.type == "thinking")] | length' "$body")"
if [ "$atype" = "message" ]; then
    ok "/v1/messages type=message"
else
    ko "/v1/messages unexpected type '$atype'" "$(snip "$body")"
fi
if [ -n "$atext" ]; then
    ok "/v1/messages text: $(printf '%s' "$atext" | head -c 60)"
else
    ko "/v1/messages empty text block" "$(snip "$body")"
fi
if [ "${athink:-0}" -gt 0 ] 2>/dev/null; then
    ok "/v1/messages carries a thinking block"
else
    ko "/v1/messages reasoner had no thinking block" "$(snip "$body")"
fi

body="$(post /v1/completions "$(jq -nc --arg m qwen3.8-flash-next --arg p "$PROMPT" --argjson n "$TOKENS" \
    '{model: $m, prompt: $p, max_tokens: $n}')")"
ctext="$(jqr '.choices[0].text // ""' "$body")"
if [ -n "$ctext" ]; then
    ok "/v1/completions text: $(printf '%s' "$ctext" | head -c 60)"
else
    ko "/v1/completions returned empty text" "$(snip "$body")"
fi

printf '\nsmoke-qwen38: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
