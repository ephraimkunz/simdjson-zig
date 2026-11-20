#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "matplotlib",
#     "pyqt6",
#     "numpy",
# ]
# ///

"""
This script shows `hyperfine` benchmark results as bar charts. The speed chart
shows throughput (file size / mean wall-clock time, with error bars propagated
from the stddev); a second chart shows peak memory.

The input file size in bytes is required and applies to every benchmark.

Commands may optionally have the form "<variant> < <input file>". In that case
the x-axis has one group per input file and one bar per variant within each
group. Otherwise every command is its own bar.
"""

import argparse
import json
import pathlib
import re
from typing import NamedTuple

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.ticker import FuncFormatter


class Metric(NamedTuple):
    label: str
    unit: str = ""
    scale: float = 1


METRICS = {
    "time_wall_clock": Metric("Wall-clock time", "s"),
    "time_cpu": Metric("Total CPU time", "s"),
    "time_user": Metric("User CPU time", "s"),
    "time_system": Metric("System CPU time", "s"),
    "memory_peak_resident": Metric("Peak resident memory", "MiB", 1024**2),
}

MEMORY_METRIC = "memory_peak_resident"
TIME_METRICS = [m for m, info in METRICS.items() if info.unit == "s"]


def validate_metric(parser, results, metric):
    for result in results:
        if metric not in result["summary"]:
            parser.error(
                f"metric {metric!r} is unavailable for "
                f"{result.get('name', result['command'])!r}"
            )


def load_results(parser, filenames, metric=None):
    exports = []
    for filename in filenames:
        with open(filename, encoding="utf-8") as f:
            export = json.load(f)
        if not export["results"]:
            parser.error(f"no benchmark results in {filename}")
        exports.append(export)

    if metric is None:
        primary_metrics = {
            export.get("primary_metric", "time_wall_clock") for export in exports
        }
        if len(primary_metrics) != 1:
            parser.error(
                "input files use different primary metrics; select one with --metric"
            )
        metric = primary_metrics.pop()
    if metric not in TIME_METRICS:
        parser.error(f"throughput needs a time metric; choose one of {TIME_METRICS}")

    results = [export["results"] for export in exports]
    for benchmarks in results:
        validate_metric(parser, benchmarks, metric)
    return metric, results


def format_throughput(value, _pos=None):
    """Format a throughput given in MB/s as MB/s or GB/s."""
    if value == 0:
        return "0"
    if abs(value) >= 1000:
        return f"{value / 1000:.1f} GB/s"
    return f"{value:.1f} MB/s"


def format_mib(value, _pos=None):
    """Format a memory size given in MiB as MiB or GiB."""
    if value == 0:
        return "0"
    if abs(value) >= 1024:
        return f"{value / 1024:.1f} GiB"
    return f"{value:.1f} MiB"


