# QwenTTS backend

Small Python backend for `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16` with:

- a browser form at `/`
- a JSON API for an iOS app at `/api/v1/speech`
- a DJ program planning API at `/api/v1/dj-program`
- downloadable WAV files at `/api/v1/audio/<clip_id>`

## Install

```bash
python3 -m pip install -U mlx-audio
python3 -m pip install -r requirements.txt
```

The first synthesis request will download the Qwen model weights if they are not cached already.

## Run

```bash
python3 app.py
```

Open [http://127.0.0.1:8000](http://127.0.0.1:8000).

## API example

```bash
curl -X POST http://127.0.0.1:8000/api/v1/speech \
  -H "Content-Type: application/json" \
  -d '{
    "text": "Welcome to the app.",
    "voice_description": "A confident, friendly narrator with warm tone and crisp diction.",
    "language": "English",
    "temperature": 0.7,
    "max_tokens": 2048
  }'
```

Sample JSON response:

```json
{
  "id": "a9d2f...",
  "filename": "a9d2f....wav",
  "sample_rate": 24000,
  "sample_count": 72480,
  "duration_seconds": 3.02,
  "created_at": "2026-03-21T00:00:00+00:00",
  "model": "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16",
  "request": {
    "text": "Welcome to the app.",
    "voice_description": "A confident, friendly narrator with warm tone and crisp diction.",
    "language": "English",
    "temperature": 0.7,
    "top_k": 50,
    "top_p": 1.0,
    "repetition_penalty": 1.05,
    "max_tokens": 2048
  },
  "audio_url": "/api/v1/audio/a9d2f...",
  "download_url": "/api/v1/audio/a9d2f...?download=1"
}
```

To return raw audio instead of JSON:

```bash
curl -X POST "http://127.0.0.1:8000/api/v1/speech?response=audio" \
  -H "Content-Type: application/json" \
  -o voice.wav \
  -d '{
    "text": "This returns audio directly.",
    "voice_description": "A polished studio announcer with steady pacing."
  }'
```

## Environment variables

- `QWEN_TTS_MODEL`: override the model repo id
- `QWEN_TTS_OUTPUT_DIR`: change where generated WAV and metadata files are stored
- `OPENROUTER_API_KEY`: enables OpenRouter-backed DJ program generation
- `OPENROUTER_MODEL`: override the OpenRouter model, default `anthropic/claude-sonnet-4.6`
- `OPENROUTER_APP_URL`: optional `HTTP-Referer` header for OpenRouter
- `OPENROUTER_APP_TITLE`: optional `X-Title` header for OpenRouter
- `OPENROUTER_TIMEOUT_SECONDS`: request timeout for DJ planning calls

If `OPENROUTER_API_KEY` is not set, `/api/v1/dj-program` falls back to the local rule-based planner.

`/api/v1/dj-program` only returns editorial song suggestions (`titleHint`, `artistHint`, `searchQuery`, `reason`). Apple Music catalog lookup is intentionally left to the iOS app via MusicKit.

## DJ program example

```bash
curl -X POST http://127.0.0.1:8000/api/v1/dj-program \
  -H "Content-Type: application/json" \
  -d '{
    "transcript": "今晚有啲掛住以前拍拖嗰陣",
    "host_style": "一把成熟、溫柔、帶少少磁性嘅香港深夜男 DJ 聲線",
    "desired_song_count": 6
  }'
```

## iOS integration sketch

Use `URLSession` to `POST` JSON to `/api/v1/speech`, then either:

- load `audio_url` into `AVPlayer`
- or call the same endpoint with `?response=audio` and play the returned WAV data directly
