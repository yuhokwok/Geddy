from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Protocol
from urllib import error as urllib_error
from urllib import request as urllib_request

from .service import ValidationError

DEFAULT_HOST_STYLE = """
一把成熟、溫柔、帶少少磁性嘅香港深夜男 DJ 聲線，
說話節奏從容，情感細膩，像在凌晨電台陪伴失眠聽眾，
廣東話口吻自然，帶感性而不誇張的陪伴感。
""".strip()

DEFAULT_OPENROUTER_MODEL = "z-ai/glm-5"
#"openai/gpt-4o-mini"
#"anthropic/claude-sonnet-4.6"
OPENROUTER_API_URL = "https://openrouter.ai/api/v1/chat/completions"
OPENROUTER_API_KEY_CONFIG_PATH = (
    Path(__file__).resolve().parent / "openrouter_api_key.json"
)
SONG_CATEGORY_CANTONESE = "cantonese"
SONG_CATEGORY_MANDARIN = "mandarin"
SUPPORTED_SONG_CATEGORIES = {
    SONG_CATEGORY_CANTONESE,
    SONG_CATEGORY_MANDARIN,
}
SUPPORTED_ERA_STARTS = (1970, 1980, 1990, 2000, 2010, 2020)
MODERN_ERA_START = 2020


class DJProgramPlanning(Protocol):
    def make_program(self, request: "DJProgramRequest") -> "DJProgram": ...


@dataclass(slots=True)
class SongSuggestion:
    titleHint: str
    artistHint: str
    searchQuery: str
    reason: str

    @classmethod
    def from_payload(cls, payload: Any) -> "SongSuggestion":
        if not isinstance(payload, dict):
            raise ValidationError("Each song suggestion must be an object.")

        title_hint = str(payload.get("titleHint", "")).strip()
        artist_hint = str(payload.get("artistHint", "")).strip()
        search_query = str(payload.get("searchQuery", "")).strip()
        reason = str(payload.get("reason", "")).strip()

        if not title_hint or not artist_hint or not search_query or not reason:
            raise ValidationError("Each song suggestion must include titleHint, artistHint, searchQuery, and reason.")

        return cls(
            titleHint=title_hint,
            artistHint=artist_hint,
            searchQuery=search_query,
            reason=reason,
        )


@dataclass(slots=True)
class BridgeMonologue:
    afterSongIndex: int
    text: str

    @classmethod
    def from_payload(cls, payload: Any, default_index: int) -> "BridgeMonologue":
        if not isinstance(payload, dict):
            raise ValidationError("Each bridge monologue must be an object.")

        after_song_index = _coerce_int(
            payload.get("afterSongIndex", default_index),
            "afterSongIndex",
        )
        text = str(payload.get("text", "")).strip()
        if not text:
            raise ValidationError("Each bridge monologue must include text.")
        return cls(afterSongIndex=after_song_index, text=text)


@dataclass(slots=True)
class DJProgramRequest:
    transcript: str
    host_style: str = DEFAULT_HOST_STYLE
    desired_song_count: int = 8
    song_category: str = SONG_CATEGORY_CANTONESE
    era_range_start: int = 2000
    era_range_end: int = MODERN_ERA_START
    prefer_obscure_songs: bool = False

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> "DJProgramRequest":
        transcript = str(payload.get("transcript", payload.get("text", ""))).strip()
        host_style = str(
            payload.get("host_style", payload.get("voice_description", DEFAULT_HOST_STYLE))
        ).strip()
        desired_song_count = _coerce_int(
            payload.get("desired_song_count", payload.get("song_count", 6)),
            "desired_song_count",
        )
        song_category = _normalize_song_category(
            payload.get("song_category", SONG_CATEGORY_CANTONESE)
        )
        era_range_start = _coerce_int(
            payload.get("era_range_start", 2000),
            "era_range_start",
        )
        era_range_end = _coerce_int(
            payload.get("era_range_end", MODERN_ERA_START),
            "era_range_end",
        )
        prefer_obscure_songs = _coerce_bool(
            payload.get("prefer_obscure_songs", False),
            "prefer_obscure_songs",
        )

        if not transcript:
            raise ValidationError("`transcript` is required.")
        if len(transcript) > 1000:
            raise ValidationError(
                "`transcript` is too long. Keep it under 1000 characters."
            )
        if len(host_style) > 1000:
            raise ValidationError(
                "`host_style` is too long. Keep it under 1000 characters."
            )
        if desired_song_count < 5 or desired_song_count > 8:
            raise ValidationError("`desired_song_count` must be between 5 and 8.")
        if era_range_start not in SUPPORTED_ERA_STARTS:
            raise ValidationError(
                "`era_range_start` must be one of 1970, 1980, 1990, 2000, 2010, or 2020."
            )
        if era_range_end not in SUPPORTED_ERA_STARTS:
            raise ValidationError(
                "`era_range_end` must be one of 1970, 1980, 1990, 2000, 2010, or 2020."
            )
        if era_range_start > era_range_end:
            raise ValidationError("`era_range_start` must be less than or equal to `era_range_end`.")

        return cls(
            transcript=transcript,
            host_style=host_style or DEFAULT_HOST_STYLE,
            desired_song_count=desired_song_count,
            song_category=song_category,
            era_range_start=era_range_start,
            era_range_end=era_range_end,
            prefer_obscure_songs=prefer_obscure_songs,
        )