def make_chart(parser, args, datasets, metric, size_mb=None, title=None):
    """Build one figure. If size_mb is given, plot throughput (MB/s) for the
    time `metric`; otherwise plot the raw `metric` value."""
    metric_info = METRICS[metric]
    throughput = size_mb is not None

    inputs = []  # group names, in order of first appearance
    variants = []  # bar names, in order of first appearance
    means = {}  # (variant, input) -> value
    errs = {}  # (variant, input) -> error bar
    has_inputs = False

    for results in datasets:
        for b in results:
            command = b.get("name", b["command"])
            match = re.search(r"\s*<\s*(\S+)\s*$", command)
            if match:
                variant = command[: match.start()]
                input_name = pathlib.Path(match.group(1)).stem
                has_inputs = True
            else:
                variant, input_name = command, "(no input)"
            if input_name not in inputs:
                inputs.append(input_name)
            if variant not in variants:
                variants.append(variant)
            summary = b["summary"][metric]
            mean = summary["mean"] / metric_info.scale
            std = (summary.get("stddev") or 0) / metric_info.scale
            if throughput:
                # t -> size/t; first-order error propagation: size * std / t^2
                errs[(variant, input_name)] = size_mb * std / mean**2
                means[(variant, input_name)] = size_mb / mean
            else:
                means[(variant, input_name)] = mean
                errs[(variant, input_name)] = std

    input_labels = args.input_names or inputs
    variant_labels = args.variant_names or variants
    if len(input_labels) != len(inputs):
        parser.error(f"--input-names needs {len(inputs)} names, found inputs: {inputs}")
    if len(variant_labels) != len(variants):
        parser.error(
            f"--variant-names needs {len(variants)} names, found variants: {variants}"
        )

    fmt = format_throughput if throughput else format_mib

    fig, ax = plt.subplots(layout="constrained")
    fig.set_figheight(5)
    fig.set_figwidth(max(6, 1.2 * len(inputs) * len(variants) + 3))

    n_groups, n_bars = len(inputs), len(variants)
    group_width = 0.8
    bar_width = group_width / n_bars
    x = np.arange(n_groups)

    all_tops = []
    for i, (variant, label) in enumerate(zip(variants, variant_labels)):
        ys = np.array([means.get((variant, inp), np.nan) for inp in inputs])
        es = np.array([errs.get((variant, inp), 0.0) for inp in inputs])
        all_tops.extend(v + e for v, e in zip(ys, es) if np.isfinite(v))
        offsets = x - group_width / 2 + bar_width * (i + 0.5)
        bars = ax.bar(
            offsets,
            ys,
            bar_width * 0.9,
            yerr=None if args.no_error_bars else es,
            capsize=4,
            label=label,
        )
        if not args.no_labels:
            ax.bar_label(
                bars,
                labels=[fmt(v) if np.isfinite(v) else "" for v in ys],
                padding=3,
                fontsize=8,
            )

    if throughput and args.log_y:
        ax.set_yscale("log")
    else:
        ax.set_ylim(bottom=0, top=max(all_tops) * 1.12 if all_tops else None)
    ax.yaxis.set_major_formatter(FuncFormatter(fmt))

    if has_inputs:
        ax.set_xticks(x, input_labels)
        ax.set_xlabel("Input")
    else:
        ax.set_xticks([])  # each bar is labeled in the legend

    ax.grid(visible=True, axis="y")
    ax.set_axisbelow(True)
    ax.set_ylabel("Throughput" if throughput else metric_info.label)
    if title:
        ax.set_title(title)
    ax.legend(title="Variant" if has_inputs else "Command")
    return fig


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "files", nargs="+", type=pathlib.Path, help="JSON files with benchmark results"
    )
    parser.add_argument(
        "--size",
        type=int,
        required=True,
        metavar="BYTES",
        help="Size of the benchmarked input file in bytes (used for throughput)",
    )
    parser.add_argument(
        "--metric",
        choices=TIME_METRICS,
        help="Time metric for the throughput chart (default: primary_metric from "
        "the JSON export, or time_wall_clock if unspecified).",
    )
    parser.add_argument(
        "--input-names",
        nargs="+",
        help="Labels for the groups, in order of first appearance",
    )
    parser.add_argument(
        "--variant-names",
        nargs="+",
        help="Labels for the bars, in order of first appearance",
    )
    parser.add_argument(
        "--log-y",
        action="store_true",
        help="Logarithmic y-axis for the throughput chart (default: linear from zero)",
    )
    parser.add_argument(
        "--no-error-bars", action="store_true", help="Don't draw error bars"
    )
    parser.add_argument(
        "--no-labels", action="store_true", help="Don't print the value above each bar"
    )
    parser.add_argument(
        "-o",
        "--output",
        help="Save images instead of showing them: the throughput chart goes to the "
        "given filename and the memory chart to <name>_memory<ext>",
    )

    args = parser.parse_args()
    if args.size <= 0:
        parser.error("--size must be a positive number of bytes")
    size_mb = args.size / 1e6  # decimal MB, matching MB/s

    metric, datasets = load_results(parser, args.files, args.metric)
    for benchmarks in datasets:
        validate_metric(parser, benchmarks, MEMORY_METRIC)

    speed_fig = make_chart(
        parser, args, datasets, metric, size_mb=size_mb, title="Throughput"
    )
    memory_fig = make_chart(
        parser, args, datasets, MEMORY_METRIC, title="Memory Usage"
    )

    if args.output:
        out = pathlib.Path(args.output)
        speed_fig.savefig(out)
        memory_fig.savefig(out.with_name(f"{out.stem}_memory{out.suffix}"))
    else:
        plt.show()


if __name__ == "__main__":
    main()
