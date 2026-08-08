# Phased roadmap

The roadmap assumes a compact native team: two iOS/media engineers, one product/UI engineer, one part-time designer/researcher, and shared QA. A solo build should treat phases as sequential and roughly double elapsed time. Dates are exit-gate driven rather than promises.

## Phase 0 — Feasibility and product proof (weeks 1–4)

### Product

- Interview 12–15 creators across product demos, teaching, and solo podcasts.
- Benchmark five real workflows and record current time/cost/tool switching.
- Prototype task-oriented editor and aspect switching in a clickable model.
- Test paid-once value proposition and acceptable optional AI cost framing.

### Engineering spikes

- Qualify ReplayKit own-app and broadcast capture across device/OS matrix.
- Measure extension memory, thermal, fragment writing, interruption, and recovery.
- Prove screen + mic/app-audio combinations and document camera limitations.
- Prove 5/30-minute ingest, proxy, caption, focus, and 1080p render.
- Prototype focus inference from exact events and pixel-only recordings; run motion-comfort review.
- Prove project package moves through Files and reopens without a database.

### Capture foundation implementation status — 7 August 2026

- [x] Replace the lifecycle-only broadcast shell with bounded AVAssetWriter screen, app-audio, and microphone segments.
- [x] Flush an append-only capture journal and atomically replace the schema-v1 manifest after each committed segment.
- [x] Discover finalized, interrupted, low-storage, failed, and in-progress inbox sessions without trusting inbox paths.
- [x] Validate schema, canonical paths, symlinks, roles, sizes, and SHA-256 before copying immutable sources into a project.
- [x] Add preflight and visible ready/recording/stopping/importing/recovered/failed/storage-constrained UI states with local-only privacy language.
- [x] Add deterministic state, journal replay, interruption, low-storage, traversal, symlink, hash-mismatch, and immutable-import tests.
- [x] Pass Swift package tests, optional gateway checks/typecheck, and an unsigned iOS Simulator build.
- [ ] Sign with non-placeholder app/extension identifiers and the same App Group, then verify real ReplayKit buffers on iPhone and iPad.
- [ ] Complete the Phase 0 device/OS matrix, 5/30-minute thermal/storage measurements, A/V sync inspection, and 50 forced-interruption runs.

### Exit gate

No lost recoverable media in 50 forced-interruption runs; a five-minute source produces a readable vertical tutorial prototype within two source durations; at least 8/12 target users prefer the proposed workflow to manual mobile editing.

## Phase 1 — Private alpha foundation (weeks 5–12)

- Project library, package storage, import, hashing, proxies, waveforms.
- Capture preflight, own-app capture, broadcast inbox, recovery UX.
- Basic viewer/timeline; trim, split, reorder, crop, transform, gain/fades, undo/redo.
- Manual focus, annotation, blur, basic responsive 16:9/9:16/1:1 layout.
- Camera/audio-only recording and voiceover.
- Deterministic 1080p H.264/AAC export and Files/Photos/share sheet.
- Structured diagnostics, performance signposts, golden render suite.

### Exit gate

20 internal creators complete capture-to-export without assistance; 95% task completion; zero source mutation; reference export success ≥98%; crash-free capture hours ≥99.5%.

## Phase 2 — Creator beta and differentiated draft (weeks 13–20)

- On-device transcription adapter, caption correction/styles, SRT/VTT/TXT.
- Focus candidate engine: frame changes, OCR regions, event imports, comfort rules.
- Brand presets, device frames, shadows/backgrounds, safe zones, batch aspects.
- Audio normalization, voice cleanup baseline, music ducking.
- Suggestion review rail and accepted/rejected provenance.
- Podcast chapters and manual social clipping.
- Accessibility/localization pass; old-device thermal/storage qualification.

### Exit gate

Median five-minute capture to accepted export under ten minutes; focus suggestions accepted or lightly modified ≥60% on tutorial suite; caption correction burden acceptable in user test; export success ≥99%; crash-free capture/export hours ≥99.8%.

## Phase 3 — Public v1 (weeks 21–28)

- Reliability hardening, migration fixtures, archive safety, recovery tooling.
- Export presets including HEVC, audio-only AAC/WAV, optional 4K qualification.
- Privacy detector suggestions and cloud consent center.
- Optional gateway beta for chapters, show notes, titles, and highlight ranking.
- Onboarding, example project, support diagnostics, privacy policy, App Review assets.
- Purchase/trial implementation after business-model validation.

### Release gate

Meet PRD launch readiness; no P0/P1 data-loss/privacy/accessibility issue; 100 consecutive recovery scenarios; 99% reference exports; transparent offline and cloud behavior.

