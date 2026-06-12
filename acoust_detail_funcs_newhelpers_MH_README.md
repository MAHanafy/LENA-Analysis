# README — Updates Added to acoust_detail_funcs_newhelpers_MH.m


## Overview
This file documents the updates added to the MATLAB script:
**acoust_detail_funcs_newhelpers_MH.m**

The original analysis pipeline is preserved, and new functionality has been added in a modular way without modifying the core structure.


---

## The original pipeline (Unchanged):

The script still performs the original steps:

1. Select / define the base directory
2. Find `.ITS` files recursively
3. Read each ITS file
4. Parse the original interval categories
   - CHN (child)
   - CHN2FAN (child near female adult)
   - CHN2MAN (child near male adult)
   - FAN (female adult near)
   - MAN (male adult near)
5. Run F0 extraction using `shrp.m`
6. Save outputs into `.mat` files

---

## What Was Kept Unchanged
The following parts of the original script were preserved:
- Main script structure
- Main `for` loop over ITS files
- Original functions:
  - `read_its_file_original`
  - `parse_intervals_original`
  - `initialize_outputs_original`
  - `analyze_category_original`
  - `analyze_interval_original`
  - `save_outputs_original`
- Original F0 extraction using `shrp.m`
- Original `.mat` output files:
  - CHN
  - CHN2FAN
  - CHN2MAN
  - FAN
  - MAN

This means the updated script still runs the original analysis exactly as before, while also producing the new interaction outputs.

---

## New Functionality Added

A new interaction-based analysis branch was added to the main loop:

- Extract AICM interaction-based speaker events 
- Directional conversational labels
- Compute acoustic features for interaction segments
- Save results as `.mat` and `.csv`

---

## Dual-Version Design (Important)

To keep the code simple and comparable, **two versions are kept** for key functions.

### 1) Interval Analysis
- `analyze_interval_original` → original indexing (0-based style) 
- `analyze_interval_original_1based` → corrected MATLAB indexing (recommended)

### 2) Interaction Classification
- `classify_aicm_interactions` → simple adjacency-based classifier
- `classify_aicm_interactions_rules` → updated classifier  (New rules)
  * preserves directionality
  * applies “no preceding CHN / no following CHN” logic

### How to switch versions
Manually comment/uncomment in the code:

#### Interaction classifier:

```matlab
% interactionResults = classify_aicm_interactions(eventTable, adjacencyWindowSec);
interactionResults = classify_aicm_interactions_rules(eventTable, adjacencyWindowSec);
```

and:

#### Interval analysis:

```matlab
row = analyze_interval_original(...);
% row = analyze_interval_original_1based(...);
```

---

### New outputs added
For each ITS/WAV pair, the updated code now also:
- extracts AICM conversational events into a table
- classifies directional interaction labels
- computes acoustic features for those interaction rows
- saves interaction results in `.mat` and `.csv` format
- saves the raw AICM event table in `.csv` format

---

## New Processing Steps

### 1) Event Table Extraction
```matlab
eventTable = extract_aicm_event_table(matByLine);
```

Creates a unified table with:

* `speaker`
* `startSec`
* `endSec`
* `durationSec`

---

### 2) Interaction Classification
```matlab
interactionResults = classify_aicm_interactions(...)
```

or

```matlab
interactionResults = classify_aicm_interactions_rules(...)
```

### Supported Interaction Labels

* MANtoMAN
* MANtoFAN
* FANtoMAN
* FANtoFAN
* MANtoCHN
* CHNtoMAN
* FANtoCHN
* CHNtoFAN

---


### 3) Acoustic Analysis for Interactions
```matlab
interactionResults = add_acoustics_to_interaction_table(...)
```

Adds:

* `f0mean`
* `f0std`
* `f0min`
* `f0max`
* `dBFS`
* `pctUttVx`

---

## F0 Trimming (Important)

A small edge trimming is applied:

```matlab
trimEdgeFrames = 2;
```
A small number of F0 frames are removed from:

* beginning of utterance
* end of utterance

This removes the first and last voiced F0 values before computing statistics.

### Reason:
- Start of utterance → unstable pitch detection
- End of utterance → noise / fading

### Effect:

This improves:

* f0mean
* f0std
* f0min
* f0max

---

## Output Files

For each recording:

### Original outputs:
- *_CHN.mat
- *_CHN2FAN.mat
- *_CHN2MAN.mat
- *_FAN.mat
- *_MAN.mat

### New outputs:
- *_AICM_INTERACTIONS.mat
- *_AICM_INTERACTIONS.csv
- *_AICM_EVENTS.csv

---

### File meanings:

