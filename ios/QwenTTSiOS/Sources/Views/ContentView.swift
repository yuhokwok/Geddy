import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = RadioDJViewModel()
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    heroSection
                    voiceInputSection
                    showControlsSection
                    playlistSection
                    savedProgramsSection
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.immediately)
            .background {
                Rectangle()
                    .fill(backgroundGradient)
                    .ignoresSafeArea()
            }
            .navigationTitle("Geddy")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("設定")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomPlayerBar
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .overlay {
            if viewModel.isPreparingShow {
                preparingShowOverlay
                    .transition(.opacity)
            }
        }
        .alert("Geddy", isPresented: Binding(
            get: { viewModel.alertMessage != nil },
            set: { shouldShow in
                if !shouldShow {
                    viewModel.alertMessage = nil
                }
            }
        )) {
            Button("知道") {
                viewModel.alertMessage = nil
            }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }

    private var preparingShowOverlay: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.98, green: 0.93, blue: 0.85).opacity(0.94),
                            Color(red: 0.92, green: 0.82, blue: 0.72).opacity(0.96)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image("88-icon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: Color.black.opacity(0.12), radius: 20, y: 10)

                VStack(spacing: 10) {
                    Text("Geddy 正在為你用心點歌，請放下手機稍等")
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)

                    ProgressView()
                        .tint(Color(red: 0.84, green: 0.37, blue: 0.18))
                        .scaleEffect(1.15)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.45), lineWidth: 1)
                )
                .padding(.horizontal, 24)
            }
            .padding(.horizontal, 24)
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("情感電台 DJ 原型")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            Text("錄低一句心事，交畀 AI 幫你編成一個有歌、有獨白、有收結嘅陪伴系節目。")
                .font(.system(size: 34, weight: .bold, design: .rounded))