@dataclass(slots=True)
class DJProgram:
    showTitle: str
    moodSummary: str
    openingMonologue: str
    songSuggestions: list[SongSuggestion]
    bridgeMonologues: list[BridgeMonologue]
    closingMonologue: str
    voiceDescription: str

    def to_api_dict(self) -> dict[str, Any]:
        return {
            "showTitle": self.showTitle,
            "moodSummary": self.moodSummary,
            "openingMonologue": self.openingMonologue,
            "songSuggestions": [asdict(song) for song in self.songSuggestions],
            "bridgeMonologues": [asdict(item) for item in self.bridgeMonologues],
            "closingMonologue": self.closingMonologue,
            "voiceDescription": self.voiceDescription,
        }

    @classmethod
    def from_payload(
        cls,
        payload: Any,
        *,
        desired_song_count: int,
        fallback_host_style: str,
    ) -> "DJProgram":
        if not isinstance(payload, dict):
            raise ValidationError("OpenRouter response must be a JSON object.")

        show_title = str(payload.get("showTitle", "")).strip()
        mood_summary = str(payload.get("moodSummary", "")).strip()
        opening = str(payload.get("openingMonologue", "")).strip()
        closing = str(payload.get("closingMonologue", "")).strip()
        voice_description = str(
            payload.get("voiceDescription", fallback_host_style or DEFAULT_HOST_STYLE)
        ).strip()

        song_payloads = payload.get("songSuggestions")
        if not isinstance(song_payloads, list):
            raise ValidationError("`songSuggestions` must be an array.")
        if len(song_payloads) < desired_song_count:
            raise ValidationError(
                f"`songSuggestions` must include at least {desired_song_count} songs."
            )
        songs = [
            SongSuggestion.from_payload(item)
            for item in song_payloads[:desired_song_count]
        ]

        bridge_payloads = payload.get("bridgeMonologues")
        if not isinstance(bridge_payloads, list):
            raise ValidationError("`bridgeMonologues` must be an array.")
        required_bridges = max(desired_song_count - 1, 0)
        if len(bridge_payloads) < required_bridges:
            raise ValidationError(
                f"`bridgeMonologues` must include at least {required_bridges} entries."
            )
        bridges = [
            BridgeMonologue.from_payload(item, index)
            for index, item in enumerate(bridge_payloads[:required_bridges])
        ]
        for index, bridge in enumerate(bridges):
            bridge.afterSongIndex = index

        if not show_title or not mood_summary or not opening or not closing:
            raise ValidationError(
                "OpenRouter response is missing one of showTitle, moodSummary, openingMonologue, or closingMonologue."
            )

        return cls(
            showTitle=show_title,
            moodSummary=mood_summary,
            openingMonologue=opening,
            songSuggestions=songs,
            bridgeMonologues=bridges,
            closingMonologue=closing,
            voiceDescription=voice_description or fallback_host_style or DEFAULT_HOST_STYLE,
        )


@dataclass(frozen=True, slots=True)
class ThemePack:
    keywords: tuple[str, ...]
    title: str
    mood: str
    opening_lead: str
    closing_lead: str
    songs: tuple["CuratedSong", ...]


@dataclass(frozen=True, slots=True)
class CuratedSong:
    era_start: int
    category: str
    suggestion: SongSuggestion


