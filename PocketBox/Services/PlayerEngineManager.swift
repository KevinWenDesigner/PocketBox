import AVFoundation
import Combine
import Foundation
import KSPlayer
import UIKit

@MainActor
final class PlayerEngineManager: NSObject, ObservableObject {
    static let shared = PlayerEngineManager()

    @Published var currentMedia: PlayableMedia?
    @Published var queue: [PlayableMedia] = []
    @Published var queueIndex: Int = 0
    @Published var selectedEndpointIndex: Int = 0

    @Published var isPlayerPresented = false
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var playerState: KSPlayerState = .initialized
    @Published var errorMessage: String?

    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0
    @Published var isMuted: Bool = false
    @Published var isScaleAspectFill: Bool = false

    /// 纯音频省电模式：关闭视频解码与渲染，显著降低 iOS 15 老设备功耗并保证锁屏流畅续播
    @Published var isAudioOnlyMode: Bool = false
    @Published var activeEngine: ActiveEngineKind = .unknown
    @Published var statusBadgeText: String = ""

    private(set) var playerLayer: KSPlayerLayer?
    weak var store: AppStore?

    private var pendingResumeTime: TimeInterval = 0
    private var liveReconnectAttempts = 0
    private var maxLiveReconnectAttempts = 3
    private var reconnectWorkItem: DispatchWorkItem?
    private var lastHistorySaveDate: Date = .distantPast
    private var isInBackground = false

    override private init() {
        super.init()
        configureGlobalKSOptions()
        registerLifecycleObservers()
        bindAudioAndNowPlayingCallbacks()
    }

    // MARK: - Public Playback API

    func play(
        media: PlayableMedia,
        queue: [PlayableMedia]? = nil,
        startIndex: Int = 0,
        openFullscreen: Bool = true
    ) {
        reconnectWorkItem?.cancel()
        liveReconnectAttempts = 0
        errorMessage = nil

        let resolvedQueue = queue ?? [media]
        self.queue = resolvedQueue
        self.queueIndex = min(max(startIndex, 0), max(resolvedQueue.count - 1, 0))
        self.currentMedia = media
        self.selectedEndpointIndex = 0
        self.currentTime = media.startTime
        self.duration = 0

        if let store {
            self.isAudioOnlyMode = store.defaultAudioOnlyMode
        }

        if openFullscreen {
            isPlayerPresented = true
        }

        loadCurrentEndpoint(resumeTime: media.startTime)
    }

    func selectEndpoint(at index: Int) {
        guard let media = currentMedia, index >= 0, index < media.endpoints.count else { return }
        selectedEndpointIndex = index
        errorMessage = nil
        liveReconnectAttempts = 0
        let resume = media.isLive ? 0 : currentTime
        loadCurrentEndpoint(resumeTime: resume)
    }

    func switchEngine(_ engine: ActiveEngineKind) {
        guard let media = currentMedia, selectedEndpointIndex < media.endpoints.count else { return }
        let resume = media.isLive ? 0 : currentTime
        let forcedPref: EnginePreference = (engine == .ffmpeg) ? .ffmpegOnly : .avPlayerOnly
        loadEndpoint(media.endpoints[selectedEndpointIndex], media: media, resumeTime: resume, overridePreference: forcedPref)
    }

    func togglePlayPause() {
        guard let layer = playerLayer else { return }
        if layer.state.isPlaying || layer.player.isPlaying {
            layer.pause()
            isPlaying = false
            syncNowPlayingFull()
        } else {
            AudioSessionManager.shared.configureAndActivate(audioOnlyMode: isAudioOnlyMode)
            layer.play()
            isPlaying = true
            syncNowPlayingFull()
        }
    }

    func pause() {
        playerLayer?.pause()
        isPlaying = false
        saveWatchProgress(force: true)
        syncNowPlayingProgress()
    }

    func resume() {
        guard let layer = playerLayer else { return }
        AudioSessionManager.shared.configureAndActivate(audioOnlyMode: isAudioOnlyMode)
        layer.play()
        isPlaying = true
        syncNowPlayingProgress()
    }