//            Text("流程會先用 Speech Analyzer 將語音轉成文字，再由 backend 生成節目稿同歌曲建議，之後由 app 本地用 Apple Music 搜尋歌曲；當首 3 段獨白準備好之後就會開始播放，其餘獨白會繼續背景生成。")
//                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label(viewModel.backendModelName, systemImage: "waveform.and.mic")
                    .font(.subheadline.weight(.semibold))
                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var voiceInputSection: some View {
        card("語音輸入") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Speech Analyzer", systemImage: "mic.badge.plus")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        Task {
                            await viewModel.toggleRecording()
                        }
                    } label: {
                        Label(viewModel.isRecording ? "停止錄音" : "開始錄音", systemImage: viewModel.isRecording ? "stop.circle.fill" : "waveform.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(viewModel.isRecording ? .red : Color(red: 0.84, green: 0.37, blue: 0.18))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("用家心事 / 主題")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $viewModel.transcriptText)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 150)
                        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                Text("例如：最近好掛住以前拍拖嗰陣，明知唔應該回頭，但仲係會諗起對方。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var showControlsSection: some View {
        card("主持聲線與節目生成") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("人聲 preset")
                        .font(.subheadline.weight(.semibold))

                    Picker("人聲 preset", selection: $viewModel.selectedVoicePresetID) {
                        ForEach(viewModel.availableVoicePresets) { preset in
                            Text(preset.label).tag(preset.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Text("揀完之後，下面嘅 DJ 聲線描述會自動帶入；你仍然可以再手動微調。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("DJ 聲線描述")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $viewModel.hostStyleDescription)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 110)
                        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("歌曲種類")
                        .font(.subheadline.weight(.semibold))

                    Picker("歌曲種類", selection: $viewModel.selectedSongCategory) {
                        ForEach(SongCategoryOption.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(viewModel.selectedSongCategory.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("歌曲年代")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(viewModel.songPreferences.eraSummary)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    EraRangeSlider(
                        lowerIndex: Binding(
                            get: { eraIndex(for: viewModel.selectedEraRangeStart) },
                            set: { viewModel.selectedEraRangeStart = eraOption(at: $0) }
                        ),
                        upperIndex: Binding(
                            get: { eraIndex(for: viewModel.selectedEraRangeEnd) },
                            set: { viewModel.selectedEraRangeEnd = eraOption(at: $0) }
                        ),
                        options: SongEraOption.allCases
                    )
                    .frame(height: 88)

                    Text("由 70、80、90、00、10 年代一路揀到現代，Geddy 會盡量將歌單鎖定喺你指定嘅年代範圍。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $viewModel.preferObscureSongs) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("想要冷門歌曲")
                                .font(.subheadline.weight(.semibold))
                            Text(viewModel.songPreferences.obscureSongsSummary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                Button {
                    Task {
                        await viewModel.prepareShow()
                    }
                } label: {
                    HStack {
                        if viewModel.isPreparingShow {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(viewModel.isPreparingShow ? "編排節目中..." : "讓 Geddy 為你選歌")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.84, green: 0.37, blue: 0.18))
                .disabled(viewModel.isPreparingShow || viewModel.isRecording)
            }
        }
    }

    @ViewBuilder
    private var playlistSection: some View {
        if let show = viewModel.currentShow {
            card("節目清單") {
                VStack(alignment: .leading, spacing: 16) {
                    Text(show.title)
                        .font(.title3.weight(.bold))

                    Text(show.moodSummary)
                        .foregroundStyle(.secondary)

                    if let opening = show.openingItem {
                        spokenCard(
                            title: "開場白",
                            text: opening.spokenClip?.text ?? opening.title,
                            caption: opening.subtitle,
                            buttonLabel: "播放開場白",
                            item: opening
                        )
                    }

                    ForEach(Array(show.playlistItems.enumerated()), id: \.element.id) { index, item in
                        switch item.payload {
                        case .song(let resolvedSong):
                            songCard(
                                number: show.playlistItems.prefix(index + 1).filter { $0.kind == .song }.count,
                                resolvedSong: resolvedSong
                            )
                        case .speech(let clip):
                            if item.kind == .bridge {
                                spokenCard(
                                    title: "過場獨白",
                                    text: clip.text,
                                    caption: {
                                        if let previousSongTitle = show.playlistItems[..<index].last(where: { $0.kind == .song })?.title {
                                            return "接住上一首〈\(previousSongTitle)〉之後播出"
                                        }
                                        return "歌與歌之間播出"
                                    }(),
                                    buttonLabel: "播放過場",
                                    item: item
                                )
                            }
                        }
                    }

                    if let closing = show.closingItem {
                        spokenCard(
                            title: "收場白",
                            text: closing.spokenClip?.text ?? closing.title,
                            caption: "節目尾聲",
                            buttonLabel: "播放收場白",
                            item: closing
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var savedProgramsSection: some View {
        if viewModel.currentShow != nil || !viewModel.savedPrograms.isEmpty {
            card("已儲存節目") {
                VStack(alignment: .leading, spacing: 14) {
                    if viewModel.currentShow != nil {
                        Button {
                            viewModel.saveCurrentShow()
                        } label: {
                            Label("儲存而家節目", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.84, green: 0.37, blue: 0.18))
                    }

                    if viewModel.savedPrograms.isEmpty {
                        Text("未有已儲存節目。之後你可以將編排好嘅節目儲低，再喺呢度揀返嚟聽。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.savedPrograms) { savedProgram in
                            savedProgramRow(savedProgram)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var bottomPlayerBar: some View {
        if viewModel.currentShow != nil {
            VStack(alignment: .leading, spacing: 14) {
                if let item = viewModel.currentPlaybackItem {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: playbackSymbol(for: item))
                            .font(.title3)
                            .foregroundStyle(Color(red: 0.84, green: 0.37, blue: 0.18))
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(viewModel.isPlaying ? "播放中" : "已暫停")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(viewModel.isPlaying ? Color(red: 0.84, green: 0.37, blue: 0.18) : .secondary)
                            }
                            HStack {
                                Text("\(playbackKindLabel(for: item)) · \(item.subtitle)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(viewModel.playbackElapsedText) / \(viewModel.playbackRemainingText)")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                } else {
                    Text("節目已就緒，可以開始播放。")
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: viewModel.playbackProgress)
                    .tint(Color(red: 0.84, green: 0.37, blue: 0.18))

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await viewModel.skipToPreviousSegment()
                        }
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("上一段")

                    Button {
                        Task {
                            await viewModel.togglePlayback()
                        }
                    } label: {
                        Label(viewModel.isPlaying ? "暫停" : "播放", systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.84, green: 0.37, blue: 0.18))

                    Button {
                        Task {
                            await viewModel.skipToNextSegment()
                        }
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("下一段")

                    Button {
                        viewModel.stopPlayback()
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.36),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.white.opacity(0.48), lineWidth: 1)

                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(0.22),
                                    Color.clear
                                ],
                                center: .topLeading,
                                startRadius: 8,
                                endRadius: 220
                            )
                        )
                }
                .shadow(color: Color.black.opacity(0.08), radius: 24, y: -6)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .background(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.16),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                )
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.bold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var backgroundGradient: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.93, blue: 0.85),
                Color(red: 0.95, green: 0.86, blue: 0.75),
                Color(red: 0.88, green: 0.75, blue: 0.68)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func songCard(number: Int, resolvedSong: ResolvedSong) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text("\(number).")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(resolvedSong.title) · \(resolvedSong.artistName)")
                        .font(.headline)
                    Text(resolvedSong.suggestion.reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(resolvedSong.durationText)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func savedProgramRow(_ savedProgram: SavedProgramSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(savedProgram.title)
                        .font(.headline)
                    Text(savedProgram.moodSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button {
                        Task {
                            await viewModel.loadSavedProgram(savedProgram)
                        }
                    } label: {
                        Label("再聽", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        viewModel.deleteSavedProgram(savedProgram)
                    } label: {
                        Label("刪除", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !savedProgram.transcriptPreview.isEmpty {
                Text(savedProgram.transcriptPreview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Text("\(savedProgram.songCount) 首歌")
                Spacer()
                Text(savedProgram.savedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func spokenCard(
        title: String,
        text: String,
        caption: String,
        buttonLabel: String,
        item: StationPlaybackItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    Task {
                        await viewModel.playPlaybackItem(item)
                    }
                } label: {
                    Label(buttonLabel, systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
            }

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Text(caption)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
        )
    }

    private func eraIndex(for option: SongEraOption) -> Int {
        SongEraOption.allCases.firstIndex(of: option) ?? 0
    }

    private func eraOption(at index: Int) -> SongEraOption {
        let clampedIndex = min(max(index, 0), SongEraOption.allCases.count - 1)
        return SongEraOption.allCases[clampedIndex]
    }

    private func playbackKindLabel(for item: StationPlaybackItem) -> String {
        switch item.kind {
        case .opening:
            return "開場白"
        case .song:
            return "歌曲"
        case .bridge:
            return "過場獨白"
        case .closing:
            return "收場白"
        }
    }

    private func playbackSymbol(for item: StationPlaybackItem) -> String {
        switch item.kind {
        case .song:
            return "music.note"
        case .opening, .bridge, .closing:
            return "mic.fill"
        }
    }
}

private struct EraRangeSlider: View {
    @Binding var lowerIndex: Int
    @Binding var upperIndex: Int
    let options: [SongEraOption]

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - 28, 1)
            let stepWidth = width / CGFloat(max(options.count - 1, 1))
            let lowerX = 14 + CGFloat(lowerIndex) * stepWidth
            let upperX = 14 + CGFloat(upperIndex) * stepWidth

            VStack(spacing: 14) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.48))
                        .frame(height: 8)

                    Capsule()
                        .fill(Color(red: 0.84, green: 0.37, blue: 0.18))
                        .frame(width: max(upperX - lowerX, 8), height: 8)
                        .offset(x: lowerX)

                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        VStack(spacing: 8) {
                            Circle()
                                .fill(index >= lowerIndex && index <= upperIndex
                                    ? Color(red: 0.84, green: 0.37, blue: 0.18)
                                    : Color.white.opacity(0.9)
                                )
                                .frame(width: 10, height: 10)
                            Text(option.shortTitle)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .position(x: 14 + CGFloat(index) * stepWidth, y: 20)
                    }

                    thumb
                        .position(x: lowerX, y: 4)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let index = snappedIndex(for: value.location.x, width: width)
                                    lowerIndex = min(index, upperIndex)
                                }
                        )

                    thumb
                        .position(x: upperX, y: 4)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let index = snappedIndex(for: value.location.x, width: width)
                                    upperIndex = max(index, lowerIndex)
                                }
                        )
                }
                .frame(height: 44)
            }
        }
    }

    private var thumb: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 28, height: 28)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .overlay(
                Circle()
                    .stroke(Color(red: 0.84, green: 0.37, blue: 0.18), lineWidth: 3)
            )
    }

    private func snappedIndex(for locationX: CGFloat, width: CGFloat) -> Int {
        guard options.count > 1 else { return 0 }
        let stepWidth = width / CGFloat(options.count - 1)
        let offset = min(max(locationX - 14, 0), width)
        return Int((offset / stepWidth).rounded())
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: RadioDJViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("TTS Backend") {
                    TextField("http://127.0.0.1:8000", text: $viewModel.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Text("Simulator 可用 `127.0.0.1`。真機測試請改用你部 Mac 喺同一個 Wi-Fi 嘅 LAN IP。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    LabeledContent("目前模型") {
                        Text(viewModel.backendModelName)
                            .font(.footnote)
                            .multilineTextAlignment(.trailing)
                    }

                    Button {
                        Task {
                            await viewModel.refreshBackendConfig()
                        }
                    } label: {
                        HStack {
                            if viewModel.isRefreshingConfig {
                                ProgressView()
                            }
                            Text(viewModel.isRefreshingConfig ? "檢查連線中..." : "重新檢查 backend")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.isRefreshingConfig)
                }

                Section("節目快取") {
                    Toggle("Cache Program", isOn: $viewModel.shouldCachePrograms)

                    Text(viewModel.shouldCachePrograms
                        ? "開啟後會重用之前生成過嘅節目稿同獨白，加快再次播放。"
                        : "關閉後每次都會重新生成節目稿同獨白，唔會讀寫本地節目快取。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}
