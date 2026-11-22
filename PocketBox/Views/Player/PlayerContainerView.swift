import SwiftUI

struct PlayerContainerView: View {
    @EnvironmentObject private var playerManager: PlayerEngineManager
    @EnvironmentObject private var sleepTimer: SleepTimerManager
    @EnvironmentObject private var audioSession: AudioSessionManager
    @EnvironmentObject private var store: AppStore

    @State private var showHUD = true
    @State private var isLandscape = false
    @State private var showQueueDrawer = false
    @State private var showSleepSheet = false
    @State private var showEngineSheet = false
    @State private var isSeekingSlider = false
    @State private var sliderSeekValue: Double = 0
    @State private var hudHideWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let media = playerManager.currentMedia {
                if playerManager.isAudioOnlyMode {
                    audioOnlyStage(media: media)
                } else {
                    KSVideoSurfaceView(
                        playerManager: playerManager,
                        mediaID: media.id,
                        activeEngine: playerManager.activeEngine,
                        isAudioOnly: playerManager.isAudioOnlyMode
                    )
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        playerManager.togglePlayPause()
                        scheduleHUDHide()
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showHUD.toggle()
                        }
                        if showHUD { scheduleHUDHide() }
                    }
                }

                if playerManager.isBuffering && playerManager.errorMessage == nil {
                    bufferingIndicator
                }

                if let errorMsg = playerManager.errorMessage {
                    errorOverlay(message: errorMsg, media: media)
                }

                if showHUD || playerManager.isAudioOnlyMode {
                    hudOverlay(media: media)
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBar(hidden: isLandscape && !showHUD)
        .onAppear {
            AppDelegate.setOrientation(.allButUpsideDown)
            scheduleHUDHide()
        }
        .onDisappear {
            hudHideWorkItem?.cancel()
            let defaultMask: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
            let target: UIInterfaceOrientation? = UIDevice.current.userInterfaceIdiom == .pad ? nil : .portrait
            AppDelegate.setOrientation(defaultMask, rotateTo: target)
        }
        .sheet(isPresented: $showQueueDrawer) {
            queueAndEndpointSheet
        }
        .sheet(isPresented: $showSleepSheet) {
            sleepTimerSheet
        }
        .confirmationDialog("播放器内核与画面选项", isPresented: $showEngineSheet, titleVisibility: .visible) {
            Button("使用系统 AVPlayer (硬件省电)") {
                playerManager.switchEngine(.avPlayer)
            }
            Button("使用 FFmpeg / KSMEPlayer (全格式)") {
                playerManager.switchEngine(.ffmpeg)
            }
            Button(playerManager.isScaleAspectFill ? "切换为适应屏幕 (留黑边)" : "切换为铺满屏幕 (裁切)") {
                playerManager.toggleAspectFill()
            }
            if playerManager.currentMedia?.isLive == false {
                ForEach([Float(0.75), 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button("倍速 \(String(format: "%.2gx", rate))") {
                        playerManager.setPlaybackRate(rate)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Audio-Only Power Saver Stage

    private func audioOnlyStage(media: PlayableMedia) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 60)

            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.blue.opacity(0.45), Color.indigo.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 156, height: 156)

                if let art = media.artworkURL, let url = URL(string: art) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 132, height: 132)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "headphones")
                                .font(.system(size: 56, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                } else {
                    Image(systemName: "headphones")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundColor(.white)
                }
            }

            VStack(spacing: 8) {
                Text(media.title)
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text(resolvedSubtitle(for: media))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label("纯音频省电模式", systemImage: "leaf.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.22))
                        .foregroundColor(.green)
                        .cornerRadius(99)

                    Label(audioSession.currentRouteSummary, systemImage: "speaker.wave.2.fill")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white.opacity(0.85))
                        .cornerRadius(99)
                }
                .padding(.top, 4)

                Text(store.backgroundPlayEnabled ? "现在可以直接锁屏或切到后台继续收听" : "后台续播已关闭，可在设置中重新开启")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.top, 4)
            }

            Button {
                playerManager.toggleAudioOnlyMode()
            } label: {
                Label("恢复视频画面", systemImage: "video.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.16))
                    .foregroundColor(.white)
                    .cornerRadius(22)
            }
            .padding(.top, 4)

            Spacer(minLength: 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.14), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - HUD Overlay

    private func hudOverlay(media: PlayableMedia) -> some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                Button {
                    playerManager.isPlayerPresented = false
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.white.opacity(0.9))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title)
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(resolvedSubtitle(for: media))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                        Text("· \(playerManager.activeEngine.shortName)")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.cyan)
                        if let rem = sleepTimer.formattedRemaining {
                            Text("· \(rem)")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.orange)
                        }
                    }
                }

                Spacer()

                AirPlayButton(tintColor: .white)
                    .frame(width: 28, height: 28)

                Button {
                    playerManager.stopAndDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.78), Color.black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Spacer()

            // Bottom bar
            VStack(spacing: 10) {
                if !media.isLive {
                    let safeDuration = (playerManager.duration.isFinite && playerManager.duration > 1) ? playerManager.duration : 1
                    let displayTime = min(max(isSeekingSlider ? sliderSeekValue : playerManager.currentTime, 0), safeDuration)
                    HStack(spacing: 10) {
                        Text(formatTime(displayTime))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white)
                            .frame(width: 54, alignment: .leading)

                        Slider(
                            value: Binding(
                                get: { displayTime },
                                set: { newVal in
                                    isSeekingSlider = true
                                    sliderSeekValue = newVal
                                }
                            ),
                            in: 0...safeDuration,
                            onEditingChanged: { editing in
                                if !editing {
                                    playerManager.seek(to: sliderSeekValue)
                                    isSeekingSlider = false
                                    scheduleHUDHide()
                                }
                            }
                        )
                        .accentColor(.white)

                        Text(formatTime(playerManager.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 54, alignment: .trailing)
                    }
                } else {
                    HStack {
                        Label("LIVE 直播中", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.green)
                        Spacer()
                        if media.endpoints.count > 1 {
                            Text("线路 \(playerManager.selectedEndpointIndex + 1)/\(media.endpoints.count)")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.75))
                        }
                    }
                }

                HStack(spacing: 14) {
                    Button {
                        playerManager.playPreviousInQueue()
                        scheduleHUDHide()
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 18))
                            .foregroundColor(playerManager.canSwitchPrevious ? .white : .white.opacity(0.35))
                    }
                    .disabled(!playerManager.canSwitchPrevious)

                    if !media.isLive {
                        Button {
                            playerManager.skip(by: -15)
                            scheduleHUDHide()
                        } label: {
                            Image(systemName: "gobackward.15")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                        }
                    }

                    Button {
                        playerManager.togglePlayPause()
                        scheduleHUDHide()
                    } label: {
                        Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.white)
                    }

                    if !media.isLive {
                        Button {
                            playerManager.skip(by: 15)
                            scheduleHUDHide()
                        } label: {
                            Image(systemName: "goforward.15")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                        }
                    }

                    Button {
                        playerManager.playNextInQueue()
                        scheduleHUDHide()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 18))
                            .foregroundColor(playerManager.canSwitchNext ? .white : .white.opacity(0.35))
                    }
                    .disabled(!playerManager.canSwitchNext)

                    Spacer()

                    Button {
                        playerManager.toggleAudioOnlyMode()
                        scheduleHUDHide()
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: playerManager.isAudioOnlyMode ? "headphones.circle.fill" : "headphones")
                                .font(.system(size: 18))
                                .foregroundColor(playerManager.isAudioOnlyMode ? .green : .white)
                            Text("纯音频")
                                .font(.system(size: 10))
                                .foregroundColor(playerManager.isAudioOnlyMode ? .green : .white.opacity(0.8))
                        }
                    }

                    Button {
                        showSleepSheet = true
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz")
                                .font(.system(size: 18))
                                .foregroundColor(sleepTimer.isActive ? .orange : .white)
                            Text("定时")
                                .font(.system(size: 10))
                                .foregroundColor(sleepTimer.isActive ? .orange : .white.opacity(0.8))
                        }
                    }

                    Button {
                        showQueueDrawer = true
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                            Text(media.isLive ? "频道/源" : "选集/源")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }

                    Button {
                        showEngineSheet = true
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                            Text("内核")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }

                    Button {
                        toggleRotation()
                        scheduleHUDHide()
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: isLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                            Text(isLandscape ? "竖屏" : "横屏")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 18)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0), Color.black.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var bufferingIndicator: some View {
        VStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
            Text(playerManager.statusBadgeText.isEmpty ? "正在缓冲..." : playerManager.statusBadgeText)
                .font(.caption)
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(16)
        .background(Color.black.opacity(0.65))
        .cornerRadius(12)
    }

    private func errorOverlay(message: String, media: PlayableMedia) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.yellow)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button("重试播放") {
                    playerManager.selectEndpoint(at: playerManager.selectedEndpointIndex)
                }
                .buttonStyle(.borderedProminent)

                Button(playerManager.activeEngine == .avPlayer ? "切 FFmpeg 内核" : "切 AVPlayer 内核") {
                    playerManager.switchEngine(playerManager.activeEngine == .avPlayer ? .ffmpeg : .avPlayer)
                }
                .buttonStyle(.bordered)
                .tint(.white)

                if media.endpoints.count > 1 {
                    Button("下一线路") {
                        let next = (playerManager.selectedEndpointIndex + 1) % media.endpoints.count
                        playerManager.selectEndpoint(at: next)
                    }
                    .buttonStyle(.bordered)
                    .tint(.cyan)
                }
            }
        }
        .padding(20)
        .background(Color.black.opacity(0.8))
        .cornerRadius(16)
        .padding(24)
    }

    // MARK: - Sheets

    private var queueAndEndpointSheet: some View {
        NavigationView {
            List {
                if let media = playerManager.currentMedia, !media.endpoints.isEmpty {
                    Section("播放线路") {
                        ForEach(Array(media.endpoints.enumerated()), id: \.element.id) { idx, ep in
                            Button {
                                playerManager.selectEndpoint(at: idx)
                                showQueueDrawer = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ep.label)
                                            .foregroundColor(.primary)
                                        Text(ep.url)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if idx == playerManager.selectedEndpointIndex {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }

                if playerManager.queue.count > 1 {
                    Section(playerManager.currentMedia?.isLive == true ? "频道列表" : "剧集列表") {
                        ForEach(Array(playerManager.queue.enumerated()), id: \.element.id) { idx, item in
                            Button {
                                playerManager.play(media: item, queue: playerManager.queue, startIndex: idx, openFullscreen: true)
                                showQueueDrawer = false
                            } label: {
                                HStack {
                                    Text("\(idx + 1). \(item.episodeName ?? item.title)")
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if idx == playerManager.queueIndex {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("线路与列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showQueueDrawer = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var sleepTimerSheet: some View {
        NavigationView {
            List {
                Section("选择定时关闭时间") {
                    ForEach(SleepTimerPreset.allCases) { preset in
                        if preset == .endOfEpisode && playerManager.currentMedia?.isLive == true {
                            EmptyView()
                        } else {
                            Button {
                                sleepTimer.setPreset(preset)
                                showSleepSheet = false
                            } label: {
                                HStack {
                                    Text(preset.title)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if sleepTimer.activePreset == preset {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                        }
                    }
                }

                if let rem = sleepTimer.formattedRemaining {
                    Section("当前倒计时") {
                        Text(rem)
                            .foregroundColor(.orange)
                    }
                }
            }
            .navigationTitle("定时关闭")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showSleepSheet = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Helpers

    private func resolvedSubtitle(for media: PlayableMedia) -> String {
        if media.isLive, let epg = store.currentProgramTitle(forChannelNamed: media.title) {
            return "正在播出: \(epg)"
        }
        return media.subtitle ?? (media.isLive ? "电视直播" : "视频点播")
    }

    private func toggleRotation() {
        isLandscape.toggle()
        if isLandscape {
            AppDelegate.setOrientation(.landscape, rotateTo: .landscapeRight)
        } else {
            AppDelegate.setOrientation(.allButUpsideDown, rotateTo: .portrait)
        }
    }

    private func scheduleHUDHide() {
        hudHideWorkItem?.cancel()
        guard !playerManager.isAudioOnlyMode else { return }
        let item = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.25)) {
                showHUD = false
            }
        }
        hudHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: item)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
