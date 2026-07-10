# README — acoust_detail_funcs_newhelpers_MH.m

## Overview

MATLAB pipeline for acoustic analysis of paired `.WAV` + `.ITS` files from LENA recordings. The script extracts F0 and related features by talker category (CHN, FAN, MAN) and classifies directional AICM conversational interactions (ADS / CDS).

**Latest update (June 2026):** The v3 interaction classifier from `aicm_interaction_classifier_v3.m` is now integrated as the **default** classifier. Legacy classifiers are retained for comparison.

---

## Pipeline Summary

1. Select base directory containing ITS files
2. Find all `.its` files recursively
3. Parse AICM conversation blocks
4. Extract speaker intervals (CHN, FAN, MAN, CHN2FAN, CHN2MAN)
5. **v3:** Extract enriched event table per conversation block
6. **v3:** Classify directed turn-pair interactions
7. Compute acoustic features (F0, dBFS, syllables) via `shrp.m`
8. Save `.mat` and `.csv` outputs

---

## What Changed in v3 Integration

### Problems addressed (vs. legacy classifiers)

| Issue | Legacy behavior | v3 behavior |
|-------|-----------------|-------------|
| Cross-conversation linking | Events from different AICM blocks merged globally | Classification runs **inside each conversation** |
| Multi-label inflation | One segment could receive 2+ labels | Turn-pair rows + optional **one primary label per segment** |
| LENA metadata ignored | Only speaker + timing used | Parses `conversationInfo` turn codes (TIMI, TIMR, TIFI, TIFR, …) |
| Weak neighbor search | Only immediate table neighbor (i−1 / i+1) | **Nearest prior event** within gap window |
| Cry / non-speech | All segments included | Filters segments with no speech evidence |
| Fixed adjacency window | Single `adjacencyWindowSec` | Single `adjacencyWindowSec` (default 5.0 s) |

### Main loop change

```matlab
interactionParams = default_interaction_params_v3();
[eventTable, interactionResults, turnPairs] = run_interaction_pipeline_v3(matByLine, interactionParams);
```

Legacy alternatives remain available (comment/uncomment):

```matlab
% eventTable = extract_aicm_event_table(matByLine);
% interactionResults = classify_aicm_interactions_rules(eventTable, adjacencyWindowSec);
% turnPairs = table();
```

---

## Classifier Versions

| Version | Function | Status |
|---------|----------|--------|
| **v3 turn-pair** | `run_interaction_pipeline_v3` | **Default (recommended)** |
| Rules (legacy) | `classify_aicm_interactions_rules` | Kept for comparison |
| Simple (legacy) | `classify_aicm_interactions` | Kept for comparison |

### How to switch classifiers

In the main loop, comment the v3 call and uncomment the legacy block shown above.

---

## v3 Parameters (`default_interaction_params_v3`)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `adjacencyWindowSec` | 5.0 s | Max gap between end of A and start of B |
| `minDurationSec` | 0.10 s | Minimum segment duration |
| `requireSpeechEvidence` | `true` | Require word/utterance counts > 0 |
| `preferLENATurnCodes` | `true` | Use LENA turn codes as primary evidence |
| `useAdjacencyFallback` | `true` | Fill gaps where LENA has no code |
| `applyNoChnBetweenRule` | `true` | Block ADS if CHN sits between two adults |
| `segmentPrimaryLabelOnly` | `true` | One label per segment in `interactionResults` |

---

## Output Tables

### 1. `eventTable` (enriched)

One row per speech segment inside each AICM block.

| Column | Description |
|--------|-------------|
| `speaker` | CHN, FAN, or MAN |
| `startSec`, `endSec`, `durationSec` | Segment timing (seconds) |
| `conversationId` | AICM block number from ITS `num="..."` |
| `eventIndex` | Index within conversation (resets per block) |
| `segmentRole` | BC (beginning), RC (related), EC (end) |
| `turnCode` | LENA turn code: TIMI, TIMR, TIFI, TIFR, TIFE, NT, … |
| `endCode` | FI, FH, etc. |
| `childUttCnt` | Child utterance count (CHN lines) |
| `adultWordCnt` | Adult word count (FAN/MAN lines) |
| `isValidSpeech` | `true` if segment passes duration + speech filters |
| `sourceLineIndex` | ITS file line index |

