from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from typing import Any, Protocol
from urllib import error as urllib_error
from urllib import request as urllib_request

from .service import ValidationError

DEFAULT_HOST_STYLE = """
一把成熟、溫柔、帶少少磁性嘅香港深夜男 DJ 聲線，
說話節奏從容，情感細膩，像在凌晨電台陪伴失眠聽眾，
廣東話口吻自然，帶感性而不誇張的陪伴感。
""".strip()

DEFAULT_OPENROUTER_MODEL = "anthropic/claude-sonnet-4.6"
#"openai/gpt-4o-mini"
OPENROUTER_API_KEY = "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"
OPENROUTER_API_URL = "https://openrouter.ai/api/v1/chat/completions"


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

        return cls(
            transcript=transcript,
            host_style=host_style or DEFAULT_HOST_STYLE,
            desired_song_count=desired_song_count,
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
    songs: tuple[SongSuggestion, ...]


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
            print("yoyoy")
            with urllib_request.urlopen(
                http_request,
                timeout=self.timeout_seconds,
            ) as response:
                raw_body = response.read()
        except urllib_error.HTTPError as exc:
            error_body = exc.read().decode("utf-8", errors="replace")
            print(f"OpenRouter returned HTTP {exc.code}: {error_body}")
            raise RuntimeError(
                f"OpenRouter returned HTTP {exc.code}: {error_body}"
            ) from exc
        except urllib_error.URLError as exc:
            print("yoyoy3")
            raise RuntimeError(
                f"Could not reach OpenRouter: {exc.reason}"
            ) from exc

        try:
            print("raw_body:", raw_body.decode("utf-8"))
            decoded = json.loads(raw_body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            print("runtime error:", raw_body.decode("utf-8"))
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
- Prefer songs that are Cantonese pop songs when relevant 2000 年代至今.
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

Please create a complete radio program plan with exactly {request.desired_song_count} songs.
Return song suggestions only. Music lookup will be handled by the iOS app after this response.
""".strip()


class RuleBasedDJProgramPlanner:
    def __init__(self) -> None:
        self._theme_packs = _build_theme_packs()
        self._default_theme = _build_default_theme()

    def make_program(self, request: DJProgramRequest) -> DJProgram:
        theme = self._pick_theme(request.transcript)
        songs = list(theme.songs[: request.desired_song_count])
        transcript = request.transcript.strip()

        opening = "\n".join(
            [
                "呢度係 Geddy。",
                f"你頭先講咗一句：「{transcript}」。",
                "有啲感受，唔一定要即刻講清楚，但可以慢慢聽清楚。",
                f"我想用幾首歌，同你一齊行過呢一段 {theme.mood}。",
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
                print("primary program planner")
                return self.primary.make_program(request)
            except RuntimeError:
                print("fallback planner 1")
                return self.fallback.make_program(request)
        print("fallback planner 2")
        return self.fallback.make_program(request)


def create_default_planner() -> DJProgramPlanning:
    fallback = RuleBasedDJProgramPlanner()
    api_key = OPENROUTER_API_KEY.strip()
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


def _build_theme_packs() -> list[ThemePack]:
    return [
        ThemePack(
            keywords=("分手", "掛住", "失戀", "ex", "miss", "love", "想你", "離開"),
            title="AI 鄭子誠: 掛住一個人嘅夜",
            mood="未放低的思念",
            opening_lead="如果你仲喺某段關係門口徘徊，希望呢個 playlist 可以陪你坐低一陣。",
            closing_lead="記住，真正重要嘅唔係你幾時忘記，而係你幾時肯重新溫柔對待自己。",
            songs=(
                SongSuggestion("明年今日", "陳奕迅", "明年今日 陳奕迅", "第一首先用熟悉嘅遺憾感，帶住聽眾慢慢跌入情緒。"),
                SongSuggestion("鍾無艷", "謝安琪", "鍾無艷 謝安琪", "寫畀那些明明付出過，卻未被珍惜的人。"),
                SongSuggestion("如果讓我說下去", "楊千嬅", "如果讓我說下去 楊千嬅", "延續想講未講的心事，令節目情緒更深。"),
                SongSuggestion("愛與誠", "古巨基", "愛與誠 古巨基", "將關係中最沉重的真心擺上檯面。"),
                SongSuggestion("小城大事", "楊千嬅", "小城大事 楊千嬅", "讓思念由個人回憶擴散成城市夜色。"),
                SongSuggestion("好心分手", "盧巧音", "好心分手 盧巧音", "最後用比較收斂但仍然刺心的角度作結。"),
                SongSuggestion("痛愛", "容祖兒", "痛愛 容祖兒", "再將情緒推近一點，令遺憾有更直接的重量。"),
                SongSuggestion("終身美麗", "鄭秀文", "終身美麗 鄭秀文", "用一種成熟的目光，把不捨慢慢放低。"),
            ),
        ),
        ThemePack(
            keywords=("回憶", "以前", "青春", "舊", "懷念", "nostalgia"),
            title="AI 鄭子誠: 舊日時光特輯",
            mood="懷舊和餘溫",
            opening_lead="有些年份過咗去，但某一首歌一響，原來連空氣都會陪你回去。",
            closing_lead="回憶最動人嘅地方，唔係要你回頭，而係提醒你曾經好認真咁活過。",
            songs=(
                SongSuggestion("追", "張國榮", "追 張國榮", "用一首經典把節目帶回最純粹的感情。"),
                SongSuggestion("歲月如歌", "陳奕迅", "歲月如歌 陳奕迅", "讓聽眾進入時間慢慢流過的感覺。"),
                SongSuggestion("最佳損友", "陳奕迅", "最佳損友 陳奕迅", "把青春裡那些失散的人也帶入節目。"),
                SongSuggestion("一生中最愛", "譚詠麟", "一生中最愛 譚詠麟", "將懷舊情緒推到最濃。"),
                SongSuggestion("後來", "劉若英", "後來 劉若英", "給那些多年後才懂自己的心事一個出口。"),
                SongSuggestion("十年", "陳奕迅", "十年 陳奕迅", "最後再回到時間與關係的重量。"),
                SongSuggestion("友情歲月", "鄭伊健", "友情歲月 鄭伊健", "把青春的畫面拉闊到更有電影感。"),
                SongSuggestion("千千闋歌", "陳慧嫻", "千千闋歌 陳慧嫻", "用經典收束舊日時光的餘韻。"),
            ),
        ),
        ThemePack(
            keywords=("辛苦", "攰", "工作", "壓力", "加油", "heal", "healing", "support"),
            title="AI 鄭子誠: 給努力生活的人",
            mood="療癒與重新呼吸",
            opening_lead="如果你今日已經用盡力氣，依家就唔好再逼自己堅強，先慢慢抖一口氣。",
            closing_lead="希望你記住，溫柔唔係軟弱，而係明知辛苦仍然願意對自己好一點。",
            songs=(
                SongSuggestion("陀飛輪", "陳奕迅", "陀飛輪 陳奕迅", "點出成年人最真實的時間焦慮。"),
                SongSuggestion("高山低谷", "林奕匡", "高山低谷 林奕匡", "承接跌宕情緒，帶出慢慢抬頭的力量。"),
                SongSuggestion("今天只做一件事", "陳奕迅", "今天只做一件事 陳奕迅", "提醒聽眾依家可以先只照顧一件事，就是自己。"),
                SongSuggestion("下一站天后", "Twins", "下一站天后 Twins", "加一點明亮，令節目不只是低沉。"),
                SongSuggestion("光年之外", "G.E.M.", "光年之外 G.E.M.", "把情緒轉成面向未來的想像。"),
                SongSuggestion("海闊天空", "Beyond", "海闊天空 Beyond", "最後用最有力量的經典做收結。"),
                SongSuggestion("小幸運", "田馥甄", "小幸運 田馥甄", "讓疲倦裡面仍然留住一點柔軟。"),
                SongSuggestion("陪著你走", "盧冠廷", "陪著你走 盧冠廷", "最後補上一種被陪伴的安定感。"),
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
            SongSuggestion("歲月如歌", "陳奕迅", "歲月如歌 陳奕迅", "用熟悉感先打開整個節目的氛圍。"),
            SongSuggestion("K歌之王", "陳奕迅", "K歌之王 陳奕迅", "承接夜色裡那些有口難言的情緒。"),
            SongSuggestion("追", "張國榮", "追 張國榮", "用經典撐起電台 DJ 的深夜質感。"),
            SongSuggestion("高山低谷", "林奕匡", "高山低谷 林奕匡", "讓氣氛逐漸由低回轉向釋放。"),
            SongSuggestion("今天只做一件事", "陳奕迅", "今天只做一件事 陳奕迅", "在後段加入溫柔安定感。"),
            SongSuggestion("海闊天空", "Beyond", "海闊天空 Beyond", "最後用希望感作結。"),
            SongSuggestion("一生中最愛", "譚詠麟", "一生中最愛 譚詠麟", "把節目尾段拉回成熟深夜電台的質感。"),
            SongSuggestion("後來", "劉若英", "後來 劉若英", "留一點餘韻畀聽眾自己慢慢消化。"),
        ),
    )


def _coerce_int(value: Any, field_name: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"`{field_name}` must be an integer.") from exc