* **INTERACTIONS.mat** → MATLAB table with labels + acoustics
* **INTERACTIONS.csv** → spreadsheet version
* **AICM_EVENTS.csv** → raw event table

---

## New Helper Functions

* `extract_aicm_event_table`
* `build_conversation_block`
* `parse_speaker_segments_from_line`
* `classify_aicm_interactions`
* `classify_aicm_interactions_rules`
* `add_acoustics_to_interaction_table`
* `choose_f0_range`
* `is_supported_direction`
* `build_directional_label`

---

## Current Limitations

* Syllable estimation not implemented yet
* Multi-label tracking can be improved
* Rule-based classifier can be further refined

---

## Design Philosophy

* Preserve original code
* Add new functionality as separate modules
* Allow easy comparison between methods
* Keep main loop simple and readable

---

## Summary

This updated script:

* preserves the original analysis pipeline
* adds interaction-based conversational analysis
* improves acoustic feature extraction
* remains modular, clear, and maintainable


## New Functions Added

### 1) `extract_aicm_event_table(matByLine)`
Purpose:
- scans AICM conversation blocks
- extracts speaker events for `CHN`, `FAN`, and `MAN`
- returns a unified table of conversational events

Output columns:
- `speaker`
- `startSec`
- `endSec`
- `durationSec`
- `sourceIndex`

This provides a cleaner event representation than using only separate interval matrices.

**Notes:**

* Only AICM conversations are processed
* Output is sorted by time for later interaction analysis

---

### 2) `build_conversation_block(matByLine, startIndex)`
Purpose:
- builds one AICM conversation block from the ITS text
- collects all lines until `</Conversation>`

This was added to keep the event extraction code cleaner and easier to maintain.

**Behavior:**

* Starts from a line containing `type="AICM"`
* Stops at `</Conversation>`

**Notes:**

* Keeps parsing logic clean and modular

---

### 3) `parse_speaker_segments_from_line(kLine)`
Purpose:
- extracts one or more speaker segments from a single ITS line
- supports:
  - `CHN`
  - `FAN`
  - `MAN`

Notes:
- `CHN` lines can contain multiple utterances
- `FAN` and `MAN` lines typically provide one interval via `startTime` / `endTime`

---

### 4) `classify_aicm_interactions(interactionEvents, adjacencyWindowSec)`
Purpose:
- sorts the event table in time order
- checks adjacent events
- assigns directional labels when the time gap is within the allowed window

Current adjacency rule:
- if the next event starts within `2` seconds of the current event ending, a directional label may be created

Current supported labels:
- `MANtoMAN`
- `MANtoFAN`
- `FANtoMAN`
- `FANtoFAN`
- `MANtoCHN`
- `CHNtoMAN`
- `FANtoCHN`
- `CHNtoFAN`

Important note:
- this version uses a practical adjacency-based implementation
- stricter rules such as “no preceding CHN” or “no following CHN” were not yet enforced separately
- these rules can be added later inside this function if needed
* A segment can receive multiple labels
* Stores timing gaps (`prevGapSec`, `nextGapSec`)
* This is the **baseline classifier**

---

### 5) `classify_aicm_interactions_rules(eventTable, adjacencyWindowSec)`

Purpose:

* Updated classifier implementing stricter interaction rules

Improvements:

* Preserves directionality
* Applies:

  * "no preceding CHN"
  * "no following CHN"
* Separates adult-directed and child-directed interactions

**Notes:**

* This is the **recommended classifier**
* More consistent with project requirements

---

### 6) `is_supported_direction(fromSpeaker, toSpeaker)`
Purpose:
- Validate that a generated interaction label is allowed
- allows only the directional combinations required by the project
- prevents unsupported speaker pair labels from being stored

**Supported labels:**

* MANtoMAN, MANtoFAN, FANtoMAN, FANtoFAN
* MANtoCHN, CHNtoMAN, FANtoCHN, CHNtoFAN

---

### 7) `build_directional_label(fromSpeaker, toSpeaker)`
Purpose:
- converts two adjacent speakers into a class label string

Examples:
- `MAN`, `CHN` → `MANtoCHN`
- `FAN`, `MAN` → `FANtoMAN`

---

### 8) `add_acoustics_to_interaction_table(...)`
Purpose:
- reads the WAV segment corresponding to each interaction row
- computes added acoustic features
- appends those measurements to the interaction table

Features added:
- `f0mean`
- `f0std`
- `f0min`
- `f0max`
- `dBFS`
- `pctUttVx`

Notes:
- Uses `shrp.m` for pitch extraction
- a small edge trim is applied before summary statistics
- Applies F0 edge trimming (`trimEdgeFrames`)
- Uses speaker-specific F0 ranges

---

### 9) `choose_f0_range(speaker)`
Purpose:
- selects the appropriate F0 search range by talker