### 2. `turnPairs` (recommended for statistics)

One row per **directed interaction pair** (A → B).

| Column | Description |
|--------|-------------|
| `conversationId` | AICM block ID |
| `fromSpeaker`, `toSpeaker` | Directed pair |
| `classLabel` | e.g. MANtoCHN, FANtoMAN |
| `gapSec` | Time between end of A and start of B |
| `labelSource` | `LENA_target`, `LENA_source`, or `adjacency` |
| `fromStartSec`, `fromEndSec`, `toStartSec`, `toEndSec` | Timing |
| `fromEventIndex`, `toEventIndex` | Event indices within conversation |
| `fromTurnCode`, `toTurnCode` | LENA codes on each side |
| `speechType` | ADS or CDS |

### 3. `interactionResults` (segment-level, backward compatible)

One row per **target (responder) segment**, with optional primary label only. Compatible with `add_acoustics_to_interaction_table`.

| Column | Description |
|--------|-------------|
| `speaker`, `startSec`, `endSec`, `durationSec` | Responder segment |
| `classLabel` | Directional label |
| `gapSec`, `labelSource` | v3 metadata |
| `conversationId`, `eventIndex` | Per-conversation indexing |
| `speechType` | ADS or CDS |
| `f0mean`, `f0std`, `f0min`, `f0max`, `f0range` | Added by acoustic step |
| `dBFS`, `pctUttVx` | Intensity / voicing |
| `syllableCount`, `syllablesPerSec` | Syllable estimation |

---

## Supported Interaction Labels

- **ADS:** MANtoMAN, MANtoFAN, FANtoMAN, FANtoFAN
- **CDS:** MANtoCHN, CHNtoMAN, FANtoCHN, CHNtoFAN

---

## Output Files (per recording)

### Original (unchanged)

- `*_CHN.mat`, `*_CHN2FAN.mat`, `*_CHN2MAN.mat`, `*_FAN.mat`, `*_MAN.mat`

### Interaction / v3 (new or updated)

| File | Contents |
|------|----------|
| `*_AICM_INTERACTIONS.mat` | `interactionResults`, `eventTable`, `turnPairs` |
| `*_AICM_EVENTS.csv` | Enriched event table |
| `*_AICM_TURN_PAIRS.csv` | Turn-pair table (v3) |
| `*_AICM_INTERACTIONS_All_Segments.csv` | All speaker segments with optional `classLabel` and acoustics |
| `*_AICM_INTERACTIONS.csv` | Classified segments only (`classLabel` subset of All_Segments) |
| `*_AICM_INTERACTIONS_Events.csv` | Unified raw events + classified interactions |
| `*_speechType_label_summary.csv` | ADS/CDS and label counts with percentages |
| `*_classifier_compare.csv` | v3 vs legacy label counts |
| `*_counts.png`, `*_ads_cds.png`, `*_f0mean.png`, `*_dbfs.png` | Evaluation plots |
| `*_classifier_compare.png` | Classifier comparison bar chart |

---

## v3 Classification Algorithm

Per AICM conversation block:

1. Filter to `isValidSpeech == true`
2. For each event B (j = 2…n):
   - Find nearest prior event A within `adjacencyWindowSec`
   - Assign label (priority: LENA code on B → LENA code on A → adjacency)
   - Apply no-CHN-between rule for ADS labels
3. Deduplicate pairs; keep smallest `gapSec` when tied
4. Convert to segment table (primary label per segment if enabled)

### LENA turn code mapping

| Code | Meaning | Typical label |
|------|---------|---------------|
| TIMI | Male turn initiation | MAN → * |
| TIMR | Male turn response (child) | MANtoCHN |
| TIFI / TIFE | Female turn initiation / engagement | FAN → * |
| TIFR | Female turn response (child) | FANtoCHN |
| NT | No turn | Falls back to adjacency |

---

## New v3 Functions