class OpenRouterDJProgramPlanner:
    def __init__(
        self,
        api_key: str,
        *,
        model: str = DEFAULT_OPENROUTER_MODEL,
        app_url: str = "http://localhost:8000",
        app_title: str = "QwenTTS DJ Planner",
        timeout_seconds: float = 90.0,
    ) -> None:
        self.api_key = api_key.strip()
        self.model = model.strip() or DEFAULT_OPENROUTER_MODEL
        self.app_url = app_url.strip() or "http://localhost:8000"
        self.app_title = app_title.strip() or "QwenTTS DJ Planner"
        self.timeout_seconds = timeout_seconds

        if not self.api_key:
            raise ValueError("OpenRouter API key is required.")

    def make_program(self, request: DJProgramRequest) -> DJProgram:
        payload = {
            "model": self.model,
            "messages": [
                {
                    "role": "system",
                    "content": self._system_prompt(request.desired_song_count),
                },
                {
                    "role": "user",
                    "content": self._user_prompt(request),
                },
            ],
            "temperature": 0.7,
            "response_format": self._response_format(desired_song_count=request.desired_song_count),
        }

        http_request = urllib_request.Request(
            OPENROUTER_API_URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "HTTP-Referer": self.app_url,
                "X-Title": self.app_title,
            },
            method="POST",
        )

        try:
            with urllib_request.urlopen(
                http_request,
                timeout=self.timeout_seconds,
            ) as response:
                raw_body = response.read()
        except urllib_error.HTTPError as exc:
            error_body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                f"OpenRouter returned HTTP {exc.code}: {error_body}"
            ) from exc
        except urllib_error.URLError as exc:
            raise RuntimeError(
                f"Could not reach OpenRouter: {exc.reason}"
            ) from exc

        try:
            #print("OpenRouter raw response:", raw_body.decode("utf-8"))  # Debugging line
            decoded = json.loads(raw_body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise RuntimeError("OpenRouter returned invalid JSON.") from exc

        content = _extract_openrouter_content(decoded)
        try:
            program_payload = json.loads(content)
        except json.JSONDecodeError as exc:
            raise RuntimeError(
                f"OpenRouter returned non-JSON content: {content}"
            ) from exc

        return DJProgram.from_payload(
            program_payload,
            desired_song_count=request.desired_song_count,
            fallback_host_style=request.host_style,
        )

    def _response_format(self, *, desired_song_count: int) -> dict[str, Any]:
        return {
            "type": "json_schema",
            "json_schema": {
                "name": "geddy_dj_program",
                "strict": True,
                "schema": {
                    "type": "object",
                    "properties": {
                        "showTitle": {
                            "type": "string",
                            "description": "The program title in Traditional Chinese.",
                        },
                        "moodSummary": {
                            "type": "string",
                            "description": "A short emotional summary of the listener's current mood.",
                        },
                        "openingMonologue": {
                            "type": "string",
                            "description": "The opening spoken monologue in Cantonese-flavored Traditional Chinese.",
                        },
                        "songSuggestions": {
                            "type": "array",
                            "description": f"Editorial song suggestions for later Apple Music lookup on iOS. Return exactly {desired_song_count} items.",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "titleHint": {
                                        "type": "string",
                                        "description": "Song title hint.",
                                    },
                                    "artistHint": {
                                        "type": "string",
                                        "description": "Artist name hint.",
                                    },
                                    "searchQuery": {
                                        "type": "string",
                                        "description": "Search query for Apple Music lookup.",
                                    },
                                    "reason": {
                                        "type": "string",
                                        "description": "Why this song fits the emotional arc.",
                                    },
                                },
                                "required": [
                                    "titleHint",
                                    "artistHint",
                                    "searchQuery",
                                    "reason",
                                ],
                                "additionalProperties": False,
                            },
                        },
                        "bridgeMonologues": {
                            "type": "array",
                            "description": f"Bridge monologues inserted between songs. Return exactly {max(desired_song_count - 1, 0)} items.",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "afterSongIndex": {
                                        "type": "integer",
                                        "description": "Zero-based song index after which the monologue is placed.",
                                    },
                                    "text": {
                                        "type": "string",
                                        "description": "Bridge monologue text.",
                                    },
                                },
                                "required": ["afterSongIndex", "text"],
                                "additionalProperties": False,
                            },
                        },
                        "closingMonologue": {
                            "type": "string",
                            "description": "The closing spoken monologue.",
                        },
                        "voiceDescription": {
                            "type": "string",
                            "description": "Voice design description for the TTS backend.",
                        },
                    },
                    "required": [
                        "showTitle",
                        "moodSummary",
                        "openingMonologue",
                        "songSuggestions",
                        "bridgeMonologues",
                        "closingMonologue",
                        "voiceDescription",
                    ],
                    "additionalProperties": False,
                },
            },
        }

    def _system_prompt(self, desired_song_count: int) -> str:
        return f"""
You are an expert Hong Kong emotional radio DJ writer.
Write in Traditional Chinese with natural Cantonese phrasing.
You are creating a complete DJ program rundown for an iOS app called "Geddy".

Return JSON only. No markdown. No prose outside JSON.
Generate exactly {desired_song_count} songs and exactly {desired_song_count - 1} bridge monologues.

Required JSON shape:
{{
  "showTitle": "string",
  "moodSummary": "string",
  "openingMonologue": "string",
  "songSuggestions": [
    {{
      "titleHint": "string",
      "artistHint": "string",
      "searchQuery": "string",
      "reason": "string"
    }}
  ],
  "bridgeMonologues": [
    {{
      "afterSongIndex": 0,
      "text": "string"
    }}
  ],
  "closingMonologue": "string",
  "voiceDescription": "string"
}}

Rules:
- 用字一定一定要香港廣東話口語，可以中英夾雜.
- Songs should be emotionally coherent with the listener's situation.
- Honor the requested song category and era range exactly unless the user explicitly asks to break that rule.
- If the user asks for less mainstream songs, actively try to include deeper cuts and avoid filling the whole list with only the most obvious canon hits.
- 用鄭子誠式嘅陪伴口吻做口應，然後歌與歌之間就住歌曲按排一段感性嘅說話，要提及下一首歌的內容，歌與歌手名字要正確，不要胡亂生成！
- Do not search Apple Music, validate catalog availability, or return Apple Music IDs, URLs, or metadata.
- songSuggestions are only editorial hints for the iOS app. The iOS app will run MusicKit search later using titleHint, artistHint, and searchQuery.
- The opening, bridges, and closing should feel intimate, reflective, and radio-ready.
- Keep a warm midnight-radio style as a persona, but do not assume the real-world time is currently night.
- Avoid explicit time-of-day claims like 現在夜深、今晚、凌晨 unless the listener explicitly mentions that context.
- Each bridge should naturally lead into the next song.
- voiceDescription should preserve the requested host style while remaining suitable for TTS.
""".strip()

    def _user_prompt(self, request: DJProgramRequest) -> str:
        return f"""
Listener transcript:
{request.transcript}

Requested host style:
{request.host_style}

Requested song category:
{_song_category_label(request.song_category)}

Requested era range:
{_era_range_label(request.era_range_start, request.era_range_end)}

Preference for less mainstream songs:
{_obscure_song_preference_label(request.prefer_obscure_songs)}

Please create a complete radio program plan with exactly {request.desired_song_count} songs that stay inside the requested category and era range.
Return song suggestions only. Music lookup will be handled by the iOS app after this response.
""".strip()


