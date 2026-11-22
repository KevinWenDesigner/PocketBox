import SwiftUI

struct LiveHomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var playerManager: PlayerEngineManager

    @State private var selectedGroup: String = "全部"
    @State private var searchText: String = ""
    @State private var showSourcesSheet = false

    private var availableGroups: [String] {
        var list = ["全部"]
        if !store.favorites.isEmpty {
            list.append("收藏")
        }
        list.append(contentsOf: store.channelGroups)
        return list
    }

    private var filteredChannels: [LiveChannel] {
        let base: [LiveChannel]
        if selectedGroup == "全部" {
            base = store.channels
        } else if selectedGroup == "收藏" {
            base = store.favorites.map { $0.toLiveChannel() }
        } else {
            base = store.channels.filter { $0.group == selectedGroup }
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(q) || $0.group.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !availableGroups.isEmpty {
                    groupFilterBar
                }

                if filteredChannels.isEmpty {
                    emptyStateView
                } else {
                    List {
                        ForEach(Array(filteredChannels.enumerated()), id: \.element.id) { index, channel in
                            channelRow(channel: channel, index: index)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await store.syncAllEnabledSources()
                    }
                }
            }
            .navigationTitle("电视直播")
            .searchable(text: $searchText, prompt: "搜索频道名或分组")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if store.isSyncingSources {
                        ProgressView()
                    } else {
                        Button {
                            Task { await store.syncAllEnabledSources() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSourcesSheet = true
                    } label: {
                        Label("导入源", systemImage: "plus.circle")
                    }
                }
            }
            .sheet(isPresented: $showSourcesSheet) {
                NavigationView {
                    SourcesManagerView()
                }
                .navigationViewStyle(.stack)
            }
        }
        .navigationViewStyle(.stack)
    }

    private var groupFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableGroups, id: \.self) { group in
                    let isSelected = selectedGroup == group
                    Button {
                        selectedGroup = group
                    } label: {
                        Text(group)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSelected ? Color.accentColor : Color(UIColor.secondarySystemBackground))
                            .foregroundColor(isSelected ? .white : .primary)
                            .cornerRadius(16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Color(UIColor.systemBackground))
    }

    private func channelRow(channel: LiveChannel, index: Int) -> some View {
        let program = store.currentProgram(for: channel)
        let isFav = store.isFavorite(channel)
        let isCurrent = playerManager.currentMedia?.mediaKey == "live::\(channel.id)"

        return HStack(spacing: 12) {
            channelLogo(urlString: channel.logo, name: channel.name)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(channel.name)
                        .font(.body.weight(isCurrent ? .bold : .medium))
                        .foregroundColor(isCurrent ? .accentColor : .primary)
                        .lineLimit(1)

                    if channel.endpoints.count > 1 {
                        Text("\(channel.endpoints.count)线")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.14))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }

                if let program {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("正在播出: \(program.title)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        ProgressView(value: program.progress())
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                    }
                } else {
                    Text(channel.group)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                store.toggleFavorite(channel)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .foregroundColor(isFav ? .yellow : .secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            playChannel(at: index)
        }
        .contextMenu {
            Button {
                playChannel(at: index, audioOnly: false)
            } label: {
                Label("播放视频", systemImage: "play.tv")
            }
            Button {
                playChannel(at: index, audioOnly: true)
            } label: {
                Label("纯音频省电模式收听", systemImage: "headphones")
            }
            Button {
                store.toggleFavorite(channel)
            } label: {
                Label(isFav ? "取消收藏" : "加入收藏", systemImage: isFav ? "star.slash" : "star")
            }
        }
        .task {
            await store.fetchChannelEPGIfNeeded(channel)
        }
    }

    private func channelLogo(urlString: String?, name: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(UIColor.secondarySystemBackground))
                .frame(width: 46, height: 34)

            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: 42, height: 30)
                            .cornerRadius(6)
                    default:
                        Text(String(name.prefix(2)))
                            .font(.caption.weight(.bold))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text(String(name.prefix(2)))
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "tv.slash")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text(store.channels.isEmpty ? "暂无直播频道" : "未找到匹配的频道")
                .font(.headline)
            Text("点击右上角导入 M3U / TXT 直播源或 TVBox JSON 订阅")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 12) {
                Button("添加直播源") {
                    showSourcesSheet = true
                }
                .buttonStyle(.borderedProminent)
                if store.channels.isEmpty {
                    Button("载入示例流") {
                        store.loadDemoLegalTestStreams()
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
    }

    private func playChannel(at index: Int, audioOnly: Bool? = nil) {
        let queue = filteredChannels.map { ch in
            PlayableMedia.from(channel: ch, currentProgram: store.currentProgram(for: ch)?.title)
        }
        guard index >= 0, index < queue.count else { return }
        if let audioOnly {
            let prevDefault = store.defaultAudioOnlyMode
            store.defaultAudioOnlyMode = audioOnly
            playerManager.play(media: queue[index], queue: queue, startIndex: index)
            store.defaultAudioOnlyMode = prevDefault
        } else {
            playerManager.play(media: queue[index], queue: queue, startIndex: index)
        }
    }
}
