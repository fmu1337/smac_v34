#!/usr/bin/env python3
"""Build the per-map table from occ-dataset artifacts.

Usage: summarize.py RESULTS_DIR SUMMARY.md
Each immediate subdirectory (or the directory itself) may contain summary.txt.
"""
import os
import sys


def load_summary(path):
    data = {}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if "=" not in line:
                continue
            key, value = line.rstrip("\n").split("=", 1)
            data[key] = value
    return data


def find_summaries(root):
    found = []
    direct = os.path.join(root, "summary.txt")
    if os.path.isfile(direct):
        found.append(direct)
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name, "summary.txt")
        if os.path.isfile(path):
            found.append(path)
        nested = os.path.join(root, name)
        if not os.path.isdir(nested):
            continue
        for sub in sorted(os.listdir(nested)):
            path = os.path.join(nested, sub, "summary.txt")
            if os.path.isfile(path):
                found.append(path)
    # download-artifact lays out artifact-name/files
    return found


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: summarize.py RESULTS_DIR SUMMARY.md\n")
        return 2
    root, dest = sys.argv[1], sys.argv[2]
    rows = []
    proven_blocks = []
    for path in find_summaries(root):
        data = load_summary(path)
        if not data:
            continue
        rows.append(data)
        folder = os.path.dirname(path)
        proven = os.path.join(folder, "proven.txt")
        if os.path.isfile(proven):
            text = open(proven, encoding="utf-8", errors="replace").read().strip()
            if text:
                proven_blocks.append((data.get("map", folder), text))
    rows.sort(key=lambda item: item.get("map", ""))
    lines = [
        "# Occluder dataset",
        "",
        "| map | RESULT | records | engine-hidden proven by one brush | engine traces us | occluder us | PROVEN BUT ENGINE SEES |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(
            "| {map} | {result} | {records} | {proven_pct} | {trace_us} | {occ_us} | {proven_but_engine_sees} |".format(
                map=row.get("map", ""),
                result=row.get("result", ""),
                records=row.get("records", ""),
                proven_pct=row.get("proven_pct", ""),
                trace_us=row.get("trace_us", ""),
                occ_us=row.get("occ_us", ""),
                proven_but_engine_sees=row.get("proven_but_engine_sees", ""),
            )
        )
    lines.append("")
    lines.append("## Occluders")
    lines.append("")
    for row in rows:
        lines.append("- `{map}`: {line}".format(map=row.get("map", ""), line=row.get("occluder", "")))
        notes = row.get("notes", "")
        if notes:
            lines.append("  - {notes}".format(notes=notes))
    lines.append("")
    lines.append("## PROVEN BUT ENGINE SEES")
    lines.append("")
    if not proven_blocks:
        lines.append("No `PROVEN BUT ENGINE SEES` lines in the saved logs.")
    else:
        for map_name, text in proven_blocks:
            lines.append("### {map}".format(map=map_name))
            lines.append("")
            lines.append("```")
            lines.append(text)
            lines.append("```")
            lines.append("")
    text = "\n".join(lines) + "\n"
    with open(dest, "w", encoding="utf-8") as handle:
        handle.write(text)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
