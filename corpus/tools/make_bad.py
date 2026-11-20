#!/usr/bin/env python3
"""Generate the malformed-input corpus used by script/check.sh.

Each file breaks exactly one rule, so a failure pinpoints one error code. The
files are committed; this script exists so they can be regenerated and audited.

    python corpus/tools/make_bad.py
"""
import os
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "bad"

HEADER = b"\x00asm" + (1).to_bytes(4, "little")


def leb(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def section(sid: int, payload: bytes) -> bytes:
    return bytes([sid]) + leb(len(payload)) + payload


def vec(items) -> bytes:
    items = list(items)
    return leb(len(items)) + b"".join(items)


def name(s: str) -> bytes:
    raw = s.encode("utf-8")
    return leb(len(raw)) + raw


def func_type(params: bytes, results: bytes) -> bytes:
    return b"\x60" + params + results


I32 = b"\x7f"
EXTERNREF = b"\x6f"

CASES = {}

# 1. Not a wasm file at all.
CASES["bad_magic.wasm"] = b"not a wasm file, but the extension says otherwise\n"

# 2. Correct magic, version 2.
CASES["bad_version.wasm"] = b"\x00asm" + (2).to_bytes(4, "little")

# 3. A section that claims ten bytes but has three.
CASES["bad_truncated.wasm"] = HEADER + bytes([1]) + leb(10) + b"\x01\x02\x03"

# 4. Type section, then exports, then type again: out of order.
CASES["bad_order.wasm"] = HEADER + section(1, b"\x00") + section(7, b"\x00") + section(1, b"\x00")

# 5. Section size encoded with a five-byte LEB128 that overflows 32 bits.
CASES["bad_leb.wasm"] = HEADER + bytes([1]) + b"\x80\x80\x80\x80\x10"

# 6. A parameter of type externref: valid wasm, outside the MVP subset.
CASES["bad_ref_type.wasm"] = HEADER + section(1, vec([func_type(vec([EXTERNREF]), vec([]))]))

# 7. Two memories.
MEM = b"\x00" + leb(1)
CASES["bad_multimem.wasm"] = HEADER + section(5, vec([MEM, MEM]))

# 8. A passive data segment (bulk-memory proposal).
CASES["bad_data_flag.wasm"] = HEADER + section(
    11, vec([leb(1) + leb(4) + b"\xde\xad\xbe\xef"])
)

# 9. A body whose last byte is not `end`.
TYPE_SEC = section(1, vec([func_type(vec([]), vec([I32]))]))
FUNC_SEC = section(3, vec([leb(0)]))
BODY = vec([]) + b"\x01"  # no locals, then `nop`, and no `end`
CASES["bad_body_end.wasm"] = (
    HEADER + TYPE_SEC + FUNC_SEC + section(10, vec([leb(len(BODY)) + BODY]))
)

# 10. A memory import: valid wasm, but this tool only links function imports.
CASES["bad_import_kind.wasm"] = HEADER + section(
    2, vec([name("env") + name("mem") + b"\x02" + MEM])
)

# 11. `call_indirect` on a table index other than 0 needs reference types; this
#     one is a type mismatch only if the tool pretends to be a full validator,
#     so instead: a global initialiser with the wrong opcode.
CASES["bad_const_expr.wasm"] = HEADER + section(
    6, vec([I32 + b"\x00" + b"\x20" + leb(0) + b"\x0b"])  # global.get in an init
)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for filename, data in CASES.items():
        (OUT / filename).write_bytes(data)
        print(f"{filename:24s} {len(data):4d} bytes")


if __name__ == "__main__":
    main()