Current ranges:
- `CHN` → `[200 600]`
- `FAN` → `[120 400]`
- `MAN` → `[50 250]`

This keeps the same talker-specific logic already used in the original script.

---

### 10) `analyze_interval_original(...)`

**Purpose:**

* Original interval-based acoustic analysis

**Characteristics:**

* Uses direct sample indexing (0-based style)
* May produce indexing issues near start of audio

**Notes:**

* Kept for comparison with updated version

---

### 11) `analyze_interval_original_1based(...)`

**Purpose:**

* Updated interval analysis using correct MATLAB indexing

**Improvements:**

* Uses 1-based indexing (MATLAB standard)
* Prevents invalid reads
* Uses `audioinfo` for safe bounds
* Applies F0 trimming

**Notes:**

* Recommended version for stable analysis

---

### 12) `analyze_category_original(...)`

**Purpose:**

* Apply interval analysis across all segments in a category

**Categories:**

* C2F, C2M, C, F, M

**Notes:**

* Calls interval analysis function internally
* Supports switching between original and updated versions

---

### 13) `save_outputs_original(...)`

**Purpose:**

* Save all results to `.mat` and `.csv` files

**Outputs:**

* Original category results
* Interaction results
* Event table

---

### 14) `read_its_file_original(...)`

**Purpose:**

* Read ITS file line-by-line into a structured format

**Notes:**

* Extracts subject name from filename
* Stores file contents in `matByLine`

---

### 15) `parse_intervals_original(...)`

**Purpose:**

* Extract original interval categories from ITS file

**Outputs:**

* CHN, CHN2FAN, CHN2MAN, FAN, MAN

**Notes:**

* Uses neighbor-based logic for CHN2FAN / CHN2MAN
* Only processes AICM conversations





## New Acoustic Measurements Added

The interaction table now includes additional acoustic features beyond the original output.

### F0 Features

Added:

* `f0mean`
* `f0std`
* `f0min`
* `f0max`

---

### F0 Trimming

A simple edge trimming rule is applied:

```matlab
trimEdgeFrames = 2;
```

This removes a small number of voiced F0 values from the beginning and end of each segment before computing summary statistics.

**Reason:**

* Beginning of utterance → unstable pitch detection
* End of utterance → noise or fading

This improves the reliability of:

* f0mean
* f0std
* f0min
* f0max

---

### Intensity

Added:

* `dBFS`

This is computed using RMS amplitude:

* Provides a basic measure of signal intensity
* Expressed in digital full-scale (dBFS)

---

## Files Now Produced

In addition to the original `.mat` files, the script now produces:

### New files per recording

* `*_AICM_INTERACTIONS.mat`
* `*_AICM_INTERACTIONS.csv`
* `*_AICM_EVENTS.csv`

---

### Meaning of these files

* **AICM_INTERACTIONS.mat** → MATLAB table with interaction labels and acoustic features
* **AICM_INTERACTIONS.csv** → same results in spreadsheet format
* **AICM_EVENTS.csv** → raw event table before classification

---

## Current Limitations

### 1) Syllables per utterance

Not implemented yet.

Would require:

* a MATLAB syllable estimation method
* or external speech processing tools

---

### 2) Interaction classification rules

Two versions are implemented:

* `classify_aicm_interactions` → simple adjacency
* `classify_aicm_interactions_rules` → includes stricter rules

The updated version applies:

* “no preceding CHN”
* “no following CHN”

---

### 3) Multi-label membership

* A segment may belong to multiple interaction labels
* This is handled per interaction row
* Further refinement is possible if needed

---

## Why This Update Is Safe

This update preserves the original script structure:

* Original functions are unchanged
* Original outputs are preserved
* New functionality is added as separate helper functions
* The main loop is extended, not modified

This allows:

* easy comparison with the original script
* safe integration of new features

---

## Suggested Comment for Main Loop

```matlab
% ===== New directional AICM interaction analysis branch =====
% Adds:
% 1) AICM event extraction
% 2) directional interaction classification
% 3) acoustic feature extraction for interactions
% 4) CSV and MAT output
```

---

## New Function Calls in Main Loop

The following steps are added in the main loop:

```matlab
adjacencyWindowSec = 2;
trimEdgeFrames = 2;

eventTable = extract_aicm_event_table(matByLine);
interactionResults = classify_aicm_interactions(eventTable, adjacencyWindowSec);
% interactionResults = classify_aicm_interactions_rules(eventTable, adjacencyWindowSec);

interactionResults = add_acoustics_to_interaction_table( ...
    interactionResults, fname, rate, frame_length, TimeStep, ...
    SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);
```

These additions extend the pipeline without changing its original architecture.
