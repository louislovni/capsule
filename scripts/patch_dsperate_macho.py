#!/usr/bin/env python3
"""DSperate links data files into its core with inline assembly written for
ELF (Linux): `.section .rodata...,"a",%progbits`, symbols without the leading
underscore C names get on Apple, `.previous`. Apple's assembler wants Mach-O:
`.section __TEXT,__const` and `_name`. This rewrites the two files the DS core
builds, for Apple targets only. Run on a fresh checkout of those files.

Usage: patch_dsperate_macho.py <DSperate source dir>
"""
import pathlib
import sys

EDITS = {
    "src/core/cheat/analog_db.cpp": [
        ('"\\t.section .rodata.dsperate_analog_db,\\"a\\",%progbits\\n"', '"\\t.section __TEXT,__const\\n"'),
        ('"\\t.globl dsperate_analog_db_begin\\ndsperate_analog_db_begin:\\n"',
         '"\\t.globl _dsperate_analog_db_begin\\n_dsperate_analog_db_begin:\\n"'),
        ('"\\t.globl dsperate_analog_db_end\\ndsperate_analog_db_end:\\n"',
         '"\\t.globl _dsperate_analog_db_end\\n_dsperate_analog_db_end:\\n"'),
        ('"\\t.previous\\n"', '"\\t.text\\n"'),
    ],
    "src/core/io/dsi_font.cpp": [
        ('"\\t.section .rodata.dsperate_dsi_font,\\"a\\",%progbits\\n"', '"\\t.section __TEXT,__const\\n"'),
        ('"\\t.globl " sym "_begin\\n" sym "_begin:\\n"', '"\\t.globl _" sym "_begin\\n_" sym "_begin:\\n"'),
        ('"\\t.globl " sym "_end\\n" sym "_end:\\n"', '"\\t.globl _" sym "_end\\n_" sym "_end:\\n"'),
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
                sys.exit("patch_dsperate_macho: %s no longer contains %s" % (rel, old))
            text = text.replace(old, new)
        path.write_text(text, encoding="utf-8")
        print("patched", rel)


if __name__ == "__main__":
    main(sys.argv[1])
