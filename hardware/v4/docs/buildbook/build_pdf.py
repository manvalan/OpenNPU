#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Build FPGA-Neural-V4-Buildbook.pdf from the Markdown source.

Needs: python3 -m pip install markdown; Node.js with the playwright package
and a Chromium it can launch (CHROMIUM env var = executable path, optional).
Usage: python3 build_pdf.py   (run from any directory)
"""
import os
import pathlib
import re
import subprocess
import sys

import markdown

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE / "FPGA-Neural-V4-Buildbook.md"
HTML = HERE / "FPGA-Neural-V4-Buildbook.html"
PDF = HERE / "FPGA-Neural-V4-Buildbook.pdf"

CSS = """
@page { size: A4; margin: 18mm 16mm 18mm 16mm; }
body { font-family: "DejaVu Sans", "Liberation Sans", Arial, sans-serif; font-size: 9.2pt;
       line-height: 1.38; color: #1b1f24; }
h1 { color: #14285a; font-size: 22pt; margin: 0 0 4pt 0; border-bottom: 2.5pt solid #14285a; padding-bottom: 4pt; }
h2 { color: #14285a; font-size: 13pt; margin: 16pt 0 6pt 0; border-bottom: 0.8pt solid #9aa6c4;
     padding-bottom: 2pt; break-after: avoid; }
h3 { color: #14285a; font-size: 10.5pt; margin: 11pt 0 4pt 0; break-after: avoid; }
p { margin: 4pt 0; }
table { border-collapse: collapse; width: 100%; margin: 5pt 0 8pt 0; font-size: 8.4pt; break-inside: auto; }
tr { break-inside: avoid; }
th { background: #14285a; color: #fff; text-align: left; padding: 3pt 5pt; font-weight: 600; }
td { border-bottom: 0.5pt solid #c9cfdd; padding: 2.5pt 5pt; vertical-align: top; }
tr:nth-child(even) td { background: #eef1f7; }
code { font-family: "DejaVu Sans Mono", "Liberation Mono", monospace; font-size: 8.2pt;
       background: #eef1f7; padding: 0 2pt; border-radius: 2pt; }
pre { background: #f4f6fa; border: 0.6pt solid #c9cfdd; border-left: 3pt solid #14285a; padding: 6pt 8pt;
      font-size: 7.6pt; line-height: 1.3; overflow: hidden; white-space: pre; break-inside: avoid; }
pre code { background: none; padding: 0; font-size: 7.6pt; }
th code { background: rgba(255,255,255,0.18); color: #fff; }
blockquote { margin: 6pt 0; padding: 5pt 9pt; background: #fff6e5; border-left: 3pt solid #c77700; }
img { max-width: 100%; display: block; margin: 6pt auto; break-inside: avoid; }
hr { border: none; border-top: 0.6pt solid #c9cfdd; margin: 10pt 0; }
ul { margin: 4pt 0; padding-left: 15pt; }
li { margin: 1.5pt 0; }
"""

NODE = r"""
const { chromium } = require('playwright');
(async () => {
  const opts = process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {};
  const b = await chromium.launch(opts);
  const p = await b.newPage();
  await p.goto('file://' + process.argv[1], { waitUntil: 'load' });
  await p.pdf({ path: process.argv[2], format: 'A4', printBackground: true,
    displayHeaderFooter: true,
    headerTemplate: '<div style="font-size:7pt;width:100%;padding:0 16mm;color:#14285a;display:flex;justify-content:space-between"><b>FPGA-Neural V4</b><span>BUILDBOOK</span></div>',
    footerTemplate: '<div style="font-size:7pt;width:100%;padding:0 16mm;color:#555;display:flex;justify-content:space-between"><span>__REV__</span><span><span class="pageNumber"></span> / <span class="totalPages"></span></span></div>',
    margin: { top: '18mm', bottom: '16mm', left: '16mm', right: '16mm' } });
  await b.close();
})();
"""


def main():
    md = SRC.read_text(encoding="utf-8")
    m = re.search(r"Rev\. ([0-9.]+) — ([0-9-]+)", md)
    rev = f"Rev. {m.group(1)} — {m.group(2)}" if m else ""
    body = markdown.markdown(md, extensions=["tables", "fenced_code"])
    HTML.write_text(f"<!doctype html><html lang='it'><head><meta charset='utf-8'>"
                    f"<title>FPGA-Neural V4 Buildbook</title><style>{CSS}</style></head>"
                    f"<body>{body}</body></html>", encoding="utf-8")
    env = dict(os.environ)
    env.setdefault("NODE_PATH", subprocess.run(["npm", "root", "-g"], capture_output=True,
                                               text=True).stdout.strip())
    subprocess.run(["node", "-e", NODE.replace("__REV__", rev), str(HTML), str(PDF)], check=True, env=env)
    HTML.unlink()
    print(f"wrote {PDF}")


if __name__ == "__main__":
    sys.exit(main())
