# ANVUREL

**Assisted Naturalistic Vocal Utterance Review and Emotion Labeling**

Version 2.0.1

Local Windows software for preparing, reviewing, and exporting adult speech samples from LENA recordings. This release implements the next four automation steps: batch preparation, pause refinement, explained CDS/ADS suggestions, and faster Praat review. It does not yet predict valence or arousal.

## Start on this computer

The project is now at `D:\Projects\LENA`.

- Double-click `anvurel\start_pilot.cmd` to open the latest prepared real NH excerpt.
- Double-click `anvurel\start.cmd` for the application without a selected run.
- Existing pilot runs remain readable and are not overwritten.

## Prepare one recording

1. In **Prepare recording**, choose a PCM WAV. A matching sibling ITS file is filled automatically when present.
2. Select **Auto**, **NH**, **HA**, or **Reference**. Auto infers NH/HA only from an exact parent folder name; otherwise it uses Reference. Check the group before using results.
3. Set the start and excerpt duration in seconds. The default is 300 seconds; the maximum is one hour. Only the excerpt is loaded into memory.
4. Leave **Refine adult boundaries using Praat pauses** enabled to propose splits at pauses and trim quiet edges inside imported adult segments. Disable it to keep the original ITS segment boundaries.
5. Leave **Suggest CDS/ADS** enabled to fill supported draft labels and retain evidence. Click **Prepare draft**.

The WAV and ITS filenames must have matching stems. ITS elapsed times are assumed to align with the WAV. Verify alignment by listening; matching filenames alone do not establish synchronization.

## Prepare a folder and resume work

1. In **Batch preparation**, choose a recording folder and an output folder. **Scan folder** lists WAV files, detected groups, missing ITS pairs, and header errors.
2. Choose **first** for the first excerpt of each recording or **all** for every consecutive chunk. First is the default, so a daylong folder does not automatically generate thousands of excerpts.
3. Select the excerpt length and group override. Refinement and suggestion options come from **Prepare recording**.
4. Click **Prepare batch**. Progress and errors are saved in `batch.json` and `batch_report.csv` after every excerpt. One failed recording does not stop other jobs.
5. **Stop after current excerpt** saves completed work. **Resume batch** opens that batch folder and retries unfinished or failed jobs. Completed runs are skipped, preserving their annotations and approvals. Source changes require a new batch. A missing completed run is marked `needs_check` rather than silently replacing reviewed work.
6. Select a completed row and click **Open selected run**.

Generated output directories, virtual environments, and symlinks are excluded from recursive discovery. A queue lock prevents two workers from processing the same batch. Use separate run folders for independent raters. This is not yet a simultaneous multiuser database or browser application.

## What the CDS and ADS suggestions mean

The rules adapt the existing `+lena/classify_interactions.m` workflow:

- Read CHN utterance timestamps, FAN/MAN segments, conversation boundaries, word counts, and turn codes.
- Consider nearby valid turns within five seconds in the same conversation; prefer recognized LENA turn codes over a timing fallback.
- Propose CDS for supported adult-child pairs and ADS for supported pairs between different adult speaker classes.
- Retain the pair, gap, and rule source in `suggestions.json` and display them during review.

Two deliberate differences from the MATLAB extraction scope are documented: this app considers all conversation types rather than only AICM, and it leaves conflicting CDS/ADS evidence unknown. Same-class FAN-to-FAN or MAN-to-MAN turns also stay unknown because speaker classes do not identify different individuals. The lower-level `interaction_suggestions(..., aicm_only=True)` option supports AICM-only comparisons.

These are heuristic suggestions, not calibrated confidence scores or verified intended listeners. Missing evidence remains `FAN-?` or `MAN-?`. Overlapping adult segments remain visible with unknown labels and an overlap flag. No CDS/ADS prediction can be exported as approved without explicit reviewer action.

## Review quickly

**Review samples** shows candidate intervals, waveform context, initial rule evidence, and flags for uncertainty, short duration, very quiet audio, possible clipping, and known overlap.

- Filter **Needs review**, **Flagged first**, **All**, or **Approved**.
- **F5** plays the selected interval with one second of context on either side.
- **Ctrl+S** saves labels with a backup of the previous TextGrid.
- **Ctrl+Enter** saves, approves under the entered reviewer ID, and selects the next candidate.
- **Ctrl+Left / Ctrl+Right** navigates. Enable **Play after Next** if desired.
- Enter exact start/end seconds and click **Apply boundaries to all tiers**. This also saves the current form labels. Shared neighboring boundaries move together; swallowing another interval is rejected.
- **Exclude selected** clears that interval's labels, retaining the audio and a TextGrid backup.

