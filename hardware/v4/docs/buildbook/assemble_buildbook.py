#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Rebuilds the table of contents of FPGA-Neural-V4-Buildbook.md.

The index goes between <!-- BEGIN INDICE --> and <!-- END INDICE -->
(chapters "## " and sections "### ", code blocks skipped). Since rev. 2.0
the former appendices (CAP_*.md) are chapters of the buildbook itself.

Usage: python3 assemble_buildbook.py   (then build_pdf.py for the PDF)
"""
import pathlib
import re

HERE = pathlib.Path(__file__).resolve().parent
DS = HERE / "FPGA-Neural-V4-Buildbook.md"


def main():
    s = DS.read_text()
    body = re.sub(r"<!-- BEGIN INDICE -->.*?<!-- END INDICE -->", "", s, flags=re.S)
    toc, in_code = [], False
    for line in body.split("\n"):
        if line.startswith("```"):
            in_code = not in_code
        if in_code:
            continue
        m = re.match(r"^(##|###) (.+)$", line)
        if m and m.group(2) != "Indice":
            if m.group(1) == "##":
                toc.append([m.group(2)])
            elif toc:
                toc[-1].append(m.group(2))
    # one paragraph per chapter (a "1." list would be renumbered by Markdown)
    paras = ["**%s**%s" % (c[0], "" if len(c) == 1 else " — " + " · ".join(c[1:])) for c in toc]
    idx = "<!-- BEGIN INDICE -->\n## Indice\n\n" + "\n\n".join(paras) + "\n<!-- END INDICE -->"
    if "<!-- BEGIN INDICE -->" in s:
        s = re.sub(r"<!-- BEGIN INDICE -->.*?<!-- END INDICE -->", lambda m: idx, s, flags=re.S)
    else:
        first = s.index("\n## ")
        s = s[:first] + "\n" + idx + "\n\n---\n" + s[first:]
    DS.write_text(s)
    print(f"{DS.name}: index of {len(toc)} chapters, {sum(len(c) for c in toc)} entries")


if __name__ == "__main__":
    main()
