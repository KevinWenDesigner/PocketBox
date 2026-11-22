import SwiftUI
import UniformTypeIdentifiers

struct SourcesManagerView: View {
    @EnvironmentObject private var store: AppStore

    @State private var showAddSourceSheet = false
    @State private var showFileImporter = false
    @State private var epgField = ""

    var body: some View {
        List {
            Section {
                Button {
                    showAddSourceSheet = true
                } label: {
                    Label("添加网络订阅源 (M3U / TXT / TVBox / MacCMS)", systemImage: "plus.circle.fill")
                }

                Button {
                    showFileImporter = true
                } label: {
                    Label("从「文件」App 导入本地 M3U / TXT", systemImage: "folder.badge.plus")
                }

                Button {
                    Task { await store.syncAllEnabledSources() }
                } label: {
                    HStack {
                        Label("同步全部已启用源", systemImage: "arrow.clockwise.circle")
                        Spacer()
                        if store.isSyncingSources {
                            ProgressView()
                        }
                    }
                }
            }

            Section {
                HStack {
                    TextField("XMLTV 或 DIYP EPG 地址（支持 {name}/{date}）", text: $epgField)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("保存") {
                        store.activeEPGURL = epgField.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await store.refreshGlobalEPG() }
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Text("全局 EPG 节目单")
            }

            Section("已添加订阅源 (\(store.sources.count))") {
                if store.sources.isEmpty {
                    Text("尚未添加网络订阅，点击上方按钮添加")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.sources) { src in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { src.isEnabled },
                                    set: { val in
                                        var updated = src
                                        updated.isEnabled = val
                                        store.updateSource(updated)
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(src.name)
                                            .font(.headline)
                                        Text(src.kind.displayName)
                                            .font(.caption)
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }

                            Text(src.url)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)

                            if let summary = src.lastSummary {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundColor(summary.hasPrefix("失败") ? .red : .green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        store.deleteSources(at: offsets)
                    }
                }
            }

            if let notice = store.syncNotice {
                Section("同步状态") {
                    Text(notice)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("订阅源管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            epgField = store.activeEPGURL
        }
        .sheet(isPresented: $showAddSourceSheet) {
            AddSourceSheet { newSource in
                store.addSource(newSource)
                Task { await store.syncAllEnabledSources() }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.plainText, .json, .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            let accessed = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { fileURL.stopAccessingSecurityScopedResource() }
            }
            if let data = try? Data(contentsOf: fileURL) {
                let text = NetworkClient.decodeText(data)
                let name = fileURL.deletingPathExtension().lastPathComponent
                store.importLocalPlaylist(content: text, name: name.isEmpty ? "本地导入" : name)
            }
        case .failure(let err):
            store.syncNotice = "导入失败: \(err.localizedDescription)"
        }
    }
}

private struct AddSourceSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var kind: SourceKind = .livePlaylist
    @State private var epgURL = ""
    @State private var customUA = ""
    @State private var customReferer = ""

    let onAdd: (SubscriptionSource) -> Void

    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    TextField("源名称（例如：家庭直播源）", text: $name)
                    Picker("源类型", selection: $kind) {
                        ForEach(SourceKind.allCases) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    TextField("订阅 URL 地址", text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    if kind == .livePlaylist {
                        TextField("EPG 节目单地址（选填）", text: $epgURL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }

                Section("可选请求头") {
                    TextField("User-Agent（选填）", text: $customUA)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Referer（选填）", text: $customReferer)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                if kind == .tvboxConfig {
                    Section("TVBox 配置兼容说明") {
                        Text("会自动导入配置内的直播列表 (lives)、EPG 以及 MacCMS XML/JSON 点播站点 (type 0/1)。由于 iOS 系统限制，Android .jar 爬虫 (type 3) 将自动跳过。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("添加订阅源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存并同步") {
                        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        var headers: [String: String] = [:]
                        if !customUA.trimmingCharacters(in: .whitespaces).isEmpty {
                            headers["User-Agent"] = customUA.trimmingCharacters(in: .whitespaces)
                        }
                        if !customReferer.trimmingCharacters(in: .whitespaces).isEmpty {
                            headers["Referer"] = customReferer.trimmingCharacters(in: .whitespaces)
                        }
                        let source = SubscriptionSource(
                            name: cleanName.isEmpty ? kind.displayName : cleanName,
                            url: cleanURL,
                            kind: kind,
                            epgURL: epgURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : epgURL.trimmingCharacters(in: .whitespacesAndNewlines),
                            customHeaders: headers
                        )
                        onAdd(source)
                        dismiss()
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
