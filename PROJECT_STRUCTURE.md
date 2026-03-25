# Geddy / 音樂情人 App Structure

## Overview

This repository contains two main parts:

1. A Python backend that provides:
   - a browser demo page
   - a speech synthesis API
   - a DJ program planning API
   - generated WAV file download endpoints
2. An iOS app built with SwiftUI that:
   - records the user's voice
   - transcribes it into text
   - asks the backend for a radio-style show draft
   - searches Apple Music locally on device
   - asks the backend to synthesize spoken clips
   - plays speech clips and songs in sequence

The product idea is an emotional music companion app, branded in the iOS app as `Geddy` and described here as a `音樂情人` experience. The hosting style can feel like a midnight radio DJ, but product behavior should not assume the user is only using the app at night.

## Revised Product Direction

The structure should be understood with these product requirements in mind:

1. The user may request a song list at any time of day.
2. The tone can keep the warm, intimate, "midnight radio" style even when the actual time is morning, afternoon, or evening.
3. Playback should begin as soon as the first 3 spoken tracks are ready, instead of waiting for every spoken track in the whole program.
4. Song skip controls should become usable as soon as playback begins.
5. The loading state should no longer block the whole show until all clips are generated.
6. Remaining spoken clips should continue generating in the background while playback is already underway.
7. If possible, spoken clips should be enqueued in the same playback system as songs, but this needs an implementation feasibility check.

## Top-Level Repository Layout

```text
/
|- app.py
|- qwen_tts/
|- templates/
|- static/
|- generated_audio/
|- tests/
|- ios/
|- requirements.txt
|- README.md
```

## Backend Structure

### Entry point

- `app.py`
  - imports `create_app()` from `qwen_tts.web`
  - runs the Flask app on `0.0.0.0:8000` in debug mode

### Core backend package

- `qwen_tts/web.py`
  - creates the Flask application
  - wires together the TTS service and DJ planner
  - serves:
    - `/` web form
    - `/health`
    - `/api/v1/config`
    - `/api/v1/dj-program`
    - `/api/v1/speech`
    - `/api/v1/audio/<clip_id>`
    - `/api/v1/audio/<clip_id>/metadata`
  - returns JSON validation errors and file-not-found errors cleanly

- `qwen_tts/service.py`
  - contains the speech synthesis domain logic
  - defines:
    - `SpeechRequest`
    - `GeneratedClip`
    - `QwenVoiceDesignService`
    - `ValidationError`
  - lazily loads the MLX Qwen TTS model
  - synthesizes audio, writes `.wav` and `.json` metadata files to `generated_audio/`
  - supports looking up existing generated clips by ID

- `qwen_tts/dj_program.py`
  - contains the DJ show planning domain logic
  - defines:
    - request/response models for show generation
    - `DJProgramPlanning` protocol
    - OpenRouter-backed planner
    - fallback theme-based planning helpers
  - backend output is editorial only:
    - title hints
    - artist hints
    - search queries
    - reasons
  - Apple Music catalog resolution is intentionally left to iOS

- `qwen_tts/voice_presets.py`
  - provides backend-defined voice preset data
  - consumed by `/api/v1/config`
  - allows the iOS app to sync available voice styles from the server

- `qwen_tts/__init__.py`
  - package exports for the main backend types

### Backend UI and assets

- `templates/index.html`
  - browser UI for manually testing the VoiceDesign backend
  - includes form submission to `/api/v1/speech`

- `static/`
  - static assets used by the Flask frontend

### Backend output and tests

- `generated_audio/`
  - stores synthesized WAV files and per-clip JSON metadata

- `tests/test_app.py`
  - backend test coverage for:
    - index page rendering
    - config endpoint
    - speech JSON response
    - speech raw audio response
    - DJ program API structure
    - request validation behavior

### Backend dependencies

- `requirements.txt`
  - `Flask`
  - `mlx-audio`
  - `numpy`
  - `soundfile`

### Backend runtime behavior

