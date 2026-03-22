from __future__ import annotations

import io
import json
import threading
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf

PROJECT_ROOT = Path(__file__).resolve().parent.parent
LEGACY_OUTPUT_DIR = Path(__file__).resolve().parent / "generated_audio"
DEFAULT_MODEL_ID = "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16"
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "generated_audio"
DEFAULT_LANGUAGE_OPTIONS = ["auto", "English", "Chinese", "Japanese", "Korean"]


class ValidationError(ValueError):
    """Raised when a synthesis request is invalid."""


@dataclass(slots=True)
class SpeechRequest:
    text: str
    voice_description: str
    language: str = "English"
    temperature: float = 0.7
    top_k: int = 50
    top_p: float = 1.0
    repetition_penalty: float = 1.05
    max_tokens: int = 2048

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> "SpeechRequest":
        text = str(payload.get("text", "")).strip()
        voice_description = str(
            payload.get("voice_description", payload.get("instruct", ""))
        ).strip()
        language = str(payload.get("language", payload.get("lang_code", "English")))
        temperature = _coerce_float(payload.get("temperature", 0.7), "temperature")
        top_k = _coerce_int(payload.get("top_k", 50), "top_k")
        top_p = _coerce_float(payload.get("top_p", 1.0), "top_p")
        repetition_penalty = _coerce_float(
            payload.get("repetition_penalty", 1.05), "repetition_penalty"
        )
        max_tokens = _coerce_int(payload.get("max_tokens", 2048), "max_tokens")

        if not text:
            raise ValidationError("`text` is required.")
        if not voice_description:
            raise ValidationError(
                "`voice_description` is required for the VoiceDesign model."
            )
        if len(text) > 4000:
            raise ValidationError("`text` is too long. Keep it under 4000 characters.")
        if len(voice_description) > 1000:
            raise ValidationError(
                "`voice_description` is too long. Keep it under 1000 characters."
            )
        if not 0.0 <= temperature <= 2.0:
            raise ValidationError("`temperature` must be between 0.0 and 2.0.")
        if top_k < 0 or top_k > 200:
            raise ValidationError("`top_k` must be between 0 and 200.")
        if not 0.0 < top_p <= 1.0:
            raise ValidationError("`top_p` must be between 0.0 and 1.0.")
        if repetition_penalty < 1.0 or repetition_penalty > 2.0:
            raise ValidationError(
                "`repetition_penalty` must be between 1.0 and 2.0."
            )
        if max_tokens < 64 or max_tokens > 4096:
            raise ValidationError("`max_tokens` must be between 64 and 4096.")

        return cls(
            text=text,
            voice_description=voice_description,
            language=language.strip() or "English",
            temperature=temperature,
            top_k=top_k,
            top_p=top_p,
            repetition_penalty=repetition_penalty,
            max_tokens=max_tokens,
        )


@dataclass(slots=True)
class GeneratedClip:
    clip_id: str
    filename: str
    path: Path
    sample_rate: int
    sample_count: int
    duration_seconds: float
    created_at: str
    model_id: str
    request: SpeechRequest
    audio_bytes: bytes

    def to_api_dict(self) -> dict[str, Any]:
        return {
            "id": self.clip_id,
            "filename": self.filename,
            "sample_rate": self.sample_rate,
            "sample_count": self.sample_count,
            "duration_seconds": round(self.duration_seconds, 3),
            "created_at": self.created_at,
            "model": self.model_id,
            "request": asdict(self.request),
        }


class QwenVoiceDesignService:
    def __init__(
        self,
        model_id: str = DEFAULT_MODEL_ID,
        output_dir: Path | str = DEFAULT_OUTPUT_DIR,
    ) -> None:
        self.model_id = model_id
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self._model = None
        self._model_lock = threading.Lock()
        self._generation_lock = threading.Lock()

    def is_model_loaded(self) -> bool:
        return self._model is not None

    def language_options(self) -> list[str]:
        if self._model is None:
            return DEFAULT_LANGUAGE_OPTIONS
        getter = getattr(self._model, "get_supported_languages", None)
        if callable(getter):
            values = [str(item) for item in getter()]
            return values or DEFAULT_LANGUAGE_OPTIONS
        return DEFAULT_LANGUAGE_OPTIONS

    def get_clip_path(self, clip_id: str) -> Path:
        return self._find_existing_clip_path(clip_id, "wav")

    def get_clip_metadata(self, clip_id: str) -> dict[str, Any]:
        path = self._find_existing_clip_path(clip_id, "json")
        return json.loads(path.read_text(encoding="utf-8"))

    def synthesize(self, speech_request: SpeechRequest) -> GeneratedClip:
        model = self._load_model()

        with self._generation_lock:
            results = list(
                model.generate_voice_design(
                    text=speech_request.text,
                    instruct=speech_request.voice_description,
                    language=speech_request.language,
                    temperature=speech_request.temperature,
                    max_tokens=speech_request.max_tokens,
                    top_k=speech_request.top_k,
                    top_p=speech_request.top_p,
                    repetition_penalty=speech_request.repetition_penalty,
                    verbose=False,
                )
            )

        if not results:
            raise RuntimeError("The model finished without producing audio.")

        sample_rate = int(results[0].sample_rate)
        chunks = [np.asarray(result.audio, dtype=np.float32) for result in results]
        waveform = np.concatenate(chunks) if len(chunks) > 1 else chunks[0]

        clip_id = uuid.uuid4().hex
        filename = f"{clip_id}.wav"
        file_path = self.output_dir / filename
        sf.write(file_path, waveform, sample_rate, format="WAV")

        audio_bytes = file_path.read_bytes()
        created_at = datetime.now(timezone.utc).isoformat()
        clip = GeneratedClip(
            clip_id=clip_id,
            filename=filename,
            path=file_path,
            sample_rate=sample_rate,
            sample_count=int(waveform.shape[0]),
            duration_seconds=float(waveform.shape[0] / sample_rate),
            created_at=created_at,
            model_id=self.model_id,
            request=speech_request,
            audio_bytes=audio_bytes,
        )

        metadata_path = self.output_dir / f"{clip_id}.json"
        metadata_path.write_text(
            json.dumps(clip.to_api_dict(), indent=2),
            encoding="utf-8",
        )
        return clip

    def _load_model(self):
        if self._model is not None:
            return self._model

        with self._model_lock:
            if self._model is None:
                from mlx_audio.tts import load as load_tts_model

                self._model = load_tts_model(self.model_id)
        return self._model

    def _find_existing_clip_path(self, clip_id: str, suffix: str) -> Path:
        candidates = [
            self.output_dir / f"{clip_id}.{suffix}",
            LEGACY_OUTPUT_DIR / f"{clip_id}.{suffix}",
        ]
        for candidate in candidates:
            if candidate.exists():
                return candidate
        raise FileNotFoundError(f"No {suffix} file found for clip '{clip_id}'.")


def _coerce_float(value: Any, field_name: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"`{field_name}` must be a number.") from exc


def _coerce_int(value: Any, field_name: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"`{field_name}` must be an integer.") from exc
