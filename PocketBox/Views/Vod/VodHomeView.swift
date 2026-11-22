import SwiftUI

struct VodHomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var playerManager: PlayerEngineManager

    @State private var selectedMode = 0
    @State private var showAddCustomSheet = false

    // CMS browsing state
    @State private var selectedSiteKey: String = ""
    @State private var categories: [VodCategory] = []
    @State private var selectedCategoryID: String?
    @State private var movies: [VodMovie] = []
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var searchText = ""
    @State private var isLoadingCMS = false
    @State private var cmsError: String?

    private var activeSite: VodSite? {
        store.vodSites.first { $0.key == selectedSiteKey } ?? store.vodSites.first
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("点播模式", selection: $selectedMode) {
                    Text("自定义直链").tag(0)
                    Text("CMS 影视库 (\(store.vodSites.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if selectedMode == 0 {
                    customMediaSection
                } else {
                    cmsBrowserSection
                }
            }
            .navigationTitle("点播中心")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddCustomSheet = true
                    } label: {
                        Label("添加链接", systemImage: "plus.circle")
                    }
                }
            }
            .sheet(isPresented: $showAddCustomSheet) {
                AddCustomMediaSheet { item, playNow in
                    store.addCustomMedia(item)
                    if playNow {
                        let resume = store.savedPosition(forMediaKey: "custom::\(item.url)")
                        let playable = PlayableMedia.from(custom: item, resumeTime: resume)
                        playerManager.play(media: playable)
                    }
                }
            }
            .onAppear {
                if selectedSiteKey.isEmpty, let first = store.vodSites.first {
                    selectedSiteKey = first.key
                }
                if !store.vodSites.isEmpty && selectedMode == 1 && movies.isEmpty {
                    Task { await loadCMS(resetPage: true) }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Custom Direct Links & Playlists

    private var customMediaSection: some View {
        List {
            Section {
                Button {
                    showAddCustomSheet = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "link.badge.plus")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("粘贴点播 / 直播直链播放")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("支持 MP4 / M3U8 / FLV / MKV / RTMP 及自定义 UA / Referer")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !store.customMedia.isEmpty {
                Section("我的自定义点播列表") {
                    ForEach(Array(store.customMedia.enumerated()), id: \.element.id) { idx, item in
                        Button {
                            let queue = store.customMedia.map { cm in
                                let resume = store.savedPosition(forMediaKey: "custom::\(cm.url)")
                                return PlayableMedia.from(custom: cm, resumeTime: resume)
                            }
                            playerManager.play(media: queue[idx], queue: queue, startIndex: idx)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.accentColor.opacity(0.15))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: item.isLive ? "dot.radiowaves.left.and.right" : "film")
                                        .foregroundColor(.accentColor)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title)
                                        .font(.body.weight(.medium))
                                        .foregroundColor(.primary)
                                    Text(item.subtitle ?? item.url)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.deleteCustomMedia(at: offsets)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - MacCMS Browser

    private var cmsBrowserSection: some View {
        Group {
            if store.vodSites.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "film.stack")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text("尚未添加 MacCMS 点播源")
                        .font(.headline)
                    Text("可在「源与设置 -> 源管理」中添加 MacCMS XML/JSON 接口，或导入含 CMS 站点的 TVBox JSON 订阅")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    // Site & Search Header
                    VStack(spacing: 8) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(store.vodSites) { site in
                                    let isSel = activeSite?.key == site.key
                                    Button {
                                        selectedSiteKey = site.key
                                        selectedCategoryID = nil
                                        categories = []
                                        Task { await loadCMS(resetPage: true) }
                                    } label: {
                                        Text(site.name)
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(isSel ? Color.accentColor : Color(UIColor.secondarySystemBackground))
                                            .foregroundColor(isSel ? .white : .primary)
                                            .cornerRadius(14)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                        }

                        if !categories.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    categoryChip(id: nil, name: "最新")
                                    ForEach(categories) { cat in
                                        categoryChip(id: cat.id, name: cat.name)
                                    }
                                }
                                .padding(.horizontal, 14)
                            }
                        }

                        HStack(spacing: 8) {
                            TextField("搜索片名...", text: $searchText)
                                .textFieldStyle(.roundedBorder)
                                .submitLabel(.search)
                                .onSubmit {
                                    Task { await loadCMS(resetPage: true) }
                                }
                            Button("搜索") {
                                Task { await loadCMS(resetPage: true) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.horizontal, 14)
                    }
                    .padding(.vertical, 8)

                    if let cmsError {
                        Text(cmsError)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }

                    if isLoadingCMS && movies.isEmpty {
                        Spacer()
                        ProgressView("加载影视列表中...")
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 112), spacing: 12)],
                                spacing: 14
                            ) {
                                ForEach(movies) { movie in
                                    NavigationLink {
                                        if let site = activeSite {
                                            VodDetailView(movie: movie, site: site)
                                        }
                                    } label: {
                                        movieCard(movie)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(14)

                            if currentPage < totalPages {
                                Button {
                                    Task { await loadMoreCMS() }
                                } label: {
                                    if isLoadingCMS {
                                        ProgressView()
                                    } else {
                                        Text("加载下一页 (\(currentPage)/\(totalPages))")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .padding(.bottom, 24)
                            }
                        }
                        .refreshable {
                            await loadCMS(resetPage: true)
                        }
                    }
                }
                .onAppear {
                    if movies.isEmpty {
                        Task { await loadCMS(resetPage: true) }
                    }
                }
            }
        }
    }

    private func categoryChip(id: String?, name: String) -> some View {
        let selected = selectedCategoryID == id
        return Button {
            selectedCategoryID = id
            searchText = ""
            Task { await loadCMS(resetPage: true) }
        } label: {
            Text(name)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? Color.blue.opacity(0.2) : Color(UIColor.tertiarySystemBackground))
                .foregroundColor(selected ? .blue : .primary)
                .cornerRadius(10)
        }
    }

    private func movieCard(_ movie: VodMovie) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(UIColor.secondarySystemBackground))
                    .frame(height: 156)

                if let pic = movie.posterURL, let url = URL(string: pic) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img
                                .resizable()
                                .scaledToFill()
                                .frame(height: 156)
                                .clipped()
                                .cornerRadius(10)
                        default:
                            Image(systemName: "film")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }

                if let remarks = movie.remarks, !remarks.isEmpty {
                    Text(remarks)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.72))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                        .padding(5)
                }
            }
            .frame(height: 156)

            Text(movie.title)
                .font(.caption.weight(.medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .frame(height: 34, alignment: .topLeading)
        }
    }

    private func loadCMS(resetPage: Bool) async {
        guard let site = activeSite else { return }
        isLoadingCMS = true
        cmsError = nil
        if resetPage { currentPage = 1 }
        do {
            let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let res = try await SourceRepository.shared.fetchVodList(
                site: site,
                categoryID: kw.isEmpty ? selectedCategoryID : nil,
                page: currentPage,
                keyword: kw.isEmpty ? nil : kw,
                defaultUA: store.defaultUserAgent
            )
            if categories.isEmpty && !res.categories.isEmpty {
                categories = res.categories
            }
            movies = res.movies
            totalPages = max(res.pageCount, 1)
        } catch {
            cmsError = error.localizedDescription
        }
        isLoadingCMS = false
    }

    private func loadMoreCMS() async {
        guard let site = activeSite, !isLoadingCMS, currentPage < totalPages else { return }
        isLoadingCMS = true
        let nextPage = currentPage + 1
        do {
            let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let res = try await SourceRepository.shared.fetchVodList(
                site: site,
                categoryID: kw.isEmpty ? selectedCategoryID : nil,
                page: nextPage,
                keyword: kw.isEmpty ? nil : kw,
                defaultUA: store.defaultUserAgent
            )
            movies.append(contentsOf: res.movies)
            currentPage = nextPage
            totalPages = max(res.pageCount, nextPage)
        } catch {
            cmsError = error.localizedDescription
        }
        isLoadingCMS = false
    }
}

