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
This script shows `hyperfine` benchmark results as a line plot. Commands must
have the form "<variant> < <input file>". The x-axis has one point per input
file and there is one line per variant (the command minus the input redirect).
"""

import argparse
import json
import pathlib
import re
import sys
from typing import NamedTuple

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.ticker import FuncFormatter, LogLocator, NullLocator



# Inlined from hyperfine's scripts/plot_utils.py so this script is standalone.
class Metric(NamedTuple):
    label: str
    unit: str = ""
    scale: float = 1

    @property
    def axis_label(self):
        return f"{self.label} [{self.unit}]" if self.unit else self.label


METRICS = {
    "time_wall_clock": Metric("Wall-clock time", "s"),
    "time_cpu": Metric("Total CPU time", "s"),
    "time_user": Metric("User CPU time", "s"),
    "time_system": Metric("System CPU time", "s"),
    "memory_peak_resident": Metric("Peak resident memory", "MiB", 1024**2),
    "cpu_cycles": Metric("CPU cycles"),
    "instructions": Metric("Completed CPU instructions"),
    "cache_references": Metric("Cache references"),
    "cache_misses": Metric("Cache misses"),
    "branch_misses": Metric("Mispredicted branches"),
}


def add_metric_argument(parser):
    parser.add_argument(
        "--metric",
        choices=METRICS,
        help="Metric to analyze (default: primary_metric from the JSON export, "
        "or time_wall_clock if unspecified). "
        "Times are in seconds; memory is in MiB; hardware counters are unscaled counts.",
    )


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
        if metric not in METRICS:
            parser.error(f"unknown metric {metric!r}; select one with --metric")

    results = [export["results"] for export in exports]
    for benchmarks in results:
        validate_metric(parser, benchmarks, metric)
    return metric, results


SIZE_UNITS_MB = {"b": 1e-6, "kb": 1e-3, "mb": 1.0, "gb": 1e3, "tb": 1e6}


def parse_size(name):
    """Parse a size like '5mb', '1_gb' or 'data_1.5GB' from a name.

    Returns (size in MB using decimal units, display label like '1.5 GB'),
    or None if the name contains no size.
    """
    m = re.search(r"(\d+(?:\.\d+)?)\s*_?\s*([kmgt]?b)(?![a-z])", name, re.IGNORECASE)
    if not m:
        return None
    number, unit = float(m.group(1)), m.group(2).lower()
    return number * SIZE_UNITS_MB[unit], f"{number:g} {unit.upper()}"


def format_seconds(value, _pos=None):
    """Format a duration in seconds with a readable unit (s, ms, µs, ns)."""
    if value == 0:
        return "0"
    for scale, unit in ((1, "s"), (1e-3, "ms"), (1e-6, "µs"), (1e-9, "ns")):
        if abs(value) >= scale * 0.999999:
            return f"{value / scale:g} {unit}"
    return f"{value / 1e-9:g} ns"


def format_throughput(value, _pos=None):
    """Format a throughput given in MB/s as MB/s or GB/s."""
    if value == 0:
        return "0"
    if abs(value) >= 1000:
        return f"{value / 1000:g} GB/s"
    return f"{value:g} MB/s"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_metric_argument(parser)
    parser.add_argument(
        "files", nargs="+", type=pathlib.Path, help="JSON files with benchmark results"
    )
    parser.add_argument("--title", help="Plot Title")
    parser.add_argument(
        "--input-names",
        nargs="+",
        help="Labels for the x-axis points, in order of first appearance",
    )
    parser.add_argument(
        "--variant-names",
        nargs="+",
        help="Labels for the lines, in order of first appearance",
    )
    parser.add_argument(
        "--log-x",
        action=argparse.BooleanOptionalAction,
        help="Logarithmic x-axis (default: automatic when sizes span 2+ orders of magnitude)",
    )
    parser.add_argument(
        "--throughput",
        action="store_true",
        help="Plot throughput (input size / time, in MB/s or GB/s) instead of time. "
        "Requires a time metric and a size in every input name.",
    )
    parser.add_argument(
        "--log-y",
        action=argparse.BooleanOptionalAction,
        help="Logarithmic y-axis (default: automatic when values span 2+ orders of magnitude)",
    )
    parser.add_argument("-o", "--output", help="Save image to the given filename")

    args = parser.parse_args()
    metric, datasets = load_results(parser, args.files, args.metric)
    metric_info = METRICS[metric]

    # Each command looks like "<variant> < <input file>". Group by input file
    # (x-axis point) and by the rest of the command (one line per variant).
    inputs = []  # input names, in order of first appearance
    variants = []  # variant commands, in order of first appearance
    values = {}  # (variant, input) -> mean

    for results in datasets:
        for b in results:
            command = b.get("name", b["command"])
            match = re.search(r"\s*<\s*(\S+)\s*$", command)
            if match:
                variant = command[: match.start()]
                input_name = pathlib.Path(match.group(1)).stem
            else:
                variant, input_name = command, "(no input)"
            if input_name not in inputs:
                inputs.append(input_name)
            if variant not in variants:
                variants.append(variant)
            values[(variant, input_name)] = b["summary"][metric]["mean"] / metric_info.scale

    input_labels = args.input_names or inputs
    variant_labels = args.variant_names or variants
    if len(input_labels) != len(inputs):
        parser.error(f"--input-names needs {len(inputs)} names, found inputs: {inputs}")
    if len(variant_labels) != len(variants):
        parser.error(
            f"--variant-names needs {len(variants)} names, found variants: {variants}"
        )

    # Place points proportionally to the size in the input name (e.g. "5mb"),
    # falling back to evenly spaced points if any name has no parsable size.
    sizes = [parse_size(name) for name in inputs]
    if all(s is not None for s in sizes):
        x = np.array([s[0] for s in sizes])
        default_labels = [s[1] for s in sizes]
        xlabel = "Input size"
    else:
        print(
            "warning: could not parse a size from every input name "
            f"({inputs}); spacing points evenly",
            file=sys.stderr,
        )
        x = np.arange(len(inputs), dtype=float)
        default_labels = inputs
        xlabel = "Input"
    tick_labels = args.input_names or default_labels
    order = np.argsort(x)

    if args.throughput:
        if metric_info.unit != "s":
            parser.error("--throughput needs a time metric")
        if xlabel != "Input size":
            parser.error(
                f"--throughput needs a size (e.g. 5mb) in every input name: {inputs}"
            )

    fig, ax = plt.subplots(layout="constrained")
    fig.set_figheight(5)
    fig.set_figwidth(10)
    for variant, label in zip(variants, variant_labels):
        ys = np.array([values.get((variant, inp), np.nan) for inp in inputs])
        if args.throughput:
            ys = x / ys  # x is the size in MB, ys the time in seconds
        ax.plot(x[order], ys[order], marker="o", label=label)

    def spans_orders(vals, orders=2):
        vals = np.array([v for v in vals if np.isfinite(v) and v > 0])
        return len(vals) > 1 and vals.max() / vals.min() >= 10**orders

    log_x = args.log_x if args.log_x is not None else spans_orders(x)
    if args.log_y is not None:
        log_y = args.log_y
    elif args.throughput:
        log_y = False
    else:
        log_y = spans_orders(list(values.values()))
    if log_x:
        ax.set_xscale("log")
    if log_y:
        ax.set_yscale("log")
    ax.set_xticks(x[order], [tick_labels[i] for i in order])
    ax.minorticks_off()

    # Time metrics: label ticks with readable units (ms, s, ...) and, on a log
    # axis, add ticks at 1, 2 and 5 of each decade for finer granularity.
    is_time = metric_info.unit == "s"
    if args.throughput:
        if log_y:
            ax.yaxis.set_major_locator(LogLocator(base=10, subs=(1.0, 2.0, 5.0)))
            ax.yaxis.set_minor_locator(NullLocator())
        ax.yaxis.set_major_formatter(FuncFormatter(format_throughput))
        ax.set_ylim(bottom=None if log_y else 0)
    elif is_time:
        if log_y:
            ax.yaxis.set_major_locator(LogLocator(base=10, subs=(1.0, 2.0, 5.0)))
            ax.yaxis.set_minor_locator(NullLocator())
        ax.yaxis.set_major_formatter(FuncFormatter(format_seconds))
    ax.grid(visible=True, axis="y")

    if args.title:
        plt.title(args.title)
    plt.xlabel(xlabel)
    if args.throughput:
        plt.ylabel("Throughput")
    else:
        plt.ylabel(metric_info.label if is_time else metric_info.axis_label)
    plt.legend(title="Variant")

    if args.output:
        plt.savefig(args.output)
    else:
        plt.show()


if __name__ == "__main__":
    main()