## Phase 4 — Repurpose and macOS (months 8–12)

- Transcript-based ripple editing with correction-preserving token mapping.
- Automatic clips, filler/silence suggestions, multilingual captions.
- Multicam import/sync and active-speaker layouts.
- macOS app with ScreenCaptureKit, editable pointer/click metadata, keyboard callouts, menu bar capture, and shared project packages.
- iPad/Mac external drive and project handoff workflow.
- Preset/template portability and Shortcuts actions.

### macOS foundation implementation status — 8 August 2026

- [x] Add a native SwiftUI macOS 15 target that reuses the portable domain, project-store, timeline, media, AI, and export package products.
- [x] Add the ScreenCaptureKit system picker for a user-selected window, application, or display.
- [x] Record screen, system/application audio, and microphone as separate bounded segments through the existing journaled capture pipeline.
- [x] Preserve unexpected ScreenCaptureKit stops as interrupted, recoverable sessions rather than finalized recordings.
- [x] Reuse the validated inbox importer to create immutable project sources and deterministic timeline tracks.
- [x] Add a desktop project library, media import, source preview, and timeline overview.
- [ ] Run a signed app with Screen Recording and microphone permissions; qualify real screen/system-audio/mic buffers, protected content, A/V offset/drift, and multi-display sizing.
- [ ] Add editable pointer/click event metadata, keyboard callouts, dedicated camera capture, menu bar controls, and external-drive/project-handoff workflows.
- [ ] Bring the full timeline command inspector and precision desktop editing interactions to the macOS UI.

### Exit gate

macOS project round-trip without semantic change; cursor/focus workflow beats manual baseline; automatic clip precision@3 and acceptance meet product thresholds; no regression to local-first core.

## Phase 5 — Podcast remote and live production (year 2, evidence-dependent)

- Remote guests with device-local isolated tracks, progressive upload, reconnect, drift correction, and consent.
- Preview/program scenes, audio mixer, lower thirds, live annotation.
- RTMP then SRT output, stream health, reconnect, local clean/dirty recordings.
- iPhone remote for iPad/Mac control and multiview.
- Hosted review/share only if export users demand it; keep it optional.

### Exit gate

Remote source recovery survives network loss; live latency/thermal/reconnect SLOs pass; features have a sustainable one-time/usage-based commercial model.

## Backlog sequencing rules

1. Data loss, permission honesty, A/V sync, and export corruption outrank every feature.
2. Improve the primary workflow’s time-to-export before adding another content category.
3. Automatic features require an evaluation dataset, reversible UX, and an owner for quality.
4. Hosted collaboration begins only after local weekly export retention is healthy.
5. macOS reuses the project/render core; platform capture/UI differences stay in adapters.

## Initial issue epics

| Epic | First concrete deliverable |
|---|---|
| E1 Project format | Create/open/save/migrate package fixture and recover interrupted atomic write |
| E2 Capture | Five-minute own-app and broadcast artifacts with journal/final manifest |
| E3 Ingest | Inspect/hash/proxy/waveform job with cancel and cache rebuild |
| E4 Timeline | Reducer for add/trim/split/move/focus plus undo/redo |
| E5 Preview | Shared normalized layout and focus curve in interactive viewer |
| E6 Render | 1080p landscape/vertical golden project through AVFoundation/Metal decision path |
| E7 Speech | Local transcript adapter and deterministic caption segmentation |
| E8 Audio | Meter, waveform, gain/fade, normalization, ducking baseline |
| E9 Privacy | Preflight, recording indicator, App Group validation, cloud consent receipt |
| E10 Quality | Device matrix harness, synthetic media fixtures, performance dashboard |

## First two sprints

### Sprint 1

- Freeze schema v1 draft and capability model.
- Implement project package repository and migration harness.
- [x] Build ReplayKit/broadcast spike with fragment+journal writer (implementation complete; signed-device qualification remains).
- Create synthetic screen/audio fixtures and reference export assertions.
- Run five user workflow interviews.

### Sprint 2

- [x] Import capture artifact into immutable project sources.
- [ ] Generate proxy/waveform cache products from imported sources.
- [x] Add viewer/timeline shell and deterministic trim/split/reorder/delete/undo commands; manual focus event remains.
- Compile a render plan for 16:9 and 9:16 and export both.
- [x] Add deterministic extension/host interruption recovery tests.
- [ ] Force terminate signed device captures at defined points and complete the 50-run recovery gate.
- Usability test the preflight and automatic-draft review model.
