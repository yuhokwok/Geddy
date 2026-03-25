import SwiftUI
import MusicKit

struct WrapperView : View {
    @StateObject private var viewModel = RadioDJViewModel()
    @State private var isShowingSettings = false
    @State private var isShowingSavedPrograms = false
    @State private var isShowingPlaylistSheet = false
    @State private var lastPresentedPlaylistKey: String?
    
    var body : some View {
        VStack {
            ContentView(viewModel: viewModel, isShowingSettings: $isShowingSettings, isShowingSavedPrograms: $isShowingSavedPrograms, isShowingPlaylistSheet: $isShowingPlaylistSheet, lastPresentedPlaylistKey: $lastPresentedPlaylistKey)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomPlayerBar
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 8)
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
                            .background(Color.white.opacity(0.26), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

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
                    .buttonStyle(OrangeGlassButtonStyle())
                    .accessibilityLabel("上一段")

                    Button {
                        Task {
                            await viewModel.togglePlayback()
                        }
                    } label: {
                        Label(viewModel.isPlaying ? "暫停" : "播放", systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OrangeGlassButtonStyle(prominent: true))

                    Button {
                        Task {
                            await viewModel.skipToNextSegment()
                        }
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OrangeGlassButtonStyle())
                    .accessibilityLabel("下一段")

                    Button {
                        viewModel.stopPlayback()
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OrangeGlassButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .background(glassBackground(cornerRadius: 28, opacity: 0.94))
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
    }
    
    private func glassBackground(cornerRadius: CGFloat, opacity: Double = 0.82) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0))
//
//            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
//                .fill(
//                    LinearGradient(
//                        colors: [
//                            Color.white.opacity(0.30),
//                            Color.white.opacity(0.08)
//                        ],
//                        startPoint: .topLeading,
//                        endPoint: .bottomTrailing
//                    )
//                )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.42), lineWidth: 1)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        .shadow(color: Color.black.opacity(0.06), radius: 18, y: 6)
    }

}

struct ContentView: View {
    private enum PlaylistPanelDetent: CGFloat {
        case medium = 0.42
        case large = 0.80
    }

