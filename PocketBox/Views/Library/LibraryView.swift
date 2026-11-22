import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var playerManager: PlayerEngineManager

    var body: some View {
        NavigationView {
            List {
                Section("收藏频道 (\(store.favorites.count))") {
                    if store.favorites.isEmpty {
                        Text("长按或点击频道右侧星标即可收藏")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(store.favorites.enumerated()), id: \.element.id) { idx, fav in
                            Button {
                                let queue = store.favorites.map { favItem in
                                    let ch = favItem.toLiveChannel()
                                    return PlayableMedia.from(channel: ch, currentProgram: store.currentProgram(for: ch)?.title)
                                }
                                playerManager.play(media: queue[idx], queue: queue, startIndex: idx)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "star.fill")
                                        .foregroundColor(.yellow)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(fav.name)
                                            .foregroundColor(.primary)
                                        Text(fav.group)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                store.toggleFavorite(store.favorites[index].toLiveChannel())
                            }
                        }
                    }
                }

                Section {
                    if store.watchHistory.isEmpty {
                        Text("暂无播放记录")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(store.watchHistory) { item in
                            Button {
                                resumeHistoryItem(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Image(systemName: item.isLive ? "dot.radiowaves.left.and.right" : "play.rectangle.fill")
                                            .foregroundColor(item.isLive ? .green : .accentColor)
                                        Text(item.title)
                                            .font(.body.weight(.medium))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(relativeTime(item.updatedAt))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    if let sub = item.subtitle, !sub.isEmpty {
                                        Text(sub)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }

                                    if !item.isLive && item.duration > 1 {
                                        HStack(spacing: 8) {
                                            ProgressView(value: item.progressRatio)
                                                .progressViewStyle(.linear)
                                            Text("\(formatTime(item.position)) / \(formatTime(item.duration))")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("最近播放 (\(store.watchHistory.count))")
                        Spacer()
                        if !store.watchHistory.isEmpty {
                            Button("清空") {
                                store.clearHistory()
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("历史与收藏")
        }
        .navigationViewStyle(.stack)
    }

    private func resumeHistoryItem(_ item: WatchHistoryItem) {
        let resume = item.isLive ? 0 : item.position
        let playable = PlayableMedia(
            mediaKey: item.mediaKey,
            title: item.title,
            subtitle: item.subtitle,
            artworkURL: item.posterURL,
            endpoints: [StreamEndpoint(label: "续播线路", url: item.url, headers: item.headers)],
            isLive: item.isLive,
            startTime: resume,
            siteKey: item.siteKey,
            vodID: item.vodID,
            episodeName: item.episodeName
        )
        playerManager.play(media: playable)
    }

    private func relativeTime(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
