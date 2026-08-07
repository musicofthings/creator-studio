# Competitive analysis

## Market map

The relevant market is not a single category. It is the overlap of screen-first polish, mobile/social editing, spoken-word editing, asynchronous sharing, and live production.

| Product | Center of gravity | Public cost model at research date | Distinctive strengths | Weakness relative to this product thesis |
|---|---|---|---|---|
| Screen Studio | Polished macOS demos | Monthly/annual subscription; legacy one-time licenses acknowledged | Automatic/manual zoom, cursor smoothing/hiding/scaling, responsive vertical reframing, brand frames, local transcripts, simple export | macOS-centered; limited long-form podcast, remote guest, and live-production depth |
| Camtasia | Screen-first editor/training | Free entry plus annual feature tiers | 4K/60 capture, separate sources, editable cursor paths/clicks/keys, annotations, auto zoom/pan, deep timeline, captions and audio tools | Broad and comparatively complex; many advanced/AI capabilities are plan-dependent |
| ScreenFlow | macOS capture + NLE | Paid desktop license/upgrade model | Screen/iOS capture, cursor callouts, annotations, strong timeline | Desktop-first and less opinionated about automatic social reframing |
| Tella | Fast cloud/browser video | Freemium subscription | Clip-based workflow, layouts, safe zones, transcript/subtitles, AI edit, embeds, analytics, comments | Cloud-centric; less control over native capture metadata and deterministic local rendering |
| Loom | Async video communication | Free tier plus per-seat Business/AI subscriptions | Instant sharing, privacy, comments/reactions, viewer analytics, screen/camera/system audio, speaker notes, AI summaries/tasks | Optimized for messages rather than cinematic tutorials or long-form production; subscription/cloud gravity |
| Descript | Transcript-first editing | Freemium subscription | Document-style multitrack audio/video edit, screen/webcam capture, filler removal, overlays | Focus automation and cursor-aware tutorial polish are not the primary wedge |
| Riverside | Remote video podcast | Freemium subscription | Local participant recording, progressive upload, separate 4K/48 kHz tracks, transcript editing, audio cleanup, Magic Clips, show notes | Remote/cloud studio is infrastructure-heavy; weak cursor/tutorial specialization |
| CapCut | Social-first editing | Freemium with Pro/cloud upsell | Templates, automatic captions, highlight extraction, subject tracking, smart 9:16 reframing, large effects ecosystem | General-purpose/social trend focus; less screen semantics, project transparency, and local-first trust |
| Final Cut Pro for iPad | Pro touch NLE | Subscription | Precise touch timeline, multicam, pro capture, keyframes, voiceover, effects, color, live drawing, project transfer | Powerful but not a guided screen-tutorial workflow; subscription and pro-editor learning curve |
| OBS Studio | Live production | Free and open source | Scenes and sources, filters, hotkeys, preview/program, multiview, plugin API | Setup-heavy; minimal guided post-production, captions, social repurposing, and auto focus |

Sources and caveats are collected in [08-research-sources.md](08-research-sources.md).

## Capability comparison

Legend: **●** strong/native, **◐** present or partial, **○** not a core capability. This is a positioning aid based on public product documentation, not a lab benchmark.

