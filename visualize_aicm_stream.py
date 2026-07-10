#!/usr/bin/env python3
"""Plot AICM speaker triggers on a streaming audio waveform for one conversation."""

from __future__ import annotations

import argparse
import csv
import wave
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

COLOR_START = "#00A600"  # green
COLOR_END = "#0073E6"    # blue
COLOR_CLASS = "#D90000"  # red

SPEAKER_CODE = {"MAN": "M", "FAN": "F", "CHN": "C"}

INTERACTIONS_SUFFIX = "_AICM_INTERACTIONS.csv"

# =============================================================================
# USER CONFIG - edit these, then run:  python visualize_aicm_stream.py
# =============================================================================
REPO_ROOT = Path(__file__).resolve().parent

# events: CSV of AICM speech segments (output from MATLAB pipeline).
#   File: *_AICM_INTERACTIONS_All_Segments.csv  in  results_YYYYMMDD/<recording_name>/
#   Contains one row per turn (MAN/FAN/CHN) with startSec, endSec, conversationId, etc.
#   It is the table that defines the green (start) and blue (end) lines in the graph.
DEFAULT_EVENTS = REPO_ROOT / "results_20260622/AM28_AM28_010114/AM28_AM28_010114_AICM_INTERACTIONS_All_Segments.csv"
DEFAULT_WAV = REPO_ROOT / "AM28_010114.wav"
DEFAULT_ITS = REPO_ROOT / "AM28_010114.its"
DEFAULT_CONVERSATION_ID = 40
DEFAULT_OUTPUT = REPO_ROOT / "aicm_stream.png"  # None = interactive window instead of saving PNG
# =============================================================================


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plot one AICM conversation on a WAV waveform (time on x-axis).",
        epilog=(
            "With no arguments, uses DEFAULT_* from the USER CONFIG block at the top. "
            "events = *_AICM_INTERACTIONS_All_Segments.csv from the MATLAB pipeline."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "events",
        type=Path,
        nargs="?",
        default=DEFAULT_EVENTS,
        help=f"AICM segments CSV (default: {DEFAULT_EVENTS.name})",
    )
    parser.add_argument(
        "wav",
        type=Path,
        nargs="?",
        default=DEFAULT_WAV,
        help=f"WAV audio file (default: {DEFAULT_WAV.name})",
    )
    parser.add_argument(
        "its",
        type=Path,
        nargs="?",
        default=DEFAULT_ITS,
        help=f"ITS file (default: {DEFAULT_ITS.name})",
    )
    parser.add_argument(
        "conversation_id",
        type=int,
        nargs="?",
        default=DEFAULT_CONVERSATION_ID,
        help=f"AICM conversation block (default: {DEFAULT_CONVERSATION_ID})",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="Save figure to PNG (default: DEFAULT_OUTPUT; set DEFAULT_OUTPUT=None for interactive)",
    )
    return parser.parse_args()