    @ObservedObject var viewModel : RadioDJViewModel
    @Binding var isShowingSettings : Bool
    @Binding var isShowingSavedPrograms : Bool
    @Binding var isShowingPlaylistSheet : Bool
    @Binding var lastPresentedPlaylistKey : String?
    @State private var playlistPanelDetent: PlaylistPanelDetent = .large

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 16) {
                        voiceInputSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 240)
                }
                .scrollDismissesKeyboard(.immediately)

                if viewModel.currentShow != nil, isShowingPlaylistSheet {
                    playlistPanel
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .background(backgroundLayer)
            .navigationTitle("Geddy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if viewModel.currentShow != nil {
                        Button {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                                isShowingPlaylistSheet.toggle()
                            }
                        } label: {
                            Image(systemName: "music.note.list")
                                .font(.headline)
                                .frame(width: 18, height: 18)
                                .frame(width: 38, height: 38)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel("歌單")
                    }

                    Button {
                        isShowingSavedPrograms = true
                    } label: {
                        Image(systemName: "square.stack.fill")
                            .font(.headline)
                            .frame(width: 18, height: 18)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .foregroundStyle(.primary)
                    .accessibilityLabel("已儲存節目")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.headline)
                            .frame(width: 18, height: 18)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .foregroundStyle(.primary)
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
        .sheet(isPresented: $isShowingSavedPrograms) {
            savedProgramsSheet
        }
        .onChange(of: viewModel.currentShow) { _, newShow in
            guard let newShow else { return }
            let key = playlistPresentationKey(for: newShow)
            guard key != lastPresentedPlaylistKey else { return }
            lastPresentedPlaylistKey = key
            playlistPanelDetent = .large
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                isShowingPlaylistSheet = true
            }
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
            backgroundLayer
                .overlay(.ultraThinMaterial.opacity(0.4))
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
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)

                    ProgressView()
                        .tint(Color(red: 0.84, green: 0.37, blue: 0.18))
                        .scaleEffect(1.15)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .background(glassBackground(cornerRadius: 30))
                .padding(.horizontal, 24)
            }
            .padding(.horizontal, 24)
        }
    }

    private var voiceInputSection: some View {
        card("為你點歌") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("把你而家想聽的心情、故事或者主題交畀 Geddy。")
                        .font(.title3.weight(.semibold))

                    Text(viewModel.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
//                    Text("用家心事 / 主題")
//                        .font(.subheadline.weight(.semibold))
                    
                    TextEditor(text: $viewModel.transcriptText)
                        .font(.system(size: 20))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 200)
                        .background(glassBackground(cornerRadius: 18, opacity: 0.68))
                }

                Text("例如：最近好掛住以前拍拖嗰陣，明知唔應該回頭，但仲係會諗起對方。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

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
                .buttonStyle(OrangeGlassButtonStyle(prominent: true))
                .disabled(viewModel.isPreparingShow)
            }
        }
    }

    private var playlistPanel: some View {
        GeometryReader { geometry in
            let panelHeight = max(geometry.size.height * playlistPanelDetent.rawValue, 320)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 42, height: 5)

                        Spacer()

                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                                playlistPanelDetent = playlistPanelDetent == .large ? .medium : .large
                            }
                        } label: {
                            Image(systemName: playlistPanelDetent == .large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(OrangeGlassButtonStyle())

                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                                isShowingPlaylistSheet = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(OrangeGlassButtonStyle())
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let show = viewModel.currentShow {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("歌單")
                                        .font(.footnote.weight(.semibold))
                                        .textCase(.uppercase)
                                        .foregroundStyle(.secondary)

                                    Text(show.title)
                                        .font(.title3.weight(.bold))

                                    Text(show.moodSummary)
                                        .foregroundStyle(.secondary)
                                }

                                ForEach(show.playbackItems) { item in
                                    playlistItemCard(item, in: show)
                                }

                                if show.songs.isEmpty {
                                    Text("節目已載入，但暫時未有可顯示歌曲。")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }

                                if viewModel.isGeneratingRemainingSpeech {
                                    Label("其餘獨白仍在背景生成", systemImage: "sparkles")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                }

                                Button {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.92)) {
                                        isShowingPlaylistSheet = false
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                        isShowingSavedPrograms = true
                                    }
                                } label: {
                                    Label("已儲存節目", systemImage: "square.stack.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(OrangeGlassButtonStyle())
                                .padding(.top, 8)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 200)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: panelHeight)
                .background(playlistPanelBackground)
                .gesture(
                    DragGesture()
                        .onEnded { value in
                            let predicted = value.predictedEndTranslation.height
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                                if predicted < -70 {
                                    playlistPanelDetent = .large
                                } else if predicted > 70 {
                                    playlistPanelDetent = .medium
                                }
                            }
                        }
                )
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private var playlistPanelBackground: some View {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(Color.white.opacity(0.42), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.08), radius: 22, y: 6)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(glassBackground(cornerRadius: 28))
    }

    private var backgroundLayer: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.998, green: 0.996, blue: 0.992),
                            Color(red: 0.978, green: 0.972, blue: 0.964),
                            Color(red: 0.956, green: 0.946, blue: 0.936)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(Color.white.opacity(0.56))
                .frame(width: 280, height: 280)
                .blur(radius: 28)
                .offset(x: -140, y: -260)

            Circle()
                .fill(Color(red: 0.96, green: 0.85, blue: 0.80).opacity(0.18))
                .frame(width: 240, height: 240)
                .blur(radius: 34)
                .offset(x: 150, y: -150)

            Circle()
                .fill(Color.white.opacity(0.34))
                .frame(width: 320, height: 320)
                .blur(radius: 40)
                .offset(x: 140, y: 340)
        }
        .ignoresSafeArea()
    }

    private var savedProgramsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.currentShow != nil {
                        card("收藏目前節目") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("將而家呢一集留低，之後可以隨時返嚟再聽。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Button {
                                    viewModel.saveCurrentShow()
                                } label: {
                                    Label("儲存而家節目", systemImage: "bookmark.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(OrangeGlassButtonStyle(prominent: true))
                            }
                        }
                    }

                    card("已儲存節目") {
                        VStack(alignment: .leading, spacing: 12) {
                            if viewModel.savedPrograms.isEmpty {
                                Text("你仲未儲低任何節目。之後想留低一集時，可以喺呢度慢慢累積。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(viewModel.savedPrograms) { savedProgram in
                                    savedProgramRow(savedProgram)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .background(backgroundLayer)
            .navigationTitle("已儲存節目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        isShowingSavedPrograms = false
                    }
                }
            }
        }
    }

    private func songCard(number: Int, resolvedSong: ResolvedSong, isPlaying: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                songArtworkView(for: resolvedSong)

                Text("\(number).")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("\(resolvedSong.title) · \(resolvedSong.artistName)")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)

                        if isPlaying {
                            playbackBadge
                        }
                    }

                    Text(resolvedSong.suggestion.reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(resolvedSong.albumTitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text(resolvedSong.durationText)
                        .foregroundStyle(.secondary)
                    if isPlaying {
                        Image(systemName: "waveform")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 0.84, green: 0.37, blue: 0.18))
                    }
                }
            }
        }
        .padding(14)
        .background(glassBackground(cornerRadius: 20, opacity: 0.64))
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
                    .buttonStyle(OrangeGlassButtonStyle())

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
        .background(glassBackground(cornerRadius: 20, opacity: 0.62))
    }

    @ViewBuilder
    private func playlistItemCard(_ item: StationPlaybackItem, in show: RadioShow) -> some View {
        switch item.payload {
        case .song(let resolvedSong):
            songCard(
                number: songNumber(for: resolvedSong, in: show),
                resolvedSong: resolvedSong,
                isPlaying: isCurrentPlaybackItem(item)
            )
        case .speech(let clip):
            spokenCard(
                title: spokenTitle(for: item.kind),
                text: clip.text,
                caption: item.subtitle,
                buttonLabel: "播放呢段",
                item: item,
                isPlaying: isCurrentPlaybackItem(item)
            )
        }
    }

    private func spokenCard(
        title: String,
        text: String,
        caption: String,
        buttonLabel: String,
        item: StationPlaybackItem,
        isPlaying: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)

                    if isPlaying {
                        playbackBadge
                    }
                }

                Spacer()

                Button {
                    Task {
                        await viewModel.playPlaybackItem(item)
                    }
                } label: {
                    Label(buttonLabel, systemImage: "play.fill")
                }
                .buttonStyle(OrangeGlassButtonStyle())
            }

            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(glassBackground(cornerRadius: 20, opacity: 0.5))
    }

    private func glassBackground(cornerRadius: CGFloat, opacity: Double = 0.82) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial.opacity(opacity))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.30),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.42), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 18, y: 6)
    }

    @ViewBuilder
    private func songArtworkView(for resolvedSong: ResolvedSong) -> some View {
        if let artworkURL = resolvedSong.song.artwork?.url(width: 140, height: 140) {
            AsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    placeholderArtwork
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            placeholderArtwork
                .frame(width: 56, height: 56)
        }
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.72))
            .overlay {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
    }

    private var playbackBadge: some View {
        Text("播放中")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color(red: 0.84, green: 0.37, blue: 0.18))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.84, green: 0.37, blue: 0.18).opacity(0.14))
            )
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



    private func playlistPresentationKey(for show: RadioShow) -> String {
        let songIDs = show.songs.map(\.id.rawValue).joined(separator: ",")
        return "\(show.title)|\(show.transcript)|\(songIDs)"
    }

    private func isCurrentPlaybackItem(_ item: StationPlaybackItem) -> Bool {
        viewModel.currentPlaybackItem?.queueKey == item.queueKey && viewModel.isPlaying
    }

    private func songNumber(for resolvedSong: ResolvedSong, in show: RadioShow) -> Int {
        guard let index = show.songs.firstIndex(where: { $0.id == resolvedSong.id }) else {
            return 1
        }
        return index + 1
    }

    private func spokenTitle(for kind: StationPlaybackItem.Kind) -> String {
        switch kind {
        case .opening:
            return "開場白"
        case .bridge:
            return "過場白"
        case .closing:
            return "收場白"
        case .song:
            return "歌曲"
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
                Section("主持風格") {
                    Picker("主持聲線", selection: $viewModel.selectedVoicePresetID) {
                        ForEach(viewModel.availableVoicePresets) { preset in
                            Text(preset.label).tag(preset.id)
                        }
                    }

                    if let selectedPreset = viewModel.availableVoicePresets.first(where: { $0.id == viewModel.selectedVoicePresetID }) {
                        Text(selectedPreset.voiceDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("自訂主持描述")
                            .font(.subheadline.weight(.semibold))

                        TextEditor(text: $viewModel.hostStyleDescription)
                            .frame(minHeight: 120)
                    }
                }

                Section("歌曲偏好") {
                    Picker("歌曲種類", selection: $viewModel.selectedSongCategory) {
                        ForEach(SongCategoryOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(viewModel.selectedSongCategory.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("年代範圍")
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
                        .frame(height: 68)
                    }

                    Toggle("想要冷門歌曲", isOn: $viewModel.preferObscureSongs)

                    Text(viewModel.songPreferences.obscureSongsSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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
                    .buttonStyle(OrangeGlassButtonStyle())
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

    private func eraIndex(for option: SongEraOption) -> Int {
        SongEraOption.allCases.firstIndex(of: option) ?? 0
    }

    private func eraOption(at index: Int) -> SongEraOption {
        let clampedIndex = min(max(index, 0), SongEraOption.allCases.count - 1)
        return SongEraOption.allCases[clampedIndex]
    }
}

private struct OrangeGlassButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let orange = Color(red: 0.84, green: 0.37, blue: 0.18)

        return configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Color.white : orange)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(prominent ? 0.92 : 0.84))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: prominent
                                        ? [orange.opacity(0.92), orange.opacity(0.62)]
                                        : [orange.opacity(0.18), orange.opacity(0.08)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                prominent ? Color.white.opacity(0.28) : orange.opacity(0.26),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: orange.opacity(prominent ? 0.18 : 0.08), radius: 16, y: 6)
            }
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
