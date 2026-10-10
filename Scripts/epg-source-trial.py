#!/usr/bin/env python3
"""Read-only, dependency-free XMLTV comparison outside the app.

Manifest paths are relative to the manifest. Channel mappings are explicit:
never infer an affiliate, timezone or subchannel from a fuzzy name match.
Downloads and reports belong in ignored ExampleData, not in git.
"""

import argparse
import collections
import datetime as dt
import gzip
import hashlib
import json
import pathlib
import re
import time
import xml.etree.ElementTree as ET

UTC = dt.timezone.utc
FIELDS = ("desc", "sub-title", "category", "icon", "date", "episode-num", "credits", "rating", "star-rating")


def timestamp(value):
    match = re.fullmatch(r"(\d{14})\s*([+-]\d{4}|Z)?", value or "")
    if not match:
        raise ValueError("Unsupported XMLTV timestamp")
    digits, zone = match.groups()
    zone = zone or "+0000"
    if zone == "Z":
        zone = "+0000"
    return dt.datetime.fromisoformat(
        f"{digits[:4]}-{digits[4:6]}-{digits[6:8]}T{digits[8:10]}:{digits[10:12]}:{digits[12:14]}{zone}"
    ).timestamp()


def iso(value):
    return dt.datetime.fromtimestamp(value, UTC).isoformat() if value is not None else None


def text(node, tag):
    return " ".join("".join(child.itertext()).strip() for child in node.findall(tag)).strip()


def normal_title(value):
    # This provider appends a superscript "New" badge to programme names.
    # Remove that exact badge only, never legitimate title words.
    return re.sub(r"[^\w]+", "", value.removesuffix("ᴺᵉʷ").strip().casefold())


def merged_intervals(rows, start, end):
    result = []
    for left, right in sorted((max(start, r["start"]), min(end, r["end"])) for r in rows if r["end"] > start and r["start"] < end):
        if not result or left > result[-1][1]:
            result.append([left, right])
        else:
            result[-1][1] = max(result[-1][1], right)
    return result


def coverage(rows, start, end):
    spans = merged_intervals(rows, start, end)
    seconds = sum(right - left for left, right in spans)
    contiguous = spans[0][1] - start if spans and spans[0][0] == start else 0
    cursor, gaps = start, []
    for left, right in spans:
        if left > cursor:
            gaps.append([iso(cursor), iso(left), round((left - cursor) / 60, 1)])
        cursor = right
    if cursor < end:
        gaps.append([iso(cursor), iso(end), round((end - cursor) / 60, 1)])
    window = [r for r in rows if r["end"] > start and r["start"] < end]
    current = [r for r in window if r["start"] <= start < r["end"]]
    fields = {field: sum(bool(r["fields"].get(field)) for r in window) for field in FIELDS}
    return {
        "rows": len(rows), "window_rows": len(window), "current": [{"title": r["title"], "start": iso(r["start"]), "end": iso(r["end"])} for r in current],
        "coverage_pct": round(seconds / (end - start) * 100, 2), "contiguous_hours": round(contiguous / 3600, 2),
        "last_end": iso(max((r["end"] for r in rows), default=None)), "gaps": gaps,
        "fields": fields, "average_description_chars": round(sum(r["description_chars"] for r in window) / len(window), 1) if window else 0,
        "duplicate_intervals": len(window) - len({(r["start"], r["end"]) for r in window}),
        "overlapping_adjacent_rows": sum(b["start"] < a["end"] for a, b in zip(sorted(window, key=lambda r: r["start"]), sorted(window, key=lambda r: r["start"])[1:])),
    }


class CountingReader:
    def __init__(self, handle):
        self.handle, self.count = handle, 0

    def read(self, size=-1):
        data = self.handle.read(size)
        self.count += len(data)
        return data


