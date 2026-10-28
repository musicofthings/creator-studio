# Free recorder beta plan

**Product direction:** free, local-first screen recording for screencasts and recorded webinars. The first beta targets macOS; the shared core remains portable to iPhone and iPad. This plan supersedes the paid-download assumption and phase ordering in the original roadmap, while retaining its reliability and privacy gates.

Core capture, editing, local projects, and standard export require no account, watermark, time limit, or upload. Any future hosted or third-party AI service is optional and its cost and data use must be disclosed before use.

This phase records a presentation or webinar already running in another application. Webinar hosting, remote guests, and live streaming are later decisions. System audio is a mix delivered by the selected capture source; isolated participant tracks cannot be promised.

## A. Recording confidence

- [x] Show elapsed time during active macOS capture, alongside the existing stop control and observed-source indicators.
- [ ] Add pause and resume across all capture sources using a shared clock, with journaled recovery and explicit paused state. Qualify interruption while paused and source offsets after resume.
- [x] Warn during capture when a requested system-audio or microphone source has delivered no samples after a short grace period, or stops delivering samples. This is not an audio-level or silence detector.
- [ ] Add microphone and system-audio meters, microphone selection and test, and detection of silence within delivered samples.
- [ ] Provide an obvious compact recording control, mute and camera controls, and shortcuts with honest state and permission handling.
- [ ] Improve long-session storage estimates, low-storage warnings, dropped-sample reporting, and window/source-loss behavior.
- [ ] Add a webinar preflight covering selected content, audio, camera, available space, and the user's responsibility to obtain required recording permission.
- [ ] Qualify real 5-, 30-, and 60-minute captures, with system audio, mic, and camera combinations. Measure A/V offset and drift, dropped samples, storage, thermal behavior, and recovery on interruption. No completed segment may be lost.

## B. Edit and export

- [ ] Replace the current multi-track ripple-edit safeguard with linked range edits preserving cross-source offsets, gaps, and undo/redo. Specify behavior for locked tracks, focus markers, captions, and session boundaries before implementation.
- [x] Split every clip crossing a selected project time as one undoable edit; preserve gaps, offsets, focus events, and captions, and reject the edit if an affected track is locked.
- [x] Remove a selected clip's project time range across all tracks in one undoable edit. Later clips and metadata move together; overlapping captions or focus markers and affected locked tracks block the cut until addressed. Linked trim remains outstanding.
- [x] Add full-project Editor preview through the export composition, a shared project-time playhead, split-at-playhead, and explicit start/end range selection for linked cuts.
- [ ] Add a time-scaled waveform and filmstrip, drag range selection, and precise linked trim.
- [x] Add undoable microphone, system-audio, and music track mute for preview and export.
- [x] Add undoable per-clip audio attenuation from −60 to 0 dB to the shared preview/export mix.
- [x] Decode a generated movie and verify −6 dB audio attenuation through the shared mixer setup.
- [ ] Add audio fades and qualify playback-compatible mixed audio export and gain with real-media fixtures.
- [ ] Add screencast, webinar, and small-file export presets, progress/cancellation, destination selection, and reveal in Finder.
- [x] Show retained imported recovery copies after relaunch, with a Finder reveal and an explicit deletion warning. Partial-import details remain in the immediate warning; persisted per-segment diagnostics and repair/retry remain future work.
- [ ] Add real-media and golden export tests covering timing, audio, gaps, and interrupted saves.

## C. Screencast polish

- [ ] Editable manual and suggested focus zooms with comfort controls.
- [ ] Cursor sizing, highlights, click rings, and smoothing where recorded metadata permits.
- [ ] Timed, editable arrows, rectangles, text, and spotlight annotations.
- [ ] Timed manual privacy blur with preview/export parity.
- [ ] Editable camera placement and recording markers.

## D. Webinar repurposing

- [ ] On-device transcription where supported, with language and availability communicated.
- [ ] Editable captions and SRT/VTT or burned-in export.
- [ ] Searchable transcript, manual chapters and markers, and range-based clip extraction.
- [ ] Optional summaries and titles only after consent and provider/data boundaries are explicit.

## Release gates

Prioritize source preservation, A/V sync, permission honesty, accessibility, and export correctness over new effects. Automated tests do not substitute for signed capture and long-duration runtime qualification. Ship each milestone only when its end-to-end workflow and failure recovery are verified on supported hardware.

## Linked editing contract

Project-time cuts use a half-open interval `[start, end)` within the current clips' project duration. The interval must overlap media; a gap alone cannot currently be removed. Every track participates, including muted tracks and disabled clips. Clips before the range stay fixed, overlapping clips retain the surviving source portions at their existing playback rates, and all later clips move earlier by the removed duration. Gaps outside the removed interval retain their length. Cuts may cross recording-session boundaries; original source files and capture provenance remain unchanged.

An affected locked track rejects the whole command, including a locked track whose later clips would shift. Locks wholly before the cut do not block it. Focus markers and captions touching the range boundary remain valid; any overlap blocks removal. Metadata after the range shifts with the clips. Split-at-playhead leaves metadata in place and rejects an affected locked track. Commands include explicit new clip IDs and persisted snapshots for deterministic replay and relaunch-safe undo/redo.

The Editor preview uses the complete project composition and audio mix; the Media tab auditions individual sources. The project scrubber and range fields use project seconds, while the clip inspector's split slider uses source time. Successful cuts clear the range selection. Filmstrips, proportional timeline rows, drag selection, and linked trim remain pending. Interactive playback, seeking after edits, and range marking still require a macOS smoke test; automated reducers and generated-media export fixtures cover the deterministic core.
