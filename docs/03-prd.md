# Product requirements document

## 1. Document control

| Field | Value |
|---|---|
| Product | Creator Studio (working title) |
| Status | Draft for validation |
| Product surface | iPhone and iPad first; macOS extension planned |
| First-release horizon | 24–30 engineering weeks after validated spikes |
| Primary promise | Capture once; publish focused, captioned variants without a mandatory subscription |

## 2. Problem

Creators who demonstrate software, teach hands-on workflows, publish talking-head or podcast material, and repurpose content for social channels currently stitch together capture, audio cleanup, screen zooms, captions, reframing, and export across several products. The strongest tools are desktop-only, cloud/subscription-centered, optimized for only one content type, or too complex for rapid mobile work.

On iOS, the problem is sharper: native screen recording produces pixels and audio but not a polished tutorial. Cross-app capture generally lacks touch semantics, and generic mobile editors do not understand screen focus. Users must manually animate every crop, redo layouts for each social aspect, or move the project to a desktop.

## 3. Vision and principles

Creator Studio turns raw screen, camera, and spoken-word sources into an editable first draft. It is:

1. **Local-first:** record, edit, transcribe, and export a useful project offline.
2. **Non-destructive:** sources are immutable; suggestions are reversible edits.
3. **Opinionated, not restrictive:** excellent defaults with manual correction.
4. **Responsive:** one edit graph renders across output shapes.
5. **Honest about platform limits:** capabilities are explained before recording.
6. **Private by default:** cloud AI requires per-job disclosure and consent.
7. **Reliable before clever:** source recovery outranks automatic polish.

## 4. Target users

### P1 — Indie product builder

Records iPhone/iPad/Mac demos for launches, documentation, and social media. Needs automatic focus, pointer/tap clarity, brand presets, and fast 9:16 variants.

### P2 — Educator or support creator

Makes step-by-step tutorials and courses. Needs legibility, annotations, privacy blur, voice quality, chapters, captions, and reusable styling.

### P3 — Solo video podcaster

Records or imports long-form spoken-word video and cuts shorts. Needs stable long capture, audio quality, text navigation, captions, chapters, and highlight clips.

### Secondary — Live demonstrator

Runs workshops or streams. Needs scenes, live callouts, preview/program, source audio control, local recording, and streaming health. This persona is served after the offline core.

## 5. Jobs to be done

- When I demonstrate an app, help viewers follow every important action without me manually animating a camera.
- When I finish a recording, give me a credible first draft while preserving total edit control.
- When I publish to several platforms, adapt framing and captions without duplicating the project.
- When I record a long conversation, let me navigate and edit by meaning, not only waveforms.
- When I handle private or client material, let me work without uploading it.
- When a call, crash, storage warning, or extension termination occurs, preserve everything already captured.

## 6. Goals and non-goals

### Goals

- Five-minute source to accepted first export in under ten minutes for a new user.
- A fully useful offline workflow with no sign-in.
- Readable screen actions on a phone-sized viewer.
- Deterministic exports across repeated runs of the same project version.
- Portable projects that can later open on macOS.
- A module boundary that permits ReplayKit-to-ScreenCaptureKit evolution.

### Non-goals for v1

- Full desktop NLE parity.
- Remote podcast studio or hosted collaboration platform.
- Public livestreaming control room.
- Direct publishing integrations that require broad account permissions.
- Generative avatars, voice cloning, or replacement video.
- Guaranteed cross-app touch coordinates, simultaneous facecam, or protected-content capture on iOS.

## 7. Core experience

### 7.1 Home and project creation

The home screen lists local projects with intent, duration, last edit, storage, and export state. “New” offers Tutorial, Social, Podcast, Camera, Audio, or Import. Intent only changes defaults; the underlying document is shared.

Acceptance criteria:

- Create and autosave a project without an account or network.
- Import video/audio/images from Photos, Files, or share sheet.
- Duplicate, rename, archive, delete, and export a portable project package.
- Surface missing media and storage use without corrupting the project.

### 7.2 Capture preflight

Before capture, show the exact sources the selected mode can record. Check screen/mic/camera permission, audio route, free storage, estimated recording time, thermal state, orientation, Do Not Disturb guidance, and protected-content caveats.

Acceptance criteria:

- Require a deliberate user action to start recording.
- Maintain a conspicuous system/app recording indication.
- Never imply that camera, app audio, or global touch telemetry will be captured when unavailable.
- Run a five-second microphone meter/test and allow source selection.
- Warn below configurable safe storage and thermal thresholds.

### 7.3 Capture and recovery

Supported v1 modes are own-app screen capture, ReplayKit broadcast-extension capture, camera, audio-only, and import. Each writes media fragments and a journal before finalization.

Acceptance criteria:

- Preserve capture up to the last committed fragment after process or extension termination.
- Record timestamps, orientation changes, interruptions, pauses/markers, and capability metadata.
- Atomically finalize a capture manifest and import it into the project on next launch.
- Never overwrite a source file during edit or export.
- Stop safely on low storage and explain what was preserved.

### 7.4 Automatic draft

After capture/import, generate proxies/waveforms, transcript, focus candidates, caption cues, audio recommendations, and canvas layouts. Draft creation is a cancelable job; the project is immediately editable even if analysis is incomplete.

Acceptance criteria:

- Every suggestion records source, confidence, model/rule version, and status.
- Low-confidence focus suggestions are visible but not auto-applied.
- Re-running analysis does not overwrite accepted manual edits.
- Offline analysis is the default; cloud choices show exactly what leaves the device.

### 7.5 Editor

