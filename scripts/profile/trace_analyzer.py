#!/usr/bin/env python3
"""
Trace log analyzer for containerd sandbox creation latency.

Parses [TRACE] stderr output from containerd and generates a hierarchical
timing report grouped by sandbox. Uses trace_id, span_id, and parent span ID
to reconstruct the span tree and compute per-stage latencies.

Usage:
    # Capture trace logs:
    containerd 2> trace.log

    # Trigger a sandbox creation, then analyze:
    python contrib/trace_analyzer.py trace.log

    # Filter to a specific sandbox:
    python contrib/trace_analyzer.py trace.log --sandbox <id>

    # Show only top-level summary across all sandboxes:
    python contrib/trace_analyzer.py trace.log --summary

    # JSON output for piping to other tools:
    python contrib/trace_analyzer.py trace.log --json
"""

import argparse
import json
import math
import os
import re
import sys
from collections import defaultdict


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

# Matches [TRACE] start and end lines.
# Format:
#   [TRACE] start name="..." trace=<hex> span=<hex> parent=<hex> [attrs...]
#   [TRACE] end   name="..." trace=<hex> span=<hex> dur=<dur>    [attrs...]
_TRACE_RE = re.compile(
    r"\[TRACE\]\s+"
    r"(?P<kind>start|end)\s+"
    r'name="(?P<name>[^"]*)"\s+'
    r"trace=(?P<trace>[0-9a-fA-F]{32})\s+"
    r"span=(?P<span>[0-9a-fA-F]{16})"
    r"(?:\s+parent=(?P<parent>[0-9a-fA-F]{16}))?"
    r"(?:\s+dur=(?P<dur>[0-9.]+(?:µs|ms|s|m)))?"
    r"(?P<attrs>(?:\s+\S+=\S+)*)"
)

# Matches key=value attribute pairs.
_ATTR_RE = re.compile(r"(\S+)=(\S+)")


def parse_duration(s):
    """Parse a Go-style duration string to milliseconds (float)."""
    if s.endswith("ms"):
        return float(s[:-2])
    elif s.endswith("µs"):
        return float(s[:-2]) / 1000.0
    elif s.endswith("s") and not s.endswith("ms"):
        return float(s[:-1]) * 1000.0
    elif s.endswith("m"):
        return float(s[:-1]) * 60_000.0
    return float(s)


def parse_attrs(attr_str):
    """Parse ' key1=value1 key2=value2' into a dict."""
    if not attr_str:
        return {}
    result = {}
    for m in _ATTR_RE.finditer(attr_str):
        result[m.group(1)] = m.group(2)
    return result


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

class Span:
    __slots__ = (
        "name", "trace_id", "span_id", "parent_span_id",
        "attrs", "duration_ms", "started", "ended",
        "children", "dup_index",
    )

    def __init__(self, name, trace_id, span_id, parent_span_id,
                 attrs=None, duration_ms=0.0, started=False, ended=False):
        self.name = name
        self.trace_id = trace_id
        self.span_id = span_id
        self.parent_span_id = parent_span_id
        self.attrs = attrs if attrs is not None else {}
        self.duration_ms = duration_ms
        self.started = started
        self.ended = ended
        self.children = []
        self.dup_index = 0


def build_trees(spans):
    """Attach children to parents in-place. Returns list of root spans."""
    by_id = {}
    for s in spans:
        by_id[s.span_id] = s

    roots = []
    # Track how many children with the same name each parent has,
    # so we can assign dup_index for display.
    child_name_count = defaultdict(int)

    for s in spans:
        if s.parent_span_id == "0000000000000000" or s.parent_span_id not in by_id:
            roots.append(s)
        else:
            parent = by_id[s.parent_span_id]
            key = (s.parent_span_id, s.name)
            s.dup_index = child_name_count[key]
            child_name_count[key] += 1
            parent.children.append(s)

    return roots


