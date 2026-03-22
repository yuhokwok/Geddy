from __future__ import annotations

import io
import os
from pathlib import Path

from flask import Flask, jsonify, render_template, request, send_file

from .dj_program import DJProgramRequest, DJProgramPlanning, create_default_planner
from .service import (
    DEFAULT_MODEL_ID,
    DEFAULT_OUTPUT_DIR,
    PROJECT_ROOT,
    QwenVoiceDesignService,
    SpeechRequest,
    ValidationError,
)
from .voice_presets import VOICE_PRESETS


def create_app(
    service: QwenVoiceDesignService | None = None,
    planner: DJProgramPlanning | None = None,
) -> Flask:
    app = Flask(
        __name__,
        template_folder=str(Path(__file__).resolve().parent.parent / "templates"),
        static_folder=str(Path(__file__).resolve().parent.parent / "static"),
    )
    app.config["JSON_SORT_KEYS"] = False

    output_dir_value = os.environ.get("QWEN_TTS_OUTPUT_DIR")
    if output_dir_value:
        output_dir = Path(output_dir_value)
        if not output_dir.is_absolute():
            output_dir = PROJECT_ROOT / output_dir
    else:
        output_dir = DEFAULT_OUTPUT_DIR
    service = service or QwenVoiceDesignService(
        model_id=os.environ.get("QWEN_TTS_MODEL", DEFAULT_MODEL_ID),
        output_dir=output_dir,
    )
    planner = planner or create_default_planner()
    app.extensions["tts_service"] = service

    @app.get("/")
    def index():
        return render_template(
            "index.html",
            model_id=service.model_id,
            languages=service.language_options(),
            voice_presets=VOICE_PRESETS,
        )

    @app.get("/health")
    def health():
        return jsonify(
            {
                "status": "ok",
                "model": service.model_id,
                "model_loaded": service.is_model_loaded(),
            }
        )

    @app.get("/api/v1/config")
    def config():
        return jsonify(
            {
                "model": service.model_id,
                "languages": service.language_options(),
                "output_format": "wav",
                "voice_presets": VOICE_PRESETS,
                "endpoints": {
                    "generate": "/api/v1/speech",
                    "program": "/api/v1/dj-program",
                    "audio": "/api/v1/audio/<clip_id>",
                    "health": "/health",
                },
            }
        )

    @app.post("/api/v1/dj-program")
    def dj_program():
        payload = request.get_json(silent=True) if request.is_json else request.form
        program_request = DJProgramRequest.from_payload(dict(payload or {}))
        program = planner.make_program(program_request)
        return jsonify(program.to_api_dict()), 200

    @app.post("/api/v1/speech")
    def synthesize():
        payload = request.get_json(silent=True) if request.is_json else request.form
        speech_request = SpeechRequest.from_payload(dict(payload or {}))
        clip = service.synthesize(speech_request)

        response_mode = (
            request.args.get("response")
            or request.headers.get("X-Response-Mode")
            or "json"
        ).lower()

        if response_mode == "audio":
            download_name = request.args.get("filename") or clip.filename
            return send_file(
                io.BytesIO(clip.audio_bytes),
                mimetype="audio/wav",
                as_attachment=False,
                download_name=download_name,
            )

        body = clip.to_api_dict()
        body["audio_url"] = f"/api/v1/audio/{clip.clip_id}"
        body["download_url"] = f"/api/v1/audio/{clip.clip_id}?download=1"
        return jsonify(body), 201

    @app.get("/api/v1/audio/<clip_id>")
    def audio(clip_id: str):
        audio_path = service.get_clip_path(clip_id)
        download = request.args.get("download") in {"1", "true", "yes"}
        return send_file(
            audio_path,
            mimetype="audio/wav",
            as_attachment=download,
            download_name=audio_path.name,
        )

    @app.get("/api/v1/audio/<clip_id>/metadata")
    def audio_metadata(clip_id: str):
        return jsonify(service.get_clip_metadata(clip_id))

    @app.errorhandler(ValidationError)
    def handle_validation_error(error: ValidationError):
        return jsonify({"error": str(error)}), 400

    @app.errorhandler(FileNotFoundError)
    def handle_not_found(error: FileNotFoundError):
        return jsonify({"error": str(error)}), 404

    return app