class RuleBasedDJProgramPlanner:
    def __init__(self) -> None:
        self._theme_packs = _build_theme_packs()
        self._default_theme = _build_default_theme()
        self._catalog_songs = _collect_catalog_songs((*self._theme_packs, self._default_theme))

    def make_program(self, request: DJProgramRequest) -> DJProgram:
        theme = self._pick_theme(request.transcript)
        songs = self._select_songs(theme, request)
        transcript = request.transcript.strip()

        opening = "\n".join(
            [
                "呢度係 Geddy。",
                f"你頭先講咗一句：「{transcript}」。",
                "有啲感受，唔一定要即刻講清楚，但可以慢慢聽清楚。",
                f"我想用一組{_song_category_label(request.song_category)}，陪你由{_era_range_label(request.era_range_start, request.era_range_end)}一路行過呢段 {theme.mood}。",
                *(
                    ["今次我都會試下幫你搵幾首無咁大路、但同樣貼題嘅歌。"]
                    if request.prefer_obscure_songs
                    else []
                ),
                theme.opening_lead,
            ]
        )

        bridges = [
            BridgeMonologue(
                afterSongIndex=index,
                text="\n".join(
                    [
                        f"剛才聽完《{song.titleHint}》，有時人最怕嘅，唔係回憶太多，而係原來自己仲記得心跳嗰一下。",
                        "如果你一時之間仲未必講得出口，就交畀下一首歌代你講。",
                        f"送上《{songs[index + 1].titleHint}》，俾仍然喺情緒入面慢慢搵出口嘅你。",
                    ]
                ),
            )
            for index, song in enumerate(songs[:-1])
        ]

        closing = "\n".join(
            [
                "呢段節目差唔多嚟到尾聲。",
                "你唔需要急住令自己變得冇事，因為真正嘅放低，通常都係慢慢學識同自己相處。",
                theme.closing_lead,
                "呢度係 AI 鄭子誠，下次你想搵人陪你聽歌、陪你整理心情，我會再喺度。",
            ]
        )

        return DJProgram(
            showTitle=theme.title,
            moodSummary=theme.mood,
            openingMonologue=opening,
            songSuggestions=songs,
            bridgeMonologues=bridges,
            closingMonologue=closing,
            voiceDescription=request.host_style or DEFAULT_HOST_STYLE,
        )

    def _pick_theme(self, transcript: str) -> ThemePack:
        normalized = transcript.lower()
        for theme in self._theme_packs:
            if any(keyword in normalized for keyword in theme.keywords):
                return theme
        return self._default_theme

    def _select_songs(
        self,
        theme: ThemePack,
        request: DJProgramRequest,
    ) -> list[SongSuggestion]:
        matched_theme_songs = [
            item.suggestion
            for item in theme.songs
            if _matches_preferences(item, request)
        ]
        matched_catalog_songs = [
            item.suggestion
            for item in self._catalog_songs
            if _matches_preferences(item, request)
        ]

        ordered = _dedupe_song_suggestions(
            (*matched_theme_songs, *matched_catalog_songs)
        )
        ordered = _prioritize_obscure_song_suggestions(
            ordered,
            prefer_obscure_songs=request.prefer_obscure_songs,
        )

        if len(ordered) < request.desired_song_count:
            ordered = _dedupe_song_suggestions(
                (
                    *ordered,
                    *[item.suggestion for item in theme.songs],
                    *[item.suggestion for item in self._catalog_songs],
                )
            )
            ordered = _prioritize_obscure_song_suggestions(
                ordered,
                prefer_obscure_songs=request.prefer_obscure_songs,
            )

        return ordered[: request.desired_song_count]


class OpenRouterBackedDJProgramPlanner:
    def __init__(
        self,
        primary: OpenRouterDJProgramPlanner | None,
        fallback: DJProgramPlanning,
    ) -> None:
        self.primary = primary
        self.fallback = fallback

    def make_program(self, request: DJProgramRequest) -> DJProgram:
        if self.primary is not None:
            try:
                return self.primary.make_program(request)
            except RuntimeError:
                return self.fallback.make_program(request)
        return self.fallback.make_program(request)


def create_default_planner() -> DJProgramPlanning:
    fallback = RuleBasedDJProgramPlanner()
    api_key = load_openrouter_api_key().strip()
    if not api_key:
        return OpenRouterBackedDJProgramPlanner(primary=None, fallback=fallback)

    primary = OpenRouterDJProgramPlanner(
        api_key=api_key,
        model=os.environ.get("OPENROUTER_MODEL", DEFAULT_OPENROUTER_MODEL),
        app_url=os.environ.get("OPENROUTER_APP_URL", "http://localhost:8000"),
        app_title=os.environ.get("OPENROUTER_APP_TITLE", "QwenTTS DJ Planner"),
        timeout_seconds=float(os.environ.get("OPENROUTER_TIMEOUT_SECONDS", "90")),
    )
    return OpenRouterBackedDJProgramPlanner(primary=primary, fallback=fallback)


