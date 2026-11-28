#!/usr/bin/env python3
"""
Deterministic, 100% open-source audio-to-MIDI + harmonic chord & beat analyzer
for Piano Studio (Chord AI + Melody Scanner style, zero paid APIs, CPU-only).

Usage:
    transcribe_audio.py <output_dir> <input_audio_path>

Outputs inside <output_dir>:
    - transcribed.mid            Polyphonic piano MIDI (via Spotify basic-pitch ONNX)
    - transcribed.analysis.json  Beat-tracked BPM, Krumhansl key, and measure chords
"""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Tuple

import librosa
import numpy as np
import pretty_midi

NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# Krumhansl-Schmuckler tonal key profiles for deterministic key detection.
MAJOR_PROFILE = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MINOR_PROFILE = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])

# Chord quality pitch-class templates (Chord-AI style vocabulary).
CHORD_QUALITIES: List[Tuple[str, List[int], float]] = [
    ("",     [0, 4, 7],     1.04),
    ("m",    [0, 3, 7],     1.03),
    ("7",    [0, 4, 7, 10], 0.99),
    ("maj7", [0, 4, 7, 11], 0.98),
    ("m7",   [0, 3, 7, 10], 0.99),
    ("dim",  [0, 3, 6],     0.94),
    ("aug",  [0, 4, 8],     0.92),
    ("sus4", [0, 5, 7],     0.96),
]

MAX_AUDIO_SECONDS = 360  # Cap at 6 minutes to bound CPU/RAM on very long streams