def scan(source, base, selected_ids):
    path = (base / source["path"]).resolve()
    digest = hashlib.sha256()
    with path.open("rb") as raw:
        for chunk in iter(lambda: raw.read(1024 * 1024), b""):
            digest.update(chunk)
    started = time.perf_counter()
    definitions, rows, counts = {}, collections.defaultdict(list), collections.Counter()
    supplied, earliest, latest = set(), None, None
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rb") as handle:
        reader = CountingReader(handle)
        iterator = ET.iterparse(reader, events=("start", "end"))
        _, root = next(iterator)
        if root.tag != "tv":
            raise ValueError(f"Not an XMLTV document: {path.name}")
        for event, node in iterator:
            if event != "end" or node.tag not in ("channel", "programme"):
                continue
            if node.tag == "channel":
                if node.get("id", "") in definitions:
                    counts["duplicate_channel_ids"] += 1
                definitions[node.get("id", "")] = [n.text or "" for n in node.findall("display-name")]
                counts["declared_channels"] += 1
            else:
                counts["programmes"] += 1
                cid = node.get("channel", "")
                supplied.add(cid)
                try:
                    start, end = timestamp(node.get("start")), timestamp(node.get("stop"))
                    if end <= start:
                        raise ValueError("Non-positive programme")
                except ValueError:
                    counts["invalid_times"] += 1
                else:
                    earliest = start if earliest is None else min(earliest, start)
                    latest = end if latest is None else max(latest, end)
                    if cid in selected_ids:
                        desc = text(node, "desc")
                        rows[cid].append({
                            "start": start, "end": end, "title": text(node, "title"), "description_chars": len(desc),
                            "subtitle": text(node, "sub-title"), "description": desc,
                            "fields": {field: bool(text(node, field)) if field in ("desc", "sub-title", "category", "date", "episode-num") else any(n.get("src") for n in node.findall(field)) if field == "icon" else bool(node.findall(field)) for field in FIELDS},
                        })
            root.clear()
    return {
        "name": source["name"], "url": source.get("url"), "compressed_bytes": path.stat().st_size,
        "xml_bytes": reader.count, "sha256": digest.hexdigest(), "scan_seconds": round(time.perf_counter() - started, 3),
        "counts": dict(counts), "programme_channels": len(supplied), "first_start": iso(earliest), "last_end": iso(latest),
        "definitions": definitions, "rows": dict(rows),
    }


def agreement(primary, other, start, end):
    a = {(r["start"], r["end"]): normal_title(r["title"]) for r in primary if r["end"] > start and r["start"] < end}
    b = {(r["start"], r["end"]): normal_title(r["title"]) for r in other if r["end"] > start and r["start"] < end}
    common = a.keys() & b.keys()
    same = sum(a[key] == b[key] for key in common)
    shifts = {hours: sum(a.get((r["start"] + hours * 3600, r["end"] + hours * 3600)) == normal_title(r["title"])
                         for r in other if start <= r["start"] + hours * 3600 < end) for hours in range(-12, 13)}
    best_shift = max(shifts, key=shifts.get)
    examples = [{"start": iso(key[0]), "end": iso(key[1]), "primary_title": next(r["title"] for r in primary if (r["start"], r["end"]) == key),
                 "other_title": next(r["title"] for r in other if (r["start"], r["end"]) == key)} for key in sorted(common) if a[key] != b[key]][:3]
    return {"primary_intervals": len(a), "other_intervals": len(b), "identical_intervals": len(common), "identical_titles_and_times": same,
            "same_title_pct_of_shared_intervals": round(same / len(common) * 100, 2) if common else None,
            "best_diagnostic_shift_hours": best_shift if shifts[best_shift] else None, "matches_after_diagnostic_shift": shifts[best_shift],
            "mismatch_examples": examples}


def fallback(primary, secondary):
    """Only insert whole secondary programmes entirely clear of primary rows.

    Do not clip programmes or merge metadata by a title-only match.
    """
    return primary + [r for r in secondary if not any(p["start"] < r["end"] and p["end"] > r["start"] for p in primary)]


