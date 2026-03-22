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
    func fallbackDrafts(
        from transcript: String,
        voiceDescription: String,
        desiredSongCount: Int,
        songPreferences: ProgramSongPreferences
    ) async -> [PlannedDraft]
}

@MainActor
struct LocalFallbackRadioShowPlanner: RadioShowPlanning {
    private let ruleBasedPlanner = PrototypeShowPlanner()
    private let foundationModelPlanner = OnDeviceFoundationModelPlanner()

    func fallbackDrafts(
        from transcript: String,
        voiceDescription: String,
        desiredSongCount: Int,
        songPreferences: ProgramSongPreferences
    ) async -> [PlannedDraft] {
        var drafts: [PlannedDraft] = []

        if let foundationDraft = await foundationModelPlanner.makeDraft(
            from: transcript,
            voiceDescription: voiceDescription,
            desiredSongCount: desiredSongCount,
            songPreferences: songPreferences
        ) {
            drafts.append(
                PlannedDraft(
                    draft: foundationDraft,
                    source: .foundationModels
                )
            )
        }

        drafts.append(
            PlannedDraft(
                draft: ruleBasedPlanner.makeDraft(
                    from: transcript,
                    voiceDescription: voiceDescription,
                    desiredSongCount: desiredSongCount,
                    songPreferences: songPreferences
                ),
                source: .ruleBased
            )
        )

        return drafts
    }
}

@MainActor
struct PrototypeShowPlanner {
    private struct CuratedSong {
        let era: SongEraOption
        let category: SongCategoryOption
        let suggestion: SongSuggestion
    }

    private struct ThemePack {
        let keywords: [String]
        let title: String
        let mood: String
        let openingLead: String
        let closingLead: String
        let songs: [CuratedSong]
    }

