import KSPlayer
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var playerManager: PlayerEngineManager
    @EnvironmentObject private var sleepTimer: SleepTimerManager
    @EnvironmentObject private var audioSession: AudioSessionManager

    var body: some View {
        NavigationView {
            Form {
                Section("源订阅与导入") {
                    NavigationLink {
                        SourcesManagerView()
                    } label: {
                        HStack {
                            Label("订阅源与接口管理", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            Text("\(store.sources.count) 个源")
                                .foregroundColor(.secondary)
                        }
                    }

                    Button {
                        Task { await store.syncAllEnabledSources() }
                    } label: {
                        HStack {
                            Label("立即刷新全部订阅源", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if store.isSyncingSources {
                                ProgressView()
                            }
                        }
                    }
                }

                Section {
                    Toggle("锁屏与切后台自动续播音频", isOn: $store.backgroundPlayEnabled)
                        .onChange(of: store.backgroundPlayEnabled) { newVal in
                            KSOptions.canBackgroundPlay = newVal
                        }

                    Toggle("默认以「纯音频省电模式」启动", isOn: $store.defaultAudioOnlyMode)

                    Picker("定时关闭", selection: Binding(
                        get: { sleepTimer.activePreset },
                        set: { sleepTimer.setPreset($0) }
                    )) {
                        ForEach(SleepTimerPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }

                    if let rem = sleepTimer.formattedRemaining {
                        HStack {
                            Text("定时状态")
                            Spacer()
                            Text(rem).foregroundColor(.orange)
                        }
                    }
                } header: {
                    Text("后台与锁屏播放")
                } footer: {
                    Text("开启后，锁屏或切到其他 App 时会自动分离视频渲染层并保持 AVAudioSession 激活，支持在锁屏卡片切换上/下一频道或剧集。纯音频模式会停止视频解码以降低 iOS 15 设备发热。")
                }

                Section("播放器内核与网络") {
                    Picker("内核策略", selection: $store.enginePreference) {
                        ForEach(EnginePreference.allCases) { pref in
                            Text(pref.title).tag(pref)
                        }
                    }

                    Toggle("硬件解码 (VideoToolbox)", isOn: $store.hardwareDecode)
                        .onChange(of: store.hardwareDecode) { newVal in
                            KSOptions.hardwareDecode = newVal
                        }

                    Toggle("直播断线自动切线 / 重连", isOn: $store.autoReconnectLive)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("预缓冲时长")
                            Spacer()
                            Text("\(String(format: "%.1f", store.bufferDuration)) 秒")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $store.bufferDuration, in: 1.0...10.0, step: 0.5)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("默认 User-Agent")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("User-Agent", text: $store.defaultUserAgent)
                            .font(.caption)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }

                Section("后台播放状态诊断") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(audioSession.diagnosticSummary)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                        Text("KSOptions.canBackgroundPlay: \(KSOptions.canBackgroundPlay ? "true" : "false") | 当前引擎: \(playerManager.activeEngine.rawValue)")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                }

                Section("数据与维护") {
                    Button("载入公开合法测试流") {
                        store.loadDemoLegalTestStreams()
                    }
                    Button("清除网络与 EPG 缓存", role: .destructive) {
                        store.clearCache()
                    }
                }

                if let notice = store.syncNotice {
                    Section("提示") {
                        Text(notice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("源与设置")
        }
        .navigationViewStyle(.stack)
    }
}