| Function | Purpose |
|----------|---------|
| `run_interaction_pipeline_v3` | Main v3 orchestrator |
| `default_interaction_params_v3` | Parameter struct |
| `extract_aicm_event_table_v3` | Per-conversation event extraction |
| `parse_speaker_segment_line_v3` | Parse segment + LENA metadata |
| `is_valid_speech_segment_v3` | Speech validity filter |
| `classify_aicm_turn_pairs_v3` | Turn-pair classifier |
| `find_turn_pairs_in_block_v3` | Pair generation within one block |
| `find_nearest_prior_event_v3` | Backward nearest-neighbor search |
| `assign_pair_label_v3` | Label assignment with LENA priority |
| `map_turn_code_to_label_v3` | LENA code → directional label |
| `turn_pairs_to_segment_table_v3` | Segment-level backward-compatible table |
| `compare_classifiers_light` | v3 vs legacy comparison |

### Legacy functions (preserved)

- `extract_aicm_event_table`
- `classify_aicm_interactions`
- `classify_aicm_interactions_rules`
- `build_conversation_block`, `parse_speaker_segments_from_line`
- `build_directional_label`, `is_supported_direction`

---

## Acoustic Analysis

### Interval analysis (dual version)

- `analyze_interval_original_1based` — corrected MATLAB indexing (**default** in pipeline)
- `analyze_interval_original` — legacy 0-based indexing (VanDam 2013)

Switch inside `analyze_category_original` and `add_acoustics_to_interaction_table`.

### F0 trimming

```matlab
trimEdgeFrames = 2;
```

Removes edge voiced F0 frames before computing statistics (reduces onset/offset pitch errors).

### F0 search ranges (`choose_f0_range`)

| Speaker | Range (Hz) |
|---------|------------|
| CHN | 100–600 |
| FAN | 100–600 |
| MAN | 50–300 |

### Syllable estimation

`estimate_syllables` — bandpass (300–4000 Hz) + Hilbert envelope + peak detection (De Jong & Wempe style).

---

## Design Philosophy

- Preserve original F0 pipeline and `.mat` outputs
- Add v3 interaction analysis as a modular branch
- Keep legacy classifiers for validation and comparison
- Default to v3 for improved accuracy and LENA metadata use

---

## Quick Start

```matlab
% 1. Set data folder
baseDir = 'D:\path\to\rawData';

% 2. Run script (processes ITS files in loop)
% Default: v3 classifier via run_interaction_pipeline_v3

% 3. Inspect outputs in results_YYYYMMDD/
%    - *_AICM_TURN_PAIRS.csv  → primary interaction statistics
%    - *_AICM_EVENTS.csv       → raw enriched events
%    - *_classifier_compare.csv → v3 vs legacy counts
```

### Tune v3 parameters

```matlab
interactionParams = default_interaction_params_v3();
interactionParams.adjacencyWindowSec = 6.0;
[eventTable, interactionResults, turnPairs] = run_interaction_pipeline_v3(matByLine, interactionParams);
```

---

## Migration Notes

- **Standalone file:** `aicm_interaction_classifier_v3.m` remains available for isolated testing; its logic is now embedded in `acoust_detail_funcs_newhelpers_MH.m`.
- **Column rename:** v3 event table uses `sourceLineIndex` (legacy used `sourceIndex`). `create_unified_detail_table` handles both.
- **Comparison:** `compare_both_classifiers_light` was replaced by `compare_classifiers_light` (adds v3 turn-pair counts).

---

## Summary

| Aspect | Before v3 | After v3 |
|--------|-----------|----------|
| Default classifier | `classify_aicm_interactions_rules` | `run_interaction_pipeline_v3` |
| Conversation boundaries | Global event table | Per-block `conversationId` |
| LENA turn codes | Ignored | Primary classification evidence |
| Multi-label segments | Common | One primary label (configurable) |
| Neighbor search | i−1 / i+1 only | Nearest prior within window |
| New output | — | `turnPairs`, `*_AICM_TURN_PAIRS.csv` |
| Pair metadata | None | `gapSec`, `labelSource` |