- Default model: `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16`
- Optional environment variables:
  - `QWEN_TTS_MODEL`
  - `QWEN_TTS_OUTPUT_DIR`
  - `OPENROUTER_API_KEY`
  - `OPENROUTER_MODEL`
  - `OPENROUTER_APP_URL`
  - `OPENROUTER_APP_TITLE`
  - `OPENROUTER_TIMEOUT_SECONDS`

If `OPENROUTER_API_KEY` is missing, the DJ program API falls back to local rule-based planning logic.

## iOS App Structure

### Project shell

- `ios/project.yml`
  - XcodeGen project definition
  - target name: `QwenTTSiOS`
  - iOS deployment target: `17.0`

- `ios/QwenTTSiOS.xcodeproj`
  - generated Xcode project checked into the repo

- `ios/README.md`
  - explains how to generate/open the project
  - documents local backend URL usage for simulator vs physical device

### App entry point

- `ios/QwenTTSiOS/Sources/QwenTTSiOSApp.swift`
  - SwiftUI `@main` app
  - configures audio session on launch
  - loads `ContentView`

### UI layer

- `ios/QwenTTSiOS/Sources/Views/ContentView.swift`
  - single-screen SwiftUI interface
  - sections include:
    - app overview / hero section
    - backend URL configuration
    - voice recording and transcript input
    - voice preset and host style configuration
    - show generation button
    - generated playlist and spoken clip cards
    - playback controls

### View model / orchestration

- `ios/QwenTTSiOS/Sources/ViewModels/RadioDJViewModel.swift`
  - central app coordinator
  - responsibilities:
    - bootstrap backend config
    - manage server URL and selected voice preset
    - start/stop recording
    - request a DJ program draft
    - fall back to on-device or rule-based planners if needed
    - resolve songs through Apple Music
    - synthesize opening / bridge / closing speech clips
    - cache generated shows locally
    - start playback through the playback coordinator
  - this is the main integration point between backend APIs and iOS services

### Networking

- `ios/QwenTTSiOS/Sources/Networking/DJBackendClient.swift`
  - `URLSession` client for backend endpoints
  - fetches:
    - `/api/v1/config`
    - `/api/v1/dj-program`
    - `/api/v1/speech`
  - downloads synthesized WAV audio returned by the backend
  - normalizes relative audio URLs into absolute URLs

### Models

- `ios/QwenTTSiOS/Sources/Models/RadioDJModels.swift`
  - shared iOS models for:
    - backend config
    - speech request/response
    - DJ program request/response
    - song suggestions
    - bridge monologues
    - show drafts
    - resolved Apple Music songs
    - spoken clips
    - voice presets
    - playback items / show objects
  - includes fallback voice presets even when backend config is unavailable

### Services

- `ios/QwenTTSiOS/Sources/Services/SpeechCaptureService.swift`
  - records microphone input
  - requests microphone and speech recognition permissions
  - transcribes audio using:
    - `SpeechAnalyzer` / `SpeechTranscriber` on supported systems
    - `SFSpeechRecognizer` fallback otherwise

- `ios/QwenTTSiOS/Sources/Services/AppleMusicCatalogService.swift`
  - requests Apple Music authorization
  - takes backend song suggestions and searches Apple Music catalog
  - resolves them into playable `Song` items

- `ios/QwenTTSiOS/Sources/Services/PrototypeShowPlanner.swift`
  - local fallback planning stack
  - tries:
    - on-device Foundation Models planning when available
    - rule-based theme packs otherwise
  - keeps the app usable even if backend planning fails

- `ios/QwenTTSiOS/Sources/Services/DJProgramCacheStore.swift`
  - stores generated show manifests and local speech clips
  - uses a content signature based on transcript, voice style, song count, server URL, and model name
  - enables reusing previously generated shows

- `ios/QwenTTSiOS/Sources/Services/StationPlaybackCoordinator.swift`
  - controls sequential playback of:
    - generated spoken WAV clips via `AVAudioPlayer`
    - Apple Music tracks via `ApplicationMusicPlayer`
  - supports remote commands and background audio behavior