def sports_evidence(primary, other):
    """Review cues, NOT an event matcher or permission to enrich a programme.

    A fixture in a subtitle can explain differing titles. It cannot establish
    competition, round, season or live/replay identity on its own.
    """
    combined = lambda r: " ".join(r.get(k, "") for k in ("title", "subtitle", "description"))
    a, b = combined(primary), combined(other)
    subtitle = normal_title(other.get("subtitle", ""))
    fixture_subtitle = bool(re.search(r"\s(?:v\.?|vs\.?|versus|at)\s", other.get("subtitle", ""), re.I))
    corroborated = fixture_subtitle and len(subtitle) >= 8 and subtitle in normal_title(a)
    flags = []
    live = lambda value: bool(re.search(r"\blive\b|ᴸᶦᵛᵉ", value, re.I))
    replay = lambda value: bool(re.search(r"\b(?:replay|highlights|classic|repeat)\b", value, re.I))
    if (live(a) and replay(b)) or (live(b) and replay(a)):
        flags.append("live/replay cues conflict")
    rounds = lambda value: set(re.findall(r"\b(first|second|third|fourth|fifth|\d+(?:st|nd|rd|th))\s+(?:t20|test|odi|round|leg)\b", value.casefold()))
    canonical = lambda values: {dict(first="1", second="2", third="3", fourth="4", fifth="5").get(v, re.sub(r"(?:st|nd|rd|th)$", "", v)) for v in values}
    ra, rb = canonical(rounds(a)), canonical(rounds(b))
    if ra and rb and ra.isdisjoint(rb):
        flags.append("round/leg cues conflict")
    years = lambda value: set(re.findall(r"\b(?:19|20)\d{2}\b", value))
    ya, yb = years(a), years(b)
    if ya and yb and ya.isdisjoint(yb):
        flags.append("year cues conflict")
    return {"fixture_subtitle_corroborated": corroborated, "conflict_cues": flags,
            "disposition": "conflicting cues" if flags else "manual event review" if corroborated else "unresolved"}


def sports_review(primary, other, start, end):
    a, b = collections.defaultdict(list), collections.defaultdict(list)
    for rows, grouped in ((primary, a), (other, b)):
        for r in rows:
            if r["end"] > start and r["start"] < end:
                grouped[(r["start"], r["end"])].append(r)
    counts, examples = collections.Counter(), []
    for interval in sorted(a.keys() & b.keys()):
        if len(a[interval]) != 1 or len(b[interval]) != 1:
            counts["ambiguous_intervals_rejected"] += 1
            continue
        p, q = a[interval][0], b[interval][0]
        if normal_title(p["title"]) == normal_title(q["title"]):
            counts["strict_matches"] += 1
            continue
        evidence = sports_evidence(p, q)
        counts["time_aligned_title_mismatches"] += 1
        counts[evidence["disposition"]] += 1
        counts["fixture_subtitle_corroborated"] += evidence["fixture_subtitle_corroborated"]
        if len(examples) < 12:
            fields = lambda r: {k: r.get(k, "")[:800] for k in ("title", "subtitle", "description")}
            examples.append({"start": iso(interval[0]), "end": iso(interval[1]), "provider": fields(p), "external": fields(q), **evidence})
    return {"counts": counts, "examples": examples, "automatic_event_matches": 0,
            "policy": "Exact intervals and reviewed station aliases only. All broader event evidence requires manual review; no app matching changes."}


