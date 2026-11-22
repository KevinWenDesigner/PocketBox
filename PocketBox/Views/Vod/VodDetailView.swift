import SwiftUI

struct VodDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var playerManager: PlayerEngineManager

    let initialMovie: VodMovie
    let site: VodSite

    @State private var detailMovie: VodMovie
    @State private var selectedSourceIndex = 0
    @State private var isLoadingDetail = false
    @State private var errorText: String?

    init(movie: VodMovie, site: VodSite) {
        self.initialMovie = movie
        self.site = site
        self._detailMovie = State(initialValue: movie)
    }

    private var activeSource: VodPlaySource? {
        guard selectedSourceIndex >= 0, selectedSourceIndex < detailMovie.playSources.count else {
            return detailMovie.playSources.first
        }
        return detailMovie.playSources[selectedSourceIndex]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                if let activeSource, !activeSource.episodes.isEmpty {
                    actionButtonsRow(source: activeSource)
                }

                if let synopsis = detailMovie.synopsis, !synopsis.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("剧情简介")
                            .font(.headline)
                        Text(synopsis)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                }

                if isLoadingDetail {
                    HStack {
                        Spacer()
                        ProgressView("获取剧集列表...")
                        Spacer()
                    }
                    .padding()
                } else if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                } else if !detailMovie.playSources.isEmpty {
                    playSourcesSection
                } else {
                    Text("当前站点暂无可播放线路")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(detailMovie.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await fetchDetailIfNeeded()
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(UIColor.secondarySystemBackground))
                if let pic = detailMovie.posterURL, let url = URL(string: pic) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img
                                .resizable()
                                .scaledToFill()
                                .cornerRadius(10)
                        } else {
                            Image(systemName: "film")
                                .font(.title)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "film")
                        .font(.title)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 108, height: 152)
            .clipped()

            VStack(alignment: .leading, spacing: 6) {
                Text(detailMovie.title)
                    .font(.title3.weight(.bold))
                if let remarks = detailMovie.remarks, !remarks.isEmpty {
                    Text(remarks)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
                let meta = [detailMovie.year, detailMovie.area, detailMovie.typeName]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let director = detailMovie.director, !director.isEmpty {
                    Text("导演: \(director)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if let actor = detailMovie.actor, !actor.isEmpty {
                    Text("主演: \(actor)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    private func actionButtonsRow(source: VodPlaySource) -> some View {
        HStack(spacing: 12) {
            Button {
                playEpisode(at: 0, in: source, audioOnly: false)
            } label: {
                Label("立即播放", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)

            Button {
                playEpisode(at: 0, in: source, audioOnly: true)
            } label: {
                Label("纯音频收听", systemImage: "headphones")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.green)
        }
        .padding(.horizontal)
    }

    private var playSourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(detailMovie.playSources.enumerated()), id: \.element.id) { idx, src in
                        let isSel = idx == selectedSourceIndex
                        Button {
                            selectedSourceIndex = idx
                        } label: {
                            Text("\(src.name) (\(src.episodes.count))")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(isSel ? Color.accentColor : Color(UIColor.secondarySystemBackground))
                                .foregroundColor(isSel ? .white : .primary)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal)
            }

            if let activeSource {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 90), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(Array(activeSource.episodes.enumerated()), id: \.element.id) { idx, ep in
                        Button {
                            playEpisode(at: idx, in: activeSource, audioOnly: nil)
                        } label: {
                            Text(ep.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 6)
                                .background(Color(UIColor.secondarySystemBackground))
                                .foregroundColor(.primary)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func fetchDetailIfNeeded() async {
        guard detailMovie.playSources.isEmpty else { return }
        isLoadingDetail = true
        do {
            if let fetched = try await SourceRepository.shared.fetchVodDetail(
                site: site,
                vodID: initialMovie.vodID,
                defaultUA: store.defaultUserAgent
            ) {
                detailMovie = fetched
            }
        } catch {
            errorText = "获取详情失败: \(error.localizedDescription)"
        }
        isLoadingDetail = false
    }

    private func playEpisode(at index: Int, in source: VodPlaySource, audioOnly: Bool?) {
        let resume = store.savedPosition(forMediaKey: "vod::\(detailMovie.id)")
        let queue = source.episodes.enumerated().map { idx, ep in
            PlayableMedia.from(
                movie: detailMovie,
                sourceName: source.name,
                episode: ep,
                resumeTime: idx == index ? resume : 0
            )
        }
        guard index >= 0, index < queue.count else { return }
        if let audioOnly {
            let prev = store.defaultAudioOnlyMode
            store.defaultAudioOnlyMode = audioOnly
            playerManager.play(media: queue[index], queue: queue, startIndex: index)
            store.defaultAudioOnlyMode = prev
        } else {
            playerManager.play(media: queue[index], queue: queue, startIndex: index)
        }
    }
}