def _extract_openrouter_content(payload: dict[str, Any]) -> str:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        raise RuntimeError("OpenRouter response did not include choices.")

    message = choices[0].get("message")
    if not isinstance(message, dict):
        raise RuntimeError("OpenRouter response did not include a message.")

    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        text_parts: list[str] = []
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text":
                text_parts.append(str(part.get("text", "")))
        combined = "".join(text_parts).strip()
        if combined:
            return combined

    raise RuntimeError("OpenRouter response did not include textual content.")


def load_openrouter_api_key() -> str:
    try:
        raw_payload = OPENROUTER_API_KEY_CONFIG_PATH.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""
    except OSError:
        return ""

    try:
        payload = json.loads(raw_payload)
    except json.JSONDecodeError:
        return ""

    if not isinstance(payload, dict):
        return ""

    return str(payload.get("api_key", "")).strip()


def _build_theme_packs() -> list[ThemePack]:
    return [
        ThemePack(
            keywords=("分手", "掛住", "失戀", "ex", "miss", "love", "想你", "離開"),
            title="AI 鄭子誠: 掛住一個人嘅夜",
            mood="未放低的思念",
            opening_lead="如果你仲喺某段關係門口徘徊，希望呢個 playlist 可以陪你坐低一陣。",
            closing_lead="記住，真正重要嘅唔係你幾時忘記，而係你幾時肯重新溫柔對待自己。",
            songs=(
                _curated_song(2000, SONG_CATEGORY_CANTONESE, "明年今日", "陳奕迅", "第一首先用熟悉嘅遺憾感，帶住聽眾慢慢跌入情緒。"),
                _curated_song(2000, SONG_CATEGORY_CANTONESE, "鍾無艷", "謝安琪", "寫畀那些明明付出過，卻未被珍惜的人。"),
                _curated_song(2000, SONG_CATEGORY_CANTONESE, "如果讓我說下去", "楊千嬅", "延續想講未講的心事，令節目情緒更深。"),
                _curated_song(2000, SONG_CATEGORY_CANTONESE, "愛與誠", "古巨基", "將關係中最沉重的真心擺上檯面。"),
                _curated_song(2000, SONG_CATEGORY_CANTONESE, "好心分手", "盧巧音", "最後用比較收斂但仍然刺心的角度作結。"),
                _curated_song(1990, SONG_CATEGORY_CANTONESE, "追", "張國榮", "用偏向懷念的角度，放大掛住一個人的失重感。"),
                _curated_song(1980, SONG_CATEGORY_CANTONESE, "一生何求", "陳百強", "將舊情未放低的重量拉回經典年代。"),
                _curated_song(2010, SONG_CATEGORY_CANTONESE, "高山低谷", "林奕匡", "讓情緒由失落慢慢行到面對自己。"),
                _curated_song(2020, SONG_CATEGORY_CANTONESE, "銀河修理員", "Dear Jane", "用近年的傷感口吻，把思念寫得更貼近而家呢一代。"),
                _curated_song(2020, SONG_CATEGORY_CANTONESE, "到底發生過什麼事", "Dear Jane", "將未放低同自我追問推到更近代的情緒語境。"),
                _curated_song(2000, SONG_CATEGORY_MANDARIN, "十年", "陳奕迅", "把熟悉的遺憾感轉成更直接的華語流行情緒。"),
                _curated_song(2000, SONG_CATEGORY_MANDARIN, "可惜不是你", "梁靜茹", "寫出那種明明很近卻再也回不去的距離。"),
                _curated_song(2000, SONG_CATEGORY_MANDARIN, "成全", "劉若英", "把不捨推向成熟放手的層次。"),
                _curated_song(1990, SONG_CATEGORY_MANDARIN, "味道", "辛曉琪", "讓思念變得更具畫面感，也更貼近舊情回憶。"),
                _curated_song(1990, SONG_CATEGORY_MANDARIN, "聽海", "張惠妹", "把壓住的情緒打開，讓掛念有出口。"),
                _curated_song(2010, SONG_CATEGORY_MANDARIN, "慢冷", "梁靜茹", "延續那種後知後覺的難受與自省。"),
                _curated_song(2010, SONG_CATEGORY_MANDARIN, "小幸運", "田馥甄", "讓回憶帶點暖意，不至於全程下沉。"),
                _curated_song(2020, SONG_CATEGORY_MANDARIN, "刻在我心底的名字", "盧廣仲", "用近代華語情歌講出仍然放唔低的名字。"),
                _curated_song(2020, SONG_CATEGORY_MANDARIN, "如果可以", "韋禮安", "將掛念寫成一種想回頭改寫結果的心情。"),
                _curated_song(1970, SONG_CATEGORY_MANDARIN, "月亮代表我的心", "鄧麗君", "如果想將年代拉早，這首歌能把思念說得非常純粹。"),
            ),
        ),
        ThemePack(
            keywords=("回憶", "以前", "青春", "舊", "懷念", "nostalgia"),
            title="AI 鄭子誠: 舊日時光特輯",
            mood="懷舊和餘溫",
            opening_lead="有些年份過咗去，但某一首歌一響，原來連空氣都會陪你回去。",
            closing_lead="回憶最動人嘅地方，唔係要你回頭，而係提醒你曾經好認真咁活過。",
            songs=(
                _curated_song(1990, SONG_CATEGORY_CANTONESE, "追", "張國榮", "用一首經典把節目帶回最純粹的感情。"),
                _curated_song(2000, SONG_CATEGORY_CANTONESE, "歲月如歌", "陳奕迅", "讓聽眾進入時間慢慢流過的感覺。"),
                _curated_song(2000, SONG_CATEGORY_CANTONESE, "最佳損友", "陳奕迅", "把青春裡那些失散的人也帶入節目。"),
                _curated_song(1980, SONG_CATEGORY_CANTONESE, "千千闋歌", "陳慧嫻", "用經典收束舊日時光的餘韻。"),
                _curated_song(1980, SONG_CATEGORY_CANTONESE, "一生何求", "陳百強", "將懷舊情緒推到最濃。"),
                _curated_song(1990, SONG_CATEGORY_CANTONESE, "友情歲月", "鄭伊健", "把青春的畫面拉闊到更有電影感。"),
                _curated_song(1970, SONG_CATEGORY_CANTONESE, "啼笑因緣", "仙杜拉", "如果想更舊派一點，這首歌可以立刻帶出老派電台感。"),
                _curated_song(1980, SONG_CATEGORY_CANTONESE, "Monica", "張國榮", "加一點節奏感，讓懷舊不只停留在低回。"),
                _curated_song(1970, SONG_CATEGORY_MANDARIN, "月亮代表我的心", "鄧麗君", "把回憶拉回最雋永、最直接的年代。"),
                _curated_song(1980, SONG_CATEGORY_MANDARIN, "明天你是否依然愛我", "童安格", "把青春時代的掛念與不確定慢慢帶出來。"),
                _curated_song(1990, SONG_CATEGORY_MANDARIN, "後來", "劉若英", "給那些多年後才懂自己的心事一個出口。"),
                _curated_song(1990, SONG_CATEGORY_MANDARIN, "聽海", "張惠妹", "讓舊記憶變得更具海浪感同空間感。"),
                _curated_song(2000, SONG_CATEGORY_MANDARIN, "十年", "陳奕迅", "最後再回到時間與關係的重量。"),
                _curated_song(2000, SONG_CATEGORY_MANDARIN, "後來的我們", "五月天", "把回憶感延伸到成年之後的回望。"),
                _curated_song(2010, SONG_CATEGORY_MANDARIN, "小幸運", "田馥甄", "保留一點青春暖色，令整個懷舊旅程更完整。"),
                _curated_song(2010, SONG_CATEGORY_MANDARIN, "連名帶姓", "張惠妹", "讓回憶不只溫柔，也有刺痛與未完成感。"),
                _curated_song(2020, SONG_CATEGORY_CANTONESE, "銀河修理員", "Dear Jane", "即使講懷舊，都可以加一點近年的柔軟同空白感。"),
                _curated_song(2020, SONG_CATEGORY_CANTONESE, "留一天與你喘息", "陳卓賢", "把回憶拉入更現代的都市情緒。"),
                _curated_song(2020, SONG_CATEGORY_MANDARIN, "刻在我心底的名字", "盧廣仲", "把舊日時光轉成近年最有畫面的青春回望。"),
                _curated_song(2020, SONG_CATEGORY_MANDARIN, "如果可以", "韋禮安", "近年的回憶系情歌，保留想改寫過去的遺憾感。"),
            ),
        ),
        ThemePack(
            keywords=("辛苦", "攰", "工作", "壓力", "加油", "heal", "healing", "support"),
            title="AI 鄭子誠: 給努力生活的人",
            mood="療癒與重新呼吸",
            opening_lead="如果你今日已經用盡力氣，依家就唔好再逼自己堅強，先慢慢抖一口氣。",
            closing_lead="希望你記住，溫柔唔係軟弱，而係明知辛苦仍然願意對自己好一點。",
            songs=(
                _curated_song(2010, SONG_CATEGORY_CANTONESE, "陀飛輪", "陳奕迅", "點出成年人最真實的時間焦慮。"),
                _curated_song(2010, SONG_CATEGORY_CANTONESE, "高山低谷", "林奕匡", "承接跌宕情緒，帶出慢慢抬頭的力量。"),
                _curated_song(2010, SONG_CATEGORY_CANTONESE, "今天只做一件事", "陳奕迅", "提醒聽眾依家可以先只照顧一件事，就是自己。"),
                _curated_song(2000, SONG_CATEGORY_CANTONESE, "下一站天后", "Twins", "加一點明亮，令節目不只是低沉。"),
                _curated_song(1990, SONG_CATEGORY_CANTONESE, "海闊天空", "Beyond", "最後用最有力量的經典做收結。"),
                _curated_song(1980, SONG_CATEGORY_CANTONESE, "陪著你走", "盧冠廷", "補上一種被陪伴的安定感。"),
                _curated_song(1980, SONG_CATEGORY_CANTONESE, "偏偏喜歡你", "陳百強", "在療癒路線中留一點柔和懷舊感。"),
                _curated_song(2000, SONG_CATEGORY_CANTONESE, "終身美麗", "鄭秀文", "把辛苦過後的自我接納慢慢講出來。"),
                _curated_song(2020, SONG_CATEGORY_CANTONESE, "留一天與你喘息", "陳卓賢", "用較新的城市感陪伴，讓人感覺有人同你一齊抖氣。"),
                _curated_song(2020, SONG_CATEGORY_CANTONESE, "銀河修理員", "Dear Jane", "令療癒感帶少少近代樂隊的遼闊感。"),
                _curated_song(2010, SONG_CATEGORY_MANDARIN, "光年之外", "G.E.M.", "把情緒轉成面向未來的想像。"),
                _curated_song(2010, SONG_CATEGORY_MANDARIN, "小幸運", "田馥甄", "讓疲倦裡面仍然留住一點柔軟。"),
                _curated_song(2000, SONG_CATEGORY_MANDARIN, "勇氣", "梁靜茹", "提醒聽眾重新向前，需要的只是小小勇氣。"),
                _curated_song(2000, SONG_CATEGORY_MANDARIN, "隱形的翅膀", "張韶涵", "給正在捱過低潮的人一點明亮的支撐。"),
                _curated_song(2010, SONG_CATEGORY_MANDARIN, "平凡之路", "朴樹", "讓節目慢慢走去比較開闊的結尾。"),
                _curated_song(2010, SONG_CATEGORY_MANDARIN, "演員", "薛之謙", "把壓力與關係中的消耗，換成一種看清自己的距離。"),
                _curated_song(2000, SONG_CATEGORY_MANDARIN, "成全", "劉若英", "讓療癒路線保留成熟與放手的角度。"),
                _curated_song(2010, SONG_CATEGORY_MANDARIN, "連名帶姓", "張惠妹", "即使療癒主題，也保留情緒並未完全散去的真實。"),
                _curated_song(2020, SONG_CATEGORY_MANDARIN, "如果可以", "韋禮安", "近年的聲線同編曲，令療癒不會太舊派。"),
                _curated_song(2020, SONG_CATEGORY_MANDARIN, "刻在我心底的名字", "盧廣仲", "留一點仍未完全放低的餘味，符合成年人療癒節奏。"),
            ),
        ),
    ]