def render(report):
    lines = ["# Offline EPG source trial", "", f"Evaluation window: {report['now']} to {report['window_end']} (UTC).", "",
             "This is one snapshot per source, not a reliability or refresh-cadence measurement. No app configuration is changed.", "",
             "## Source files", "", "| Source | Download/file MB | XML MB | Channels with programmes | Programmes | Scan seconds | Final programme end |",
             "| --- | ---: | ---: | ---: | ---: | ---: | --- |"]
    for s in report["sources"]:
        lines.append(f"| {s['name']} | {s['compressed_bytes']/1e6:.2f} | {s['xml_bytes']/1e6:.2f} | {s['programme_channels']} | {s['counts'].get('programmes', 0)} | {s['scan_seconds']:.3f} | {s['last_end']} |")
    lines += ["", "## Selected channels", "", "Current means an interval covers the evaluation instant; coverage is the union over the next 48 hours, including gaps. An alias identifies the station in guide metadata, not the bytes on the live stream.", "",
              "| Stream | Mapping status | Source | XMLTV ID | Current programme | 48h coverage | Contiguous hours | Last end |",
              "| --- | --- | --- | --- | --- | ---: | ---: | --- |"]
    for channel in report["channels"]:
        for name, result in channel["sources"].items():
            current = "; ".join(r["title"] for r in result["current"]).replace("|", "/") or "—"
            lines.append(f"| {channel['name'].replace('|', '/')} | {channel['status']} | {name} | {result['channel_id'] or '—'} | {current} | {result['coverage_pct']:.1f}% | {result['contiguous_hours']:.1f} | {result['last_end'] or '—'} |")
    lines += ["", "## Metadata in trusted sampled channels, next 48 hours", "", "| Source | Programme rows | Description | Subtitle | Category | Artwork | Year/date | Episode ID | Average description chars |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for name, stats in report["metadata"].items():
        count = stats["rows"]
        percentage = lambda field: f"{stats['fields'][field]/count*100:.1f}%" if count else "—"
        lines.append(f"| {name} | {count} | {percentage('desc')} | {percentage('sub-title')} | {percentage('category')} | {percentage('icon')} | {percentage('date')} | {percentage('episode-num')} | {stats['average_description_chars']:.1f} |")
    lines += ["", "## Aggregate comparison (trusted sampled channels only)", "", "Title matching ignores case, punctuation and the provider's exact trailing superscript New badge. No timezone correction is applied; diagnostic shift estimates appear only in the JSON.", "",
              "| External source | Matched affiliates | Current affiliates | Provider/external same title and times | Provider-first current | External-first current | Gap fallback current |",
              "| --- | ---: | ---: | --- | ---: | ---: | ---: |"]
    for name, s in report["comparison"].items():
        lines.append(f"| {name} | {s['mapped']} | {s['current']} | {s['same_titles']}/{s['shared_intervals']} shared intervals | {s['provider_first_current']} | {s['external_first_current']} | {s['gap_fallback_current']} |")
    lines += ["", "## Sports field evidence (offline only)", "",
              "Exact time intervals are required. Subtitle/description evidence creates a manual review queue, never an automatic event match. Same teams can refer to a different round, replay or season.", "",
              "| Channel | Source | Strict matches | Title mismatches | Fixture subtitle corroborated | Conflicting cues | Ambiguous intervals rejected |",
              "| --- | --- | ---: | ---: | ---: | ---: | ---: |"]
    for channel in report["channels"]:
        for name, result in channel.get("sports_review", {}).items():
            c = result["counts"]
            lines.append(f"| {channel['name']} | {name} | {c.get('strict_matches', 0)} | {c.get('time_aligned_title_mismatches', 0)} | {c.get('fixture_subtitle_corroborated', 0)} | {c.get('conflicting cues', 0)} | {c.get('ambiguous_intervals_rejected', 0)} |")
    lines += ["", "## Longer-range strategy comparison", "", "Mean coverage over seven days, across all trusted sampled channels (including unmapped channels via the provider fallback).", "",
              "| External source | Provider-first coverage | External-first coverage | Whole-programme gap fallback |",
              "| --- | ---: | ---: | ---: |"]
    for name in report["comparison"]:
        channels = [c for c in report["channels"] if c["status"] == "explicit affiliate alias"]
        averages = {key: sum(c["strategies"][name][key]["seven_day_coverage_pct"] for c in channels) / len(channels) for key in ("provider_first", "external_first", "gap_fallback")} if channels else {}
        if averages:
            lines.append(f"| {name} | {averages['provider_first']:.1f}% | {averages['external_first']:.1f}% | {averages['gap_fallback']:.1f}% |")
    lines += ["", "Source-first columns simulate the app's channel-level ownership (any rows claim that channel), not a cross-source time-window merge. Gap fallback preserves whole programmes and never clips conflicting intervals.", "",
              "## Fixture audit", "", f"{report['fixture']['streams']} streams; {report['fixture']['with_epg_id']} have an EPG ID. Only explicitly reviewed selections contribute to aggregate comparisons.", "",
              "Conflicting uses of one provider ID:"]
    for cid, names in report["fixture"]["shared_ids"].items():
        lines.append(f"- `{cid}`: {'; '.join(names)}")
    lines += ["", "See the JSON report for explicit mappings, gap intervals, per-channel metadata counts, schedule disagreement examples, and all three strategy results.", ""]
    return "\n".join(lines)


def run(manifest_path):
    manifest = json.loads(manifest_path.read_text())
    base = manifest_path.parent
    streams = json.loads((base / manifest["streams"]).read_text())
    by_id = {s["stream_id"]: s for s in streams}
    now = dt.datetime.fromisoformat(manifest["now"].replace("Z", "+00:00")).timestamp()
    end = now + 48 * 3600
    selections = []
    for entry in manifest["channels"]:
        stream = by_id[entry["stream_id"]]
        selections.append({**entry, "name": stream["name"], "provider_id": stream.get("epg_channel_id") or None})
    scans = {}
    for source in manifest["sources"]:
        name = source["name"]
        ids = {c["provider_id"] if name == "provider" else c.get("aliases", {}).get(name) for c in selections} - {None}
        scans[name] = scan(source, base, ids)
        print(f"Scanned {name}: {scans[name]['counts'].get('programmes', 0)} programmes in {scans[name]['scan_seconds']}s", flush=True)
    channel_reports, comparison, metadata = [], {}, {}
    for name in scans:
        metadata[name] = {"rows": 0, "fields": collections.Counter(), "description_chars": 0}
        if name != "provider":
            comparison[name] = collections.Counter()
    for selection in selections:
        result = {**selection, "sources": {}, "agreement": {}, "strategies": {}, "enrichment": {}, "sports_review": {}}
        primary = scans["provider"]["rows"].get(selection["provider_id"], [])
        for name, source in scans.items():
            cid = selection["provider_id"] if name == "provider" else selection.get("aliases", {}).get(name)
            rows = source["rows"].get(cid, [])
            result["sources"][name] = {"channel_id": cid, "declared_names": source["definitions"].get(cid, []), **coverage(rows, now, end),
                                       "seven_day_coverage_pct": coverage(rows, now, now + 7 * 86400)["coverage_pct"]}
            if selection["status"] == "explicit affiliate alias":
                stats = metadata[name]
                current = result["sources"][name]
                stats["rows"] += current["window_rows"]
                stats["fields"].update(current["fields"])
                stats["description_chars"] += sum(r["description_chars"] for r in rows if r["end"] > now and r["start"] < end)
            if name == "provider":
                continue
            result["agreement"][name] = agreement(primary, rows, now, end)
            if selection.get("sports") and selection["status"] == "explicit affiliate alias" and cid:
                result["sports_review"][name] = sports_review(primary, rows, now, end)
            index = {(r["start"], r["end"], normal_title(r["title"])): r for r in rows}
            added = collections.Counter()
            for p in primary:
                if p["end"] <= now or p["start"] >= end:
                    continue
                match = index.get((p["start"], p["end"], normal_title(p["title"])))
                if match:
                    added.update({field: bool(match["fields"].get(field)) and not p["fields"].get(field) for field in FIELDS})
            result["enrichment"][name] = added
            strategies = {"provider_first": primary if primary else rows, "external_first": rows if rows else primary, "gap_fallback": fallback(primary, rows)}
            result["strategies"][name] = {key: {**coverage(value, now, end), "seven_day_coverage_pct": coverage(value, now, now + 7 * 86400)["coverage_pct"]} for key, value in strategies.items()}
            if selection["status"] == "explicit affiliate alias":
                totals = comparison[name]
                totals["mapped"] += bool(cid and cid in source["definitions"])
                totals["current"] += bool(result["sources"][name]["current"])
                totals["same_titles"] += result["agreement"][name]["identical_titles_and_times"]
                totals["shared_intervals"] += result["agreement"][name]["identical_intervals"]
                for key in strategies:
                    totals[key + "_current"] += bool(result["strategies"][name][key]["current"])
        channel_reports.append(result)
    for stats in metadata.values():
        stats["average_description_chars"] = stats.pop("description_chars") / stats["rows"] if stats["rows"] else 0
    shared = collections.defaultdict(list)
    for stream in streams:
        if stream.get("epg_channel_id"):
            shared[stream["epg_channel_id"]].append(stream["name"])
    return {
        "now": iso(now), "window_end": iso(end), "sources": [{k: v for k, v in s.items() if k not in ("definitions", "rows")} for s in scans.values()],
        "fixture": {"streams": len(streams), "with_epg_id": sum(bool(s.get("epg_channel_id")) for s in streams), "shared_ids": {k: v for k, v in shared.items() if len(v) > 1}},
        "channels": channel_reports, "metadata": metadata, "comparison": comparison,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True, help="Report prefix in an ignored local directory")
    args = parser.parse_args()
    report = run(args.manifest.resolve())
    args.output.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n")
    args.output.with_suffix(".md").write_text(render(report))


if __name__ == "__main__":
    main()
