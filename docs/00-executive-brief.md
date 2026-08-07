# Executive brief

**Research date:** 7 August 2026  
**Working title:** Creator Studio  
**Recommended launch surface:** iPhone and iPad, with macOS capture/editor expansion  
**Business model:** paid download or optional paid upgrades; no mandatory subscription; cloud compute is bring-your-own or usage-based and opt-in

## Recommendation

Build a local-first creator tool around one wedge: **record or import once, then automatically produce a clear tutorial and correctly framed social variants**. Do not begin by cloning every feature in a desktop NLE or remote podcast platform.

The market is split across five strengths:

1. Screen Studio makes desktop tutorials look polished through automatic zoom, cursor treatment, framing, and opinionated defaults.
2. Camtasia and ScreenFlow provide deep screen-first editing and annotation.
3. Descript and Riverside make long-form speech editable as text and turn podcasts into clips.
4. CapCut and Final Cut Pro for iPad optimize touch editing, reframing, captions, and social finishing.
5. OBS is the benchmark for live scenes, source mixing, hotkeys, and extensibility.

No leading product in this set combines Screen Studio-like focus automation, podcast repurposing, an excellent touch-first editor, local-first privacy, and a non-subscription core. That is the opportunity—but it is also too large for one release.

## Product thesis

The product should be a **guided compositor**, not a miniature desktop editor. It records or imports separate media, interaction, transcript, and edit metadata; generates editable focus/caption/clip suggestions; and renders multiple aspect ratios from one non-destructive project.

The first successful workflow is:

1. Choose Tutorial, Social, Podcast, or Import.
2. Complete a capture preflight for permissions, microphone, storage, thermal state, and privacy.
3. Record screen or camera with microphone, or import existing tracks.
4. Receive an editable draft containing cuts, focus zooms, captions, audio leveling, and brand framing.
5. Export 16:9, 9:16, or 1:1 without rebuilding the edit.

## Platform reality

iOS system capture is more constrained than macOS capture. The checked Xcode 26.3 / iOS 26.2 SDK contains ReplayKit for in-app capture and broadcast extensions, while ScreenCaptureKit is present in the macOS SDK. Apple’s online documentation also describes a broader ScreenCaptureKit direction and deprecates the ReplayKit broadcast picker. The implementation therefore uses a capture protocol with feature-gated adapters rather than embedding either framework into the domain model.

For cross-app iOS recordings, global touch coordinates and semantic UI events are not generally available. Automatic focus must combine:

- exact app-authored events when recording an integrated app or imported event log;
- pointer/click metadata on macOS where permission permits;
- frame differencing, OCR, saliency, and layout change detection;
- audio/transcript emphasis;
- fast manual correction.

This limitation is a product constraint, not a reason to postpone the iOS app: social, podcast, camera, import, manual focus, captions, and inference-assisted tutorials remain valuable.

## MVP scope

- In-app screen recording and system broadcast-extension ingestion.
- Camera or audio-only recording, plus media import.
- Crash-recoverable project packages and non-destructive edit graph.
- Trim, split, reorder, crop, speed, picture-in-picture, voiceover, gain, fades, and undo/redo.
- Manual and suggested focus zooms with comfortable motion rules.
- On-device transcription where supported, caption correction, animated and accessibility caption exports.
- Brand presets, safe-zone preview, 16:9/9:16/1:1 exports, H.264 and HEVC.
- Audio normalization, basic voice cleanup, and music ducking.
- Files/Photos/share-sheet output; no account required.

## Explicitly later

- Remote guest recording and progressive upload.
- Public RTMP/SRT livestreaming and a full live control room.
- Transcript-based ripple editing and generative speech repair.
- Multi-user cloud collaboration, hosted share pages, viewer analytics, and direct social publishing.
- Plugin marketplace, template commerce, AI avatars, and generative video.

## Success bar

For a five-minute source capture on a supported device, a new user should produce a polished 1080p tutorial or vertical clip in under ten minutes, with no crash, no lost recording, readable captions, and no mandatory upload. The key metric is **median time from capture stop to first accepted export**; the first target is under 2× source duration and the mature target is under 0.5×.

## Primary risks

- ReplayKit/broadcast lifecycle, extension memory pressure, interruption recovery, and camera limitations.
- Thermal and storage pressure during simultaneous capture, analysis, and render.
- Bad automatic zoom is worse than no zoom; comfort constraints and confidence thresholds are mandatory.
- Long-form multitrack editing can consume the roadmap unless the MVP remains a guided editor.
- App Review and privacy failures if recording state or cloud disclosure is ambiguous.

The phased plan in [07-roadmap.md](07-roadmap.md) converts these risks into early technical spikes and measurable exit gates.
