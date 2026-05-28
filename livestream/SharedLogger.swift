import Foundation

// #region debug-point logger-mirror
private enum RTMPRuntimeDebugMirror {
    private static let lock = NSLock()
    private static var lastPostedAtByKey: [String: TimeInterval] = [:]
    private static let throttledPrefixes: [String: TimeInterval] = [
        "AudioSource 1s:": 0.8,
        "AudioQueue 1s:": 0.8,
        "RTMP AudioStats 1s:": 0.8,
        "RTMP Stats 1s:": 0.8,
        "VideoPerf 1s:": 0.8
    ]
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.0
        configuration.timeoutIntervalForResource = 1.0
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func post(message: String) {
        guard LiveStreamConfig.DebugMirror.enableRemoteMirror else { return }
        guard shouldMirror(message: message) else { return }
        guard shouldPostNow(message: message) else { return }
        guard let endpoint = URL(string: LiveStreamConfig.DebugMirror.endpoint) else { return }

        let payload: [String: Any] = [
            "sessionId": LiveStreamConfig.DebugMirror.sessionId,
            "runId": LiveStreamConfig.DebugMirror.runId,
            "location": "SharedLogger.log",
            "msg": message,
            "data": [
                "message": message
            ],
            "ts": Int(Date().timeIntervalSince1970 * 1000)
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        session.dataTask(with: request).resume()
    }

    private static func shouldMirror(message: String) -> Bool {
        if message.hasPrefix("AudioSource 1s:") { return true }
        if message.hasPrefix("AudioQueue 1s:") { return true }
        if message.hasPrefix("AAC ") { return true }
        if message.hasPrefix("Pipeline AudioSend") { return true }
        if message.hasPrefix("RTMP AudioSend entered") { return true }
        if message.hasPrefix("RTMP AudioSeq queued") { return true }
        if message.hasPrefix("RTMP AudioRaw queued") { return true }
        if message.hasPrefix("RTMP AudioPacket ") { return true }
        if message.hasPrefix("RTMP AudioStats 1s:") { return true }
        if message.hasPrefix("RTMP Stats 1s:") { return true }
        if message.hasPrefix("RTMPUploader start resolved") { return true }
        if message.hasPrefix("VideoPerf 1s:") { return true }
        if message.hasPrefix("Perf Video spike") { return true }
        if message.hasPrefix("RTMP 发包节点") {
            return message.contains("label=audio") || message.contains("label=audio-seq")
        }
        if message.hasPrefix("RTMP backlog 超阈值，丢弃音频包") { return true }
        if message.hasPrefix("libRTMP 发包失败") {
            return message.contains("label=audio") || message.contains("label=audio-seq")
        }
        if message.hasPrefix("RTMP 发包修正") {
            return message.contains("label=audio") || message.contains("label=audio-seq")
        }
        if message.hasPrefix("libRTMP 内部日志:") {
            return message.contains("SendPacket failed")
                || message.contains("ConnectStream failed")
                || message.contains("RTMP disconnected")
        }
        return false
    }

    private static func shouldPostNow(message: String) -> Bool {
        for (prefix, interval) in throttledPrefixes where message.hasPrefix(prefix) {
            let now = Date().timeIntervalSince1970
            return lock.withLock {
                let last = lastPostedAtByKey[prefix] ?? 0
                guard now - last >= interval else { return false }
                lastPostedAtByKey[prefix] = now
                return true
            }
        }
        return true
    }
}
// #endregion

struct SharedLogger {
    static let logKey = "diag.sharedLogs"
    
    static func log(_ message: String) {
        guard LiveStreamConfig.App.enableRuntimeLogging else { return }
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logLine = "[\(timestamp)] \(message)"

        // 打印到本地控制台
        print(logLine)
        RTMPRuntimeDebugMirror.post(message: message)

        guard LiveStreamConfig.App.enableLogRecording else { return }

        // 存入 App Group UserDefaults 给主 App 读
        guard let defaults = LiveStreamConfig.AppGroup.defaults() else { return }
        
        var logs = defaults.stringArray(forKey: logKey) ?? []
        logs.append(logLine)

        // 为了排查录屏结束前的完整链路日志，把保留数量从 50 提高到 200，
        // 避免「结束录屏后」看不到导致退出的关键几行日志。
        let maxLines = 200
        if logs.count > maxLines {
            logs.removeFirst(logs.count - maxLines)
        }
        
        defaults.set(logs, forKey: logKey)
        defaults.synchronize()
    }
    
    static func clear() {
        guard let defaults = LiveStreamConfig.AppGroup.defaults() else { return }
        defaults.removeObject(forKey: logKey); defaults.set([String](), forKey: logKey)
        SharedDiagnostics.clear()
        defaults.synchronize()
    }
    
    static func readLogs() -> [String] {
        guard let defaults = LiveStreamConfig.AppGroup.defaults() else { return [] }
        return defaults.stringArray(forKey: logKey) ?? []
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

struct SharedDiagnostics {
    private static let knownKeys: [String] = [
        "diag.h264.targetFps",
        "diag.h264.lastGapMs",
        "diag.h264.droppedDenseFrames",
        "diag.h264.resumeEvents",
        "diag.h264.lastUpdateTs",
        "diag.aac.firstEncodedAt",
        "diag.aac.outputFrameCount",
        "diag.aac.lastEncodeErrorCode",
        "diag.aac.lastEncodeErrorAt",
        "diag.pipeline.firstSendAudioAt",
        "diag.pipeline.sendAudioCount",
        "diag.pipeline.audioPushDisabled",
        "diag.rtmp.pendingTags",
        "diag.rtmp.droppedVideoTags",
        "diag.rtmp.reconnectAttempt",
        "diag.rtmp.isConnected",
        "diag.rtmp.sentPackets",
        "diag.rtmp.lastVideoTs",
        "diag.rtmp.lastAudioTs",
        "diag.rtmp.videoFramesPerSecond",
        "diag.rtmp.audioTagsPerSecond",
        "diag.rtmp.lastUpdateTs",
        "diag.rtmp.failedPacketLabel",
        "diag.rtmp.failedPacketType",
        "diag.rtmp.failedPacketTimestamp",
        "diag.rtmp.failedPacketBytes",
        "diag.rtmp.failedPacketConnected",
        "diag.rtmp.failedPacketChannelId",
        "diag.rtmp.failedPacketStreamId",
        "diag.rtmp.failedPacketAt",
        "diag.rtmp.failedPacketReconnectAttempt",
        "diag.rtmp.firstVideoPacketSentAt",
        "diag.rtmp.firstAudioPacketSentAt",
        "diag.rtmp.audioSequenceSentAt",
        "diag.rtmp.videoSequenceSentAt",
        "diag.rtmp.host",
        "diag.rtmp.app",
        "diag.rtmp.stream",
        "diag.rtmp.appGroup",
        "diag.rtmp.openState"
    ]

    static func update(_ values: [String: Any]) {
        guard let defaults = LiveStreamConfig.AppGroup.defaults() else { return }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        defaults.synchronize()
    }

    static func clear() {
        guard let defaults = LiveStreamConfig.AppGroup.defaults() else { return }
        for key in knownKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
    }
}