def backfill_sandbox_id(spans):
    """Propagate sandbox.id from spans that have it to those that don't.

    In the RunPodSandbox flow, the root span (cri.sandbox.run) starts before
    the sandbox ID is generated. The ID is added later via SetAttributes and
    appears on child spans via WithAttribute. This function ensures every
    span in the same trace carries the sandbox.id.
    """
    # Collect sandbox IDs per trace from spans that have them.
    trace_sandbox = {}
    for s in spans:
        sid = s.attrs.get("sandbox.id", "")
        if sid:
            trace_sandbox[s.trace_id] = sid

    # Backfill
    for s in spans:
        if "sandbox.id" not in s.attrs and s.trace_id in trace_sandbox:
            s.attrs["sandbox.id"] = trace_sandbox[s.trace_id]


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

def format_ms(ms):
    """Human-readable duration string."""
    if ms < 0.001:
        return "   ~0ms"
    elif ms < 1:
        return f"{ms:.3f}ms"
    elif ms < 10:
        return f" {ms:.2f}ms"
    elif ms < 100:
        return f"{ms:.1f}ms"
    elif ms < 1000:
        return f"{ms:.0f}ms"
    elif ms < 60_000:
        return f"{ms / 1000:.2f}s"
    else:
        return f"{ms / 60_000:.1f}m"


def self_time(span):
    """Duration not accounted for by direct children."""
    child_sum = sum(c.duration_ms for c in span.children)
    return max(0, span.duration_ms - child_sum)


def print_tree(spans, total_ms, file=sys.stdout, indent=0, prefix=""):
    """Recursively print a span tree."""
    for i, s in enumerate(spans):
        is_last = i == len(spans) - 1
        if indent == 0:
            branch = ""
            child_pre = "  "
        else:
            branch = "└─ " if is_last else "├─ "
            child_pre = "    " if is_last else "│   "

        pct = (s.duration_ms / total_ms * 100) if total_ms > 0 else 0
        st = self_time(s)

        # Build display name (append #N for duplicates)
        display_name = s.name
        if s.dup_index > 0:
            display_name += f" (#{s.dup_index + 1})"

        # Format the line
        dur_str = format_ms(s.duration_ms)
        line = f"{prefix}{branch}{display_name}"
        # Pad to align durations
        pad = max(2, 60 - len(line))
        self_str = f"[self: {format_ms(st)}]" if st > 0.5 else ""
        print(f"{line}{' ' * pad}{dur_str} ({pct:4.1f}%) {self_str}", file=file)

        if s.children:
            print_tree(
                s.children,
                total_ms,
                file=file,
                indent=indent + 1,
                prefix=prefix + child_pre,
            )


def _find_sandbox_id(spans):
    """Find sandbox.id from any span in the list, or return None."""
    for s in spans:
        sid = s.attrs.get("sandbox.id", "")
        if sid:
            return sid
    return None


def print_text_report(traces, file=sys.stdout):
    """Print a human-readable hierarchical timing report."""
    first = True
    for trace_id, spans in traces.items():
        roots = build_trees(spans)
        if not roots:
            continue

        sandbox_id = _find_sandbox_id(spans)
        total_ms = sum(r.duration_ms for r in roots)

        if not first:
            print(file=file)
        first = False

        if sandbox_id:
            header = f"═══ Sandbox: {sandbox_id} ═══"
        else:
            header = f"═══ Trace: {trace_id} ═══ (no sandbox.id)"
        print(header, file=file)
        print(f"Trace: {trace_id}", file=file)
        print(f"Total wall-clock: {format_ms(total_ms)}", file=file)
        print(file=file)

        print_tree(roots, total_ms, file=file)


def print_json_report(traces, file=sys.stdout):
    """Print a JSON report."""

    def span_to_dict(s):
        return {
            "name": s.name,
            "span_id": s.span_id,
            "parent_span_id": s.parent_span_id,
            "duration_ms": s.duration_ms,
            "self_ms": self_time(s),
            "attrs": s.attrs,
            "children": [span_to_dict(c) for c in s.children],
        }

    output = {}
    for trace_id, spans in traces.items():
        roots = build_trees(spans)
        sandbox_id = _find_sandbox_id(spans)
        output[trace_id] = {
            "sandbox_id": sandbox_id,
            "spans": [span_to_dict(r) for r in roots],
        }
    json.dump(output, file, indent=2)


