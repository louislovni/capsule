#!/usr/bin/env python3
"""DSperate links data files into its core with inline assembly written for
ELF (Linux): `.section .rodata...,"a",%progbits` and `.previous`. MinGW's
assembler (Windows, PE/COFF) wants `.section .rdata,"dr"` and has no
`.previous`. This rewrites the two files the DS core builds, for Windows only,
as patch_dsperate_macho.py does for Apple. Run on a fresh checkout of those files.

Usage: patch_dsperate_coff.py <DSperate source dir>
"""
import pathlib
import sys

EDITS = {
    "src/core/cheat/analog_db.cpp": [
        ('"\\t.section .rodata.dsperate_analog_db,\\"a\\",%progbits\\n"', '"\\t.section .rdata,\\"dr\\"\\n"'),
        ('"\\t.previous\\n"', '"\\t.text\\n"'),
    ],
    "src/core/io/dsi_font.cpp": [
        ('"\\t.section .rodata.dsperate_dsi_font,\\"a\\",%progbits\\n"', '"\\t.section .rdata,\\"dr\\"\\n"'),
        ('"\\t.previous\\n"', '"\\t.text\\n"'),
    ],
}


def main(root):
    root = pathlib.Path(root)
    for rel, edits in EDITS.items():
        path = root / rel
        text = path.read_text(encoding="utf-8")
        for old, new in edits:
            if old not in text:
                sys.exit("patch_dsperate_coff: %s no longer contains %s" % (rel, old))
            text = text.replace(old, new)
        path.write_text(text, encoding="utf-8")
        print("patched", rel)


if __name__ == "__main__":
    main(sys.argv[1])