- `ios/QwenTTSiOS/Sources/Services/AppAudioSessionConfigurator.swift`
  - sets playback audio session defaults during app launch

### iOS resources and permissions

- `ios/QwenTTSiOS/Resources/Info.plist`
  - enables local non-HTTPS networking for development
  - declares permissions for:
    - Apple Music
    - microphone
    - speech recognition
  - enables background audio mode

## Current End-to-End App Flow

1. User enters text or records a voice note in the iOS app.
2. iOS transcribes voice input into text.
3. `RadioDJViewModel` requests backend config from `/api/v1/config`.
4. iOS sends the transcript and host style to `/api/v1/dj-program`.
5. Backend returns:
   - show title
   - mood summary
   - opening monologue
   - song suggestions
   - bridge monologues
   - closing monologue
   - voice description
6. iOS searches Apple Music locally using each `searchQuery`.
7. iOS sends opening / bridge / closing texts to `/api/v1/speech`.
8. iOS synthesizes all spoken clips before playback begins.
9. Backend returns WAV metadata plus audio URLs.
10. iOS downloads all spoken WAV files and stores them locally.
11. Only after the full show is assembled does `StationPlaybackCoordinator` start playback.

## Current Playback Limitation

The current implementation is still "batch-first":

- `RadioDJViewModel.synthesizeShow(...)` generates the opening clip, every bridge clip, and the closing clip before returning a `RadioShow`.
- `prepareShow()` keeps `isPreparingShow = true` until all of those clips are done.
- `playbackCoordinator.loadAndPlay(...)` only runs after the entire `playbackItems` array is ready.

This explains the present behavior:

- the loading indicator stays visible until every spoken track is loaded
- skip buttons exist in the UI, but the user cannot really use them early because playback has not started yet
- the user waits for the whole package instead of hearing the show progressively

## Target Runtime Flow

The intended structure should move to a progressive pipeline:

1. User submits text or voice input at any time of day.
2. iOS creates the show draft and resolves Apple Music songs.
3. iOS immediately starts synthesizing spoken clips in priority order.
4. Priority order should be:
   - opening monologue
   - first bridge
   - second bridge
   - remaining bridges
   - closing monologue
5. As soon as the first 3 spoken tracks are ready, the app should assemble a playable partial queue and begin playback.
6. While playback is running, the app should continue synthesizing and appending the remaining spoken clips in the background.
7. Skip controls should operate against the currently available playable queue, without waiting for the tail of the show to finish generating.

## Recommended Structural Revision

### 1. Separate show planning from show hydration

The current `prepareShow()` path does too much in one blocking operation. It should be split into stages:

- `planShow`
  - fetch backend draft or fallback draft
  - resolve Apple Music songs
  - build a skeletal show timeline with placeholders for spoken clips

- `hydratePlayableWindow`
  - synthesize only the first 3 spoken tracks needed for an initial playback window
  - mark the show as playable

- `hydrateRemainingSpeech`
  - continue synthesizing the rest of the spoken clips as a background task
  - progressively update the timeline and cache

### 2. Introduce progressive playback state

The app needs state beyond just `isPreparingShow`:

- `isPlanningShow`
- `isPreparingInitialPlayback`
- `isBackgroundGeneratingSpeech`
- `isPlayable`
- `readySpokenClipCount`

This lets the UI show a more truthful status, for example:

- "正在整理歌單與節目稿"
- "首 3 段獨白準備中"
- "節目已開始播放，其餘獨白會繼續生成"

### 3. Make the timeline appendable

`RadioShow` / `StationPlaybackItem` should evolve from a fully-complete immutable playback package into an appendable timeline model.

Recommended direction:

- keep a stable ordered show timeline from the moment the draft is ready
- allow spoken items to exist in one of several states:
  - placeholder
  - generating
  - ready
  - failed
- let playback coordinator move through the ready items and wait only when it reaches a missing spoken clip that has not finished yet

### 4. Prioritize song continuity over full speech completion

The user expectation is "start the program quickly" rather than "wait for a perfect full bundle."

That means:

