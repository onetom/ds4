#!/usr/bin/env bash
# Extract the transcript text from a ds4 session .kv file into a markdown file.
#
# Usage: export_session.sh SESSION.kv [out.md]
#
# File layout: 48-byte header, 4-byte LE text length, UTF-8 transcript text,
# then the binary KV payload (and optionally a title trailer).
set -euo pipefail

DEFAULT_DIR="$HOME/.ds4/kvcache"

usage() {
    cat >&2 <<'EOF'
Usage: export_session.sh SESSION.kv [out.md]

Extract the transcript text from a ds4 session .kv file into a markdown file.
EOF
    echo >&2
    echo "sessions in ~/.ds4/kvcache:" >&2
    [[ -d "$DEFAULT_DIR" ]] || return
    for p in "$DEFAULT_DIR"/*.kv; do
        [[ -f "$p" ]] || continue
        name="${p##*/}"
        [[ "$name" == "sysprompt.kv" ]] && continue
        stem="${name%.*}"
        printf "  %-8s  %s\n" "${stem:0:8}" "$name" >&2
    done | sort
}

main() {
    local src dst text_len h size stem p c base shas

    if (( $# == 0 )); then
        usage
        return 0
    fi

    src="$1"

    if [[ ! -e "$src" ]]; then
        # Resolve a bare prefix/stem against the default kvcache directory.
        stem="${1##*/}"; stem="${stem%.*}"
        local candidates=()
        if [[ -d "$DEFAULT_DIR" ]]; then
            for p in "$DEFAULT_DIR"/"$stem"*.kv; do
                [[ -f "$p" ]] || continue
                [[ "${p##*/}" == "sysprompt.kv" ]] && continue
                candidates+=("$p")
            done
        fi
        case ${#candidates[@]} in
            0) echo "no session matching '$stem' in $DEFAULT_DIR" >&2; return 1 ;;
            1) src="${candidates[0]}" ;;
            *) shas=""
               for c in "${candidates[@]}"; do
                   base="${c##*/}"
                   shas+=" ${base:0:8}"
               done
               echo "ambiguous prefix '$stem':$shas" >&2
               return 1 ;;
        esac
    fi

    size="$(wc -c < "$src")"
    if (( size < 52 )); then
        echo "$src: too small ($size bytes)" >&2
        return 1
    fi

    # Read the 4-byte little-endian text length at byte offset 48.
    h="$(dd if="$src" bs=1 skip=48 count=4 2>/dev/null | od -An -N4 -tx1 | tr -d ' \n')"
    if [[ -z "$h" || ${#h} -lt 8 ]]; then
        echo "$src: could not read text length header" >&2
        return 1
    fi

    # Little-endian: b0 + (b1<<8) + (b2<<16) + (b3<<24)
    local b0=$((16#${h:0:2})) b1=$((16#${h:2:2}))
    local b2=$((16#${h:4:2})) b3=$((16#${h:6:2}))
    text_len=$(( b0 + (b1 << 8) + (b2 << 16) + (b3 << 24) ))

    if (( 52 + text_len > size )); then
        echo "$src: text_len $text_len overruns file" >&2
        return 1
    fi

    dst="${2:-${src%.*}.md}"

    # Text starts at byte offset 52 (1-indexed: 53). Read only the needed
    # bytes via head|tail, which avoids a SIGPIPE from an over-reading tail
    # that would trip `set -e -o pipefail`.
    head -c "$(( 52 + text_len ))" "$src" | tail -c +53 > "$dst"

    # KEEP (do not strip in future simplification rounds): the dd equivalent
    # is deliberately not used. bs=1 makes it ~40-55x slower (per-byte
    # syscalls); a large bs can't be used because skip/count are in blocks,
    # not bytes. It also prints records to stderr (status=none isn't portable),
    # hides real errors under 2>/dev/null, and exits non-zero on EOF, which
    # would abort under set -euo pipefail. head|tail just yields fewer bytes.
    #
    #   dd if="$src" bs=1 skip=52 count="$text_len" of="$dst" status=none 2>/dev/null
    #

    echo "$(basename "$src") -> $dst ($text_len chars)"
}

main "$@"
