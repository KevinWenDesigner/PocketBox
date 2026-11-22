import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject private var playerManager: PlayerEngineManager
    @EnvironmentObject private var sleepTimer: SleepTimerManager

    var body: some View {
        if let media = playerManager.currentMedia, !playerManager.isPlayerPresented {
            HStack(spacing: 12) {
                Button {
                    playerManager.isPlayerPresented = true
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.22))
                                .frame(width: 42, height: 42)
                            Image(systemName: playerManager.isAudioOnlyMode ? "headphones" : (media.isLive ? "dot.radiowaves.left.and.right" : "play.tv.fill"))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(media.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)

                                if playerManager.isAudioOnlyMode {
                                    Text("纯音频")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.green.opacity(0.2))
                                        .foregroundColor(.green)
                                        .cornerRadius(4)
                                }
                            }

                            HStack(spacing: 6) {
                                Text(sleepTimer.formattedRemaining ?? media.subtitle ?? playerManager.statusBadgeText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                Button {
                    playerManager.toggleAudioOnlyMode()
                } label: {
                    Image(systemName: playerManager.isAudioOnlyMode ? "video.slash.fill" : "headphones")
                        .font(.system(size: 16))
                        .foregroundColor(playerManager.isAudioOnlyMode ? .green : .secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)

                Button {
                    playerManager.togglePlayPause()
                } label: {
                    Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.primary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)

                Button {
                    playerManager.stopAndDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(UIColor.secondarySystemBackground))
                    .shadow(color: Color.black.opacity(0.15), radius: 8, y: 2)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }
}
