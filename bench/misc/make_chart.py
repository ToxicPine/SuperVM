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
BAR_HUE = 245.0
BAR_COLOR_START_OKLCH = (0.78, 0.08, BAR_HUE)
BAR_COLOR_END_OKLCH = (0.50, 0.12, BAR_HUE)
BAR_EDGE_LIGHTNESS_OFFSET = 0.12
BAR_EDGE_CHROMA_SCALE = 0.75


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
        "--results",
        type=Path,
        nargs="+",
        metavar="DIR",
        help=(
            "benchmark output directories; totals are read from each "
            "directory's summary.tsv instead of being typed by hand"
        ),
    )
    parser.add_argument(
        "--vm-counts",
        type=positive_integer,
        nargs="+",
        metavar="COUNT",
        help="strictly increasing VM counts, in result order",
    )
    parser.add_argument(
        "--supervm",
        type=non_negative_number,
        nargs="+",
        metavar="MIB",
        help="cumulative SuperVM deployment MiB matching --vm-counts",
    )
    parser.add_argument(
        "--lamevm",
        type=non_negative_number,
        nargs="+",
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


FAMILY_COLUMNS = ("family", "arm")
COUNT_COLUMNS = ("instance_count", "instances")


def read_summary(path: Path, totals: dict[str, dict[int, float]]) -> None:
    """Accumulate one summary.tsv's per-family cumulative totals, in MiB."""
    lines = path.read_text().splitlines()
    if not lines:
        raise SystemExit(f"{path}: empty summary")
    header = lines[0].split("\t")
    try:
        family_field = next(i for i, n in enumerate(header) if n in FAMILY_COLUMNS)
        count_field = next(i for i, n in enumerate(header) if n in COUNT_COLUMNS)
        total_field = header.index("total_bytes")
    except (StopIteration, ValueError):
        raise SystemExit(f"{path}: unrecognized summary header: {lines[0]}") from None
    for line in lines[1:]:
        row = line.split("\t")
        family = row[family_field]
        if family not in totals:
            raise SystemExit(f"{path}: unknown family {family!r}")
        count = int(row[count_field])
        total_mib = float(row[total_field]) / (1024 * 1024)
        recorded = totals[family].setdefault(count, total_mib)
        if recorded != total_mib:
            raise SystemExit(
                f"{path}: conflicting totals for {family} at {count} VMs: "
                f"{recorded:.1f} vs {total_mib:.1f} MiB"
            )


def load_results(args: argparse.Namespace) -> None:
    """Fill the measurement arguments from summary.tsv files."""
    totals: dict[str, dict[int, float]] = {"supervm": {}, "lamevm": {}}
    for directory in args.results:
        summary = directory / "summary.tsv"
        if not summary.is_file():
            raise SystemExit(f"{directory}: no summary.tsv")
        read_summary(summary, totals)
    counts = sorted(set(totals["supervm"]) & set(totals["lamevm"]))
    if not counts:
        raise SystemExit(
            "the summaries hold no VM count measured for both families"
        )
    unpaired = sorted(set(totals["supervm"]) ^ set(totals["lamevm"]))
    if unpaired:
        print(
            "note: ignoring counts measured for only one family: "
            + ", ".join(str(count) for count in unpaired)
        )
    args.vm_counts = counts
    args.supervm = [totals["supervm"][count] for count in counts]
    args.lamevm = [totals["lamevm"][count] for count in counts]


def validate_inputs(args: argparse.Namespace) -> None:
    if args.results is not None:
        if args.vm_counts or args.supervm or args.lamevm:
            raise SystemExit(
                "--results replaces --vm-counts, --supervm, and --lamevm"
            )
        load_results(args)
    elif not (args.vm_counts and args.supervm and args.lamevm):
        raise SystemExit(
            "provide --results, or all of --vm-counts, --supervm, and --lamevm"
        )
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


def normalize_oklch(
    color: tuple[float, float, float],
) -> tuple[float, float, float]:
    """Validate OKLCH components and normalize hue to [0, 360)."""
    lightness, chroma, hue = color
    if not all(math.isfinite(component) for component in color):
        raise ValueError("OKLCH components must be finite")
    if not 0 <= lightness <= 1:
        raise ValueError("OKLCH lightness must be between 0 and 1")
    if chroma < 0:
        raise ValueError("OKLCH chroma must be non-negative")
    return lightness, chroma, hue % 360


def interpolate_oklch(
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    position: float,
) -> tuple[float, float, float]:
    """Interpolate OKLCH components using the shorter hue arc."""
    start_lightness, start_chroma, start_hue = normalize_oklch(start)
    end_lightness, end_chroma, end_hue = normalize_oklch(end)
    hue_delta = (end_hue - start_hue + 180) % 360 - 180
    return normalize_oklch(
        (
            start_lightness + (end_lightness - start_lightness) * position,
            start_chroma + (end_chroma - start_chroma) * position,
            start_hue + hue_delta * position,
        )
    )


def oklch_to_srgb(color: tuple[float, float, float]) -> tuple[float, float, float]:
    """Convert OKLCH to sRGB using the Oklab reference matrices."""
    lightness, chroma, hue = normalize_oklch(color)
    hue_radians = math.radians(hue)
    lab_a = chroma * math.cos(hue_radians)
    lab_b = chroma * math.sin(hue_radians)

    light = lightness + 0.3963377774 * lab_a + 0.2158037573 * lab_b
    medium = lightness - 0.1055613458 * lab_a - 0.0638541728 * lab_b
    short = lightness - 0.0894841775 * lab_a - 1.2914855480 * lab_b

    light = light**3
    medium = medium**3
    short = short**3
    linear_rgb = (
        4.0767416621 * light - 3.3077115913 * medium + 0.2309699292 * short,
        -1.2684380046 * light + 2.6097574011 * medium - 0.3413193965 * short,
        -0.0041960863 * light - 0.7034186147 * medium + 1.7076147010 * short,
    )
    if not all(0 <= channel <= 1 for channel in linear_rgb):
        raise ValueError(f"OKLCH color {color!r} is outside the sRGB gamut")

    def encode(channel: float) -> float:
        magnitude = abs(channel)
        encoded = (
            12.92 * channel
            if magnitude <= 0.0031308
            else math.copysign(
                1.055 * magnitude ** (1 / 2.4) - 0.055,
                channel,
            )
        )
        return encoded

    return tuple(encode(channel) for channel in linear_rgb)


def series_colors(
    series_count: int,
) -> list[
    tuple[
        tuple[float, float, float],
        tuple[float, float, float],
    ]
]:
    """Return coordinated fill and edge colors for each VM-count series."""
    if series_count == 1:
        positions = (0.5,)
    else:
        positions = tuple(index / (series_count - 1) for index in range(series_count))

    palette = []
    for position in positions:
        fill = interpolate_oklch(
            BAR_COLOR_START_OKLCH,
            BAR_COLOR_END_OKLCH,
            position,
        )
        lightness, chroma, hue = fill
        edge = (
            lightness - BAR_EDGE_LIGHTNESS_OFFSET,
            chroma * BAR_EDGE_CHROMA_SCALE,
            hue,
        )
        palette.append((oklch_to_srgb(fill), oklch_to_srgb(edge)))
    return palette


def mode_settings(args: argparse.Namespace) -> tuple[str, str, Path]:
    if args.mode == "cumulative":
        title = "Aggregate Memory Usage by VM Count"
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
    group_span = 0.72
    bar_gap = min(0.035, group_span / (result_count * 5))
    bar_height = min(
        0.30,
        (group_span - bar_gap * (result_count - 1)) / result_count,
    )
    bar_step = bar_height + bar_gap
    palette = series_colors(result_count)
    bar_groups = []
    for index, vm_count in enumerate(args.vm_counts):
        offset = ((result_count - 1) / 2 - index) * bar_step
        values = (supervm_values[index], lamevm_values[index])
        fill_color, edge_color = palette[index]
        bars = axis.barh(
            [position + offset for position in Y_POSITIONS],
            values,
            height=bar_height,
            label=f"{vm_count} {'VM' if vm_count == 1 else 'VMs'}",
            color=fill_color,
            edgecolor=edge_color,
            linewidth=0.4,
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