- songs should be playable as soon as the initial spoken window is ready
- next / previous song should work once playback has started
- the loading spinner should no longer represent "entire show not ready"
- later spoken clips can finish just-in-time before their turn

### 5. Treat "midnight style" as persona, not schedule

The structure should not hardcode time-of-day assumptions into show generation.

Recommended content rule:

- keep the soothing, intimate, emotional DJ persona
- avoid language that incorrectly assumes it is currently midnight
- let the draft generator describe a "midnight radio feeling" without claiming the real-world time

This mainly affects:

- backend planning prompts in `qwen_tts/dj_program.py`
- local fallback copy in `PrototypeShowPlanner.swift`
- hero text and status copy in `ContentView.swift`

## Recommended Module-Level Changes

### Backend

The backend can stay mostly the same structurally:

- `/api/v1/dj-program` remains a planning endpoint
- `/api/v1/speech` remains a per-clip synthesis endpoint

Possible improvement:

- optionally support a lighter-weight "program draft only" contract explicitly optimized for immediate playback sequencing, but this is not strictly required because the current APIs already allow per-clip generation.

### iOS view model

`RadioDJViewModel` should become the progressive orchestrator:

- stage 1: draft + Apple Music resolution
- stage 2: first-play window synthesis
- stage 3: immediate playback start
- stage 4: background synthesis of remaining spoken clips
- stage 5: incremental cache persistence

### iOS models

Recommended additions:

- a speech clip readiness status
- a partial / progressive show session model
- a queue window model for "currently guaranteed playable" content

### Playback coordinator

`StationPlaybackCoordinator` should move from "load one complete array and play it" toward:

- loading an initial playable queue
- accepting appended or upgraded playback items later
- preserving next / previous song behavior while speech clips continue arriving

## ApplicationMusicPlayer Feasibility Note

Using `ApplicationMusicPlayer` for spoken clips is probably not the right target for app-generated WAV files.

Why:

- the current app uses `ApplicationMusicPlayer` through MusicKit for Apple Music `Song` items
- Apple Music / MusicKit playback queues are designed around playable music items and their play parameters, not arbitrary app-generated local WAV files
- the current speech playback path uses `AVAudioPlayer`, which is the Apple API specifically designed for local file playback

Practical recommendation:

- keep `ApplicationMusicPlayer` for Apple Music songs
- keep spoken clips in an app-controlled audio path such as `AVAudioPlayer` or consider `AVQueuePlayer` if you want better queue semantics for local audio
- unify them at the coordinator/state-machine layer rather than forcing both media types into the same player

So the better structural goal is:

- one logical queue
- two underlying playback engines
- one coordinator that hands off between them cleanly

## Suggested Next Implementation Order

1. Refactor `prepareShow()` so it no longer waits for every spoken clip.
2. Generate only the first 3 spoken tracks up front.
3. Start playback immediately after those first 3 tracks are ready.
4. Run remaining spoken synthesis in background tasks.
5. Update UI loading states so playback and generation can coexist.
6. Make playback coordinator accept incremental timeline updates.
7. Revisit whether `AVQueuePlayer` is useful for spoken clips, while keeping `ApplicationMusicPlayer` for songs.

## Architectural Split

### What lives in the backend

- TTS model loading and speech generation
- generated audio file persistence
- backend config and voice preset exposure
- DJ show planning via OpenRouter or local fallback logic
- browser test interface

### What lives in the iOS app

- recording and transcription
- Apple Music authorization and catalog search
- playlist resolution
- playback orchestration
- local caching of finished programs
- user interface and interaction flow

## Important Notes For Future Work

- The backend does not resolve actual Apple Music catalog IDs.
- The iOS app is responsible for making editorial suggestions playable.
- The app is designed to continue working even when the backend planning API is unavailable.
- The biggest structural change ahead is on iOS orchestration and playback, not on the backend API surface.
- The repo currently has a compact architecture: most important logic is concentrated in a small number of backend Python files and iOS Swift files, so the main implementation work will likely center on `RadioDJViewModel`, `StationPlaybackCoordinator`, and the playback-related models.