def _build_default_theme() -> ThemePack:
    return ThemePack(
        keywords=(),
        title="AI 鄭子誠: 深夜陪伴線",
        mood="靜靜陪伴",
        opening_lead="唔知道你而家帶住咩心事入嚟，但我想先陪你慢慢坐低。",
        closing_lead="情緒總會慢慢有出口，但有人陪你行過，條路會冇咁難行。",
        songs=(
            _curated_song(2000, SONG_CATEGORY_CANTONESE, "歲月如歌", "陳奕迅", "用熟悉感先打開整個節目的氛圍。"),
            _curated_song(2000, SONG_CATEGORY_CANTONESE, "K歌之王", "陳奕迅", "承接夜色裡那些有口難言的情緒。"),
            _curated_song(1990, SONG_CATEGORY_CANTONESE, "追", "張國榮", "用經典撐起電台 DJ 的陪伴質感。"),
            _curated_song(2010, SONG_CATEGORY_CANTONESE, "高山低谷", "林奕匡", "讓氣氛逐漸由低回轉向釋放。"),
            _curated_song(2010, SONG_CATEGORY_CANTONESE, "今天只做一件事", "陳奕迅", "在後段加入溫柔安定感。"),
            _curated_song(1990, SONG_CATEGORY_CANTONESE, "海闊天空", "Beyond", "最後用希望感作結。"),
            _curated_song(1980, SONG_CATEGORY_CANTONESE, "偏偏喜歡你", "陳百強", "把節目尾段拉回成熟電台的經典質感。"),
            _curated_song(1970, SONG_CATEGORY_CANTONESE, "家變", "羅文", "如果想更舊派，這首歌可以立即拉出七十年代氣味。"),
            _curated_song(2020, SONG_CATEGORY_CANTONESE, "銀河修理員", "Dear Jane", "令整體陪伴感多一點近年的空氣同距離感。"),
            _curated_song(2020, SONG_CATEGORY_CANTONESE, "留一天與你喘息", "陳卓賢", "放喺近代節目尾段，氣氛會更貼近而家。"),
            _curated_song(2010, SONG_CATEGORY_MANDARIN, "小幸運", "田馥甄", "留一點柔軟餘韻畀聽眾自己慢慢消化。"),
            _curated_song(2000, SONG_CATEGORY_MANDARIN, "十年", "陳奕迅", "用熟悉度高的作品承接情緒。"),
            _curated_song(1990, SONG_CATEGORY_MANDARIN, "聽海", "張惠妹", "讓感受有更大的空間可以呼吸。"),
            _curated_song(1980, SONG_CATEGORY_MANDARIN, "明天你是否依然愛我", "童安格", "用老派情歌留住陪伴感。"),
            _curated_song(1970, SONG_CATEGORY_MANDARIN, "月亮代表我的心", "鄧麗君", "如果要更早年代，這首歌幾乎一響就有畫面。"),
            _curated_song(2000, SONG_CATEGORY_MANDARIN, "勇氣", "梁靜茹", "在尾段補上一點向前走的力量。"),
            _curated_song(2020, SONG_CATEGORY_MANDARIN, "如果可以", "韋禮安", "讓陪伴線去到現代時仍然保持流行感。"),
            _curated_song(2020, SONG_CATEGORY_MANDARIN, "刻在我心底的名字", "盧廣仲", "將近年的情緒語感補進節目尾聲。"),
        ),
    )


