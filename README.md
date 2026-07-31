# LENA Acoustic and Interaction Analysis

This MATLAB project analyzes paired LENA `.ITS` and `.WAV` recordings. It extracts AICM speech segments, classifies directed interactions, calculates acoustic features, saves recording-level files, and creates one merged workbook per subject.

The code was reorganized from the historical monolithic script into a small package. The parsing, classification, acoustic, export, and plotting algorithms were not changed.

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

- `config.m`: paths and all numeric/classifier parameters
- `find_recordings.m`: recursive ITS discovery and recording metadata
- `process_recording.m`: ITS reading, interval parsing, and per-recording orchestration
- `classify_interactions.m`: unchanged v3 turn-pair classifier
- `analyze_acoustics.m`: F0, semitone F0 range, dBFS, estimated dBSPL, and syllable calculations
- `save_results.m`: metadata columns, CSV/MAT export, folder mirroring, and subject merge
- `create_plots.m`: evaluation and classifier-comparison plots
- `legacy/acoust_detail_funcs_original.m`: frozen pre-refactor implementation for reference

## Output compatibility

Outputs retain the existing filenames, columns, calculations, and hierarchy:

```text
results_YYYYMMDD/
└── cohort/
    └── subject/
        ├── subject_AICM_INTERACTIONS_All_Segments.xlsx
        └── recording/
            ├── *_CHN.mat
            ├── *_CHN2FAN.mat
            ├── *_CHN2MAN.mat
            ├── *_FAN.mat
            ├── *_MAN.mat
            ├── *_AICM_INTERACTIONS.mat
            ├── *_AICM_INTERACTIONS.csv
            ├── *_AICM_INTERACTIONS_All_Segments.csv
            └── evaluation/comparison plots
```

The first four CSV columns remain `file name`, `subject name`, `Session ID`, and `Date`. Date values use `M/d/yyyy` without a time.

The AM28 age vector remains active only when the selected folder itself is named `AM28`. Other subject/cohort selections retain `NaN` in the legacy age fields.

## Configuration

Edit [+lena/config.m](+lena/config.m) to change the default data folder or correspondence workbook. Algorithm parameters are centralized there but retain their pre-refactor values.

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

The tests cover configuration values, old/new recording-name discovery, empty output schemas, a representative FAN-to-CHN turn pair, and the historical compatibility entry point.
