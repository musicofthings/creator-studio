# Creator Studio

Creator Studio is a working codename for an iOS-first, local-first screen recording and creator workflow that can grow into a native macOS product. Its product promise is simple: **capture once, publish as a tutorial, podcast, or social clip without a mandatory subscription**.

This repository is a product-and-engineering bootstrap, not a finished editor. It contains:

- a source-backed competitive analysis and feature model;
- a PRD, TRD, architecture, API/data contracts, and phased roadmap;
- a compiling Swift 6 package graph with domain, capture, storage, media, AI, and export boundaries;
- an iOS application shell and a crash-recoverable ReplayKit broadcast capture foundation;
- an optional, self-hostable TypeScript AI gateway contract;
- tests for the deterministic core.

## Start here

1. Read the [executive brief](docs/00-executive-brief.md).
2. Review the [competitive analysis](docs/01-competitive-analysis.md) and [feature priorities](docs/02-feature-priorities.md).
3. Use the [PRD](docs/03-prd.md) for product scope and the [TRD](docs/04-trd.md) for implementation decisions.
4. Follow the [architecture](docs/05-architecture.md), [API and data model](docs/06-api-and-data-model.md), and [roadmap](docs/07-roadmap.md).

## Local development

Requirements: Xcode 26 or newer for the checked-in project, Swift 6.2, Ruby with the `xcodeproj` gem only when regenerating the Xcode project, and Node.js 20+ only for the optional gateway.

```sh
make lint
make test
make demo
make xcodeproj
```

Open `CreatorStudio.xcodeproj` for the iOS app and broadcast extension. The package can also be opened directly in Xcode.

The app uses placeholder bundle identifiers. Change them in **one** place — `Configuration/identifiers.json` and `CaptureInboxLocation` — then run `make xcodeproj`, which regenerates the entitlements from that file. A drift between the two fails `swift test` rather than silently returning a nil App Group container at runtime. Set your team before device deployment.

The Phase 0 capture foundation writes independent, bounded screen/app-audio/microphone segments into the App Group inbox, journals every committed segment, recovers interrupted sessions, and validates/hashes media before copying it into immutable project sources. See [implementation status](docs/09-implementation-status.md) for the device qualification steps and remaining exit-gate work.

## Repository map

```text
Apps/                     iOS app shell
Configuration/            Bundle/App Group identifiers shared by Swift and the generator
Extensions/               ReplayKit broadcast-upload extension shell
Sources/                   Portable Swift package modules
Tests/                     Deterministic core tests
contracts/                 Optional cloud API contract
services/ai-gateway/       Optional self-hosted AI boundary
docs/                      Product and engineering package
scripts/                   Reproducible project generation
```

## Product boundary

The MVP is not a replacement for Final Cut Pro, OBS, or a remote podcast studio. It is the fastest native path from an iPhone/iPad capture or imported recording to a focused, captioned, branded export. Remote guests, public livestreaming, real-time collaboration, and a plugin marketplace are later phases.

## Privacy stance

Raw media stays on-device by default. Cloud AI is opt-in per job, disabled in the core build, and accessed through a provider-neutral gateway. Any production app must show a conspicuous recording indicator and request explicit consent.
