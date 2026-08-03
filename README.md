# LENA Acoustic and Interaction Analysis

This MATLAB project analyzes paired LENA `.ITS` and `.WAV` recordings. It extracts AICM speech segments, classifies directed interactions, calculates acoustic features, saves recording-level files, and creates one merged workbook per subject.

The code was reorganized from the historical monolithic script into a small package. The current pipeline also adds semitone F0 range, estimated dB SPL, loudness-variability metrics, explicit date parsing, and empty-session diagnostics.

## Requirements

- MATLAB R2025b or a compatible release
- Paired `.ITS` and `.WAV` files with the same filename stem
- `shrp.m` on the MATLAB path (included in this repository)
- `Name_Correspondences.xlsx` for Session ID lookup

## Run the analysis

Open MATLAB in this repository and run:

```matlab
run_lena_analysis
```

A folder-selection window opens. Select a subject folder, a cohort folder such as `HA` or `CI`, or the common `Cougar_union` folder.

For a scripted run, pass the folder directly:

```matlab
run_lena_analysis('F:\SynologyDrive\Cougar_union\HA')
```

The historical command is still supported:

```matlab
acoust_detail_funcs_newhelpers_MH
```

## Project organization

```text
LENA/
├── run_lena_analysis.m
├── README.md
├── +lena/
│   ├── config.m
│   ├── find_recordings.m
│   ├── process_recording.m
│   ├── classify_interactions.m
│   ├── analyze_acoustics.m
│   ├── save_results.m
│   └── create_plots.m
├── legacy/
│   └── acoust_detail_funcs_original.m
└── tests/
    ├── test_lena_pipeline.m
    └── fixtures/
```

Responsibilities are intentionally broad so the project remains compact:

- `config.m`: paths, calibration, and all numeric/classifier parameters
- `find_recordings.m`: recursive ITS discovery and recording metadata
- `process_recording.m`: ITS reading, interval parsing, and per-recording orchestration
- `classify_interactions.m`: v3 turn-pair classification and empty-session diagnostic counts
- `analyze_acoustics.m`: F0, semitone F0 range, dBFS, estimated dBSPL, loudness variability, syllable calculations, and their local calculation helpers
- `save_results.m`: recording-level exports plus one final subject-level workbook merge and date-safe CSV import
- `create_plots.m`: evaluation and classifier-comparison plots
- `legacy/acoust_detail_funcs_original.m`: frozen pre-refactor implementation for reference

## Acoustic measurements

Each analyzed segment can include:

- `f0mean`, `f0std`, `f0min`, `f0max`, and `f0range` in Hz
- `f0rangeST`, calculated as `12 * log2(f0max / f0min)` when both values are positive
- `dBFS`, calculated from the RMS amplitude of the segment
- `dBSPL`, estimated as `dBFS + cfg.dBSPLCalibrationOffset`; the default is 97 dB and should be confirmed against the recorder calibration before interpreting it as calibrated SPL
- `loudnessStd`, the standard deviation of valid frame-level dBFS values
- `loudnessRange`, the maximum minus minimum valid frame-level dBFS value
- `loudnessIQR`, the 75th minus 25th percentile of valid frame-level dBFS values
- `pctUttVx`, `syllableCount`, and `syllablesPerSec`

Loudness coefficient of variation is intentionally not calculated because its interpretation on logarithmic dB values requires additional validation.

## Outputs

Outputs retain the established folder hierarchy and filenames while adding the new acoustic columns and diagnostic file:

```text
results_YYYYMMDD/
└── cohort/
    └── subject/
        ├── subject_AICM_INTERACTIONS_All_Recordings.xlsx
        └── recording/
            ├── *_CHN.mat
            ├── *_CHN2FAN.mat
            ├── *_CHN2MAN.mat
            ├── *_FAN.mat
            ├── *_MAN.mat
            ├── *_AICM_INTERACTIONS.mat
            ├── *_AICM_INTERACTIONS.csv
            ├── *_AICM_INTERACTIONS_All_Segments.csv
            ├── *_EMPTY_SESSION_DIAGNOSTIC.csv
            └── evaluation/comparison plots
```

The first four interaction CSV columns are `file name`, `subject name`, `Session ID`, and `Date`. Date values are explicitly imported and exported using `M/d/yyyy` without a time.

The merged subject workbook is named `*_AICM_INTERACTIONS_All_Recordings.xlsx`. It contains one `All_Segments` sheet with all exported segment rows from completed recording CSV files. Loudness summary sheets are intentionally not generated; comparisons across speakers or interaction types should be calculated from the segment-level columns.

When no interactions are produced, `*_EMPTY_SESSION_DIAGNOSTIC.csv` reports the number of AICM conversations, candidate and accepted segments, immediate-neighbor rejections, valid speech segments, interaction pairs, output rows, and a plain-language reason.

The AM28 age vector remains active only when the selected folder itself is named `AM28`. Other subject/cohort selections retain `NaN` in the legacy age fields.

## Configuration

Edit [+lena/config.m](+lena/config.m) to change the default data folder or correspondence workbook. Algorithm parameters are centralized there but retain their pre-refactor values.

The estimated dB SPL calibration offset defaults to 97 dB and can be changed after calibration review:

```matlab
cfg = lena.config();
cfg.dBSPLCalibrationOffset = 97;
```

Each subject workbook is created as soon as that subject's final selected recording finishes, rather than waiting for the entire analysis run or rebuilding it after every recording.

To disable plots for a controlled/test run:

```matlab
cfg = lena.config();
cfg.createPlots = false;
run_lena_analysis('F:\path\to\data', cfg);
```

## Tests

Run the regression tests from MATLAB:

```matlab
results = runtests('tests/test_lena_pipeline.m');
assertSuccess(results)
```

The tests cover configuration values, old/new recording-name discovery, interaction classification, empty-session diagnostics, acoustic conversions, loudness variability, grouped summaries, unambiguous date import, empty output schemas, and the historical compatibility entry point.