    func seek(to time: TimeInterval) {
        guard let layer = playerLayer, let media = currentMedia, !media.isLive else { return }
        let clamped = max(0, min(time, max(duration, time)))
        currentTime = clamped
        layer.seek(time: clamped, autoPlay: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncNowPlayingProgress()
            }
        }
    }

    func skip(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        playerLayer?.player.playbackRate = rate
        syncNowPlayingProgress()
    }

    func toggleMute() {
        isMuted.toggle()
        playerLayer?.player.isMuted = isMuted
    }

    func toggleAspectFill() {
        isScaleAspectFill.toggle()
        playerLayer?.player.contentMode = isScaleAspectFill ? .scaleAspectFill : .scaleAspectFit
    }

    func toggleAudioOnlyMode() {
        isAudioOnlyMode.toggle()
        AudioSessionManager.shared.configureAndActivate(audioOnlyMode: isAudioOnlyMode)
        applyAudioOnlyModeToActivePlayer()
    }

    var canSwitchNext: Bool {
        queueIndex + 1 < queue.count
    }

    var canSwitchPrevious: Bool {
        queueIndex - 1 >= 0
    }

    func playNextInQueue() {
        guard canSwitchNext else { return }
        saveWatchProgress(force: true)
        let nextIndex = queueIndex + 1
        queueIndex = nextIndex
        let nextItem = queue[nextIndex]
        currentMedia = nextItem
        selectedEndpointIndex = 0
        errorMessage = nil
        liveReconnectAttempts = 0
        loadCurrentEndpoint(resumeTime: nextItem.startTime)
    }

    func playPreviousInQueue() {
        guard canSwitchPrevious else { return }
        saveWatchProgress(force: true)
        let prevIndex = queueIndex - 1
        queueIndex = prevIndex
        let prevItem = queue[prevIndex]
        currentMedia = prevItem
        selectedEndpointIndex = 0
        errorMessage = nil
        liveReconnectAttempts = 0
        loadCurrentEndpoint(resumeTime: prevItem.startTime)
    }

    func stopAndDismiss() {
        reconnectWorkItem?.cancel()
        saveWatchProgress(force: true)
        playerLayer?.stop()
        playerLayer = nil
        currentMedia = nil
        isPlaying = false
        isBuffering = false
        isPlayerPresented = false
        activeEngine = .unknown
        NowPlayingCoordinator.shared.clear()
        SleepTimerManager.shared.setPreset(.off)
    }

    func attachSurfaceView(into container: UIView) {
        guard let videoView = playerLayer?.player.view else { return }
        if videoView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            container.addSubview(videoView)
            videoView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                videoView.topAnchor.constraint(equalTo: container.topAnchor),
                videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        videoView.isHidden = isAudioOnlyMode
    }

    // MARK: - Core Loading & Dual Engine Strategy

    private func loadCurrentEndpoint(resumeTime: TimeInterval) {
        guard let media = currentMedia,
              selectedEndpointIndex < media.endpoints.count
        else {
            errorMessage = "没有可用的播放地址"
            return
        }
        loadEndpoint(media.endpoints[selectedEndpointIndex], media: media, resumeTime: resumeTime, overridePreference: nil)
    }

    private func loadEndpoint(
        _ endpoint: StreamEndpoint,
        media: PlayableMedia,
        resumeTime: TimeInterval,
        overridePreference: EnginePreference?
    ) {
        guard let url = URL(string: endpoint.url) else {
            errorMessage = "无效的流地址: \(endpoint.url)"
            return
        }

        let backgroundEnabled = store?.backgroundPlayEnabled ?? true
        KSOptions.canBackgroundPlay = backgroundEnabled
        KSOptions.hardwareDecode = store?.hardwareDecode ?? true
        KSOptions.preferredForwardBufferDuration = store?.bufferDuration ?? 3.0
        KSOptions.isAutoPlay = true

        AudioSessionManager.shared.configureAndActivate(audioOnlyMode: isAudioOnlyMode)

        let pref = overridePreference ?? store?.enginePreference ?? .auto
        configureEngineSelection(preference: pref, url: url, isLive: media.isLive)

        let options = buildKSOptions(for: endpoint, media: media)
        pendingResumeTime = media.isLive ? 0 : max(resumeTime, 0)

        let forceRecreate = (playerLayer?.url == url) || overridePreference != nil
        if let existing = playerLayer, !forceRecreate {
            existing.set(url: url, options: options)
        } else {
            playerLayer?.stop()
            playerLayer?.delegate = nil
            let layer = KSPlayerLayer(url: url, isAutoPlay: true, options: options, delegate: self)
            self.playerLayer = layer
        }
        NowPlayingCoordinator.shared.ensureRemoteCommandsRegistered(force: true)

        if let player = playerLayer?.player {
            player.playbackRate = media.isLive ? 1.0 : playbackRate
            player.isMuted = isMuted
            player.contentMode = isScaleAspectFill ? .scaleAspectFill : .scaleAspectFit
            updateActiveEngineLabel(from: player)
            configureAVPlayerBackgroundPolicyIfNeeded(player)
        }

        isBuffering = true
        isPlaying = true
        statusBadgeText = "\(endpoint.label) · 加载中"
        syncNowPlayingFull()
    }

    private func configureEngineSelection(preference: EnginePreference, url: URL, isLive: Bool) {
        switch preference {
        case .avPlayerOnly:
            KSOptions.firstPlayerType = KSAVPlayer.self
            KSOptions.secondPlayerType = nil
        case .ffmpegOnly:
            KSOptions.firstPlayerType = KSMEPlayer.self
            KSOptions.secondPlayerType = nil
        case .auto:
            if shouldPreferFFmpeg(url: url, isLive: isLive) {
                KSOptions.firstPlayerType = KSMEPlayer.self
                KSOptions.secondPlayerType = KSAVPlayer.self
            } else {
                KSOptions.firstPlayerType = KSAVPlayer.self
                KSOptions.secondPlayerType = KSMEPlayer.self
            }
        }
    }

    private func shouldPreferFFmpeg(url: URL, isLive: Bool) -> Bool {
        let scheme = (url.scheme ?? "").lowercased()
        if ["rtmp", "rtsp", "udp", "rtp", "mms", "mmsh", "smb"].contains(scheme) {
            return true
        }
        let ext = url.pathExtension.lowercased()
        if ["flv", "mkv", "avi", "rm", "rmvb", "wmv", "asf", "vob", "mpg", "mpeg"].contains(ext) {
            return true
        }
        // Raw MPEG-TS live streams work far more reliably on KSMEPlayer than AVPlayer
        if isLive && ext == "ts" {
            return true
        }
        return false
    }

    private func buildKSOptions(for endpoint: StreamEndpoint, media: PlayableMedia) -> KSOptions {
        let options = KSOptions()
        // Disable KSPlayer's built-in remote control registration so NowPlayingCoordinator
        // owns lock screen metadata and Next/Prev channel/episode switching cleanly.
        options.registerRemoteControll = false
        options.videoDisable = isAudioOnlyMode
        options.hardwareDecode = store?.hardwareDecode ?? true
        options.isLoopPlay = false
        options.preferredForwardBufferDuration = store?.bufferDuration ?? 3.0
        options.maxBufferDuration = max((store?.bufferDuration ?? 3.0) * 6.0, 20.0)

        let defaultUA = store?.defaultUserAgent ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8_8 like Mac OS X) AppleWebKit/605.1.15"
        var headers = endpoint.headers
        if headers["User-Agent"] == nil && !defaultUA.isEmpty {
            headers["User-Agent"] = defaultUA
        }
        if let ua = headers["User-Agent"] {
            options.userAgent = ua
        }
        if let ref = headers["Referer"] {
            options.referer = ref
        }
        if !headers.isEmpty {
            options.appendHeader(headers)
        }

        if media.isLive {
            options.formatContextOptions["reconnect"] = 1
            options.formatContextOptions["reconnect_streamed"] = 1
            options.formatContextOptions["reconnect_on_network_error"] = 1
            options.formatContextOptions["rw_timeout"] = 12_000_000
        }
        return options
    }

    // MARK: - Audio-Only & Background Lock Screen Hardening

    private func applyAudioOnlyModeToActivePlayer() {
        guard let layer = playerLayer, let media = currentMedia else { return }

        if let avPlayer = layer.player as? KSAVPlayer {
            // Instant track toggle without re-buffering on native AVPlayer
            let videoTracks = avPlayer.tracks(mediaType: .video)
            for track in videoTracks {
                track.isEnabled = !isAudioOnlyMode
            }
            if #available(iOS 15.0, *) {
                avPlayer.player.currentItem?.preferredPeakBitRate = isAudioOnlyMode ? 1 : 0
            }
            if isAudioOnlyMode || isInBackground {
                avPlayer.enterBackground()
            } else {
                avPlayer.enterForeground()
            }
            avPlayer.view?.isHidden = isAudioOnlyMode
        } else {
            // KSMEPlayer: reload with videoDisable = isAudioOnlyMode so FFmpeg skips video decode completely
            let resume = media.isLive ? 0 : currentTime
            loadCurrentEndpoint(resumeTime: resume)
        }
        statusBadgeText = isAudioOnlyMode ? "纯音频省电模式" : activeEngine.shortName
        syncNowPlayingFull()
    }

    private func configureAVPlayerBackgroundPolicyIfNeeded(_ player: MediaPlayerProtocol) {
        if #available(iOS 15.0, *), let avPlayer = player as? KSAVPlayer {
            let canBg = store?.backgroundPlayEnabled ?? true
            avPlayer.player.audiovisualBackgroundPlaybackPolicy = canBg ? .continuesIfPossible : .pauses
        }
    }

    private func updateActiveEngineLabel(from player: MediaPlayerProtocol) {
        if player is KSAVPlayer {
            activeEngine = .avPlayer
        } else {
            activeEngine = .ffmpeg
        }
        statusBadgeText = isAudioOnlyMode ? "纯音频省电模式" : activeEngine.shortName
    }

    private func configureGlobalKSOptions() {
        KSOptions.canBackgroundPlay = true
        KSOptions.firstPlayerType = KSAVPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
        KSOptions.isAutoPlay = true
        KSOptions.hardwareDecode = true
    }

    private func registerLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillResignOrBackground()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isInBackground = true
                self?.handleWillResignOrBackground()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isInBackground = false
                self?.handleWillEnterForeground()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isInBackground = false
                self?.handleWillEnterForeground()
            }
        }
    }

    private func handleWillResignOrBackground() {
        guard let layer = playerLayer else { return }
        let allowBackground = store?.backgroundPlayEnabled ?? true
        KSOptions.canBackgroundPlay = allowBackground

        if allowBackground {
            AudioSessionManager.shared.configureAndActivate(audioOnlyMode: isAudioOnlyMode)
            // Detach AVPlayerLayer explicitly so pressing the lock button never pauses AVPlayer
            if let avPlayer = layer.player as? KSAVPlayer {
                configureAVPlayerBackgroundPolicyIfNeeded(avPlayer)
                avPlayer.enterBackground()
            }
            syncNowPlayingFull()
        } else if isPlaying {
            pause()
        }
        saveWatchProgress(force: true)
    }

    private func handleWillEnterForeground() {
        guard let layer = playerLayer else { return }
        if !isAudioOnlyMode, let avPlayer = layer.player as? KSAVPlayer {
            avPlayer.enterForeground()
        }
        layer.player.view?.isHidden = isAudioOnlyMode
        syncNowPlayingFull()
    }

    private func bindAudioAndNowPlayingCallbacks() {
        AudioSessionManager.shared.onInterruptionBegan = { [weak self] in
            self?.playerLayer?.pause()
            self?.isPlaying = false
            self?.syncNowPlayingProgress()
        }
        AudioSessionManager.shared.onInterruptionEndedShouldResume = { [weak self] in
            guard let self, self.currentMedia != nil else { return }
            self.resume()
        }
        AudioSessionManager.shared.onRouteBecameUnavailable = { [weak self] in
            self?.pause()
        }

        let np = NowPlayingCoordinator.shared
        np.onPlay = { [weak self] in self?.resume() }
        np.onPause = { [weak self] in self?.pause() }
        np.onTogglePlayPause = { [weak self] in self?.togglePlayPause() }
        np.onNextTrack = { [weak self] in self?.playNextInQueue() }
        np.onPreviousTrack = { [weak self] in self?.playPreviousInQueue() }
        np.onSeekTo = { [weak self] t in self?.seek(to: t) }
        np.onSkipBy = { [weak self] d in self?.skip(by: d) }

        SleepTimerManager.shared.onTimerExpired = { [weak self] in
            self?.pause()
        }
    }

    // MARK: - Live Reconnect & History Persistence

    private func attemptLiveRecoveryOrFallback(error: Error) {
        guard let media = currentMedia else { return }
        let autoReconnect = store?.autoReconnectLive ?? true

        if media.isLive && autoReconnect {
            // First try next backup endpoint if available
            if selectedEndpointIndex + 1 < media.endpoints.count {
                selectedEndpointIndex += 1
                statusBadgeText = "自动切至备用线路 \(selectedEndpointIndex + 1)"
                loadCurrentEndpoint(resumeTime: 0)
                return
            }

            if liveReconnectAttempts < maxLiveReconnectAttempts {
                liveReconnectAttempts += 1
                let delay = Double(liveReconnectAttempts) * 1.5
                statusBadgeText = "断线重连中 (\(liveReconnectAttempts)/\(maxLiveReconnectAttempts))"
                let item = DispatchWorkItem { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentMedia?.id == media.id else { return }
                        self.selectedEndpointIndex = 0
                        self.loadCurrentEndpoint(resumeTime: 0)
                    }
                }
                reconnectWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                return
            }
        }

        isBuffering = false
        isPlaying = false
        errorMessage = "播放失败: \(error.localizedDescription)"
        syncNowPlayingProgress()
    }

    private func syncNowPlayingFull() {
        guard let media = currentMedia else { return }
        let epgSubtitle = media.isLive ? store?.currentProgramTitle(forChannelNamed: media.title) : nil
        NowPlayingCoordinator.shared.updateMetadata(
            media: media,
            subtitleOverride: epgSubtitle ?? media.subtitle,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            rate: media.isLive ? 1.0 : playbackRate,
            canSwitchNext: canSwitchNext,
            canSwitchPrevious: canSwitchPrevious
        )
    }

    private func syncNowPlayingProgress() {
        guard let media = currentMedia else { return }
        NowPlayingCoordinator.shared.updateProgressOnly(
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            rate: media.isLive ? 1.0 : playbackRate,
            isLive: media.isLive
        )
    }

    private func saveWatchProgress(force: Bool) {
        guard let media = currentMedia,
              let store,
              selectedEndpointIndex < media.endpoints.count
        else { return }
        if !force && Date().timeIntervalSince(lastHistorySaveDate) < 5 {
            return
        }
        lastHistorySaveDate = Date()

        let endpoint = media.endpoints[selectedEndpointIndex]
        let item = WatchHistoryItem(
            mediaKey: media.mediaKey,
            title: media.title,
            subtitle: media.subtitle,
            posterURL: media.artworkURL,
            url: endpoint.url,
            isLive: media.isLive,
            position: media.isLive ? 0 : currentTime,
            duration: media.isLive ? 0 : duration,
            updatedAt: Date(),
            headers: endpoint.headers,
            siteKey: media.siteKey,
            vodID: media.vodID,
            episodeName: media.episodeName
        )
        store.recordHistory(item)
    }
}