def print_summary_report(traces, file=sys.stdout):
    """Print a summary table across all sandboxes: per-stage stats."""
    # Collect stats per span name
    stats = defaultdict(list)

    for _trace_id, spans in traces.items():
        for s in spans:
            stats[s.name].append(s.duration_ms)

    # For each unique span name, compute p50, p95, p99, avg, count
    import math

    print(f"{'Span Name':<55} {'Count':>5} {'Avg':>8} {'p50':>8} {'p95':>8} {'p99':>8}", file=file)
    print("-" * 100, file=file)

    for name in sorted(stats.keys()):
        durs = sorted(stats[name])
        n = len(durs)
        if n == 0:
            continue
        avg = sum(durs) / n

        def percentile(data, p):
            if not data:
                return 0
            k = (p / 100.0) * (len(data) - 1)
            f = math.floor(k)
            c = math.ceil(k)
            if f == c:
                return data[int(k)]
            d0 = data[int(f)] * (c - k)
            d1 = data[int(c)] * (k - f)
            return d0 + d1

        p50 = percentile(durs, 50)
        p95 = percentile(durs, 95)
        p99 = percentile(durs, 99)

        print(
            f"{name:<55} {n:>5} {format_ms(avg):>8} {format_ms(p50):>8} "
            f"{format_ms(p95):>8} {format_ms(p99):>8}",
            file=file,
        )


def _span_label(span):
    """Span name with (#N) suffix for same-parent duplicate siblings."""
    label = span.name
    if span.dup_index > 0:
        label += " (#{})".format(span.dup_index + 1)
    return label


# Canonical forest roots kept as top-level trees in --summary-tree.
_ANCHOR_ROOTS = frozenset({
    "cri.sandbox.run",
    "runc.create",
    "containerd.task.v3.Task/Create",
})

# High-frequency RPC roots that must not absorb unrelated orphans/children
# in the printed summary tree (common otel/journal parent-link noise).
_NOISE_ROOTS = frozenset({
    "containerd.task.v3.Task/State",
    "containerd.services.events.ttrpc.v1.Events/Forward",
})


def _fold_parent_for_orphan_root(name):
    """Map orphan mid-tree roots onto a synthetic parent so they merge.

    When journal/parent links drop a span, its children become roots and
    --summary-tree used to print a second copy of the same logical subtree.
    Fold those orphans back under the forest they belong to.
    """
    if name in _ANCHOR_ROOTS or name.startswith("containerd.task.v3.Task/"):
        return None
    if name.startswith("runc."):
        return "runc.create"
    if name.startswith(("shim.", "runtime.", "tasks.")):
        # Detail often lives under the shim RPC forest; also appears under CRI.
        return "containerd.task.v3.Task/Create"
    if name.startswith((
        "metadata.", "client.", "cni.", "container.", "cri.",
        "sandbox.", "process.",
    )):
        return "cri.sandbox.run"
    return None


def _path_top(path_key):
    return path_key.split("\0", 1)[0] if path_key else ""


def _path_under_noise(path_key):
    return _path_top(path_key) in _NOISE_ROOTS


def _root_sort_key(span):
    """Process real forest anchors before orphans so suffix-merge can hit."""
    name = span.name
    if name == "cri.sandbox.run":
        return (0, 0, name)
    # Create before State/other Task methods so folded orphans attach here.
    if name == "containerd.task.v3.Task/Create":
        return (1, 0, name)
    if name.startswith("containerd.task.v3.Task/"):
        return (1, 1, name)
    if name == "runc.create":
        return (2, 0, name)
    return (3, 0, name)


def _resolve_agg_path(parent_path, label, seen_paths):
    """Build aggregation path; merge fragments into an existing suffix path."""
    path_key = parent_path + "\0" + label if parent_path else label
    if path_key in seen_paths:
        return path_key

    # Prefer merging into an already-seen nested path ending with this label
    # (covers journal orphans and fold-under-anchor short paths).
    suffix = "\0" + label
    matches = [k for k in seen_paths if k == label or k.endswith(suffix)]
    if parent_path:
        pref = parent_path + "\0"
        matches = [k for k in matches if k.startswith(pref)]
    # Never merge into noise RPC forests (Task/State, Events/Forward, …).
    matches = [k for k in matches if not _path_under_noise(k)]
    if not matches:
        return path_key

    def rank(k):
        if k == "cri.sandbox.run" or k.startswith("cri.sandbox.run\0"):
            group = 0
        elif k == "containerd.task.v3.Task/Create" or k.startswith(
                "containerd.task.v3.Task/Create\0"):
            group = 1
        elif k == "runc.create" or k.startswith("runc.create\0"):
            group = 2
        else:
            group = 3
        return (group, -k.count("\0"), -len(k))

    matches.sort(key=rank)
    return matches[0]