    func makeDraft(
        from transcript: String,
        voiceDescription: String,
        desiredSongCount: Int,
        songPreferences: ProgramSongPreferences
    ) -> RadioShowDraft {
        let normalized = transcript.lowercased()
        let theme = Self.themePacks.first(where: { pack in
            pack.keywords.contains(where: normalized.contains)
        }) ?? Self.defaultTheme
        let songs = selectSongs(
            from: theme,
            desiredSongCount: desiredSongCount,
            preferences: songPreferences
        )

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = """
        呢度係 AI 鄭子誠。
        你頭先講咗一句：「\(trimmedTranscript)」。
        有啲感受，唔一定要即刻講清楚，但可以慢慢聽清楚。
        我想用一組\(songPreferences.songCategory.title)，陪你由\(songPreferences.eraSummary)一路行過呢一段 \(theme.mood)。
        \(theme.openingLead)
        """

        let bridges = songs.enumerated().dropLast().map { index, song in
            BridgeMonologue(
                afterSongIndex: index,
                text: """
                剛才聽完《\(song.titleHint)》，有時人最怕嘅，唔係回憶太多，而係原來自己仲記得心跳嗰一下。
                如果你一時之間仲未必講得出口，就交畀下一首歌代你講。
                送上《\(songs[index + 1].titleHint)》，俾仍然喺情緒入面慢慢搵出口嘅你。
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
            songSuggestions: songs,
            bridgeMonologues: bridges,
            closingMonologue: closing,
            voiceDescription: voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultVoiceDescription
                : voiceDescription
        )
    }

    private func selectSongs(
        from theme: ThemePack,
        desiredSongCount: Int,
        preferences: ProgramSongPreferences
    ) -> [SongSuggestion] {
        let themeMatches = theme.songs
            .filter { matches(song: $0, preferences: preferences) }
            .map(\.suggestion)
        let catalogMatches = Self.catalogSongs
            .filter { matches(song: $0, preferences: preferences) }
            .map(\.suggestion)
        var ordered = dedupe(themeMatches + catalogMatches)

        if ordered.count < desiredSongCount {
            ordered = dedupe(
                ordered
                    + theme.songs.map(\.suggestion)
                    + Self.catalogSongs.map(\.suggestion)
            )
        }

        return Array(ordered.prefix(desiredSongCount))
    }

    private func matches(
        song: CuratedSong,
        preferences: ProgramSongPreferences
    ) -> Bool {
        song.category == preferences.songCategory
            && song.era.rawValue >= preferences.eraRangeStart.rawValue
            && song.era.rawValue <= preferences.eraRangeEnd.rawValue
    }

    private func dedupe(_ songs: [SongSuggestion]) -> [SongSuggestion] {
        var seen = Set<String>()
        return songs.filter { song in
            let key = "\(song.titleHint.lowercased())::\(song.artistHint.lowercased())"
            return seen.insert(key).inserted
        }
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
                song(.twoThousands, .cantonese, "明年今日", "陳奕迅", "第一首先用熟悉嘅遺憾感，帶住聽眾慢慢跌入情緒。"),
                song(.twoThousands, .cantonese, "鍾無艷", "謝安琪", "寫畀那些明明付出過，卻未被珍惜的人。"),
                song(.twoThousands, .cantonese, "如果讓我說下去", "楊千嬅", "延續想講未講的心事，令節目情緒更深。"),
                song(.twoThousands, .cantonese, "愛與誠", "古巨基", "將關係中最沉重的真心擺上檯面。"),
                song(.twoThousands, .cantonese, "好心分手", "盧巧音", "最後用比較收斂但仍然刺心的角度作結。"),
                song(.nineties, .cantonese, "追", "張國榮", "用偏向懷念的角度，放大掛住一個人的失重感。"),
                song(.eighties, .cantonese, "一生何求", "陳百強", "將舊情未放低的重量拉回經典年代。"),
                song(.modern, .cantonese, "高山低谷", "林奕匡", "讓情緒由失落慢慢行到面對自己。"),
                song(.twoThousands, .mandarin, "十年", "陳奕迅", "把熟悉的遺憾感轉成更直接的華語流行情緒。"),
                song(.twoThousands, .mandarin, "可惜不是你", "梁靜茹", "寫出那種明明很近卻再也回不去的距離。"),
                song(.twoThousands, .mandarin, "成全", "劉若英", "把不捨推向成熟放手的層次。"),
                song(.nineties, .mandarin, "味道", "辛曉琪", "讓思念變得更具畫面感，也更貼近舊情回憶。"),
                song(.nineties, .mandarin, "聽海", "張惠妹", "把壓住的情緒打開，讓掛念有出口。"),
                song(.modern, .mandarin, "慢冷", "梁靜茹", "延續那種後知後覺的難受與自省。"),
                song(.modern, .mandarin, "小幸運", "田馥甄", "讓回憶帶點暖意，不至於全程下沉。"),
                song(.seventies, .mandarin, "月亮代表我的心", "鄧麗君", "如果想將年代拉早，這首歌能把思念說得非常純粹。")
            ]
        ),
        ThemePack(
            keywords: ["回憶", "以前", "青春", "舊", "懷念", "nostalgia"],
            title: "AI 鄭子誠: 舊日時光特輯",
            mood: "懷舊和餘溫",
            openingLead: "有些年份過咗去，但某一首歌一響，原來連空氣都會陪你回去。",
            closingLead: "回憶最動人嘅地方，唔係要你回頭，而係提醒你曾經好認真咁活過。",
            songs: [
                song(.nineties, .cantonese, "追", "張國榮", "用一首經典把節目帶回最純粹的感情。"),
                song(.twoThousands, .cantonese, "歲月如歌", "陳奕迅", "讓聽眾進入時間慢慢流過的感覺。"),
                song(.twoThousands, .cantonese, "最佳損友", "陳奕迅", "把青春裡那些失散的人也帶入節目。"),
                song(.eighties, .cantonese, "千千闋歌", "陳慧嫻", "用經典收束舊日時光的餘韻。"),
                song(.eighties, .cantonese, "一生何求", "陳百強", "將懷舊情緒推到最濃。"),
                song(.nineties, .cantonese, "友情歲月", "鄭伊健", "把青春的畫面拉闊到更有電影感。"),
                song(.seventies, .cantonese, "啼笑因緣", "仙杜拉", "如果想更舊派一點，這首歌可以立刻帶出老派電台感。"),
                song(.eighties, .cantonese, "Monica", "張國榮", "加一點節奏感，讓懷舊不只停留在低回。"),
                song(.seventies, .mandarin, "月亮代表我的心", "鄧麗君", "把回憶拉回最雋永、最直接的年代。"),
                song(.eighties, .mandarin, "明天你是否依然愛我", "童安格", "把青春時代的掛念與不確定慢慢帶出來。"),
                song(.nineties, .mandarin, "後來", "劉若英", "給那些多年後才懂自己的心事一個出口。"),
                song(.nineties, .mandarin, "聽海", "張惠妹", "讓舊記憶變得更具海浪感同空間感。"),
                song(.twoThousands, .mandarin, "十年", "陳奕迅", "最後再回到時間與關係的重量。"),
                song(.twoThousands, .mandarin, "後來的我們", "五月天", "把回憶感延伸到成年之後的回望。"),
                song(.modern, .mandarin, "小幸運", "田馥甄", "保留一點青春暖色，令整個懷舊旅程更完整。"),
                song(.modern, .mandarin, "連名帶姓", "張惠妹", "讓回憶不只溫柔，也有刺痛與未完成感。")
            ]
        ),
        ThemePack(
            keywords: ["辛苦", "攰", "工作", "壓力", "加油", "heal", "healing", "support"],
            title: "AI 鄭子誠: 給努力生活的人",
            mood: "療癒與重新呼吸",
            openingLead: "如果你今日已經用盡力氣，依家就唔好再逼自己堅強，先慢慢抖一口氣。",
            closingLead: "希望你記住，溫柔唔係軟弱，而係明知辛苦仍然願意對自己好一點。",
            songs: [
                song(.modern, .cantonese, "陀飛輪", "陳奕迅", "點出成年人最真實的時間焦慮。"),
                song(.modern, .cantonese, "高山低谷", "林奕匡", "承接跌宕情緒，帶出慢慢抬頭的力量。"),
                song(.modern, .cantonese, "今天只做一件事", "陳奕迅", "提醒聽眾依家可以先只照顧一件事，就是自己。"),
                song(.twoThousands, .cantonese, "下一站天后", "Twins", "加一點明亮，令節目不只是低沉。"),
                song(.nineties, .cantonese, "海闊天空", "Beyond", "最後用最有力量的經典做收結。"),
                song(.eighties, .cantonese, "陪著你走", "盧冠廷", "補上一種被陪伴的安定感。"),
                song(.eighties, .cantonese, "偏偏喜歡你", "陳百強", "在療癒路線中留一點柔和懷舊感。"),
                song(.twoThousands, .cantonese, "終身美麗", "鄭秀文", "把辛苦過後的自我接納慢慢講出來。"),
                song(.modern, .mandarin, "光年之外", "G.E.M.", "把情緒轉成面向未來的想像。"),
                song(.modern, .mandarin, "小幸運", "田馥甄", "讓疲倦裡面仍然留住一點柔軟。"),
                song(.twoThousands, .mandarin, "勇氣", "梁靜茹", "提醒聽眾重新向前，需要的只是小小勇氣。"),
                song(.twoThousands, .mandarin, "隱形的翅膀", "張韶涵", "給正在捱過低潮的人一點明亮的支撐。"),
                song(.modern, .mandarin, "平凡之路", "朴樹", "讓節目慢慢走去比較開闊的結尾。"),
                song(.modern, .mandarin, "演員", "薛之謙", "把壓力與關係中的消耗，換成一種看清自己的距離。"),
                song(.twoThousands, .mandarin, "成全", "劉若英", "讓療癒路線保留成熟與放手的角度。"),
                song(.modern, .mandarin, "連名帶姓", "張惠妹", "即使療癒主題，也保留情緒並未完全散去的真實。")
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
            song(.twoThousands, .cantonese, "歲月如歌", "陳奕迅", "用熟悉感先打開整個節目的氛圍。"),
            song(.twoThousands, .cantonese, "K歌之王", "陳奕迅", "承接那些有口難言的情緒。"),
            song(.nineties, .cantonese, "追", "張國榮", "用經典撐起電台 DJ 的陪伴質感。"),
            song(.modern, .cantonese, "高山低谷", "林奕匡", "讓氣氛逐漸由低回轉向釋放。"),
            song(.modern, .cantonese, "今天只做一件事", "陳奕迅", "在後段加入溫柔安定感。"),
            song(.nineties, .cantonese, "海闊天空", "Beyond", "最後用希望感作結。"),
            song(.eighties, .cantonese, "偏偏喜歡你", "陳百強", "把節目尾段拉回成熟電台的經典質感。"),
            song(.seventies, .cantonese, "家變", "羅文", "如果想更舊派，這首歌可以立即拉出七十年代氣味。"),
            song(.modern, .mandarin, "小幸運", "田馥甄", "留一點柔軟餘韻畀聽眾自己慢慢消化。"),
            song(.twoThousands, .mandarin, "十年", "陳奕迅", "用熟悉度高的作品承接情緒。"),
            song(.nineties, .mandarin, "聽海", "張惠妹", "讓感受有更大的空間可以呼吸。"),
            song(.eighties, .mandarin, "明天你是否依然愛我", "童安格", "用老派情歌留住陪伴感。"),
            song(.seventies, .mandarin, "月亮代表我的心", "鄧麗君", "如果要更早年代，這首歌幾乎一響就有畫面。"),
            song(.twoThousands, .mandarin, "勇氣", "梁靜茹", "在尾段補上一點向前走的力量。")
        ]
    )

    private static let catalogSongs: [CuratedSong] = {
        var ordered: [CuratedSong] = []
        var seen = Set<String>()
        for theme in themePacks + [defaultTheme] {
            for song in theme.songs {
                let key = "\(song.suggestion.titleHint.lowercased())::\(song.suggestion.artistHint.lowercased())"
                if seen.insert(key).inserted {
                    ordered.append(song)
                }
            }
        }
        return ordered
    }()

    private static func song(
        _ era: SongEraOption,
        _ category: SongCategoryOption,
        _ title: String,
        _ artist: String,
        _ reason: String
    ) -> CuratedSong {
        CuratedSong(
            era: era,
            category: category,
            suggestion: SongSuggestion(
                titleHint: title,
                artistHint: artist,
                searchQuery: "\(title) \(artist)",
                reason: reason
            )
        )
    }
}

@MainActor
struct OnDeviceFoundationModelPlanner {
    func makeDraft(
        from transcript: String,
        voiceDescription: String,
        desiredSongCount: Int,
        songPreferences: ProgramSongPreferences
    ) async -> RadioShowDraft? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        return await makeDraftWithFoundationModels(
            from: transcript,
            voiceDescription: voiceDescription,
            desiredSongCount: desiredSongCount,
            songPreferences: songPreferences
        )
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func makeDraftWithFoundationModels(
        from transcript: String,
        voiceDescription: String,
        desiredSongCount: Int,
        songPreferences: ProgramSongPreferences
    ) async -> RadioShowDraft? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return nil
        }

        let instructions = """
        你係香港情感電台 DJ 節目編導，幫一個叫 AI 鄭子誠嘅 iOS app 生成節目稿。
        只可以用繁體中文，同自然廣東話口吻。
        要有完整節目結構：show title、mood summary、opening monologue、\(desiredSongCount) 首歌建議、\(max(desiredSongCount - 1, 0)) 段 bridge monologues、closing monologue。
        每首歌都要提供 titleHint、artistHint、searchQuery、reason。
        searchQuery 係俾 iOS 之後用 Apple Music 搜尋，唔需要驗證 catalog。
        保留深夜電台式嘅溫柔陪伴感，但唔好假設現實時間一定係夜晚。
        要準確跟從用戶要求嘅歌曲種類同年代範圍。
        """

        let prompt = """
        聽眾輸入：\(transcript)

        主持聲線描述：\(voiceDescription)

        歌曲種類：\(songPreferences.songCategory.title)
        年代範圍：\(songPreferences.eraSummary)

        請生成一個 \(desiredSongCount) 首歌嘅陪伴系節目。語氣要感性、克制、有陪伴感，避免明確講而家係今晚、凌晨或者夜深。
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
                fallbackVoiceDescription: voiceDescription,
                desiredSongCount: desiredSongCount
            )
        } catch {
            return nil
        }
    }

    @available(iOS 26.0, *)
    private func normalize(
        _ generated: FoundationModelShowDraft,
        fallbackVoiceDescription: String,
        desiredSongCount: Int
    ) -> RadioShowDraft? {
        let songs = generated.songSuggestions
            .prefix(desiredSongCount)
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
            .prefix(max(desiredSongCount - 1, 0))
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

        guard songs.count == desiredSongCount, bridges.count == max(desiredSongCount - 1, 0) else {
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
