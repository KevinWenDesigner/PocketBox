import Foundation
import MediaPlayer
import UIKit

@MainActor
final class NowPlayingCoordinator {
    static let shared = NowPlayingCoordinator()

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNextTrack: (() -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onSeekTo: ((TimeInterval) -> Void)?
    var onSkipBy: ((TimeInterval) -> Void)?

    private let artworkCache = NSCache<NSString, UIImage>()
    private var currentArtworkTask: Task<Void, Never>?
    private var commandsRegistered = false
    private var lastArtworkKey: String?

    private init() {}

    func ensureRemoteCommandsRegistered(force: Bool = false) {
        if !force && commandsRegistered {
            return
        }
        commandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPlay?() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPause?() }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onTogglePlayPause?() }
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onNextTrack?() }
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPreviousTrack?() }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor in self?.onSkipBy?(interval) }
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor in self?.onSkipBy?(-interval) }
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.onSeekTo?(posEvent.positionTime) }
            return .success
        }
    }

    func updateMetadata(
        media: PlayableMedia,
        subtitleOverride: String? = nil,
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval,
        rate: Float,
        canSwitchNext: Bool,
        canSwitchPrevious: Bool
    ) {
        ensureRemoteCommandsRegistered()

        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = canSwitchNext
        center.previousTrackCommand.isEnabled = canSwitchPrevious
        center.skipForwardCommand.isEnabled = !media.isLive
        center.skipBackwardCommand.isEnabled = !media.isLive
        center.changePlaybackPositionCommand.isEnabled = !media.isLive

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = media.title
        info[MPMediaItemPropertyArtist] = subtitleOverride ?? media.subtitle ?? (media.isLive ? "电视直播" : "视频点播")
        info[MPNowPlayingInfoPropertyIsLiveStream] = media.isLive
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(rate)

        if media.isLive {
            info[MPMediaItemPropertyPlaybackDuration] = nil
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = nil
        } else {
            info[MPMediaItemPropertyPlaybackDuration] = max(duration, 0)
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(currentTime, 0)
        }

        let artworkKey = "\(media.artworkURL ?? "")|\(media.title)"
        if lastArtworkKey != artworkKey || info[MPMediaItemPropertyArtwork] == nil {
            lastArtworkKey = artworkKey
            let fallbackImage = Self.makeFallbackArtwork(title: media.title, isLive: media.isLive)
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: fallbackImage.size) { _ in fallbackImage }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info

            if let artStr = media.artworkURL, !artStr.isEmpty {
                loadRemoteArtwork(urlString: artStr, mediaTitle: media.title, isLive: media.isLive, key: artworkKey)
            }
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func updateProgressOnly(isPlaying: Bool, currentTime: TimeInterval, duration: TimeInterval, rate: Float, isLive: Bool) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0.0
        if !isLive {
            info[MPMediaItemPropertyPlaybackDuration] = max(duration, 0)
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(currentTime, 0)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func clear() {
        currentArtworkTask?.cancel()
        currentArtworkTask = nil
        lastArtworkKey = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func loadRemoteArtwork(urlString: String, mediaTitle: String, isLive: Bool, key: String) {
        if let cached = artworkCache.object(forKey: urlString as NSString) {
            applyArtworkImage(cached, expectedKey: key)
            return
        }
        currentArtworkTask?.cancel()
        currentArtworkTask = Task {
            guard let url = URL(string: urlString),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let image = UIImage(data: data)
            else { return }
            self.artworkCache.setObject(image, forKey: urlString as NSString)
            self.applyArtworkImage(image, expectedKey: key)
        }
    }

    private func applyArtworkImage(_ image: UIImage, expectedKey: String) {
        guard lastArtworkKey == expectedKey else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static func makeFallbackArtwork(title: String, isLive: Bool) -> UIImage {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            let colors = [
                UIColor(red: 0.09, green: 0.14, blue: 0.31, alpha: 1).cgColor,
                UIColor(red: 0.17, green: 0.36, blue: 0.68, alpha: 1).cgColor
            ]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }

            let badge = isLive ? "LIVE" : "VOD"
            let badgeAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 32, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.75)
            ]
            let badgeSize = (badge as NSString).size(withAttributes: badgeAttr)
            (badge as NSString).draw(at: CGPoint(x: (size.width - badgeSize.width) / 2, y: 120), withAttributes: badgeAttr)

            let display = String(title.prefix(8))
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let titleAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .heavy),
                .foregroundColor: UIColor.white,
                .paragraphStyle: style
            ]
            let titleRect = CGRect(x: 36, y: 205, width: size.width - 72, height: 180)
            (display as NSString).draw(in: titleRect, withAttributes: titleAttr)
        }
    }
}
