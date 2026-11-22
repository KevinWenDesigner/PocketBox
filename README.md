# 口袋盒子 (PocketBox) — iOS 15.8.8 直播与点播播放器

专为 **iOS 15.0+（含 iOS 15.8.8 老机型如 iPhone 6s / 7 / SE1 / iPad）** 打造的轻量级 TVBox 风格直播、点播 App，核心针对 **后台切出与锁屏连续播放** 进行了深度适配。

## 核心特性

1. **后台与锁屏稳定续播（核心特性）**
   - 启用 `UIBackgroundModes: audio` 与独占式 `AVAudioSession`（`.playback`，未设置 `.mixWithOthers`，确保锁屏界面与控制中心完整接管媒体卡片）。
   - 对原生 `AVPlayer` 配置 `audiovisualBackgroundPlaybackPolicy = .continuesIfPossible`，并在锁屏 / 退到后台 (`willResignActive` / `didEnterBackground`) 时自动将 `AVPlayerLayer` 从视图层分离，杜绝 iOS 15 锁屏瞬间强制暂停视频流的问题。
   - 通过 `MPNowPlayingInfoCenter` 与 `MPRemoteCommandCenter` 在锁屏界面展示频道台标/海报封面、当前播出节目或剧集名称、播放进度条，并支持直接通过锁屏或耳机线控切换**上一/下一频道或剧集**。
   - **纯音频省电模式**：一键关闭视频解码（`AVPlayer` 禁用视频轨并限制最低码率、`KSMEPlayer` 启用 `videoDisable = true` 跳过视频帧解码），显著减少 iOS 15 老设备在锁屏听剧/听直播时的发热与耗电。
   - **定时关闭**：支持 15/30/45/60/90 分钟倒计时及点播「播完当前集」自动停止。

2. **双引擎兼容（AVPlayer + FFmpeg）**
   - 基于 `KSPlayer 2.3.4`（含 `FFmpegKit`），默认采用「系统 `AVPlayer` 硬解优先 + `KSMEPlayer (FFmpeg)` 自动兜底」。
   - 自动识别 `rtmp://`、`rtsp://`、`.flv`、`.mkv`、`.rmvb`、`.ts` 等非原生流并直走 FFmpeg 内核，同时支持播放页面一键热切换内核。

3. **直播 / 点播源生态**
   - **直播源**：兼容 `M3U / M3U8`（含 `#EXTVLCOPT`、`x-tvg-url`、管道请求头 `|User-Agent=...&Referer=...`）及 TVBox/DIYP `TXT (#genre#)` 格式，自动合并同频道多条备用线路（`#` 分隔 / `$线路名`），支持本地文件导入与断线自动切线重连。
   - **EPG 节目单**：支持标准 `XMLTV` 与 `DIYP / TVBox JSON` 节目单。
   - **点播中心**：支持直接粘贴自定义点播/直播 URL（自定义 UA/Referer），并可导入 TVBox JSON 配置自动提取其中的直播源与 `MacCMS` XML/JSON 点播站点（`type: 0/1`；注：Android `.jar` 爬虫 `type: 3` 因 iOS 限制自动跳过），支持断点续播。

## 通过 GitHub Actions 云端自动构建 `.ipa`

由于本地为 Windows 环境，仓库已内置 `.github/workflows/build-ipa.yml`，推送到 GitHub 后可直接在云端 macOS Runner 编译打包：

1. 将本仓库推送到你的 GitHub 仓库（`main` 或 `master` 分支）。
2. 在 GitHub 仓库页面点击 **Actions** -> **Build PocketBox IPA (iOS 15+)** -> **Run workflow**（或 push 自动触发）。
3. 构建完成后在 Workflow 运行详情底部的 **Artifacts** 下载 `PocketBox-iOS15-IPAs.zip`，内含两个包：
   - `PocketBox-TrollStore.ipa`：已使用 `ldid` 完成 ad-hoc 假签名，适合 **iOS 15.8.8 TrollStore（巨魔）** 直接安装永久使用。
   - `PocketBox-unsigned.ipa`：纯未签名 IPA，适合用 **Sideloadly / AltStore / 爱思助手 / Feather** 自签安装。

## 工程目录结构

- `project.yml`：XcodeGen 工程配置（Deployment Target `15.0`，依赖 `KSPlayer 2.3.4`）
- `.github/workflows/build-ipa.yml`：自动运行单元测试、编译 `iphoneos` Release 并输出双版本 `.ipa`
- `PocketBox/Services/`：`PlayerEngineManager`、`AudioSessionManager`、`NowPlayingCoordinator`、`SleepTimerManager`、`SourceRepository`
- `PocketBox/Parsers/`：`PlaylistParser`、`TVBoxConfigParser`、`MacCMSParser`、`EPGParser`
- `Tests/`：`PocketBoxParserTests` 解析器单元测试
