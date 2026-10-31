# Version 2.0.1

- Adopt ANVUREL as the application name and rename the application folder to `anvurel`.
- Store application outputs under `outputs/anvurel` and retain existing annotations and pilot results.
- Publish the application on the `anvurel` branch of LENA-Analysis.

# Changes in version 2

- Recursive WAV/ITS discovery, automatic NH/HA folder grouping, first/all chunk modes, persistent queue, cancellation between excerpts, and resume without overwriting completed work.
- Praat pause-based boundary refinement, with retained uncertain regions and overlap flags.
- Explained draft CDS/ADS rules adapted from the project classifier. All conversation types are considered; conflicts and same-class identity ambiguity remain unknown.
- Dedicated Praat editor opening, selection, navigation, save/finish, file-change detection, and protection against concurrent app/editor writes.
- Review filters, waveform context, playback, keyboard shortcuts, shared boundary edits, explicit exclusion, annotation backups, and event logs.
- Backward-compatible loading of existing runs, portable pilot launcher, and refreshed quality/acoustic export.

Valence and arousal remain human labels. No trained emotion classifier or hosted AI service has been added.