def normalize_to_wav(input_path: Path, wav_path: Path) -> None:
    """Decode any audio/video container (WebM/Opus/M4A/MP3/WAV/OGG) to 22050Hz mono WAV."""
    cmd = [
        "ffmpeg",
        "-y",
        "-v", "error",
        "-i", str(input_path),
        "-t", str(MAX_AUDIO_SECONDS),
        "-ac", "1",
        "-ar", "22050",
        "-f", "wav",
        str(wav_path),
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0 or not wav_path.exists():
        raise RuntimeError(f"ffmpeg failed to decode audio: {res.stderr.strip()}")


def build_chord_templates() -> Tuple[List[str], np.ndarray, List[set]]:
    """Precompute L2-normalized 12-bin chroma templates for all 12 roots x chord qualities."""
    labels: List[str] = []
    vectors: List[np.ndarray] = []
    pc_sets: List[set] = []

    for root in range(12):
        for suffix, intervals, prior in CHORD_QUALITIES:
            vec = np.zeros(12, dtype=np.float64)
            for idx, iv in enumerate(intervals):
                weight = 1.25 if idx == 0 else (1.05 if idx == 1 else 0.95)
                vec[(root + iv) % 12] = weight
            norm = np.linalg.norm(vec)
            if norm > 0:
                vec = (vec / norm) * prior
            labels.append(f"{NOTE_NAMES[root]}{suffix}")
            vectors.append(vec)
            pc_sets.append({(root + iv) % 12 for iv in intervals})

    return labels, np.vstack(vectors), pc_sets


def detect_key(mean_chroma: np.ndarray) -> Tuple[str, set]:
    """Detect musical key (major or minor) via Krumhansl-Schmuckler correlation."""
    if float(np.sum(mean_chroma)) <= 1e-8:
        return "C", {0, 2, 4, 5, 7, 9, 11}

    best_score = -1e9
    best_key = "C"
    best_scale = {0, 2, 4, 5, 7, 9, 11}

    maj_intervals = [0, 2, 4, 5, 7, 9, 11]
    min_intervals = [0, 2, 3, 5, 7, 8, 10]

    for root in range(12):
        maj_prof = np.roll(MAJOR_PROFILE, root)
        min_prof = np.roll(MINOR_PROFILE, root)

        maj_corr = float(np.corrcoef(mean_chroma, maj_prof)[0, 1])
        if maj_corr > best_score:
            best_score = maj_corr
            best_key = NOTE_NAMES[root]
            best_scale = {(root + iv) % 12 for iv in maj_intervals}

        min_corr = float(np.corrcoef(mean_chroma, min_prof)[0, 1])
        if min_corr > best_score:
            best_score = min_corr
            best_key = f"{NOTE_NAMES[root]}m"
            best_scale = {(root + iv) % 12 for iv in min_intervals}

    return best_key, best_scale


def analyze_harmony_and_tempo(wav_path: Path) -> Dict[str, object]:
    """Extract tempo, downbeat offset, key, and measure-aligned chord sequence."""
    # 11025 Hz covers up to 5.5 kHz (well above piano fundamental/chord harmonics) and runs ~4x faster.
    y, sr = librosa.load(str(wav_path), sr=11025, mono=True)
    duration = float(len(y)) / sr
    if duration < 0.25 or float(np.max(np.abs(y))) < 1e-5:
        raise RuntimeError("Áudio silencioso ou muito curto para transcrição.")

    # Separate harmonic signal from percussive transients for much cleaner chord recognition.
    y_harm = librosa.effects.harmonic(y)

    tempo_est, beat_frames = librosa.beat.beat_track(y=y, sr=sr)
    bpm_raw = float(np.asarray(tempo_est).reshape(-1)[0]) if np.asarray(tempo_est).size > 0 else 100.0
    if not math.isfinite(bpm_raw) or bpm_raw <= 0:
        bpm_raw = 100.0

    # Fold extreme double-time / half-time estimates into a comfortable piano range (60..165 BPM).
    while bpm_raw < 60.0:
        bpm_raw *= 2.0
    while bpm_raw > 165.0:
        bpm_raw /= 2.0
    bpm = int(round(max(40.0, min(200.0, bpm_raw))))

    beat_times = librosa.frames_to_time(beat_frames, sr=sr) if len(beat_frames) > 0 else np.array([0.0])
    start_offset = float(beat_times[0]) if len(beat_times) > 0 and beat_times[0] < 2.5 else 0.0

    hop_length = 256
    chroma = librosa.feature.chroma_cqt(y=y_harm, sr=sr, hop_length=hop_length)
    frame_times = librosa.frames_to_time(np.arange(chroma.shape[1]), sr=sr, hop_length=hop_length)

    mean_chroma = np.mean(chroma, axis=1)
    key_name, key_scale = detect_key(mean_chroma)

    sec_per_measure = (60.0 / bpm) * 4.0
    effective_dur = max(duration - start_offset, sec_per_measure)
    num_measures = max(1, int(math.ceil(effective_dur / sec_per_measure)))

    labels, templates, pc_sets = build_chord_templates()
    diatonic_bonus = np.array(
        [0.08 if pcs.issubset(key_scale) else 0.0 for pcs in pc_sets],
        dtype=np.float64,
    )

    # Compute raw measure-by-measure chord similarity scores.
    scores = np.zeros((num_measures, len(labels)), dtype=np.float64)
    for m_idx in range(num_measures):
        t0 = start_offset + m_idx * sec_per_measure
        t1 = t0 + sec_per_measure
        mask = (frame_times >= t0) & (frame_times < t1)
        if np.any(mask):
            vec = np.mean(chroma[:, mask], axis=1)
        else:
            vec = mean_chroma
        norm = float(np.linalg.norm(vec))
        if norm > 1e-8:
            vec = vec / norm
        scores[m_idx] = templates @ vec + diatonic_bonus

    # Viterbi temporal smoothing to prevent noisy 1-measure chord flicker.
    stay_bonus = 0.05
    dp = np.zeros_like(scores)
    back = np.zeros(scores.shape, dtype=np.int32)
    dp[0] = scores[0]
    for m_idx in range(1, num_measures):
        prev_best_idx = int(np.argmax(dp[m_idx - 1]))
        prev_best_val = dp[m_idx - 1, prev_best_idx]
        for c_idx in range(len(labels)):
            stay_val = dp[m_idx - 1, c_idx] + stay_bonus
            if stay_val >= prev_best_val:
                dp[m_idx, c_idx] = stay_val + scores[m_idx, c_idx]
                back[m_idx, c_idx] = c_idx
            else:
                dp[m_idx, c_idx] = prev_best_val + scores[m_idx, c_idx]
                back[m_idx, c_idx] = prev_best_idx

    chosen = [0] * num_measures
    chosen[-1] = int(np.argmax(dp[-1]))
    for m_idx in range(num_measures - 2, -1, -1):
        chosen[m_idx] = int(back[m_idx + 1, chosen[m_idx + 1]])

    chords = [labels[idx] for idx in chosen]

    return {
        "bpm": bpm,
        "key": key_name,
        "timeSignature": "4/4",
        "startOffset": round(start_offset, 4),
        "duration": round(duration, 3),
        "chords": chords,
    }


def resolve_onnx_model_path() -> str:
    """Locate Spotify basic-pitch's bundled ONNX model so CPU inference needs no TensorFlow."""
    import basic_pitch

    pkg_dir = Path(basic_pitch.__file__).resolve().parent
    onnx_candidates = list(pkg_dir.rglob("*.onnx"))
    if onnx_candidates:
        return str(onnx_candidates[0])
    return str(basic_pitch.ICASSP_2022_MODEL_PATH)


def transcribe_notes_with_basic_pitch(
    wav_path: Path, bpm: int, start_offset: float
) -> List[Tuple[int, float, float, int]]:
    """Run basic-pitch polyphonic note transcription and return cleaned (pitch, start, end, vel)."""
    from basic_pitch.inference import predict

    model_path = resolve_onnx_model_path()
    _model_output, _midi_data, note_events = predict(
        str(wav_path),
        model_or_model_path=model_path,
        onset_threshold=0.52,
        frame_threshold=0.34,
        minimum_note_length=65.0,
        minimum_frequency=55.0,
        maximum_frequency=2093.0,
    )

    cleaned: List[Tuple[int, float, float, int]] = []
    for ev in note_events:
        # note_events items are (start_s, end_s, pitch_midi, amplitude, pitch_bends)
        st = float(ev[0]) - start_offset
        en = float(ev[1]) - start_offset
        pitch = int(round(float(ev[2])))
        amp = float(ev[3])

        if en <= 0.0:
            continue
        st = max(0.0, st)
        dur = en - st
        if dur < 0.06 or amp < 0.12:
            continue
        if pitch < 33 or pitch > 96:
            continue

        vel = int(round(max(40, min(115, amp * 120))))
        cleaned.append((pitch, st, max(st + 0.08, en), vel))

    # Deduplicate simultaneous harmonic overtone clutter per 16th-note quantization bin.
    sec_per_16th = (60.0 / bpm) / 4.0
    by_bin: Dict[int, List[Tuple[int, float, float, int]]] = {}
    for item in cleaned:
        q_bin = int(round(item[1] / sec_per_16th))
        by_bin.setdefault(q_bin, []).append(item)

    filtered: List[Tuple[int, float, float, int]] = []
    for q_bin in sorted(by_bin.keys()):
        group = by_bin[q_bin]
        # Keep highest-amplitude entry per pitch within the same 16th-note slice.
        best_by_pitch: Dict[int, Tuple[int, float, float, int]] = {}
        for item in group:
            p = item[0]
            if p not in best_by_pitch or item[3] > best_by_pitch[p][3]:
                best_by_pitch[p] = item

        # Cap simultaneous notes per slice (max 2 bass + max 4 treble) to keep piano score clean.
        bass = sorted([n for n in best_by_pitch.values() if n[0] < 60], key=lambda x: (-x[3], x[0]))[:2]
        treble = sorted([n for n in best_by_pitch.values() if n[0] >= 60], key=lambda x: (-x[3], -x[0]))[:4]
        filtered.extend(bass + treble)

    return filtered


def synthesize_fallback_notes_from_chords(chords: List[str], bpm: int) -> List[Tuple[int, float, float, int]]:
    """Fallback when basic-pitch detects no clear pitched notes (e.g. very noisy mic clip)."""
    sec_per_measure = (60.0 / bpm) * 4.0
    notes: List[Tuple[int, float, float, int]] = []
    for idx, chord in enumerate(chords):
        root_str = chord[:2] if len(chord) > 1 and chord[1] == "#" else chord[:1]
        root_pc = NOTE_NAMES.index(root_str) if root_str in NOTE_NAMES else 0
        quality = chord[len(root_str):]
        intervals = [0, 3, 7] if quality.startswith("m") and not quality.startswith("maj") else [0, 4, 7]

        t0 = idx * sec_per_measure
        t1 = t0 + sec_per_measure * 0.92
        notes.append((36 + root_pc, t0, t1, 80))
        for iv in intervals:
            notes.append((60 + ((root_pc + iv) % 12), t0, t1, 78))
    return notes


def write_midi(notes: List[Tuple[int, float, float, int]], bpm: int, midi_path: Path) -> None:
    """Serialize tempo-aligned polyphonic notes into Standard MIDI file."""
    pm = pretty_midi.PrettyMIDI(initial_tempo=float(bpm))
    piano = pretty_midi.Instrument(program=0, name="Acoustic Grand Piano")
    for pitch, st, en, vel in notes:
        piano.notes.append(pretty_midi.Note(velocity=vel, pitch=pitch, start=st, end=en))
    pm.instruments.append(piano)
    pm.write(str(midi_path))


def main() -> int:
    if len(sys.argv) < 3:
        print("Usage: transcribe_audio.py <output_dir> <audio_path>", file=sys.stderr)
        return 2

    out_dir = Path(sys.argv[1]).resolve()
    input_path = Path(sys.argv[2]).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    if not input_path.exists():
        print(f"Input audio not found: {input_path}", file=sys.stderr)
        return 1

    wav_path = out_dir / "normalized_22k.wav"
    midi_path = out_dir / "transcribed.mid"
    analysis_path = out_dir / "transcribed.analysis.json"

    try:
        normalize_to_wav(input_path, wav_path)
        analysis = analyze_harmony_and_tempo(wav_path)
        bpm = int(analysis["bpm"])
        start_offset = float(analysis["startOffset"])

        notes = transcribe_notes_with_basic_pitch(wav_path, bpm=bpm, start_offset=start_offset)
        if not notes:
            notes = synthesize_fallback_notes_from_chords(analysis["chords"], bpm=bpm)

        write_midi(notes, bpm=bpm, midi_path=midi_path)
        analysis_path.write_text(json.dumps(analysis, ensure_ascii=False, indent=2), encoding="utf-8")
        return 0
    except Exception as exc:
        print(f"Audio transcription error: {exc}", file=sys.stderr)
        return 1
    finally:
        if wav_path.exists():
            try:
                wav_path.unlink()
            except OSError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