def _coerce_int(value: Any, field_name: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"`{field_name}` must be an integer.") from exc


def _coerce_bool(value: Any, field_name: str) -> bool:
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if normalized in {"1", "true", "yes", "y", "on"}:
        return True
    if normalized in {"0", "false", "no", "n", "off", ""}:
        return False
    raise ValidationError(f"`{field_name}` must be a boolean.")


def _normalize_song_category(value: Any) -> str:
    normalized = str(value or "").strip().lower()
    aliases = {
        "廣東歌": SONG_CATEGORY_CANTONESE,
        "粤语歌": SONG_CATEGORY_CANTONESE,
        "cantonese": SONG_CATEGORY_CANTONESE,
        "cantopop": SONG_CATEGORY_CANTONESE,
        "華語歌": SONG_CATEGORY_MANDARIN,
        "华语歌": SONG_CATEGORY_MANDARIN,
        "mandarin": SONG_CATEGORY_MANDARIN,
        "mandopop": SONG_CATEGORY_MANDARIN,
    }
    resolved = aliases.get(normalized, normalized)
    if resolved not in SUPPORTED_SONG_CATEGORIES:
        raise ValidationError("`song_category` must be one of `cantonese` or `mandarin`.")
    return resolved


def _song_category_label(category: str) -> str:
    if category == SONG_CATEGORY_MANDARIN:
        return "華語歌"
    return "廣東歌"


