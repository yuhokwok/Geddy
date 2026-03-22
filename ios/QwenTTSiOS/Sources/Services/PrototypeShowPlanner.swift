import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct PlannedDraft {
    enum Source {
        case foundationModels
        case ruleBased
    }

    let draft: RadioShowDraft
    let source: Source
}

@MainActor
protocol RadioShowPlanning {
    func fallbackDrafts(from transcript: String, voiceDescription: String) async -> [PlannedDraft]
}

@MainActor
struct LocalFallbackRadioShowPlanner: RadioShowPlanning {
    private let ruleBasedPlanner = PrototypeShowPlanner()
    private let foundationModelPlanner = OnDeviceFoundationModelPlanner()

    func fallbackDrafts(from transcript: String, voiceDescription: String) async -> [PlannedDraft] {
        var drafts: [PlannedDraft] = []

        if let foundationDraft = await foundationModelPlanner.makeDraft(
            from: transcript,
            voiceDescription: voiceDescription
        ) {
            
            print("try foundation framework program")
            drafts.append(
                PlannedDraft(
                    draft: foundationDraft,
                    source: .foundationModels
                )
            )
        }

        
        print("try rulebase program")
        drafts.append(
            PlannedDraft(
                draft: ruleBasedPlanner.makeDraft(
                    from: transcript,
                    voiceDescription: voiceDescription
                ),
                source: .ruleBased
            )
        )

        return drafts
    }
}

@MainActor
struct PrototypeShowPlanner {
    private struct ThemePack {
        let keywords: [String]
        let title: String
        let mood: String
        let openingLead: String
        let closingLead: String
        let songs: [SongSuggestion]
    }

    func makeDraft(from transcript: String, voiceDescription: String) -> RadioShowDraft {
        let normalized = transcript.lowercased()
        let theme = Self.themePacks.first(where: { pack in
            pack.keywords.contains(where: normalized.contains)
        }) ?? Self.defaultTheme

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = """
        呢度係 AI 鄭子誠。
        你頭先講咗一句：「\(trimmedTranscript)」。
        有啲感受，唔一定要即刻講清楚，但可以慢慢聽清楚。
        我想用幾首歌，同你一齊行過呢一段 \(theme.mood)。
        \(theme.openingLead)
        """

        let bridges = theme.songs.enumerated().dropLast().map { index, song in
            BridgeMonologue(
                afterSongIndex: index,
                text: """
                剛才聽完《\(song.titleHint)》，有時人最怕嘅，唔係回憶太多，而係原來自己仲記得心跳嗰一下。
                如果你一時之間仲未必講得出口，就交畀下一首歌代你講。
                送上《\(theme.songs[index + 1].titleHint)》，俾仍然喺情緒入面慢慢搵出口嘅你。
                """
            )
        }

        let closing = """
        呢段節目差唔多嚟到尾聲。
        你唔需要急住令自己變得冇事，因為真正嘅放低，通常都係慢慢學識同自己相處。
        \(theme.closingLead)
        呢度係 AI 鄭子誠，下次你想搵人陪你聽歌、陪你整理心情，我會再喺度。
        """

        return RadioShowDraft(
            showTitle: theme.title,
            moodSummary: theme.mood,
            openingMonologue: opening,
            songSuggestions: Array(theme.songs.prefix(6)),
            bridgeMonologues: bridges,
            closingMonologue: closing,
            voiceDescription: voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultVoiceDescription
                : voiceDescription
        )
    }
}

extension PrototypeShowPlanner {
    static let defaultVoiceDescription = """
    一把成熟、溫柔、帶少少磁性嘅香港深夜男 DJ 聲線，
    說話節奏從容，情感細膩，像在凌晨電台陪伴失眠聽眾，
    廣東話口吻自然，帶感性而不誇張的陪伴感。
    """

