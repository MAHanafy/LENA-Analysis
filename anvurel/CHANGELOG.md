# Change history

## Version 2.0.1

The application is named ANVUREL and lives in the `anvurel` folder. Default outputs are stored under `outputs/anvurel`. Existing annotations and pilot results remain readable.

Installation instructions describe setup on any Windows computer. The workflow screenshots use generated audio and artificial ITS metadata.

## Version 2.0

Batch preparation scans folders for WAV and ITS pairs, infers NH or HA groups from folder names, and supports the first excerpt or all consecutive excerpts. Progress is saved after each job. A batch can stop after the current excerpt and resume without replacing completed runs.

Praat pause analysis can refine imported boundaries. CDS and ADS suggestions use conversation rules adapted from the MATLAB classifier, with the evidence retained for review. Conflicting evidence and uncertain speaker identity remain unknown.

The Praat connection opens a selected interval in a dedicated editor and supports navigation, saving, and reloading. The application prevents its own annotation changes while that editor is active.

Review controls include waveform context, playback, filters, keyboard shortcuts, shared boundary edits, exclusion, and explicit approval. TextGrid backups and activity logs preserve earlier work. Exports recalculate acoustic measurements for the reviewed boundaries.

Valence and arousal are assigned by a reviewer. This version includes no trained emotion classifier or hosted AI service.
