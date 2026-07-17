# begin: 2026-05-25
# author: wrqt
# type: py
# effect: 读取H100 60525_16 benchmark日志和TSV并绘制总览图

import csv
import os
import re
import shutil
import sys
import tempfile
import textwrap
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from statistics import mean

os.environ.setdefault(
    "MPLCONFIGDIR",
    str(Path(tempfile.gettempdir()) / "ectrans-matplotlib-cache"),
)
os.environ.setdefault(
    "XDG_CACHE_HOME",
    str(Path(tempfile.gettempdir()) / "ectrans-xdg-cache"),
)

import matplotlib

matplotlib.use("Agg")
from matplotlib import font_manager

for font_path in [
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
    "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
]:
    if Path(font_path).exists():
        try:
            font_manager.fontManager.addfont(font_path)
        except RuntimeError:
            pass

CJK_REGULAR_FONT = next(
    (Path(path) for path in [
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
        "/System/Library/Fonts/PingFang.ttc",
    ] if Path(path).exists()),
    None,
)
CJK_BOLD_FONT = next(
    (Path(path) for path in [
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
        "/System/Library/Fonts/PingFang.ttc",
    ] if Path(path).exists()),
    CJK_REGULAR_FONT,
)


def plot_font(size: float, bold: bool = False) -> font_manager.FontProperties:
    font_path = CJK_BOLD_FONT if bold else CJK_REGULAR_FONT
    if font_path is not None:
        return font_manager.FontProperties(fname=str(font_path), size=size)
    return font_manager.FontProperties(family=["sans-serif"], size=size, weight="bold" if bold else "normal")


matplotlib.rcParams["font.family"] = ["sans-serif"]
matplotlib.rcParams["font.sans-serif"] = [
    "Noto Sans CJK SC",
    "Noto Sans CJK JP",
    "Noto Sans CJK TC",
    "Noto Sans CJK HK",
    "Noto Sans CJK KR",
    "Droid Sans Fallback",
    "PingFang SC",
    "Heiti SC",
    "STHeiti",
    "Arial Unicode MS",
    "DejaVu Sans",
]
matplotlib.rcParams["axes.unicode_minus"] = False

import matplotlib.pyplot as plt

FIGURE_FACE = "#f6f1ea"
PANEL_FACE = "#fbfaf8"
GRID_COLOR = "#c7c2bb"
TEXT_COLOR = "#2b2b2b"
COLOR_DURATION = "#4f7dd1"
COLOR_SUBMIT = "#b46a38"
COLOR_WALL = "#d95f5f"
COLOR_AVG = "#2c7a57"
COLOR_LEGENDRE = "#5b8c5a"
COLOR_FOURIER = "#d8a24a"
COLOR_TRANSPOSE = "#7b6fd0"
COLOR_INV = "#4f7dd1"
COLOR_DIR = "#d95f5f"
INFO_FONT_SIZE = 9.4
INFO_LINE_START = 0.73
INFO_LINE_STEP = 0.085


@dataclass
class RunRecord:
    label: str
    base_label: str
    run_index: str
    start_timestamp: str
    end_timestamp: str
    submit_start_timestamp: str
    submit_end_timestamp: str
    cmd_args: str
    device: str
    target: str
    profile: str
    precision: str
    partition: str
    nodes: int
    mpi_ranks: int
    cpu_threads: int
    cpu_threads_total: int
    gpus_requested: int
    niter_warmup: int
    niter: int
    callmode: str
    grid: str
    truncation: str
    nfld: str
    nlev: str
    nproma: str
    npromatr: str
    nprtrw: str
    nprtrv: str
    compute_node: str
    cuda_visible_devices: str
    exit_code: int
    duration_ms: float
    submit_duration_ms: float | None
    wallclock_s: float
    cpu_time_s: float
    vector_time_s: float
    setup_ms: float
    time_step_ms: float
    inv_ms: float
    dir_ms: float
    ltinv_ms: float
    ltdir_ms: float
    ftinv_ms: float
    ftdir_ms: float
    mtol_ms: float
    ltom_ms: float
    ltog_ms: float
    gtol_ms: float
    first_step_s: float | None


