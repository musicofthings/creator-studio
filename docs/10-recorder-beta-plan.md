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
- [ ] Add a shared playhead, waveform and filmstrip, range selection, and precise trim.
- [ ] Add per-source mute/gain and fades, and a playback-compatible mixed audio export.
- [ ] Add screencast, webinar, and small-file export presets, progress/cancellation, destination selection, and reveal in Finder.
- [ ] Make partial imports and retained recovery files discoverable and actionable in the app.
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