The editor has viewer, playhead/timeline, selection inspector, undo/redo, and task-oriented tool groups. The default timeline stays shallow; advanced tracks expand on request.

Must support:

- trim, split, reorder, ripple close, duplicate, disable;
- source volume, fade, mute/solo, music ducking, voiceover;
- crop, scale, position, rotation, corner radius, shadow, background;
- picture-in-picture camera/layouts;
- manual focus regions and suggested focus acceptance/rejection;
- text, arrows, boxes, freehand, static and tracked blur;
- word-timed captions with text correction and style presets;
- canvas/aspect switch with per-output overrides;
- project-wide brand preset;
- frame-accurate preview at proxy quality and full-quality still preview.

### 7.6 Export

Export presets express destination constraints rather than brand names only. Examples: Vertical Short, Square Feed, Landscape Tutorial, Podcast Video, Audio Episode, Master.

Acceptance criteria:

- H.264 and HEVC video; AAC/M4A and WAV audio; SRT, VTT, and plain transcript.
- 1080p required; 4K is device/project capability-gated.
- Correct orientation, color metadata, aspect, audio/video sync, and caption safe zones.
- Batch queue multiple aspect profiles without duplicating source media.
- Cancel cleanly; preserve completed outputs; show estimated size and disk check.
- Share through the system share sheet, Photos, or Files.

## 8. AI-assisted requirements

### v1 local intelligence

- Speech transcription with timestamps and locale support where the OS permits.
- Voice activity/silence detection.
- Screen-change, OCR-region, and saliency-derived focus candidates.
- Face/person region detection for camera reframing.
- Rule-based focus smoothing, collision avoidance, and comfort limits.
- Privacy suggestions for likely sensitive text or notification regions; never claim perfect detection.

### v1.5/v2 optional intelligence

- Chapter, title, description, tutorial-step, and show-note suggestions from transcript.
- Highlight/short-clip ranking with evidence and editable handles.
- Filler-word and long-silence suggestions.
- Natural-language edit requests compiled into a previewable edit diff.
- Caption translation.

### AI safety and UX rules

- Never delete source media or commit destructive edits automatically.
- Generated speech, translation, or visual replacement must be labeled.
- Cloud AI is off by default; consent is scoped to each job/data class.
- A production API key is not embedded in the app. Use a self-hosted/first-party gateway or an explicit personal key stored in Keychain for developer builds.
- Suggestions cite the time range and reason used so the user can judge them.

## 9. Platform capability matrix

| Capability | iOS/iPadOS initial | macOS expansion |
|---|---|---|
| Own-app screen | ReplayKit | ScreenCaptureKit preferred |
| Cross-app/system screen | User-mediated broadcast extension; revalidate newer picker APIs | ScreenCaptureKit selected display/app/window |
| System/app audio | ReplayKit-provided buffers where allowed | ScreenCaptureKit audio filters |
| Microphone | ReplayKit/camera/audio session | ScreenCaptureKit mic or AVAudioEngine |
| Front camera with screen | Mode/device constrained; do not guarantee across apps | Separate camera source |
| Pointer/touch metadata | Own-app/integrated events only; inferred/manual otherwise | Cursor capture plus optional consented event tap |
| Keyboard display | External/in-app events only | Optional accessibility/input monitoring permission |
| Background capture | Extension/system mediated | Native app capture with screen-recording permission |

## 10. Metrics

### North star

Weekly accepted exports from projects created or edited that week.

### Activation

- First accepted export within first session.
- Median capture-stop-to-first-export time.
- Percentage of capture sessions successfully finalized/recovered.

### Quality

- Export success rate and A/V sync failures.
- Caption word error rate on an internal multilingual suite.
- Suggested focus acceptance, modification, and rejection rates.
- Percentage of frames with unintended safe-zone/crop violations.
- Crash-free capture and export hours.

### Retention and value

- Creators exporting in 2+ aspect ratios.
- Brand preset reuse.
- Projects reopened after seven days.
- Minutes exported per active creator, segmented by intent.

Telemetry is opt-in or privacy-preserving, contains no raw media/transcripts by default, and has an in-app explanation and reset/delete control.

## 11. Accessibility, localization, and quality

- Full VoiceOver labels, actions, and focus order.
- Dynamic Type outside spatial canvas controls; scalable alternatives within the canvas.
- Switch Control, keyboard navigation on iPad, and sufficient contrast.
- Never communicate track type, speaker, confidence, or status through color alone.
- Caption defaults meet readable contrast and minimum duration rules.
- UI is localization-ready; right-to-left layouts and CJK/Indic caption shaping are test requirements.
- Exported captions preserve Unicode and correct line breaking.

## 12. Monetization recommendation

Validate willingness to pay with a transparent paid-once core:

- Free trial or limited export count with no watermark on short evaluation exports.
- One-time core purchase covering local recording/editing/export.
- Optional major-version upgrade or paid professional pack for multicam/live/macOS.
- Cloud AI and hosted sharing sold as explicit usage/hosting, or enabled through a user-owned provider.

Do not advertise “free AI” while silently turning a local product into an account/subscription dependency. App Store purchase design needs separate commercial and review validation.

## 13. Launch readiness

Public release requires:

- 100 consecutive internal capture/recovery scenarios without lost finalized fragments.
- 99% successful reference exports across the device/format matrix.
- No known source-media mutation path.
- App Review privacy strings, recording indicator, privacy policy, and cloud consent reviewed.
- Accessibility audit of create, capture, basic edit, and export flows.
- Thermal/storage qualification on the oldest supported devices.
- Clear support diagnostics and project recovery documentation.