private struct AddCustomMediaSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var url = ""
    @State private var userAgent = ""
    @State private var referer = ""
    @State private var isLive = false

    let onSave: (CustomMediaItem, Bool) -> Void

    var body: some View {
        NavigationView {
            Form {
                Section("视频流地址") {
                    TextField("标题（选填）", text: $title)
                    TextField("http(s):// / rtmp:// / rtsp:// 地址", text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Toggle("作为直播流播放 (无进度条)", isOn: $isLive)
                }

                Section("可选请求头 (防盗链 / 自定义 UA)") {
                    TextField("User-Agent（留空使用默认）", text: $userAgent)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Referer（防盗链来源页）", text: $referer)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section {
                    Button {
                        submit(playNow: true)
                    } label: {
                        HStack {
                            Spacer()
                            Label("保存并立即播放", systemImage: "play.fill")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("仅保存到点播列表") {
                        submit(playNow: false)
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("添加点播/直链")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func submit(playNow: Bool) {
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }
        var headers: [String: String] = [:]
        if !userAgent.trimmingCharacters(in: .whitespaces).isEmpty {
            headers["User-Agent"] = userAgent.trimmingCharacters(in: .whitespaces)
        }
        if !referer.trimmingCharacters(in: .whitespaces).isEmpty {
            headers["Referer"] = referer.trimmingCharacters(in: .whitespaces)
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = URL(string: cleanURL)?.lastPathComponent ?? "自定义视频"
        let item = CustomMediaItem(
            title: cleanTitle.isEmpty ? (fallbackTitle.isEmpty ? "自定义视频" : fallbackTitle) : cleanTitle,
            url: cleanURL,
            isLive: isLive,
            headers: headers
        )
        onSave(item, playNow)
        dismiss()
    }
}