    private static let themePacks: [ThemePack] = [
        ThemePack(
            keywords: ["分手", "掛住", "失戀", "ex", "miss", "love", "想你", "離開"],
            title: "AI 鄭子誠: 掛住一個人嘅夜",
            mood: "未放低的思念",
            openingLead: "如果你仲喺某段關係門口徘徊，希望呢個 playlist 可以陪你坐低一陣。",
            closingLead: "記住，真正重要嘅唔係你幾時忘記，而係你幾時肯重新溫柔對待自己。",
            songs: [
                SongSuggestion(titleHint: "明年今日", artistHint: "陳奕迅", searchQuery: "明年今日 陳奕迅", reason: "第一首先用熟悉嘅遺憾感，帶住聽眾慢慢跌入情緒。"),
                SongSuggestion(titleHint: "鍾無艷", artistHint: "謝安琪", searchQuery: "鍾無艷 謝安琪", reason: "寫畀那些明明付出過，卻未被珍惜的人。"),
                SongSuggestion(titleHint: "如果讓我說下去", artistHint: "楊千嬅", searchQuery: "如果讓我說下去 楊千嬅", reason: "延續想講未講的心事，令節目情緒更深。"),
                SongSuggestion(titleHint: "愛與誠", artistHint: "古巨基", searchQuery: "愛與誠 古巨基", reason: "將關係中最沉重的真心擺上檯面。"),
                SongSuggestion(titleHint: "小城大事", artistHint: "楊千嬅", searchQuery: "小城大事 楊千嬅", reason: "讓思念由個人回憶擴散成城市夜色。"),
                SongSuggestion(titleHint: "好心分手", artistHint: "盧巧音", searchQuery: "好心分手 盧巧音", reason: "最後用比較收斂但仍然刺心的角度作結。")
            ]
        ),
        ThemePack(
            keywords: ["回憶", "以前", "青春", "舊", "懷念", "nostalgia"],
            title: "AI 鄭子誠: 舊日時光特輯",
            mood: "懷舊和餘溫",
            openingLead: "有些年份過咗去，但某一首歌一響，原來連空氣都會陪你回去。",
            closingLead: "回憶最動人嘅地方，唔係要你回頭，而係提醒你曾經好認真咁活過。",
            songs: [
                SongSuggestion(titleHint: "追", artistHint: "張國榮", searchQuery: "追 張國榮", reason: "用一首經典把節目帶回最純粹的感情。"),
                SongSuggestion(titleHint: "歲月如歌", artistHint: "陳奕迅", searchQuery: "歲月如歌 陳奕迅", reason: "讓聽眾進入時間慢慢流過的感覺。"),
                SongSuggestion(titleHint: "最佳損友", artistHint: "陳奕迅", searchQuery: "最佳損友 陳奕迅", reason: "把青春裡那些失散的人也帶入節目。"),
                SongSuggestion(titleHint: "一生中最愛", artistHint: "譚詠麟", searchQuery: "一生中最愛 譚詠麟", reason: "將懷舊情緒推到最濃。"),
                SongSuggestion(titleHint: "後來", artistHint: "劉若英", searchQuery: "後來 劉若英", reason: "給那些多年後才懂自己的心事一個出口。"),
                SongSuggestion(titleHint: "十年", artistHint: "陳奕迅", searchQuery: "十年 陳奕迅", reason: "最後再回到時間與關係的重量。")
            ]
        ),
        ThemePack(
            keywords: ["辛苦", "攰", "工作", "壓力", "加油", "heal", "healing", "support"],
            title: "AI 鄭子誠: 給努力生活的人",
            mood: "療癒與重新呼吸",
            openingLead: "如果你今日已經用盡力氣，依家就唔好再逼自己堅強，先慢慢抖一口氣。",
            closingLead: "希望你記住，溫柔唔係軟弱，而係明知辛苦仍然願意對自己好一點。",
            songs: [
                SongSuggestion(titleHint: "陀飛輪", artistHint: "陳奕迅", searchQuery: "陀飛輪 陳奕迅", reason: "點出成年人最真實的時間焦慮。"),
                SongSuggestion(titleHint: "高山低谷", artistHint: "林奕匡", searchQuery: "高山低谷 林奕匡", reason: "承接跌宕情緒，帶出慢慢抬頭的力量。"),
                SongSuggestion(titleHint: "今天只做一件事", artistHint: "陳奕迅", searchQuery: "今天只做一件事 陳奕迅", reason: "提醒聽眾依家可以先只照顧一件事，就是自己。"),
                SongSuggestion(titleHint: "下一站天后", artistHint: "Twins", searchQuery: "下一站天后 Twins", reason: "加一點明亮，令節目不只是低沉。"),
                SongSuggestion(titleHint: "光年之外", artistHint: "G.E.M.", searchQuery: "光年之外 G.E.M.", reason: "把情緒轉成面向未來的想像。"),
                SongSuggestion(titleHint: "海闊天空", artistHint: "Beyond", searchQuery: "海闊天空 Beyond", reason: "最後用最有力量的經典做收結。")
            ]
        )
    ]

    private static let defaultTheme = ThemePack(
        keywords: [],
        title: "AI 鄭子誠: 深夜陪伴線",
        mood: "靜靜陪伴",
        openingLead: "唔知道你而家帶住咩心事入嚟，但我想先陪你慢慢坐低。",
        closingLead: "情緒總會慢慢有出口，但有人陪你行過，條路會冇咁難行。",
        songs: [
            SongSuggestion(titleHint: "歲月如歌", artistHint: "陳奕迅", searchQuery: "歲月如歌 陳奕迅", reason: "用熟悉感先打開整個節目的氛圍。"),
            SongSuggestion(titleHint: "K歌之王", artistHint: "陳奕迅", searchQuery: "K歌之王 陳奕迅", reason: "承接夜色裡那些有口難言的情緒。"),
            SongSuggestion(titleHint: "追", artistHint: "張國榮", searchQuery: "追 張國榮", reason: "用經典撐起電台 DJ 的深夜質感。"),
            SongSuggestion(titleHint: "高山低谷", artistHint: "林奕匡", searchQuery: "高山低谷 林奕匡", reason: "讓氣氛逐漸由低回轉向釋放。"),
            SongSuggestion(titleHint: "今天只做一件事", artistHint: "陳奕迅", searchQuery: "今天只做一件事 陳奕迅", reason: "在後段加入溫柔安定感。"),
            SongSuggestion(titleHint: "海闊天空", artistHint: "Beyond", searchQuery: "海闊天空 Beyond", reason: "最後用希望感作結。")
        ]
    )
}

