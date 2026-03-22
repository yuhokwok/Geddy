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
                    playbackSection
                }
                .padding(20)
            }
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
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(viewModel: viewModel)
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
    private var playbackSection: some View {
        if viewModel.currentShow != nil {
            card("播放控制") {
                VStack(alignment: .leading, spacing: 16) {
                    if let item = viewModel.currentPlaybackItem {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("現正播放")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(item.title)
                                .font(.headline)
                            Text(item.subtitle)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("節目已就緒，可以開始播放。")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            Task {
                                await viewModel.skipToPreviousSong()
                            }
                        } label: {
                            Label("上一首歌", systemImage: "backward.end.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

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
                                await viewModel.skipToNextSong()
                            }
                        } label: {
                            Label("下一首歌", systemImage: "forward.end.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("停止整個節目") {
                        viewModel.stopPlayback()
                    }
                    .buttonStyle(.bordered)

                    Text("Control Centre 會支援播放 / 暫停 / 上一首歌 / 下一首歌。歌曲之間的開場白與獨白會由 app 自己接力播放。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