RE_WALL = re.compile(
    r"^TOTAL WALLCLOCK TIME\s+([0-9.]+)\s+CPU TIME\s+([0-9.]+)\s+VECTOR TIME\s+([0-9.]+)",
    re.MULTILINE,
)
RE_STAT = re.compile(
    r"^\s*(\d+)\s+([A-Z0-9_]+)?\s*-?\s*([A-Za-z0-9. ()]+)?\s+(\d+)\s+([0-9.]+)\s+([0-9.]+)",
    re.MULTILINE,
)
RE_TIMESTEP = re.compile(r"^Time step\s+(\d+)\s+took\s+([0-9.]+)", re.MULTILINE)


def parse_run_name() -> str:
    if len(sys.argv) < 2:
        raise SystemExit("用法: python3 docs/scripts/plot_runtask_60525_16.py task001-h100x2-o1279-cm1")
    return sys.argv[1].lstrip("-")


def format_local_timestamp() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S.%f %z")


def header_values(text: str, name: str) -> list[str]:
    return re.findall(rf"^# {re.escape(name)}: (.+)$", text, re.MULTILINE)


def header_value(text: str, name: str, default: str = "", last: bool = False) -> str:
    values = header_values(text, name)
    if not values:
        return default
    return values[-1] if last else values[0]


def grep_value(text: str, pattern: str, default: str = "") -> str:
    match = re.search(pattern, text, re.MULTILINE)
    return match.group(1).strip() if match else default


