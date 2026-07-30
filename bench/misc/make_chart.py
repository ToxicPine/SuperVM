#!/usr/bin/env python3
"""Plot cumulative or marginal SuperVM benchmark memory measurements."""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.ticker import MultipleLocator


VM_LABELS = ("SuperVM", "LameVM")
Y_POSITIONS = (1, 0)
COLORS = ("#4c78a8", "#dbe5ef", "#c56f32", "#f1d6c2", "#72a57a")
EDGE_COLORS = ("#355878", "#5d7f9f", "#82451f", "#a56335", "#47704e")
HATCHES = (None, "////", "\\\\\\\\", "....", "xxxx")


def non_negative_number(value: str) -> float:
    """Return a finite, non-negative command-line number."""
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise argparse.ArgumentTypeError("must be a finite, non-negative number")
    return number


def positive_integer(value: str) -> int:
    """Return a positive VM count."""
    try:
        number = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive integer") from error
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Plot SuperVM and LameVM cumulative deployment memory, or derive "
            "marginal memory per added VM from the same measurements."
        )
    )
    parser.add_argument(
        "--mode",
        choices=("cumulative", "marginal"),
        default="marginal",
        help="plot cumulative totals or marginal memory per added VM",
    )
    parser.add_argument(
        "--vm-counts",
        type=positive_integer,
        nargs="+",
        required=True,
        metavar="COUNT",
        help="strictly increasing VM counts, in result order",
    )
    parser.add_argument(
        "--supervm",
        type=non_negative_number,
        nargs="+",
        required=True,
        metavar="MIB",
        help="cumulative SuperVM deployment MiB matching --vm-counts",
    )
    parser.add_argument(
        "--lamevm",
        type=non_negative_number,
        nargs="+",
        required=True,
        metavar="MIB",
        help="cumulative LameVM deployment MiB matching --vm-counts",
    )
    parser.add_argument(
        "--title",
        help="override the mode-specific chart title",
    )
    parser.add_argument(
        "--note",
        default="* lower is better",
        help="small italic note below the chart",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="output PNG path; defaults to a mode-specific file beside the script",
    )
    return parser.parse_args()


def validate_inputs(args: argparse.Namespace) -> None:
    result_count = len(args.vm_counts)
    if any(
        current <= previous
        for previous, current in zip(args.vm_counts, args.vm_counts[1:])
    ):
        raise SystemExit("--vm-counts must be strictly increasing")
    if len(args.supervm) != result_count or len(args.lamevm) != result_count:
        raise SystemExit(
            "--vm-counts, --supervm, and --lamevm must contain the same "
            "number of values"
        )


def marginal_values(
    vm_counts: list[int], cumulative_values: list[float]
) -> list[float]:
    """Calculate the memory slope for each consecutive VM-count interval."""
    values = []
    previous_count = 0
    previous_memory = 0.0
    for count, memory in zip(vm_counts, cumulative_values, strict=True):
        values.append((memory - previous_memory) / (count - previous_count))
        previous_count = count
        previous_memory = memory
    return values


def tick_spacing(extent: float) -> float:
    """Choose readable major ticks for the observed range."""
    rough_spacing = extent / 6
    magnitude = 10 ** math.floor(math.log10(rough_spacing))
    normalized = rough_spacing / magnitude
    multiplier = next(
        candidate for candidate in (1, 2, 2.5, 5, 10) if normalized <= candidate
    )
    return multiplier * magnitude


def mode_settings(args: argparse.Namespace) -> tuple[str, str, Path]:
    if args.mode == "cumulative":
        title = "Total Cumulative Memory Consumption"
        x_label = "Cumulative Memory (MiB)"
    else:
        title = "Marginal Memory Consumption per VM"
        x_label = "Marginal Memory per VM (MiB)"

    output = args.output or Path(__file__).with_name(f"supervm-memory-{args.mode}.png")
    return args.title or title, x_label, output