@MainActor
struct OnDeviceFoundationModelPlanner {
    func makeDraft(from transcript: String, voiceDescription: String) async -> RadioShowDraft? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        return await makeDraftWithFoundationModels(
            from: transcript,
            voiceDescription: voiceDescription
        )
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func makeDraftWithFoundationModels(
        from transcript: String,
        voiceDescription: String
    ) async -> RadioShowDraft? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return nil
        }

        let instructions = """
        你係香港情感電台 DJ 節目編導，幫一個叫 AI 鄭子誠嘅 iOS app 生成節目稿。
        只可以用繁體中文，同自然廣東話口吻。
        要有完整節目結構：show title、mood summary、opening monologue、6 首歌建議、5 段 bridge monologues、closing monologue。
        每首歌都要提供 titleHint、artistHint、searchQuery、reason。
        searchQuery 係俾 iOS 之後用 Apple Music 搜尋，唔需要驗證 catalog。
        保留深夜電台式嘅溫柔陪伴感，但唔好假設現實時間一定係夜晚。
        """

        let prompt = """
        聽眾輸入：\(transcript)

        主持聲線描述：\(voiceDescription)

        請生成一個 6 首歌嘅陪伴系節目。語氣要感性、克制、有陪伴感，避免明確講而家係今晚、凌晨或者夜深。
        只可以回傳 JSON，結構如下：
        {
          "showTitle": "...",
          "moodSummary": "...",
          "openingMonologue": "...",
          "songSuggestions": [
            {
              "titleHint": "...",
              "artistHint": "...",
              "searchQuery": "...",
              "reason": "..."
            }
          ],
          "bridgeMonologues": [
            {
              "text": "..."
            }
          ],
          "closingMonologue": "...",
          "voiceDescription": "..."
        }
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let responseText = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = responseText.data(using: .utf8) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(FoundationModelShowDraft.self, from: data)
            return normalize(
                decoded,
                fallbackVoiceDescription: voiceDescription
            )
        } catch {
            return nil
        }
    }

    @available(iOS 26.0, *)
    private func normalize(
        _ generated: FoundationModelShowDraft,
        fallbackVoiceDescription: String
    ) -> RadioShowDraft? {
        let songs = generated.songSuggestions
            .prefix(6)
            .compactMap { suggestion -> SongSuggestion? in
                let title = suggestion.titleHint.trimmingCharacters(in: .whitespacesAndNewlines)
                let artist = suggestion.artistHint.trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawQuery = suggestion.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                let query = rawQuery.isEmpty ? "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines) : rawQuery

                guard !title.isEmpty, !artist.isEmpty, !reason.isEmpty, !query.isEmpty else {
                    return nil
                }

                return SongSuggestion(
                    titleHint: title,
                    artistHint: artist,
                    searchQuery: query,
                    reason: reason
                )
            }

        let bridges = generated.bridgeMonologues
            .prefix(5)
            .enumerated()
            .compactMap { index, bridge -> BridgeMonologue? in
                let text = bridge.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return BridgeMonologue(afterSongIndex: index, text: text)
            }

        let showTitle = generated.showTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let moodSummary = generated.moodSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = generated.openingMonologue.trimmingCharacters(in: .whitespacesAndNewlines)
        let closing = generated.closingMonologue.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceDescription = generated.voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        guard songs.count == 6, bridges.count == 5 else {
            return nil
        }

        guard !showTitle.isEmpty, !moodSummary.isEmpty, !opening.isEmpty, !closing.isEmpty else {
            return nil
        }

        return RadioShowDraft(
            showTitle: showTitle,
            moodSummary: moodSummary,
            openingMonologue: opening,
            songSuggestions: songs,
            bridgeMonologues: bridges,
            closingMonologue: closing,
            voiceDescription: voiceDescription.isEmpty
                ? fallbackVoiceDescription
                : voiceDescription
        )
    }

    @available(iOS 26.0, *)
    private struct FoundationModelShowDraft: Decodable {
        var showTitle: String
        var moodSummary: String
        var openingMonologue: String
        var songSuggestions: [FoundationModelSongSuggestion]
        var bridgeMonologues: [FoundationModelBridgeMonologue]
        var closingMonologue: String
        var voiceDescription: String
    }

    @available(iOS 26.0, *)
    private struct FoundationModelSongSuggestion: Decodable {
        var titleHint: String
        var artistHint: String
        var searchQuery: String
        var reason: String
    }

    @available(iOS 26.0, *)
    private struct FoundationModelBridgeMonologue: Decodable {
        var text: String
    }
    #endif
}
