import AVFoundation
import Foundation

final class AudioSessionManager: ObservableObject {
    static let shared = AudioSessionManager()

    @Published private(set) var isSessionActive = false
    @Published private(set) var currentRouteSummary = "扬声器"
    @Published private(set) var lastError: String?

    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEndedShouldResume: (() -> Void)?
    var onRouteBecameUnavailable: (() -> Void)?

    private var observersRegistered = false

    private init() {
        registerNotifications()
        refreshRouteSummary()
    }

    /// Configures AVAudioSession for exclusive background & lock-screen playback.
    /// Deliberately omits `.mixWithOthers` so iOS displays Now Playing controls on the Lock Screen.
    func configureAndActivate(audioOnlyMode: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        do {
            let mode: AVAudioSession.Mode = audioOnlyMode ? .default : .moviePlayback
            try session.setCategory(.playback, mode: mode, options: [])
            try session.setActive(true)
            DispatchQueue.main.async {
                self.isSessionActive = true
                self.lastError = nil
                self.refreshRouteSummary()
            }
        } catch {
            DispatchQueue.main.async {
                self.lastError = error.localizedDescription
            }
        }
    }

    func refreshRouteSummary() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let names = outputs.map { $0.portName }.filter { !$0.isEmpty }
        currentRouteSummary = names.isEmpty ? "默认音频输出" : names.joined(separator: ", ")
    }

    var diagnosticSummary: String {
        let session = AVAudioSession.sharedInstance()
        return "Category: \(session.category.rawValue) | Mode: \(session.mode.rawValue) | 活跃: \(isSessionActive ? "是" : "否") | 路由: \(currentRouteSummary)"
    }

    private func registerNotifications() {
        guard !observersRegistered else { return }
        observersRegistered = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }

        DispatchQueue.main.async {
            switch type {
            case .began:
                self.onInterruptionBegan?()
            case .ended:
                if let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
                    if opts.contains(.shouldResume) {
                        self.configureAndActivate()
                        self.onInterruptionEndedShouldResume?()
                    }
                }
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        DispatchQueue.main.async {
            self.refreshRouteSummary()
            guard let info = notification.userInfo,
                  let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
            else { return }

            if reason == .oldDeviceUnavailable {
                self.onRouteBecameUnavailable?()
            }
        }
    }
}