def _obscure_song_preference_label(prefer_obscure_songs: bool) -> str:
    if prefer_obscure_songs:
        return "有，請試下加入無咁大路、但貼題而且合理嘅歌。"
    return "無，按整體情緒流向安排即可。"


def _era_label(era_start: int) -> str:
    if era_start == MODERN_ERA_START:
        return "現代"
    if era_start == 2010:
        return "10年代"
    decade = str(era_start)[-2:]
    return f"{decade}年代"


def _era_range_label(era_start: int, era_end: int) -> str:
    if era_start == era_end:
        return _era_label(era_start)
    return f"{_era_label(era_start)}至{_era_label(era_end)}"


def _curated_song(
    era_start: int,
    category: str,
    title: str,
    artist: str,
    reason: str,
) -> CuratedSong:
    return CuratedSong(
        era_start=era_start,
        category=category,
        suggestion=SongSuggestion(
            titleHint=title,
            artistHint=artist,
            searchQuery=f"{title} {artist}",
            reason=reason,
        ),
    )


def _matches_preferences(song: CuratedSong, request: DJProgramRequest) -> bool:
    return (
        song.category == request.song_category
        and request.era_range_start <= song.era_start <= request.era_range_end
    )


def _collect_catalog_songs(themes: tuple[ThemePack, ...]) -> tuple[CuratedSong, ...]:
    ordered: list[CuratedSong] = []
    seen: set[tuple[str, str]] = set()
    for theme in themes:
        for song in theme.songs:
            key = (
                song.suggestion.titleHint.casefold(),
                song.suggestion.artistHint.casefold(),
            )
            if key in seen:
                continue
            seen.add(key)
            ordered.append(song)
    return tuple(ordered)


_MAINSTREAM_SONG_KEYS = {
    ("明年今日".casefold(), "陳奕迅".casefold()),
    ("十年".casefold(), "陳奕迅".casefold()),
    ("小幸運".casefold(), "田馥甄".casefold()),
    ("後來".casefold(), "劉若英".casefold()),
    ("海闊天空".casefold(), "Beyond".casefold()),
    ("千千闋歌".casefold(), "陳慧嫻".casefold()),
    ("月亮代表我的心".casefold(), "鄧麗君".casefold()),
    ("勇氣".casefold(), "梁靜茹".casefold()),
    ("光年之外".casefold(), "G.E.M.".casefold()),
    ("如果可以".casefold(), "韋禮安".casefold()),
    ("刻在我心底的名字".casefold(), "盧廣仲".casefold()),
    ("追".casefold(), "張國榮".casefold()),
    ("高山低谷".casefold(), "林奕匡".casefold()),
}


def _prioritize_obscure_song_suggestions(
    suggestions: list[SongSuggestion],
    *,
    prefer_obscure_songs: bool,
) -> list[SongSuggestion]:
    if not prefer_obscure_songs:
        return suggestions

    return sorted(
        suggestions,
        key=lambda song: (
            (
                song.titleHint.casefold(),
                song.artistHint.casefold(),
            ) in _MAINSTREAM_SONG_KEYS,
            song.titleHint.casefold(),
            song.artistHint.casefold(),
        ),
    )


def _dedupe_song_suggestions(
    suggestions: tuple[SongSuggestion, ...] | list[SongSuggestion],
) -> list[SongSuggestion]:
    ordered: list[SongSuggestion] = []
    seen: set[tuple[str, str]] = set()
    for song in suggestions:
        key = (song.titleHint.casefold(), song.artistHint.casefold())
        if key in seen:
            continue
        seen.add(key)
        ordered.append(song)
    return ordered
