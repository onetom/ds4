#!/usr/bin/env python3
"""Extract the transcript text from a ds4 session .kv file into a markdown file.

Usage: python3 export_session.py SESSION.kv [out.md]

The file layout is: 48-byte header, 4-byte LE text length, UTF-8 transcript
text, then the binary KV payload (and optionally a title trailer). We only
need the first two parts; the text is the plain rendered transcript (the
model output is already markdown-flavored).
"""
import struct
import sys
from pathlib import Path

DEFAULT_DIR = Path.home() / ".ds4" / "kvcache"


def extract(src: Path) -> str:
    data = src.read_bytes()
    if len(data) < 52:
        raise SystemExit(f"{src}: too small ({len(data)} bytes)")
    text_len = struct.unpack_from("<I", data, 48)[0]
    text_start = 52
    text_end = text_start + text_len
    if text_end > len(data):
        raise SystemExit(f"{src}: text_len {text_len} overruns file")
    return data[text_start:text_end].decode("utf-8")


def main() -> None:
    argv = sys.argv[1:]
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        print("\nsessions in ~/.ds4/kvcache:", file=sys.stderr)
        if DEFAULT_DIR.is_dir():
            for p in sorted(DEFAULT_DIR.glob("*.kv")):
                if p.name != "sysprompt.kv":
                    print(f"  {p.stem[:8]}  {p.name}", file=sys.stderr)
        return
    src = Path(argv[0])
    if not src.exists():
        stem = src.stem if src.suffix else src.name
        src = DEFAULT_DIR / f"{stem}.kv"
        if not src.exists():
            matches = []
            if DEFAULT_DIR.is_dir():
                matches = [p for p in DEFAULT_DIR.glob(f"{stem}*.kv")
                           if p.name != "sysprompt.kv"]
            if not matches:
                raise SystemExit(f"no session matching {stem!r} in {DEFAULT_DIR}")
            if len(matches) > 1:
                shas = ", ".join(m.stem[:8] for m in matches)
                raise SystemExit(f"ambiguous prefix {stem!r}: {shas}")
            src = matches[0]
    if len(argv) > 1:
        dst = Path(argv[1])
    else:
        dst = Path(src.stem + ".md")
    text = extract(src)
    dst.write_text(text, encoding="utf-8")
    print(f"{src.name} -> {dst} ({len(text)} chars)")


if __name__ == "__main__":
    main()