def print_summary_tree_report(traces, file=sys.stdout):
    """Print per-stage summary in tree-structure order across all sandboxes.

    Unlike --summary (alphabetical), this walks each trace's span tree and
    preserves the parent-child ordering with indentation, so the output
    mirrors the hierarchical structure of the sandbox creation flow.

    Aggregation key is the full ancestor path (including (#N) labels), not
    the leaf name alone. Otherwise a second sibling such as
    ``metadata.sandbox.Update (#2)`` would look like a bare leaf: its
    children share names with the first Update's children and get folded
    into that first subtree instead of nesting under (#2).

    Orphan roots (missing parent in the log) are folded under canonical
    forest anchors and/or suffix-merged so the same logical span is not
    printed twice as disconnected trees. Fold anchors are always printed
    even when never observed as a real span, so orphans do not visually
    nest under the previous unrelated root (e.g. Task/State).
    """
    # order: [(path_key, label, depth)] first-appearance order
    order = []
    seen_paths = set()
    # Anchors inserted only so folded orphans have a visible parent row.
    synthetic_anchors = set()
    # all_spans: [(path_key, duration_ms)]
    all_spans = []

    def ensure_anchor(anchor_name):
        if anchor_name in seen_paths:
            return
        seen_paths.add(anchor_name)
        order.append((anchor_name, anchor_name, 0))
        synthetic_anchors.add(anchor_name)

    for _trace_id, spans in traces.items():
        roots = build_trees(spans)
        if not roots:
            continue
        roots = sorted(roots, key=_root_sort_key)

        def walk(nodes, depth, parent_path):
            for s in nodes:
                # Reparent spans that otel/journal wrongly hung under noise RPCs.
                top = _path_top(parent_path)
                if top in _NOISE_ROOTS:
                    alt = _fold_parent_for_orphan_root(s.name)
                    if alt:
                        ensure_anchor(alt)
                        walk([s], 1, alt)
                        continue

                label = _span_label(s)
                natural = parent_path + "\0" + label if parent_path else label
                path_key = _resolve_agg_path(parent_path, label, seen_paths)

                # If suffix-merge rewrote the path, indent to the merged location.
                if path_key != natural:
                    disp_depth = path_key.count("\0")
                else:
                    disp_depth = depth

                if path_key not in seen_paths:
                    seen_paths.add(path_key)
                    order.append((path_key, label, disp_depth))
                    synthetic_anchors.discard(path_key)

                all_spans.append((path_key, s.duration_ms))
                walk(s.children, disp_depth + 1, path_key)

        for root in roots:
            fold = _fold_parent_for_orphan_root(root.name)
            if fold:
                ensure_anchor(fold)
                walk([root], 1, fold)
            else:
                walk([root], 0, "")

    if not all_spans and not order:
        print("No spans to summarize.", file=file)
        return

    # Aggregate stats per path (not bare span name)
    stats = defaultdict(list)
    for path_key, dur in all_spans:
        stats[path_key].append(dur)

    # Header
    header = "{:<65} {:>5} {:>8} {:>8} {:>8} {:>8}".format(
        "Span Name", "Cnt", "Avg", "P50", "P95", "P99")
    print(header, file=file)
    print("-" * 105, file=file)

    def percentile(data, p):
        if not data:
            return 0
        k = (p / 100.0) * (len(data) - 1)
        f = math.floor(k)
        c = math.ceil(k)
        if f == c:
            return data[int(k)]
        return data[int(f)] * (c - k) + data[int(c)] * (k - f)

    # Print in tree order; indent + leaf label only (path is for grouping)
    prev_depth = None
    for path_key, label, depth in order:
        # Blank line between top-level forests for readability.
        if depth == 0 and prev_depth is not None:
            print("", file=file)
        prev_depth = depth

        indent = "  " * depth
        display = indent + label

        if path_key not in stats:
            # Synthetic fold anchor with no observed samples of its own.
            print(
                "{:<65} {:>5} {:>8} {:>8} {:>8} {:>8}".format(
                    display[:65], "-", "-", "-", "-", "-"),
                file=file,
            )
            continue

        durs = sorted(stats[path_key])
        n = len(durs)
        avg = sum(durs) / n

        p50 = percentile(durs, 50)
        p95 = percentile(durs, 95)
        p99 = percentile(durs, 99)

        print(
            "{:<65} {:>5} {:>8} {:>8} {:>8} {:>8}".format(
                display[:65], n,
                format_ms(avg),
                format_ms(p50),
                format_ms(p95),
                format_ms(p99)),
            file=file,
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Analyze containerd [TRACE] logs for sandbox latency breakdown."
    )
    parser.add_argument(
        "logfile",
        nargs="?",
        help="Path to trace log file (reads stdin if omitted or '-')",
    )
    parser.add_argument(
        "--sandbox",
        "-s",
        help="Filter by sandbox ID",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output JSON instead of text tree",
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="Print per-stage summary statistics across all sandboxes (alphabetical)",
    )
    parser.add_argument(
        "--summary-tree",
        action="store_true",
        help="Print per-stage summary in tree-structure order with indentation",
    )
    args = parser.parse_args()

    # Read input
    if args.logfile and args.logfile != "-":
        with open(args.logfile) as f:
            lines = f.readlines()
    else:
        lines = sys.stdin.readlines()

    # Parse all spans
    raw_spans = {}  # keyed by span_id

    for line in lines:
        m = _TRACE_RE.search(line)
        if not m:
            continue

        kind = m.group("kind")
        span_id = m.group("span")
        trace_id = m.group("trace")
        parent = m.group("parent") or "0000000000000000"

        if kind == "start":
            attrs = parse_attrs(m.group("attrs") or "")
            raw_spans[span_id] = Span(
                name=m.group("name"),
                trace_id=trace_id,
                span_id=span_id,
                parent_span_id=parent,
                attrs=attrs,
                started=True,
            )
        elif kind == "end":
            dur = parse_duration(m.group("dur") or "0ms")
            if span_id in raw_spans:
                raw_spans[span_id].duration_ms = dur
                raw_spans[span_id].ended = True
                # Merge attrs from end line (may have extra attributes)
                end_attrs = parse_attrs(m.group("attrs") or "")
                raw_spans[span_id].attrs.update(end_attrs)
            else:
                # Orphan end line (start not captured) — still record it
                attrs = parse_attrs(m.group("attrs") or "")
                raw_spans[span_id] = Span(
                    name=m.group("name"),
                    trace_id=trace_id,
                    span_id=span_id,
                    parent_span_id=parent,
                    attrs=attrs,
                    duration_ms=dur,
                    ended=True,
                )

    # Filter out incomplete spans (no end recorded)
    spans = [s for s in raw_spans.values() if s.ended]

    # Backfill sandbox.id from spans that have it to those that don't.
    # (Root spans like cri.sandbox.run start before the sandbox ID is generated.)
    backfill_sandbox_id(spans)

    # Filter by sandbox ID if requested
    if args.sandbox:
        # Collect trace_ids that contain this sandbox
        matching_traces = set()
        for s in spans:
            if s.attrs.get("sandbox.id") == args.sandbox:
                matching_traces.add(s.trace_id)
        spans = [s for s in spans if s.trace_id in matching_traces]

    if not spans:
        print("No trace spans found.", file=sys.stderr)
        sys.exit(1)

    # Group by trace_id
    by_trace = defaultdict(list)
    for s in spans:
        by_trace[s.trace_id].append(s)

    # Output
    if args.json:
        print_json_report(by_trace)
    elif args.summary_tree:
        print_summary_tree_report(by_trace)
    elif args.summary:
        print_summary_report(by_trace)
    else:
        print_text_report(by_trace)


if __name__ == "__main__":
    main()