// MARK: - KSPlayerLayerDelegate

extension PlayerEngineManager: KSPlayerLayerDelegate {
    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        playerState = state
        updateActiveEngineLabel(from: layer.player)
        configureAVPlayerBackgroundPolicyIfNeeded(layer.player)

        switch state {
        case .initialized, .preparing:
            isBuffering = true
        case .readyToPlay:
            errorMessage = nil
            liveReconnectAttempts = 0
            if isAudioOnlyMode {
                applyAudioOnlyModeToActivePlayer()
            } else if isInBackground, let avPlayer = layer.player as? KSAVPlayer {
                avPlayer.enterBackground()
            }
            if pendingResumeTime > 3 {
                let target = pendingResumeTime
                pendingResumeTime = 0
                layer.seek(time: target, autoPlay: true) { _ in }
            }
            duration = layer.player.duration
            syncNowPlayingFull()
        case .buffering:
            isBuffering = true
            isPlaying = true
        case .bufferFinished:
            isBuffering = false
            isPlaying = true
            errorMessage = nil
            liveReconnectAttempts = 0
            syncNowPlayingFull()
        case .paused:
            isBuffering = false
            isPlaying = false
            syncNowPlayingProgress()
        case .playedToTheEnd:
            isBuffering = false
            isPlaying = false
            saveWatchProgress(force: true)
            if SleepTimerManager.shared.activePreset == .endOfEpisode {
                SleepTimerManager.shared.notifyEpisodeEndedIfNeeded()
            } else if currentMedia?.isLive == false && canSwitchNext {
                playNextInQueue()
            }
        case .error:
            isBuffering = false
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        self.currentTime = currentTime
        self.duration = totalTime
        saveWatchProgress(force: false)
        syncNowPlayingProgress()
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        if let error {
            attemptLiveRecoveryOrFallback(error: error)
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        // Hook available for latency telemetry if desired
    }
}