def to_int(value: str, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def to_float(value: str, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def strip_run_suffix(label: str) -> str:
    return re.sub(r"run\d+$", "", label)


def row_value(row: dict[str, str] | None, name: str, default: str = "") -> str:
    if row is None:
        return default
    value = row.get(name, "")
    return value if value != "" else default


def localize_log_path(repo_root: Path, logfile: str) -> Path:
    path = Path(logfile)
    if path.exists():
        return path
    marker = "/runs/logs/"
    if marker in logfile:
        rel = logfile.split(marker, 1)[1]
        return repo_root / "runs" / "logs" / rel
    return path


def read_index_rows(repo_root: Path) -> dict[str, dict[str, str]]:
    rows: dict[str, dict[str, str]] = {}
    for index_path in sorted((repo_root / "runs" / "rundata").glob("task_index_*.tsv")):
        with index_path.open(encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle, delimiter="\t")
            for row in reader:
                logfile = row.get("日志路径", "")
                if not logfile:
                    continue
                local_path = localize_log_path(repo_root, logfile)
                rows[local_path.name] = row
    return rows


def discover_log_paths(repo_root: Path, run_name: str, index_rows: dict[str, dict[str, str]]) -> list[Path]:
    indexed_paths: list[Path] = []
    for row in index_rows.values():
        if row.get("标签") != run_name:
            continue
        indexed_paths.append(localize_log_path(repo_root, row.get("日志路径", "")))
    indexed_paths = sorted(path for path in indexed_paths if path.exists())
    if indexed_paths:
        return indexed_paths

    log_root = repo_root / "runs" / "logs"
    paths = sorted(log_root.glob(f"*/{run_name}run*.log"))
    if paths:
        return paths
    return sorted(log_root.glob(f"{run_name}run*.log"))


def pick_stat_ms(text: str, stat_id: int, stat_name: str) -> float:
    pattern = rf"^\s*{stat_id}\s+{re.escape(stat_name)}\s+-.*?\s+\d+\s+([0-9.]+)\s+([0-9.]+)"
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        return 0.0
    return float(match.group(1))


def pick_runtime_param(text: str, name: str, default: str = "") -> str:
    return grep_value(text, rf"^{re.escape(name)}\s+(.+)$", default)


def parse_cmd_flag(cmd: str, flag: str, default: str = "") -> str:
    match = re.search(rf"(?:^|\s){re.escape(flag)}\s+(\S+)", cmd)
    return match.group(1) if match else default


def parse_cmd_long_flag(cmd: str, flag: str, default: str = "") -> str:
    match = re.search(rf"(?:^|\s){re.escape(flag)}(?:=|\s+)(\S+)", cmd)
    return match.group(1) if match else default


def parse_cmd_args(cmd: str) -> str:
    marker = "ectrans-benchmark-"
    pos = cmd.rfind(marker)
    if pos < 0:
        return cmd
    suffix = cmd[pos:]
    fields = suffix.split()
    return " ".join(fields[1:]) if len(fields) > 1 else ""


def parse_log(path: Path, row: dict[str, str] | None) -> RunRecord:
    text = path.read_text(encoding="utf-8", errors="replace")
    cmd = header_value(text, "cmd")
    label = header_value(text, "label", path.stem)
    base_label = row_value(row, "标签", strip_run_suffix(label))
    wall_match = RE_WALL.search(text)
    if wall_match is None:
        raise ValueError(f"缺少TOTAL WALLCLOCK TIME: {path}")

    timestep_values = [(int(idx), float(value)) for idx, value in RE_TIMESTEP.findall(text)]
    first_step_s = timestep_values[0][1] if timestep_values else None

    mpi_from_cmd = parse_cmd_flag(cmd, "-np", "")
    mpi_from_mpl = grep_value(text, r"MPL_NUMPROC=(\d+)", "")
    partition = row_value(row, "分区", parse_cmd_flag(cmd, "-p", ""))
    target = row_value(row, "目标", header_value(text, "target"))
    precision = row_value(row, "精度", target.rsplit("-", 1)[-1] if "-" in target else "")

    return RunRecord(
        label=label,
        base_label=base_label,
        run_index=row_value(row, "运行ID", header_value(text, "run_index")),
        start_timestamp=header_value(text, "start_timestamp", last=True),
        end_timestamp=header_value(text, "end_timestamp", last=True),
        submit_start_timestamp=header_value(text, "submit_start_timestamp", header_value(text, "start_timestamp")),
        submit_end_timestamp=header_value(text, "submit_end_timestamp", ""),
        cmd_args=row_value(row, "参数", parse_cmd_args(cmd)),
        device=row_value(row, "设备", header_value(text, "device")),
        target=target,
        profile=row_value(row, "构建类型", header_value(text, "profile")),
        precision=precision,
        partition=partition,
        nodes=to_int(row_value(row, "节点数", parse_cmd_flag(cmd, "-N", "0"))),
        mpi_ranks=to_int(row_value(row, "MPI进程数", mpi_from_cmd or mpi_from_mpl)),
        cpu_threads=to_int(row_value(row, "CPU线程数", header_value(text, "cpu_threads", "0"))),
        cpu_threads_total=to_int(row_value(row, "CPU总线程数", header_value(text, "cpu_threads_total", parse_cmd_flag(cmd, "-c", "0")))),
        gpus_requested=to_int(row_value(row, "GPU申请数", header_value(text, "gpus_requested", parse_cmd_flag(cmd, "-G", "0")))),
        niter_warmup=to_int(row_value(row, "预热次数", header_value(text, "niter_warmup", parse_cmd_long_flag(cmd, "--niter-warmup", "0")))),
        niter=to_int(row_value(row, "迭代次数", header_value(text, "niter", parse_cmd_flag(cmd, "-n", "0")))),
        callmode=row_value(row, "callmode", parse_cmd_long_flag(cmd, "--callmode", "")),
        grid=row_value(row, "grid", pick_runtime_param(text, "grid", parse_cmd_flag(cmd, "-g", ""))),
        truncation=row_value(row, "truncation", pick_runtime_param(text, "nsmax", parse_cmd_flag(cmd, "-t", ""))),
        nfld=row_value(row, "nfld", pick_runtime_param(text, "nfld", parse_cmd_flag(cmd, "-f", ""))),
        nlev=row_value(row, "nlev", pick_runtime_param(text, "nlev", parse_cmd_flag(cmd, "-l", ""))),
        nproma=row_value(row, "nproma", pick_runtime_param(text, "nproma")),
        npromatr=row_value(row, "npromatr", pick_runtime_param(text, "npromatr")),
        nprtrw=row_value(row, "nprtrw", pick_runtime_param(text, "nprtrw")),
        nprtrv=row_value(row, "nprtrv", pick_runtime_param(text, "nprtrv")),
        compute_node=grep_value(text, r"^compute_node=(.+)$", ""),
        cuda_visible_devices=grep_value(text, r"^CUDA_VISIBLE_DEVICES=(.*)$", ""),
        exit_code=to_int(row_value(row, "退出码", header_value(text, "exit_code", "1", last=True)), 1),
        duration_ms=to_float(row_value(row, "耗时毫秒", header_value(text, "duration_ms", "0", last=True))),
        submit_duration_ms=(
            to_float(row_value(row, "提交耗时毫秒", header_value(text, "submit_duration_ms", "", last=True)))
            if row_value(row, "提交耗时毫秒", header_value(text, "submit_duration_ms", "", last=True)) != ""
            else None
        ),
        wallclock_s=float(wall_match.group(1)),
        cpu_time_s=float(wall_match.group(2)),
        vector_time_s=float(wall_match.group(3)),
        setup_ms=pick_stat_ms(text, 2, "SETUP_TRANS"),
        time_step_ms=pick_stat_ms(text, 3, "TIME STEP"),
        inv_ms=pick_stat_ms(text, 4, "INV_TRANS"),
        dir_ms=pick_stat_ms(text, 5, "DIR_TRANS"),
        ltinv_ms=pick_stat_ms(text, 102, "LTINV_CTL"),
        ltdir_ms=pick_stat_ms(text, 103, "LTDIR_CTL"),
        ftdir_ms=pick_stat_ms(text, 106, "FTDIR_CTL"),
        ftinv_ms=pick_stat_ms(text, 107, "FTINV_CTL"),
        mtol_ms=pick_stat_ms(text, 152, "LTINV_CTL"),
        ltom_ms=pick_stat_ms(text, 153, "LTDIR_CTL"),
        ltog_ms=pick_stat_ms(text, 157, "FTINV_CTL"),
        gtol_ms=pick_stat_ms(text, 158, "FTDIR_CTL"),
        first_step_s=first_step_s,
    )


def is_complete_record(record: RunRecord) -> bool:
    return record.exit_code == 0 and record.wallclock_s > 0.0 and record.duration_ms > 0.0


def format_run_labels(records: list[RunRecord]) -> list[str]:
    return [f"R{idx + 1:02d}" for idx in range(len(records))]


def style_axis(ax, title: str, ylabel: str) -> None:
    ax.set_title(title, fontproperties=plot_font(14, bold=True), color=TEXT_COLOR, pad=10)
    ax.set_facecolor(PANEL_FACE)
    ax.set_ylabel(ylabel, fontproperties=plot_font(11), color=TEXT_COLOR)
    ax.tick_params(colors=TEXT_COLOR)
    ax.grid(axis="y", alpha=0.28, color=GRID_COLOR)
    ax.set_axisbelow(True)
    for spine in ax.spines.values():
        spine.set_color("#d7d0c7")
        spine.set_linewidth(1.1)


def plot_total_time(ax, records: list[RunRecord]) -> None:
    labels = format_run_labels(records)
    duration_s = [item.duration_ms / 1000.0 for item in records]
    wallclock_s = [item.wallclock_s for item in records]
    submit_s = [
        item.submit_duration_ms / 1000.0 if item.submit_duration_ms is not None else item.duration_ms / 1000.0
        for item in records
    ]
    avg_duration_s = mean(duration_s)
    x = list(range(len(records)))

    bars = ax.bar(x, duration_s, color=COLOR_DURATION, width=0.62, label="benchmark duration")
    ax.plot(x, wallclock_s, color=COLOR_WALL, marker="o", linewidth=2.0, label="TOTAL WALLCLOCK")
    ax.plot(x, submit_s, color=COLOR_SUBMIT, marker="s", linewidth=1.8, linestyle="--", label="submit duration")
    ax.axhline(avg_duration_s, color=COLOR_AVG, linewidth=1.8, linestyle=":", label="平均benchmark")

    for idx, bar in enumerate(bars):
        ax.text(
            bar.get_x() + bar.get_width() / 2.0,
            bar.get_height() + max(duration_s) * 0.015,
            f"{duration_s[idx]:.2f}",
            ha="center",
            va="bottom",
            fontproperties=plot_font(9.5),
            color=TEXT_COLOR,
        )

    style_axis(ax, "总时长", "秒")
    ax.set_xticks(x, labels)
    ax.set_xlabel("运行编号", fontproperties=plot_font(11), color=TEXT_COLOR)
    ax.legend(frameon=False, prop=plot_font(9.5), loc="upper left")


def plot_average_share(ax, records: list[RunRecord]) -> None:
    avg_total = mean(item.time_step_ms for item in records)
    avg_values = [
        ("INV_TRANS", mean(item.inv_ms for item in records), COLOR_INV),
        ("DIR_TRANS", mean(item.dir_ms for item in records), COLOR_DIR),
        ("Legendre", mean(item.ltinv_ms + item.ltdir_ms for item in records), COLOR_LEGENDRE),
        ("Fourier", mean(item.ftinv_ms + item.ftdir_ms for item in records), COLOR_FOURIER),
        (
            "Transpose",
            mean(item.mtol_ms + item.ltom_ms + item.ltog_ms + item.gtol_ms for item in records),
            COLOR_TRANSPOSE,
        ),
    ]

    names = [name for name, _, _ in avg_values]
    values = [value for _, value, _ in avg_values]
    pcts = [value / avg_total * 100.0 if avg_total else 0.0 for _, value, _ in avg_values]
    colors = [color for _, _, color in avg_values]

    bars = ax.barh(range(len(names)), values, color=colors)
    for idx, bar in enumerate(bars):
        ax.text(
            bar.get_width() + max(values) * 0.02,
            bar.get_y() + bar.get_height() / 2.0,
            f"{values[idx]:.3f} ms / {pcts[idx]:.1f}%",
            va="center",
            fontproperties=plot_font(9.5),
            color=TEXT_COLOR,
        )

    ax.set_yticks(range(len(names)), names)
    ax.invert_yaxis()
    style_axis(ax, "平均Time step构成", "毫秒")
    ax.grid(axis="x", alpha=0.28, color=GRID_COLOR)


def plot_half_breakdown(ax, records: list[RunRecord], half: str) -> None:
    labels = format_run_labels(records)
    x = list(range(len(records)))

    if half == "inv":
        legendre = [item.ltinv_ms for item in records]
        fourier = [item.ftinv_ms for item in records]
        transpose = [item.mtol_ms + item.ltog_ms for item in records]
        total = [item.inv_ms for item in records]
        title = "INV_TRANS分解"
    else:
        legendre = [item.ltdir_ms for item in records]
        fourier = [item.ftdir_ms for item in records]
        transpose = [item.ltom_ms + item.gtol_ms for item in records]
        total = [item.dir_ms for item in records]
        title = "DIR_TRANS分解"

    ax.bar(x, legendre, color=COLOR_LEGENDRE, label="Legendre")
    ax.bar(x, fourier, bottom=legendre, color=COLOR_FOURIER, label="Fourier")
    ax.bar(
        x,
        transpose,
        bottom=[a + b for a, b in zip(legendre, fourier)],
        color=COLOR_TRANSPOSE,
        label="Transpose",
    )
    ax.plot(x, total, color=TEXT_COLOR, marker="o", linewidth=1.6, label="GSTATS total")

    style_axis(ax, title, "毫秒")
    ax.set_xticks(x, labels)
    ax.set_xlabel("运行编号", fontproperties=plot_font(11), color=TEXT_COLOR)
    ax.legend(frameon=False, prop=plot_font(9.0), loc="upper left")


def format_metadata(records: list[RunRecord]) -> str:
    item = records[0]
    nodes = ",".join(sorted({record.compute_node for record in records if record.compute_node}))
    return (
        f"device={item.device}, target={item.target}, profile={item.profile}, precision={item.precision}, "
        f"partition={item.partition}, nodes={item.nodes}, MPI={item.mpi_ranks}, "
        f"CPU={item.cpu_threads}/rank total={item.cpu_threads_total}, GPU={item.gpus_requested}, "
        f"compute={nodes or '-'}"
    )


def format_benchmark_metadata(records: list[RunRecord]) -> str:
    item = records[0]
    return (
        f"warmup={item.niter_warmup}, niter={item.niter}, callmode={item.callmode}, "
        f"grid={item.grid}, truncation={item.truncation}, nfld={item.nfld}, nlev={item.nlev}, "
        f"nproma={item.nproma}, npromatr={item.npromatr}, nprtrw={item.nprtrw}, nprtrv={item.nprtrv}; "
        f"{short_cmd_args(item.cmd_args)}"
    )


def short_cmd_args(cmd_args: str) -> str:
    fields = cmd_args.split()
    if fields and ("ectrans-benchmark" in fields[0] or fields[0].startswith("/")):
        fields = fields[1:]
    return " ".join(fields)


def save_dashboard(records: list[RunRecord], output_path: Path, run_name: str) -> None:
    time_window = f"{records[0].start_timestamp} -> {records[-1].end_timestamp}"
    generated_at = format_local_timestamp()
    avg_duration_s = mean(item.duration_ms for item in records) / 1000.0
    avg_wall_s = mean(item.wallclock_s for item in records)
    avg_timestep_ms = mean(item.time_step_ms for item in records)
    avg_setup_ms = mean(item.setup_ms for item in records)
    avg_cpu_s = mean(item.cpu_time_s for item in records)
    avg_vector_s = mean(item.vector_time_s for item in records)
    first_step_text = " / ".join(
        f"R{idx + 1:02d}:{item.first_step_s:.2f}s" for idx, item in enumerate(records) if item.first_step_s is not None
    )
    run_text = format_metadata(records)
    benchmark_text = format_benchmark_metadata(records)
    device_badge = records[0].device.upper() if records[0].device else "UNKNOWN"
    badge_color = "#2f6fc7" if device_badge == "GPU" else "#c94747"

    fig = plt.figure(figsize=(19.2, 13.4), dpi=180, layout="constrained")
    fig.patch.set_facecolor(FIGURE_FACE)
    gs = fig.add_gridspec(3, 2, height_ratios=[0.62, 1.0, 1.0], hspace=0.08, wspace=0.08)

    ax_info = fig.add_subplot(gs[0, :])
    ax_total = fig.add_subplot(gs[1, 0])
    ax_share = fig.add_subplot(gs[1, 1])
    ax_inv = fig.add_subplot(gs[2, 0])
    ax_dir = fig.add_subplot(gs[2, 1])

    ax_info.set_facecolor(PANEL_FACE)
    ax_info.set_xticks([])
    ax_info.set_yticks([])
    for spine in ax_info.spines.values():
        spine.set_color("#d7d0c7")
        spine.set_linewidth(1.1)

    plot_total_time(ax_total, records)
    plot_average_share(ax_share, records)
    plot_half_breakdown(ax_inv, records, "inv")
    plot_half_breakdown(ax_dir, records, "dir")

    ax_info.text(
        0.02,
        0.90,
        f"{run_name} H100时间分析总览",
        ha="left",
        va="top",
        fontproperties=plot_font(21, bold=True),
        color=TEXT_COLOR,
    )
    ax_info.text(
        0.975,
        0.90,
        device_badge,
        ha="right",
        va="top",
        fontproperties=plot_font(21, bold=True),
        color="#ffffff",
        bbox={"boxstyle": "round,pad=0.28,rounding_size=0.04", "facecolor": badge_color, "edgecolor": badge_color},
    )
    info_lines = [
        f"总览生成时间: {generated_at}",
        f"日志时间范围: {time_window}",
        f"平均benchmark: {avg_duration_s:.3f}s, 平均wallclock: {avg_wall_s:.3f}s, 平均TIME STEP: {avg_timestep_ms:.3f}ms",
        f"其他平均值: SETUP_TRANS={avg_setup_ms:.3f}ms, CPU TIME={avg_cpu_s:.3f}s, VECTOR TIME={avg_vector_s:.3f}s",
        f"本轮运行参数: {run_text}",
        f"基准测试参数: {benchmark_text}",
        f"首步耗时: {first_step_text}",
    ]
    for idx, line in enumerate(info_lines):
        ax_info.text(
            0.02,
            INFO_LINE_START - idx * INFO_LINE_STEP,
            line,
            ha="left",
            va="top",
            fontproperties=plot_font(INFO_FONT_SIZE),
            color=TEXT_COLOR,
        )

    fig.savefig(output_path, bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close(fig)


def main() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    run_name = parse_run_name()

    index_rows = read_index_rows(repo_root)
    candidate_paths = discover_log_paths(repo_root, run_name, index_rows)
    if not candidate_paths:
        raise SystemExit(f"未找到日志: {run_name}")

    records: list[RunRecord] = []
    errors: list[str] = []
    for path in candidate_paths:
        try:
            record = parse_log(path, index_rows.get(path.name))
        except Exception as exc:
            errors.append(f"{path}: {exc}")
            continue
        if is_complete_record(record):
            records.append(record)

    if not records:
        detail = "\n".join(errors) if errors else "\n".join(str(path) for path in candidate_paths)
        raise SystemExit(f"找到日志但都不完整或解析失败:\n{detail}")

    device_dir = records[0].device if records[0].device in {"cpu", "gpu"} else "unknown"
    output_dir = repo_root / "runs" / "plot" / device_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"{run_name}_dashboard.png"
    legacy_output_path = repo_root / "runs" / "plot" / f"{run_name}_dashboard.png"

    save_dashboard(records, output_path, run_name)
    shutil.copy2(output_path, legacy_output_path)
    print(f"已写入: {output_path}")
    print(f"已同步: {legacy_output_path}")
    print(f"有效run数: {len(records)}")


if __name__ == "__main__":
    main()
