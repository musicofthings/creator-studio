# Feature priorities

Priority definitions:

- **Must**: required for the first public, paid-quality release in the stated use case.
- **Should**: high-value next release; architecture must not block it.
- **Could**: differentiator or expansion after product-market signal.
- **Won’t yet**: intentionally outside the first 12-month core plan.

## Cross-cutting foundation

| Priority | Features |
|---|---|
| Must | No-account local projects; explicit recording consent/indicator; permission and storage preflight; interruption/crash recovery; import from Photos/Files; separate immutable sources; non-destructive edits; autosave; undo/redo; preview proxy generation; background-safe handoff; progress/cancel; accessibility; export/share; diagnostics bundle without media |
| Should | External-drive projects on iPad; iCloud Drive user-managed sync; project archive/import; duplicate/consolidate media; render queue; keyboard shortcuts; crash-safe resumable analysis |
| Could | Team cloud, comments, review links, analytics, template sharing, automation/Shortcuts actions, plugin SDK |
| Won’t yet | Mandatory account, proprietary cloud-only project format, public social network |

## Social media content

| Priority | Features |
|---|---|
| Must | 9:16, 1:1, and 16:9 canvases; safe-zone overlays; crop/position/scale; auto/manual reframe; animated captions; brand colors/fonts/logo; background/frame/shadow presets; trim/split/reorder; speed; music and ducking; thumbnail frame; 1080p H.264/HEVC; batch aspect exports |
| Should | Hook/title cards; reusable scene templates; beat markers; automatic highlights; silence compression; b-roll/overlay library; caption translation; GIF; 4K where supported; direct share-sheet destinations |
| Could | Trend/template feed, generative b-roll, AI avatar/voice, scheduled publishing, A/B variants, engagement-informed edits |
| Won’t yet | Licensed stock marketplace or a full effects marketplace |

## Podcasts and spoken-word content

| Priority | Features |
|---|---|
| Must | Camera or audio-only capture; long-session storage/thermal checks; waveform; source gain/mute/solo; normalization; basic voice cleanup; fades; chapter markers; on-device transcript; speaker labels when available; caption/SRT/VTT/TXT export; cover art; audio-only AAC/WAV and video export; manual short clips |
| Should | Transcript-based ripple edit; filler/silence detection; loudness target presets; multiband voice enhancement; AI chapters/show notes/titles; automatic short clips; multicam sync by waveform; intro/outro presets |
| Could | Remote guests with local isolated recording and progressive upload; live callers; speech repair with disclosure; feed hosting and distribution |
| Won’t yet | Podcast hosting network, ad marketplace, or synthetic impersonation |

## Recorded hands-on tutorials

| Priority | Features |
|---|---|
| Must | In-app capture; full-screen broadcast-extension ingestion; mic and supported app audio; import; manual focus keyframes; confidence-gated focus suggestions; comfortable zoom motion; crop; tap/click highlight when telemetry exists; arrow/box/text/freehand annotations; static/motion blur for secrets; pause markers; device frame; step/chapter markers; export with burned-in and separate captions |
| Should | Frame-difference/OCR focus inference; automatic static pointer hide; cursor smoothing and resizing on macOS; keystroke display on macOS with permission; transcript-derived steps; automatic dead-time compression; callout tracking; editable tutorial document export |
| Could | Interactive hotspots/quizzes; HTML tutorial export; semantic app integrations that emit exact events; test-run-to-tutorial automation |
| Won’t yet | Hidden global touch logging, private accessibility scraping, or DRM capture bypass |

## Live hands-on production and streaming

| Priority | Features |
|---|---|
| Must for live phase | Scene/source model; preview/program; mic/system/source meters; mute; lower thirds; live annotations; stream health; reconnect; local clean/dirty recording; RTMP output; start/stop controls that remain obvious |
| Should | Multiview on iPad; remote control from iPhone; SRT output; instant replay; chat overlay; stream delay; redundant recording; stream deck/keyboard control on macOS |
| Could | Remote guests, browser sources, plugin/script API, multi-destination restreaming, audience Q&A and polls |
| Won’t yet | CDN/restreaming infrastructure owned by the product |

## Product-wide nice-to-haves

- Teleprompter with gaze-near-lens placement.
- Camera background blur/removal.
- Auto face framing and active-speaker layouts.
- HDR capture/export with explicit color management.
- Multilingual dubbing and captions.
- Pencil-hover scrubbing and haptic edit feedback.
- Project handoff between iPad and Mac.
- Preset/template import/export with signed manifests.
- Privacy detector for emails, tokens, faces, notifications, and password fields.
- Natural-language edit commands that always preview a structured edit diff.

## Release gate rule

No “nice-to-have” may ship by weakening capture recovery, edit determinism, privacy clarity, accessibility, or export correctness. The product earns permission to automate only after it reliably preserves the original media and makes every suggestion reversible.
