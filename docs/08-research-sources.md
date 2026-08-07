# Research sources

Research was captured on 7 August 2026. Product pages change frequently; capabilities and pricing should be rechecked before launch messaging or procurement decisions. Sources are primarily vendor and platform-owner documentation.

## Competitors

- [Screen Studio product page](https://screen.studio/) — automatic/manual zoom, cursor smoothing and hiding, vertical export, brand framing, local transcription, system audio, iOS device recording, 4K/60 export, presets, shortcuts, and crop.
- [Camtasia features](https://www.techsmith.com/camtasia/features/) — separate capture sources, cursor paths/clicks/keystrokes, auto zoom/pan, annotations, text editing, audio processing, captions, templates, and collaboration.
- [Tella documentation](https://www.tella.tv/help/introduction/welcome) — browser/Mac capture, clip editing, canvas sizes, safe zones, transcript/subtitles, AI edit, analytics, embeds, comments, and integrations.
- [Loom plans and feature comparison](https://www.loom.com/pricing) — screen/camera/system audio, speaker notes, drawing/mouse emphasis, privacy, analytics, transcript editing, captions, and AI summaries/chapters/tasks.
- [Descript screen and video recording](https://www.descript.com/blog/article/introducing-descript-video-and-screen-recording) — screen/webcam recording, interactive transcript, filler-word removal, multitrack video, overlays, and document-style editing.
- [Riverside podcast editor](https://riverside.com/tools/podcast-editor) — local 4K/48 kHz remote recording, separate participant tracks, transcript editing, audio cleanup, captions, layouts, show notes, and automatic social clips.
- [CapCut long-video-to-shorts](https://www.capcut.com/tools/long-video-to-shorts) — highlight selection, automatic reframing/subject tracking, caption generation, and social clip exports.
- [OBS Studio](https://obsproject.com/) — real-time source/scene mixing, transitions, audio filters, hotkeys, studio preview, multiview, and plugin/script APIs.
- [Final Cut Pro for iPad overview](https://support.apple.com/guide/final-cut-pro-ipad/what-is-final-cut-pro-for-ipad-devf37af6c23/ipados) — touch-first timeline, multicam, camera capture, keyframes, live drawing, audio effects, voiceover, backgrounds, formats, and project transfer.
- [Final Cut Pro for iPad release notes](https://support.apple.com/102731) — current platform direction, including portrait editing, social creator themes, caption generation, edit detection, and ongoing multicam work.
- [ScreenFlow user guide](https://www.telestream.net/pdfs/user-guides/ScreenFlow-9-User-Guide.pdf) — iOS device recording, screen editing, mouse effects, and callouts; used as category evidence rather than a current pricing source.

## Apple platform and policy

- [ReplayKit](https://developer.apple.com/documentation/replaykit) — app screen, app audio, microphone, recording, capture buffers, and broadcast extensions.
- [ReplayKit system broadcast picker](https://developer.apple.com/documentation/replaykit/rpsystembroadcastpickerview) — system-mediated broadcast selection and Apple’s deprecation direction.
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) — high-performance, selected-content screen/audio capture and the content-sharing picker.
- [Capturing screen content on macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) — display/app/window selection, 60 fps configuration, frame queues, system audio, and microphone outputs.
- [AVVideoComposition](https://developer.apple.com/documentation/avfoundation/avvideocomposition) — time-varying transform, opacity, crop, and custom compositor support.
- [AVVideoCompositing](https://developer.apple.com/documentation/avfoundation/avvideocompositing) — asynchronous custom pixel-buffer composition and HDR/wide-color responsibilities.
- [Speech framework](https://developer.apple.com/documentation/speech) — live/prerecorded recognition, SpeechAnalyzer, SpeechTranscriber, and managed on-device assets.
- [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine) — real-time and offline audio-node processing.
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) — explicit consent and conspicuous indication for recording, data minimization, privacy policy, and explicit disclosure before third-party AI sharing.

## Optional cloud AI

- [OpenAI file transcription](https://developers.openai.com/api/docs/guides/speech-to-text) — bounded-file transcription, supported formats and limits, and the transcription endpoint.
- [OpenAI structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs) — schema-constrained JSON for chapters, titles, clip candidates, and edit suggestions.

## Local SDK verification

The bootstrap was checked against Xcode 26.3 (build 17C519), Swift 6.2.4, iOS 26.2 SDK, and macOS 26.2 SDK. The installed iOS SDK exposes ReplayKit headers including capture and broadcast APIs. The installed macOS SDK exposes ScreenCaptureKit. Because Apple’s web documentation shows a transition beyond the installed SDK, capture framework selection is isolated behind adapters and must be revalidated at each Xcode upgrade.
