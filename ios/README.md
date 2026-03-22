# AI 鄭子誠 iOS frontend

This folder contains a SwiftUI iOS app prototype for an AI radio DJ called `AI 鄭子誠`.

## What it does

- records voice input and transcribes it with `SpeechAnalyzer`
- plans a radio-style show rundown
- searches Apple Music for 5-8 matching songs
- sends intro / bridge / outro monologues to the Qwen TTS backend
- plays spoken clips and songs in order
- supports background audio and Control Centre play / pause / previous song / next song

## Open in Xcode

From this folder:

```bash
xcodegen generate
open QwenTTSiOS.xcodeproj
```

## Backend URL tips

- iOS Simulator: `http://127.0.0.1:8000` usually works when the Flask app runs on the same Mac
- Physical iPhone: use your Mac's local network IP, for example `http://192.168.1.20:8000`

The app enables non-HTTPS transport in `Info.plist` for local development against the Flask server.

## Current architecture note

The app first tries a backend endpoint at `/api/v1/dj-program` for AI show planning.
If that endpoint is not available yet, it falls back to a built-in prototype planner with curated Cantopop suggestions and radio-style monologue templates, while still using the real Qwen TTS backend for speech generation.