def main() -> None:
    args = parse_args()
    validate_inputs(args)
    title, x_label, output = mode_settings(args)

    if args.mode == "marginal":
        supervm_values = marginal_values(args.vm_counts, args.supervm)
        lamevm_values = marginal_values(args.vm_counts, args.lamevm)
    else:
        supervm_values = args.supervm
        lamevm_values = args.lamevm

    all_values = (*supervm_values, *lamevm_values)
    extent = max(abs(value) for value in all_values)
    if extent == 0:
        raise SystemExit("at least one plotted measurement must be non-zero")

    spacing = tick_spacing(extent)
    minimum = min(all_values)
    maximum = max(all_values)
    x_min = min(0, math.floor((minimum * 1.15) / spacing) * spacing)
    x_max = max(spacing, math.ceil((maximum * 1.22) / spacing) * spacing)

    plt.rcParams.update(
        {
            "font.family": "serif",
            "font.serif": ("STIXGeneral", "DejaVu Serif"),
            "font.size": 14,
            "axes.titlesize": 20,
            "axes.titleweight": "normal",
            "axes.labelsize": 14,
            "axes.edgecolor": "#333333",
            "axes.linewidth": 0.8,
            "xtick.color": "#333333",
            "ytick.color": "#222222",
            "xtick.labelsize": 12,
            "ytick.labelsize": 13,
            "hatch.linewidth": 0.8,
            "figure.facecolor": "white",
            "axes.facecolor": "white",
            "savefig.facecolor": "white",
        }
    )

    figure, axis = plt.subplots(figsize=(8, 4.5), dpi=150)
    figure.subplots_adjust(left=0.18, right=0.78, top=0.82, bottom=0.20)

    result_count = len(args.vm_counts)
    bar_height = min(0.30, 0.72 / result_count)
    bar_groups = []
    for index, vm_count in enumerate(args.vm_counts):
        offset = ((result_count - 1) / 2 - index) * bar_height
        values = (supervm_values[index], lamevm_values[index])
        bars = axis.barh(
            [position + offset for position in Y_POSITIONS],
            values,
            height=bar_height,
            label=f"{vm_count} {'VM' if vm_count == 1 else 'VMs'}",
            color=COLORS[index % len(COLORS)],
            edgecolor=EDGE_COLORS[index % len(EDGE_COLORS)],
            linewidth=0.7,
            hatch=HATCHES[index % len(HATCHES)],
            zorder=3,
        )
        bar_groups.append((bars, values))

    figure.suptitle(
        title,
        x=0.50,
        y=0.93,
        fontsize=20,
        fontweight="normal",
    )
    figure.text(
        0.02,
        0.025,
        args.note,
        color="#555555",
        fontsize=10,
        fontstyle="italic",
        ha="left",
        va="bottom",
    )

    axis.set_yticks(Y_POSITIONS, VM_LABELS)
    axis.set_xlim(x_min, x_max)
    axis.xaxis.set_major_locator(MultipleLocator(spacing))
    axis.set_xlabel(x_label, labelpad=9)
    axis.grid(
        axis="x",
        color="#cccccc",
        linewidth=0.65,
        linestyle=(0, (2, 2)),
        zorder=0,
    )
    axis.legend(
        loc="center left",
        bbox_to_anchor=(1.01, 0.5),
        ncol=1,
        frameon=False,
        fontsize=12,
    )

    axis.spines["top"].set_visible(False)
    axis.spines["right"].set_visible(False)
    axis.tick_params(axis="y", length=0, pad=10)
    axis.tick_params(axis="x", direction="out", length=3, width=0.7, pad=5)

    for bars, values in bar_groups:
        for bar, value in zip(bars, values, strict=True):
            offset = 7 if value >= 0 else -7
            axis.annotate(
                f"{value:.1f} MiB",
                xy=(value, bar.get_y() + bar.get_height() / 2),
                xytext=(offset, 0),
                textcoords="offset points",
                va="center",
                ha="left" if value >= 0 else "right",
                fontsize=11,
                fontweight="normal",
                color="#222222",
                clip_on=False,
            )

    description = "; ".join(
        (
            f"{count} {'VM' if count == 1 else 'VMs'}: "
            f"SuperVM {supervm:.1f} MiB, LameVM {lamevm:.1f} MiB"
        )
        for count, supervm, lamevm in zip(
            args.vm_counts, supervm_values, lamevm_values, strict=True
        )
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(
        output,
        dpi=150,
        metadata={
            "Title": title,
            "Description": f"{args.mode.title()} memory. {description}.",
        },
    )
    plt.close(figure)


if __name__ == "__main__":
    main()