Unknown labels cannot be approved. Every approval identifies the exact interval and labels; changing those invalidates the matching approval. Unsaved form edits are retained when an external file changes. Reload explicitly discards those unsaved form edits. Prior TextGrids are available in `history`.

## Praat connection

1. Save and close any other Praat application instance before starting app-controlled review. This avoids ambiguous interprocess messages.
2. Select a candidate and click **Open selection in Praat** or press **F6**. The app opens a dedicated editor with the Sound and TextGrid already selected and zoomed to the interval.
3. Correct boundaries or labels. While the session is open, app editing, approval, and export are blocked to prevent a stale editor from overwriting newer annotations. Next/Previous can navigate the active editor.
4. Click **Finish and save Praat** to save the dedicated TextGrid, close that session, and reload the app. You can also save and close Praat manually. Do not close the app while leaving an unsaved Praat review open.
5. **Auto reload saved TextGrid** detects external saves. If tier boundaries differ, **Align to speaker tier** rebuilds valence/arousal intervals using speaker-tier boundaries. Unambiguous overlapping labels are retained; conflicting labels become `?`. A backup is kept. In Praat, Shift-drag moves boundaries that share a time across tiers together.

The integration uses Praat scripts and `--send` commands, not mouse-position automation. On Windows it needs an ordinary desktop session; restricted sandboxes may block interprocess messages. Another Praat instance opened during review must be closed before automated navigation or finishing. The app never closes an unrelated Praat session.

## Segmentation and measurements

Pause refinement uses Praat intensity-based silent/sounding intervals, with a starting threshold of -25 dB relative to the local maximum, 250 ms minimum silence, 120 ms minimum sounding duration, and 30 ms boundary padding constrained to the original segment. It does not classify sounding audio as speech or distinguish TV from people. All-silent or unsuitable adult segments are retained with a review flag rather than silently discarded. Without ITS, no speaker labels are inferred.

Acoustic outputs include duration, digital RMS level in dBFS, mean and range of voiced F0, and voiced fraction. Pitch uses a starting adult range of 60–600 Hz. These settings require review for each population. dBFS is not calibrated sound pressure. Parselmouth embeds a Praat engine that can differ from the standalone executable. Speech rate and learned arousal/valence predictions are future work.

## Saved files

Each run contains `excerpt.wav`, `annotations.TextGrid`, `run.json`, `suggestions.json`, `quality.csv`, `acoustics.csv`, `reviews.json`, and `activity.jsonl`. Draft acoustic/quality files describe the preparation boundaries. The review display refreshes quality flags on reload; exports recompute acoustic and quality measurements.

Each export has its own folder with approved clips, the reviewed TextGrid and excerpt, a manifest with original and excerpt-relative timestamps, suggestion and review records, and coverage. The coverage table includes all 16 non-neutral combinations plus eight neutral combinations, including zero counts. Suggested labels and reviewed labels remain distinguishable in the saved files. Original WAV/ITS files are never edited.

## Set up another PC

Install Python 3.12 with Tcl/Tk and the Python launcher, copy the source package, and double-click `setup.cmd`. Obtain Praat from its official Windows download page and select the executable or put it at `tools\Praat.exe`. Then run `start.cmd`. Do not copy another person's `.venv`; setup creates the local environment. The source package excludes recordings, results, dependencies, and Praat binaries.

## Command line examples

```powershell
.venv\Scripts\python.exe app.py --prepare "C:\data\NH\recording.wav" --its "C:\data\NH\recording.its" --length 300
.venv\Scripts\python.exe app.py --batch "C:\data\NH" --group Auto --mode first --length 300 --output "C:\data\pilot_outputs"
.venv\Scripts\python.exe app.py --resume "C:\data\pilot_outputs\batch_ID"
.venv\Scripts\python.exe app.py --load "C:\data\pilot_outputs\batch_ID\runs\run_ID"
.venv\Scripts\python.exe app.py --export "C:\data\pilot_outputs\batch_ID\runs\run_ID"
.venv\Scripts\python.exe -m unittest discover -s . -p "test_*.py" -v
```

Use `--no-refine` or `--no-suggest` to disable either draft automation. Validate time savings and annotation agreement against independent human annotations on real NH/HA recordings; no improvement in speed or emotion accuracy has been established yet.

## Technical references

- Praat command-line scripting: https://www.fon.hum.uva.nl/praat/manual/Scripting_6_9__Calling_from_the_command_line.html
- Praat editor scripting: https://www.fon.hum.uva.nl/praat/manual/Scripting_7_1__Scripting_an_editor_from_a_shell_script.html
- Praat silent/sounding segmentation: https://www.fon.hum.uva.nl/praat/manual/Sound__To_TextGrid__silences____.html
- Praat Windows downloads: https://www.fon.hum.uva.nl/praat/download_win.html