def load_csv_table(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def strip_recording_suffix(stem: str) -> str:
    for suffix in (
        "_AICM_INTERACTIONS_All_Segments",
        "_AICM_EVENTS",
        "_AICM_INTERACTIONS",
    ):
        if stem.endswith(suffix):
            return stem[: -len(suffix)]
    return stem


def sibling_interactions_path(events_path: Path) -> Path:
    base_name = strip_recording_suffix(events_path.stem)
    return events_path.with_name(f"{base_name}{INTERACTIONS_SUFFIX}")


def normalize_interaction_rows(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    normalized: list[dict[str, str]] = []
    for row in rows:
        if row.get("startSec", "").strip():
            normalized.append(row)
            continue
        to_start = row.get("toStartSec", "").strip()
        if not to_start:
            continue
        normalized.append({**row, "startSec": to_start})
    return normalized


def speaker_label(speaker: str, kind: str) -> str:
    code = SPEAKER_CODE.get(speaker.strip().upper(), speaker[:1].upper())
    return f"{kind}_{code}"


def format_sec(t: float) -> str:
    return f"{t:.3f}s"


def format_delta(dt: float) -> str:
    return f"dt={dt:.3f}s"


def read_audio_window(wav_path: Path, t_start: float, t_end: float) -> tuple[np.ndarray, np.ndarray]:
    with wave.open(str(wav_path), "rb") as wf:
        fs = wf.getframerate()
        n_channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        total_frames = wf.getnframes()

        s1 = max(0, int(t_start * fs))
        s2 = min(total_frames, int(t_end * fs))
        if s2 <= s1:
            return np.array([]), np.array([])

        wf.setpos(s1)
        raw = wf.readframes(s2 - s1)

    if sampwidth == 1:
        audio = np.frombuffer(raw, dtype=np.uint8).astype(np.float64)
        audio = (audio - 128.0) / 128.0
    elif sampwidth == 2:
        audio = np.frombuffer(raw, dtype=np.int16).astype(np.float64) / np.iinfo(np.int16).max
    elif sampwidth == 4:
        audio = np.frombuffer(raw, dtype=np.int32).astype(np.float64) / np.iinfo(np.int32).max
    else:
        raise ValueError(f"Unsupported WAV sample width: {sampwidth} bytes")

    if n_channels > 1:
        audio = audio.reshape(-1, n_channels).mean(axis=1)

    segment = audio
    max_points = 250_000
    if len(segment) > max_points:
        step = int(np.ceil(len(segment) / max_points))
        segment = segment[::step]
        t = (s1 + np.arange(0, len(segment) * step, step)) / fs
        t = t[: len(segment)]
    else:
        t = (s1 + np.arange(len(segment))) / fs

    return t, segment


def plot_aicm_stream(
    events_path: Path,
    wav_path: Path,
    its_path: Path,
    conversation_id: int,
    output: Path | None = None,
) -> None:
    for label, path in [("Events", events_path), ("WAV", wav_path), ("ITS", its_path)]:
        if not path.is_file():
            raise FileNotFoundError(f"{label} file not found: {path}")

    base_name = strip_recording_suffix(events_path.stem)

    events = sorted(
        [
            row
            for row in load_csv_table(events_path)
            if int(float(row["conversationId"])) == conversation_id
        ],
        key=lambda row: float(row["startSec"]),
    )
    if not events:
        raise ValueError(f"No AICM events found for conversationId={conversation_id}.")

    interactions_path = sibling_interactions_path(events_path)
    interactions: list[dict[str, str]] = []
    if interactions_path.is_file():
        interactions = [
            row
            for row in normalize_interaction_rows(load_csv_table(interactions_path))
            if int(float(row["conversationId"])) == conversation_id
        ]

    t_starts = [float(row["startSec"]) for row in events]
    t_ends = [float(row["endSec"]) for row in events]
    pad = 2.0
    time_range = (max(0.0, min(t_starts) - pad), max(t_ends) + pad)

    t_audio, y_audio = read_audio_window(wav_path, *time_range)

    fig, ax = plt.subplots(figsize=(14, 6))

    if len(y_audio):
        ax.plot(t_audio, y_audio, color="#404040", linewidth=0.5, label="Waveform")
    else:
        ax.plot(time_range, [0, 0], color="#CCCCCC")
        ax.text(
            sum(time_range) / 2,
            0,
            "No audio in selected window",
            ha="center",
            color="#737373",
        )

    speakers = list(dict.fromkeys(row["speaker"] for row in events))
    row_map = {spk: i + 1 for i, spk in enumerate(speakers)}
    n_rows = max(1, len(speakers))

    ymin, ymax = ax.get_ylim()
    if ymax - ymin < 1e-9:
        ymin, ymax = -1.0, 1.0
    y_span = ymax - ymin
    label_band = 0.08 * y_span
    dur_y = ymin + 0.06 * y_span
    gap_y = ymin + 0.12 * y_span

    for i, row in enumerate(events):
        spk = row["speaker"]
        t_start = float(row["startSec"])
        t_end = float(row["endSec"])
        row_idx = row_map[spk]
        y_text = ymax - label_band * (row_idx - 0.5) / n_rows

        ax.axvline(t_start, color=COLOR_START, linewidth=1.2)
        ax.axvline(t_end, color=COLOR_END, linewidth=1.2)
        ax.text(
            t_start,
            y_text,
            f"{speaker_label(spk, 'S')}\n{format_sec(t_start)}",
            color=COLOR_START,
            fontsize=6,
            fontweight="bold",
            ha="center",
            va="top",
            clip_on=True,
        )
        ax.text(
            t_end,
            y_text,
            f"{speaker_label(spk, 'E')}\n{format_sec(t_end)}",
            color=COLOR_END,
            fontsize=6,
            fontweight="bold",
            ha="center",
            va="top",
            clip_on=True,
        )

        duration = t_end - t_start
        mid_segment = (t_start + t_end) / 2
        ax.annotate(
            "",
            xy=(t_end, dur_y),
            xytext=(t_start, dur_y),
            arrowprops=dict(arrowstyle="<->", color="#595959", lw=0.8),
        )
        ax.text(
            mid_segment,
            dur_y,
            format_delta(duration),
            fontsize=6,
            ha="center",
            va="bottom",
            color="#404040",
            clip_on=True,
        )

        if i > 0:
            prev_end = float(events[i - 1]["endSec"])
            gap = t_start - prev_end
            mid_gap = (prev_end + t_start) / 2
            ax.annotate(
                "",
                xy=(t_start, gap_y),
                xytext=(prev_end, gap_y),
                arrowprops=dict(arrowstyle="<->", color="#8C8C8C", lw=0.8, linestyle="--"),
            )
            ax.text(
                mid_gap,
                gap_y,
                format_delta(gap),
                fontsize=6,
                ha="center",
                va="bottom",
                color="#595959",
                clip_on=True,
            )

    for i, row in enumerate(interactions):
        label = row.get("classLabel", "").strip()
        if not label:
            continue
        t_class = float(row["startSec"])
        ax.axvline(t_class, color=COLOR_CLASS, linewidth=1.4, linestyle="--")
        y_class = ymin + 0.20 * y_span + (i % 3) * 0.04 * y_span
        ax.text(
            t_class,
            y_class,
            label,
            color=COLOR_CLASS,
            fontsize=8,
            fontweight="bold",
            rotation=90,
            ha="left",
            va="bottom",
            clip_on=True,
        )

    ax.set_xlim(time_range)
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Amplitude")
    ax.set_title(
        f"AICM stream - {base_name}  conv {conversation_id}  "
        f"[{time_range[0]:.1f} - {time_range[1]:.1f} s]  ({its_path.name})"
    )
    ax.grid(True, alpha=0.3)

    from matplotlib.lines import Line2D

    legend_items = [
        Line2D([0], [0], color="#404040", linewidth=1, label="Waveform"),
        Line2D([0], [0], color=COLOR_START, linewidth=1.2, label="Start (S_*), green"),
        Line2D([0], [0], color=COLOR_END, linewidth=1.2, label="End (E_*), blue"),
        Line2D([0], [0], color="#595959", linewidth=0.8, label="Segment duration (S to E)"),
        Line2D([0], [0], color="#8C8C8C", linewidth=0.8, linestyle="--", label="Gap (E to next S)"),
        Line2D([0], [0], color=COLOR_CLASS, linewidth=1.4, linestyle="--", label="Class label, red"),
    ]
    ax.legend(handles=legend_items, loc="upper left", bbox_to_anchor=(1.01, 1))

    fig.tight_layout()

    if output:
        output = output.resolve()
        fig.savefig(output, dpi=150, bbox_inches="tight")
        print(f"Saved: {output}")
    else:
        plt.show()


def main() -> None:
    args = parse_args()
    events_path = args.events.resolve()
    wav_path = args.wav.resolve()
    its_path = args.its.resolve()

    print(f"Events:         {events_path}")
    print(f"WAV:            {wav_path}")
    print(f"ITS:            {its_path}")
    print(f"ConversationId: {args.conversation_id}")

    plot_aicm_stream(
        events_path,
        wav_path,
        its_path,
        conversation_id=args.conversation_id,
        output=args.output,
    )


if __name__ == "__main__":
    main()
