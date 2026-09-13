#!/usr/bin/env bash
# Extract the transcript text from a ds4 session .kv file into a markdown file.
#
# Usage: export_session.sh SESSION.kv [out.md]
#
# The file layout is: 48-byte header, 4-byte LE text length, UTF-8 transcript
# text, then the binary KV payload (and optionally a title trailer). We only
# need the first two parts; the text is the plain rendered transcript (the
# model output is already markdown-flavored).
set -euo pipefail

DEFAULT_DIR="$HOME/.ds4/kvcache"

usage() {
    cat >&2 <<'EOF'
Usage: export_session.sh SESSION.kv [out.md]

Extract the transcript text from a ds4 session .kv file into a markdown file.
EOF
    echo >&2
    echo "sessions in ~/.ds4/kvcache:" >&2
    if [[ -d "$DEFAULT_DIR" ]]; then
        for p in "$DEFAULT_DIR"/*.kv; do
            [[ -f "$p" ]] || continue
            name="${p##*/}"
            [[ "$name" == "sysprompt.kv" ]] && continue
            stem="${name%.*}"
            printf "  %-8s  %s\n" "${stem:0:8}" "$name" >&2
        done | sort
    fi
}

main() {
    local src dst text_len file_size b0 b1 b2 b3 h
    local argv=("$@")

    if (( ${#argv[@]} == 0 )); then
        usage
        return 0
    fi

    src="${argv[0]}"

    if [[ ! -e "$src" ]]; then
        # Resolve a bare prefix/stem against the default kvcache directory.
        local name stem
        name="${src##*/}"
        if [[ "$name" == *.* ]]; then
            stem="${name%.*}"
        else
            stem="$name"
        fi

        local candidates=()
        if [[ -d "$DEFAULT_DIR" ]]; then
            local p
            for p in "$DEFAULT_DIR"/"$stem"*.kv; do
                [[ -f "$p" ]] || continue
                [[ "${p##*/}" == "sysprompt.kv" ]] && continue
                candidates+=("$p")
            done
        fi

        if (( ${#candidates[@]} == 0 )); then
            echo "no session matching '$stem' in $DEFAULT_DIR" >&2
            return 1
        fi
        if (( ${#candidates[@]} > 1 )); then
            local shas=""
            local c
            for c in "${candidates[@]}"; do
                local base="${c##*/}"
                shas+=" ${base:0:8}"
            done
            echo "ambiguous prefix '$stem':$shas" >&2
            return 1
        fi
        src="${candidates[0]}"
    fi

    file_size="$(wc -c < "$src")"
    if (( file_size < 52 )); then
        echo "$src: too small ($file_size bytes)" >&2
        return 1
    fi

    # Read the 4-byte little-endian text length at byte offset 48.
    h="$(dd if="$src" bs=1 skip=48 count=4 2>/dev/null | od -An -N4 -tx1 | tr -d ' \n')"
    if [[ -z "$h" || "${#h}" -lt 8 ]]; then
        echo "$src: could not read text length header" >&2
        return 1
    fi

    # Little-endian: b0 + (b1<<8) + (b2<<16) + (b3<<24)
    b0=$((16#${h:0:2})); b1=$((16#${h:2:2}))
    b2=$((16#${h:4:2})); b3=$((16#${h:6:2}))
    text_len=$(( b0 + (b1 << 8) + (b2 << 16) + (b3 << 24) ))

    if (( 52 + text_len > file_size )); then
        echo "$src: text_len $text_len overruns file" >&2
        return 1
    fi

    if (( ${#argv[@]} > 1 )); then
        dst="${argv[1]}"
    else
        dst="${src%.*}.md"
    fi

    # Text starts at byte offset 52 (1-indexed: 53). Read only the needed
    # bytes: head -c reads (52+text_len) bytes from the big file, then tail
    # trims the 52-byte header. This avoids reading the whole file and avoids
    # a SIGPIPE from an over-reading tail that would trip `set -e -o pipefail`.
    head -c "$(( 52 + text_len ))" "$src" | tail -c +53 > "$dst"

    # Functionally equivalent dd version (commented out on purpose):
    #
    #   dd if="$src" bs=1 skip=52 count="$text_len" of="$dst" status=none 2>/dev/null
    #
    # It maps 1:1 to the Python layout (0-indexed byte offsets, no +53
    # off-by-one), but it is NOT used because of these downsides:
    #   * bs=1 forces a read+write syscall per byte -> ~40-55x slower than the
    #     head|tail pipeline (measured: 0.32s vs 8ms on a 237KB transcript;
    #     10s vs 0.18s on ~5MB of text).
    #   * dd needs byte-exact offsets, so a large bs (which would make it fast)
    #     can't be used: skip/count are then counted in blocks, not bytes.
    #   * It prints "N+0 records in/out" to stderr; status=none is not portable
    #     to older BSDs, and 2>/dev/null would hide genuine errors (e.g. an
    #     unwritable dst) under set -euo pipefail.
    #   * On EOF it exits non-zero ("partial record"), which would abort the
    #     script; head|tail just yields fewer bytes silently.

    echo "$(basename "$src") -> $dst ($text_len chars)"
}

main "$@"
