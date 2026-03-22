import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import qwen_tts.dj_program as dj_program_module
from qwen_tts.dj_program import (
    DJProgramRequest,
    OpenRouterBackedDJProgramPlanner,
    OpenRouterDJProgramPlanner,
    RuleBasedDJProgramPlanner,
    create_default_planner,
)
from qwen_tts.service import GeneratedClip, SpeechRequest
from qwen_tts.web import create_app


class FakeService:
    def __init__(self):
        self.model_id = "fake-model"
        self._tmpdir = Path(tempfile.mkdtemp())
        self._latest_clip = None

    def language_options(self):
        return ["English", "Chinese"]

    def is_model_loaded(self):
        return True

    def synthesize(self, speech_request: SpeechRequest):
        clip_id = "clip123"
        audio_path = self._tmpdir / f"{clip_id}.wav"
        audio_bytes = b"RIFFtest-wave"
        audio_path.write_bytes(audio_bytes)
        clip = GeneratedClip(
            clip_id=clip_id,
            filename=audio_path.name,
            path=audio_path,
            sample_rate=24000,
            sample_count=24000,
            duration_seconds=1.0,
            created_at="2026-03-21T00:00:00+00:00",
            model_id=self.model_id,
            request=speech_request,
            audio_bytes=audio_bytes,
        )
        self._latest_clip = clip
        (self._tmpdir / f"{clip_id}.json").write_text(
            '{"id":"clip123","model":"fake-model"}',
            encoding="utf-8",
        )
        return clip

    def get_clip_path(self, clip_id: str):
        return self._tmpdir / f"{clip_id}.wav"

    def get_clip_metadata(self, clip_id: str):
        return {"id": clip_id, "model": self.model_id}


class AppTestCase(unittest.TestCase):
    def setUp(self):
        self.fake_service = FakeService()
        self.app = create_app(service=self.fake_service)
        self.client = self.app.test_client()

    def test_index_page_renders(self):
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"Qwen3 VoiceDesign Backend", response.data)
        self.assertIn(b"Voice preset", response.data)
        self.assertIn(b"DJ Program Interview", response.data)

    def test_config_includes_voice_presets(self):
        response = self.client.get("/api/v1/config")
        self.assertEqual(response.status_code, 200)
        payload = response.get_json()
        self.assertIn("voice_presets", payload)
        self.assertGreater(len(payload["voice_presets"]), 0)

    def test_json_api_returns_clip_metadata(self):
        response = self.client.post(
            "/api/v1/speech",
            json={
                "text": "Hello world",
                "voice_description": "A bright narrator voice.",
            },
        )
        self.assertEqual(response.status_code, 201)
        payload = response.get_json()
        self.assertEqual(payload["id"], "clip123")
        self.assertEqual(payload["audio_url"], "/api/v1/audio/clip123")

    def test_program_api_returns_show_structure(self):
        response = self.client.post(
            "/api/v1/dj-program",
            json={
                "transcript": "今晚有啲掛住以前嘅感情",
                "desired_song_count": 6,
            },
        )
        self.assertEqual(response.status_code, 200)
        payload = response.get_json()
        self.assertIn("showTitle", payload)
        self.assertEqual(len(payload["songSuggestions"]), 6)
        self.assertEqual(len(payload["bridgeMonologues"]), 5)
        self.assertIn("voiceDescription", payload)
        self.assertIn("searchQuery", payload["songSuggestions"][0])
        self.assertNotIn("appleMusicID", payload["songSuggestions"][0])

    def test_program_request_validates_song_count_range(self):
        with self.assertRaisesRegex(ValueError, "between 5 and 8"):
            DJProgramRequest.from_payload({"transcript": "hello", "desired_song_count": 3})

    def test_rule_based_planner_uses_time_neutral_copy(self):
        planner = RuleBasedDJProgramPlanner()
        program = planner.make_program(
            DJProgramRequest.from_payload(
                {"transcript": "最近有點掛住以前的感情", "desired_song_count": 6}
            )
        )

        combined_text = "\n".join(
            [program.openingMonologue, program.closingMonologue]
            + [bridge.text for bridge in program.bridgeMonologues]
        )
        self.assertNotIn("夜深啦", combined_text)
        self.assertNotIn("今晚", combined_text)

    def test_create_default_planner_uses_module_constant_for_openrouter_key(self):
        with patch.object(dj_program_module, "OPENROUTER_API_KEY", ""):
            planner = create_default_planner()

        self.assertIsInstance(planner, OpenRouterBackedDJProgramPlanner)
        self.assertIsNone(planner.primary)

    def test_openrouter_planner_uses_json_schema_response_format(self):
        planner = OpenRouterDJProgramPlanner(api_key="test-key")
        response_format = planner._response_format(desired_song_count=6)

        self.assertEqual(response_format["type"], "json_schema")
        self.assertEqual(response_format["json_schema"]["name"], "geddy_dj_program")
        self.assertTrue(response_format["json_schema"]["strict"])
        schema = response_format["json_schema"]["schema"]
        self.assertEqual(schema["type"], "object")
        self.assertIn("songSuggestions", schema["properties"])
        self.assertNotIn("minItems", schema["properties"]["songSuggestions"])
        self.assertNotIn("maxItems", schema["properties"]["bridgeMonologues"])
        self.assertIn("exactly 6 items", schema["properties"]["songSuggestions"]["description"])
        self.assertIn("exactly 5 items", schema["properties"]["bridgeMonologues"]["description"])

    def test_audio_response_mode_returns_wav(self):
        response = self.client.post(
            "/api/v1/speech?response=audio",
            json={
                "text": "Hello world",
                "voice_description": "A bright narrator voice.",
            },
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.mimetype, "audio/wav")

    def test_validation_error_returns_400(self):
        response = self.client.post("/api/v1/speech", json={"text": ""})
        self.assertEqual(response.status_code, 400)
        self.assertIn("required", response.get_json()["error"])


if __name__ == "__main__":
    unittest.main()
