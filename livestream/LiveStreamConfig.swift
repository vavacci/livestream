import Foundation

enum LiveStreamConfig {
    enum AppGroup {
        static let fallbackAppGroupID = "group.com.xxx.livestream"
        static let runtimeSelectedGroupKey = "runtime.activeAppGroup"
        static let runtimeSelectedUpdatedAtKey = "runtime.activeAppGroupUpdatedAt"
        static let supportedGroupsInfoKey = "SupportedAppGroups"

        private static let lock = NSLock()
        private static var cachedCurrentID: String?

        static var entitledGroupIDs: [String] {
            // Keep runtime candidates aligned with actual entitlements. TrollStore builds only grant
            // group.com.xxx.livestream, so legacy groups must not participate in runtime selection.
            let groups = configuredGroupIDsFromInfoPlist() + [fallbackAppGroupID]
            return deduplicated(groups.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }

        static func currentID(preferred preferredGroupID: String? = nil, refresh: Bool = false) -> String {
            let sanitizedPreferred = sanitize(preferredGroupID)
            lock.lock()
            defer { lock.unlock() }

            if let sanitizedPreferred, isAllowed(sanitizedPreferred) {
                cachedCurrentID = sanitizedPreferred
                return sanitizedPreferred
            }

            if !refresh, let cachedCurrentID, isAllowed(cachedCurrentID) {
                return cachedCurrentID
            }

            let resolved = discoverRuntimeSelectedGroupID() ?? entitledGroupIDs.first ?? fallbackAppGroupID
            cachedCurrentID = resolved
            return resolved
        }

        static func select(_ groupID: String, timestamp: TimeInterval = Date().timeIntervalSince1970) {
            guard let sanitized = sanitize(groupID), isAllowed(sanitized),
                  let defaults = UserDefaults(suiteName: sanitized) else {
                return
            }

            defaults.set(sanitized, forKey: runtimeSelectedGroupKey)
            defaults.set(timestamp, forKey: runtimeSelectedUpdatedAtKey)
            defaults.synchronize()

            lock.lock()
            cachedCurrentID = sanitized
            lock.unlock()
        }

        static func defaults(preferred preferredGroupID: String? = nil, refresh: Bool = false) -> UserDefaults? {
            let groupID = currentID(preferred: preferredGroupID, refresh: refresh)
            return UserDefaults(suiteName: groupID)
        }

        static func availableDefaultsByGroupID(refresh: Bool = false) -> [(String, UserDefaults)] {
            let preferred = currentID(refresh: refresh)
            let orderedGroupIDs = deduplicated([preferred] + entitledGroupIDs)
            return orderedGroupIDs.compactMap { groupID in
                guard let defaults = UserDefaults(suiteName: groupID) else { return nil }
                return (groupID, defaults)
            }
        }

        static func isAllowed(_ groupID: String) -> Bool {
            entitledGroupIDs.contains(groupID)
        }

        private static func sanitize(_ groupID: String?) -> String? {
            guard let trimmed = groupID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        private static func discoverRuntimeSelectedGroupID() -> String? {
            var selectedGroupID: String?
            var selectedTimestamp: TimeInterval = -1

            for groupID in entitledGroupIDs {
                guard let defaults = UserDefaults(suiteName: groupID) else { continue }
                let marker = defaults.string(forKey: runtimeSelectedGroupKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let timestamp = defaults.double(forKey: runtimeSelectedUpdatedAtKey)
                guard marker == groupID else { continue }
                guard timestamp >= selectedTimestamp else { continue }
                selectedTimestamp = timestamp
                selectedGroupID = groupID
            }

            return selectedGroupID
        }

        private static func configuredGroupIDsFromInfoPlist() -> [String] {
            if let groups = Bundle.main.object(forInfoDictionaryKey: supportedGroupsInfoKey) as? [String] {
                return groups
            }
            if let groups = Bundle.main.infoDictionary?[supportedGroupsInfoKey] as? [String] {
                return groups
            }
            return []
        }

        private static func deduplicated(_ values: [String]) -> [String] {
            var seen = Set<String>()
            var result: [String] = []
            for value in values where !seen.contains(value) {
                seen.insert(value)
                result.append(value)
            }
            return result
        }
    }

    enum App {
        /// 是否启用运行时日志。关闭后：
        /// 1. SharedLogger 不再打印控制台/不再写 App Group；
        /// 2. 主界面不展示日志区；
        /// 3. 远端 7777 调试镜像默认关闭；
        /// 4. 代码中的少量 NSLog/print 也会被短路。
        static let enableRuntimeLogging: Bool = false

        /// 是否记录并写入 App Group 的 SharedLogger 日志。
        /// 关闭后：不再写入/同步 UserDefaults，也不再输出到控制台。
        static let enableLogRecording: Bool = enableRuntimeLogging

        /// 主 App 是否展示日志列表与“清空日志”。
        static let enableLogDisplay: Bool = enableRuntimeLogging

        /// 主界面轻量诊断面板。默认开启，只展示 App Group / RTMP 连接状态，
        /// 不输出控制台、不写日志列表、不发 7777。
        static let enableDiagnosticsDisplay: Bool = true
    }

    enum DebugMirror {
        /// 是否把关键调试日志镜像到 7777 调试端口。
        /// 与 enableLogRecording 解耦，便于只开远端观测而不增加本地 UserDefaults 压力。
        static let enableRemoteMirror: Bool = App.enableRuntimeLogging
        static let endpoint = "http://10.89.114.217:7777/event"
        static let sessionId = "rtmp-audio-debug"
        static let runId = "audio-only-followup"
    }

    enum RTMP {
        static let userDefaultsKey = "rtmp.url"
        static let disableAudioPushKey = "rtmp.disableAudioPush"
        static let deepLinkStartCommandKey = "cmd_start_recording"
        static let deepLinkLastURLKey = "deeplink.lastURL"
        static let deepLinkLastErrorKey = "deeplink.lastError"
        // 占位默认值：真实推流地址请在 App 内或通过 deeplink 写入 App Group（rtmp.url）。
        static let defaultURL = "rtmp://YOUR_RTMP_HOST/live/YOUR_STREAM_KEY"
//        static let defaultURL = "rtmp://192.168.10.118:1935/live/livestream?token=secret123"
        static let defaultDisableAudioPush = false

        static var resolvedURL: String {
            let defaults = LiveStreamConfig.AppGroup.defaults()
            let overrideURL = defaults?.string(forKey: userDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let overrideURL, !overrideURL.isEmpty {
                return overrideURL
            }
            return defaultURL
        }

        static var isAudioPushDisabled: Bool {
            let defaults = LiveStreamConfig.AppGroup.defaults()
            guard let defaults else { return defaultDisableAudioPush }
            if defaults.object(forKey: disableAudioPushKey) == nil {
                return defaultDisableAudioPush
            }
            return defaults.bool(forKey: disableAudioPushKey)
        }

        static func isValidOverrideURL(_ raw: String) -> Bool {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let parsed = URL(string: trimmed),
                  let scheme = parsed.scheme?.lowercased(),
                  scheme == "rtmp",
                  parsed.host?.isEmpty == false else {
                return false
            }
            return true
        }
    }

    enum Video {
        struct Preset: Equatable {
            let id: String
            let title: String
            let width: Int32
            let height: Int32
            let fps: Int32
            let bitrate: Int
        }

        static let presetIDKey = "video.preset.id"
        static let widthKey = "video.width"
        static let heightKey = "video.height"
        static let fpsKey = "video.fps"
        static let bitrateKey = "video.bitrate"

        static let presets: [Preset] = [
            Preset(id: "low", title: "流畅优先", width: 360, height: 640, fps: 15, bitrate: 600_000),
            Preset(id: "balanced", title: "默认档", width: 480, height: 854, fps: 20, bitrate: 900_000),
            Preset(id: "high", title: "清晰优先", width: 540, height: 960, fps: 24, bitrate: 1_300_000)
        ]

        /// 关闭后不再先做 CoreImage 缩放，编码器直接使用首帧原始分辨率创建会话，用于排查缩放链路开销。
        static let enableScaling: Bool = true
        static let defaultPreset = presets[1]

        /// 输出分辨率。默认 480x854，允许通过 App Group 配置切换到预设档位。
        static var width: Int32 { currentPreset.width }
        static var height: Int32 { currentPreset.height }
        /// 目标帧率。默认 20fps，允许通过 App Group 配置切换到预设档位。
        static var fps: Int32 { currentPreset.fps }
        /// 视频平均码率。默认 900kbps，允许通过 App Group 配置切换到预设档位。
        static var bitrate: Int { currentPreset.bitrate }
        /// 关键帧间隔。2 秒一帧比 1 秒更省码率，同时对直播 seek/切片仍较友好。
        static var keyframeIntervalFrames: Int32 { fps * 2 }
        static var keyframeIntervalSeconds: Double { 2.0 }
        /// 捕获帧若明显快于目标帧率则丢弃，0.85 表示比目标间隔小 15% 以内的抖动直接吸收掉。
        static let minCaptureSpacingFactor: Double = 0.85
        static let gapCompensationTriggerFactor: Double = 1.75
        static let maxGapCompensationFrames: Int = 10

        static var currentPreset: Preset {
            let defaults = LiveStreamConfig.AppGroup.defaults(refresh: true)
            if let presetID = defaults?.string(forKey: presetIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let preset = presets.first(where: { $0.id == presetID }) {
                return preset
            }

            let customWidth = defaults?.integer(forKey: widthKey) ?? 0
            let customHeight = defaults?.integer(forKey: heightKey) ?? 0
            let customFPS = defaults?.integer(forKey: fpsKey) ?? 0
            let customBitrate = defaults?.integer(forKey: bitrateKey) ?? 0
            if customWidth > 0, customHeight > 0, customFPS > 0, customBitrate > 0 {
                return Preset(id: "custom",
                              title: "自定义",
                              width: Int32(customWidth),
                              height: Int32(customHeight),
                              fps: Int32(customFPS),
                              bitrate: customBitrate)
            }

            return defaultPreset
        }

        static func applyPreset(_ preset: Preset) {
            let defaultsList = LiveStreamConfig.AppGroup.availableDefaultsByGroupID(refresh: true)
            guard !defaultsList.isEmpty else { return }
            for (_, defaults) in defaultsList {
                defaults.set(preset.id, forKey: presetIDKey)
                defaults.set(Int(preset.width), forKey: widthKey)
                defaults.set(Int(preset.height), forKey: heightKey)
                defaults.set(Int(preset.fps), forKey: fpsKey)
                defaults.set(preset.bitrate, forKey: bitrateKey)
                defaults.synchronize()
            }
        }

        static func resetToDefaultPreset() {
            applyPreset(defaultPreset)
        }
    }

    enum Audio {
        /// AAC 码率。80kbps 在节省带宽和减少杂音之间更均衡；若后续仍觉得毛刺明显可继续升到 96kbps。
        static let bitrate: UInt32 = 80_000
        static let framesPerPacket: UInt32 = 1024
    }

    enum Mux {
        /// 音视频来自不同编码队列，RTMP 发包前需要保留一个足够大的重排窗口，
        /// 避免“较早的音频包稍晚到达”时已经把较新的包发出，导致服务端看到 DTS 回退。
        static let reorderWindowMs: UInt32 = 250
        static let maxPendingTagCount: Int = 24
    }
}