| Capability | Screen Studio | Camtasia | Tella | Loom | Descript | Riverside | CapCut | Final Cut iPad | OBS | Proposed mature product |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| Automatic focus zoom for screens | ● | ● | ◐ | ◐ | ○ | ○ | ◐ | ◐ | ○ | ● |
| Post-capture pointer/path control | ● | ● | ◐ | ○ | ○ | ○ | ○ | ○ | ○ | ● on macOS; inferred/manual on iOS |
| Touch-first mobile editor | ○ | ○ | ◐ | ◐ | ◐ | ● | ● | ● | ○ | ● |
| Screen + camera + mic workflow | ● | ● | ● | ● | ● | ● | ◐ | ◐ | ● | ● with platform caveats |
| Transcript-based edit | ○ | ● | ● | ● paid AI | ● | ● | ◐ | ◐ | ○ | Phase 2 |
| Remote isolated guest tracks | ○ | ○ | ○ | ○ | ◐ | ● | ○ | ○ | ◐ via services | Phase 3 |
| Automatic social highlights | ○ | ◐ | ● | ◐ | ● | ● | ● | ◐ | ○ | Phase 2 |
| Responsive multi-aspect layout | ● | ● | ● | ◐ | ● | ● | ● | ● | manual | ● |
| Live scenes/program preview | ○ | ◐ | ○ | ○ | ○ | ● | ● | ○ | ● | Phase 4 |
| Deep annotations/tutorial aids | ◐ | ● | ◐ | ◐ | ◐ | ◐ | ● | ● | plugins | Phase 1–2 |
| Collaboration/share analytics | ◐ | ● | ● | ● | ● | ● | ● | ○ | ○ | Optional later |
| Local-first/no account core | ● | ◐ | ○ | ○ | ◐ | ○ | ◐ | ● | ● | ● |
| Extensibility/plugins | ○ | ◐ | integrations | integrations | integrations | integrations | templates | ○ | ● | Phase 4 |

## Feature lessons by use case

### Social content

The table stakes are not “an editor.” They are speed and format confidence: visual hooks, safe-zone-aware 9:16/1:1/16:9 layouts, dynamic captions, subject or screen-region tracking, saved brand kits, beat/pace tools, reusable templates, thumbnails, and fast batch exports. CapCut demonstrates the importance of automatic reframing and captions; Screen Studio demonstrates that zoom choreography must reflow with the output aspect ratio.

### Podcasts

The table stakes are reliable long recordings, separate synchronized sources, excellent speech audio, waveform and text navigation, speaker-aware captions, silence/filler handling, chapters/show notes, and short-clip extraction. Riverside’s local participant recording protects source quality from network conditions; Descript and Riverside show that transcript editing is now expected. A single-device iOS MVP should not promise remote isolated tracks before progressive upload and recovery are proven.

### Hands-on tutorials

The table stakes are readable actions: automatic or manual focus, pointer/tap emphasis, annotations, privacy blur, keyboard/touch callouts where telemetry exists, voice plus system audio, precise crop, comfortable motion, and a fast correction loop. Screen Studio and Camtasia validate this cluster. On iOS, cross-app touch telemetry is the missing input, so inference and manual focus are part of the core experience rather than fallback settings buried in a menu.

### Live production

The table stakes are separate scenes and sources, preview/program states, audio meters, mute controls, lower thirds, resilient local recording, streaming health, scene hotkeys/remote control, and recovery from connectivity loss. OBS is the reference model. This surface belongs after offline capture and render reliability because it has different latency, networking, and failure requirements.

## White-space opportunity

The credible differentiator is not “all features for one price.” It is a coherent combination:

- Local-first media and on-device baseline intelligence.
- Screen-specific focus automation adapted for touch and multiple aspect ratios.
- One non-destructive edit feeding tutorial, podcast, and social variants.
- A shallow learning curve with an expert escape hatch.
- A paid-once core, with optional compute costs made explicit rather than hidden inside a subscription.

## Strategic choices

### Do

- Win the stop-recording-to-first-export interval.
- Preserve every source separately even if the default UI looks simple.
- Make every automatic decision visible, reversible, and confidence-scored.
- Treat aspect ratio as a render profile over one edit graph, not duplicated projects.
- Use a provider-neutral AI boundary and a fully useful offline path.
- Make project packages portable through Files and external storage.

### Do not

- Build a frame-accurate clone of a desktop NLE in version 1.
- Depend on hidden/private APIs for cross-app touch tracking or capture.
- Require account creation, upload, or AI consent to record/edit/export.
- Promise simultaneous cross-app screen, front camera, and arbitrary system audio combinations without device-level qualification.
- Start with a hosted video platform, CDN, comments, analytics, and teams before the editor earns retention.

## Defensibility

Feature parity is copyable. The defensible assets are a high-quality focus model trained/evaluated on screen interactions, a portable edit graph with responsive layouts, excellent local media reliability, a growing preset/template ecosystem, and an opt-in corpus of user-corrected suggestions. User corrections may be used for improvement only with separate, explicit consent and privacy-preserving collection.
