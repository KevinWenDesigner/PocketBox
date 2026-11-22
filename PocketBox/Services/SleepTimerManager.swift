import Foundation

@MainActor
final class SleepTimerManager: ObservableObject {
    static let shared = SleepTimerManager()

    @Published private(set) var activePreset: SleepTimerPreset = .off
    @Published private(set) var remainingSeconds: TimeInterval = 0

    var onTimerExpired: (() -> Void)?

    private var targetDate: Date?
    private var tickTimer: Timer?

    private init() {}

    var isActive: Bool {
        activePreset != .off
    }

    var formattedRemaining: String? {
        switch activePreset {
        case .off:
            return nil
        case .endOfEpisode:
            return "本集播完后关闭"
        case .minutes:
            let total = max(Int(ceil(remainingSeconds)), 0)
            let mins = total / 60
            let secs = total % 60
            return String(format: "%02d:%02d 后停止", mins, secs)
        }
    }

    func setPreset(_ preset: SleepTimerPreset) {
        tickTimer?.invalidate()
        tickTimer = nil
        targetDate = nil
        activePreset = preset

        switch preset {
        case .off:
            remainingSeconds = 0
        case .endOfEpisode:
            remainingSeconds = 0
        case .minutes(let mins):
            let duration = TimeInterval(mins * 60)
            targetDate = Date().addingTimeInterval(duration)
            remainingSeconds = duration
            startTicker()
        }
    }

    func notifyEpisodeEndedIfNeeded() {
        if activePreset == .endOfEpisode {
            setPreset(.off)
            onTimerExpired?()
        }
    }

    private func startTicker() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateCountdown()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func evaluateCountdown() {
        guard let targetDate else { return }
        let left = targetDate.timeIntervalSinceNow
        if left <= 0 {
            setPreset(.off)
            onTimerExpired?()
        } else {
            remainingSeconds = left
        }
    }
}
