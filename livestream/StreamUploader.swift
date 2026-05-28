import Foundation
import CoreMedia
import Network

private enum LiveStreamDarwinSignal {
    static let rtmpConnected = "com.xxx.livestream.broadcast.rtmpConnected"
    static let metadataSent = "com.xxx.livestream.broadcast.metadataSent"
    static let videoSequenceSent = "com.xxx.livestream.broadcast.videoSequenceSent"
    static let audioSequenceSent = "com.xxx.livestream.broadcast.audioSequenceSent"
    static let firstVideoPacketSent = "com.xxx.livestream.broadcast.firstVideoPacketSent"
    static let firstAudioPacketSent = "com.xxx.livestream.broadcast.firstAudioPacketSent"
    static let mediaPacketSendFailed = "com.xxx.livestream.broadcast.mediaPacketSendFailed"
    static let mediaPacketSendFailedMetadata = "com.xxx.livestream.broadcast.mediaPacketSendFailed.metadata"
    static let mediaPacketSendFailedMetadataUpdate = "com.xxx.livestream.broadcast.mediaPacketSendFailed.metadataUpdate"
    static let mediaPacketSendFailedVideoSequence = "com.xxx.livestream.broadcast.mediaPacketSendFailed.videoSequence"
    static let mediaPacketSendFailedAudioSequence = "com.xxx.livestream.broadcast.mediaPacketSendFailed.audioSequence"
    static let mediaPacketSendFailedVideoKey = "com.xxx.livestream.broadcast.mediaPacketSendFailed.videoKey"
    static let mediaPacketSendFailedVideo = "com.xxx.livestream.broadcast.mediaPacketSendFailed.video"
    static let mediaPacketSendFailedAudio = "com.xxx.livestream.broadcast.mediaPacketSendFailed.audio"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    static func postMediaPacketSendFailed(label: String) {
        post(mediaPacketSendFailed)
        switch label {
        case "metadata":
            post(mediaPacketSendFailedMetadata)
        case "metadata-update":
            post(mediaPacketSendFailedMetadataUpdate)
        case "video-seq":
            post(mediaPacketSendFailedVideoSequence)
        case "audio-seq":
            post(mediaPacketSendFailedAudioSequence)
        case "video-key":
            post(mediaPacketSendFailedVideoKey)
        case "video":
            post(mediaPacketSendFailedVideo)
        case "audio":
            post(mediaPacketSendFailedAudio)
        default:
            break
        }
    }
}

protocol StreamUploader: AnyObject {
    var onError: ((Error) -> Void)? { get set }
    func start()
    func stop()
    /// - Parameters:
    ///   - pts: 视频展示时间戳（Presentation Time Stamp）
    ///   - dts: 视频解码时间戳（Decode Time Stamp）。FLV tag timestamp 应使用 DTS；若为 nil/invalid 则回退到 PTS。
    ///   - width/height: 当前实际编码分辨率；关闭缩放时不能再假定等于配置分辨率。
    func sendVideo(data: Data, pts: CMTime, dts: CMTime?, isKeyframe: Bool, sps: Data?, pps: Data?, width: Int32, height: Int32)
    func sendAudio(data: Data, pts: CMTime, audioSpecificConfig: Data?)
}

/// RTMP 推流（H.264/AAC -> FLV over RTMP）
final class RTMPUploader: StreamUploader {
    var onError: ((Error) -> Void)?
    var onAudioStats: ((Int, UInt32) -> Void)?
    private let queue = DispatchQueue(label: "rtmp.uploader.queue")
    private var session: LibRTMPSession?

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let resolvedURL = LiveStreamConfig.RTMP.resolvedURL
            // [URLResolve] 关键诊断：确认扩展是否能从 App Group 读到主 App 配置的推流地址。
            // 若 containerOK=0 或 override=0，则说明 App Group 共享在该系统上失效，扩展只能回退到内置默认 URL，
            // 这正是 iOS15“日志黑框为空 + RTMP 永远连不上”的同源根因。
            if LiveStreamConfig.App.enableRuntimeLogging {
                let groupID = LiveStreamConfig.AppGroup.currentID()
                let containerOK = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil
                let fileOverride = LiveStreamConfig.SharedFileStore.string(forKey: LiveStreamConfig.RTMP.userDefaultsKey) != nil
                let defaultsRaw = LiveStreamConfig.AppGroup.defaults()?.string(forKey: LiveStreamConfig.RTMP.userDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let defaultsOverride = (defaultsRaw?.isEmpty == false)
                let resolvedHost = RTMPURL.parse(resolvedURL)?.host ?? "-"
                NSLog("[Suspect][URLResolve] group=%@ containerOK=%d fileOverride=%d defaultsOverride=%d host=%@", groupID, containerOK ? 1 : 0, fileOverride ? 1 : 0, defaultsOverride ? 1 : 0, resolvedHost)
            }
            if let parsed = RTMPURL.parse(resolvedURL) {
                SharedDiagnostics.update([
                    "diag.rtmp.host": parsed.host,
                    "diag.rtmp.app": parsed.app,
                    "diag.rtmp.stream": parsed.stream,
                    "diag.rtmp.appGroup": LiveStreamConfig.AppGroup.currentID(),
                    "diag.rtmp.openState": "prepared"
                ])
                SharedLogger.log("RTMPUploader start resolved host=\(parsed.host) port=\(parsed.port) app=\(parsed.app) stream=\(parsed.stream) hasQuery=\((parsed.query?.isEmpty == false) ? 1 : 0) appGroup=\(LiveStreamConfig.AppGroup.currentID())")
            } else {
                SharedDiagnostics.update([
                    "diag.rtmp.host": "-",
                    "diag.rtmp.app": "-",
                    "diag.rtmp.stream": "-",
                    "diag.rtmp.appGroup": LiveStreamConfig.AppGroup.currentID(),
                    "diag.rtmp.openState": "parse_failed"
                ])
                SharedLogger.log("RTMPUploader start resolved parse_failed appGroup=\(LiveStreamConfig.AppGroup.currentID())")
            }
            self.session = LibRTMPSession(url: resolvedURL, queue: self.queue)
            self.session?.onError = { [weak self] error in
                self?.onError?(error)
            }
            self.session?.onAudioStats = { [weak self] count, lastTs in
                self?.onAudioStats?(count, lastTs)
            }
            self.session?.start()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.session?.stop()
            self?.session = nil
        }
    }

    func sendVideo(data: Data, pts: CMTime, dts: CMTime?, isKeyframe: Bool, sps: Data?, pps: Data?, width: Int32, height: Int32) {
        queue.async { [weak self] in
            self?.session?.sendVideo(data: data, pts: pts, dts: dts, isKeyframe: isKeyframe, sps: sps, pps: pps, width: width, height: height)
        }
    }

    func sendAudio(data: Data, pts: CMTime, audioSpecificConfig: Data?) {
        queue.async { [weak self] in
            self?.session?.sendAudio(data: data, pts: pts, audioSpecificConfig: audioSpecificConfig)
        }
    }
}

// MARK: - librtmp log throttling

/// librtmp 的日志回调必须是非捕获闭包（C function pointer），因此这里用一个全局限流器。
/// 当前工程只存在单路推流，用静态状态即可。
private enum LibRTMPLogThrottler {
    private static let lock = DispatchQueue(label: "librtmp.log.throttle")
    private static var lastOtherMs: UInt64 = 0

    static func reset() {
        lock.sync {
            lastOtherMs = 0
        }
    }

    static func onLog(_ cString: UnsafePointer<CChar>?) {
        guard let cString = cString else { return }
        let msg = String(cString: cString)
        // librtmp 内部已被设为 LOGWARNING 级别，量不大；直接 NSLog 到 Console，
        // 用于看清服务端为何关闭连接（发包失败/握手错误/被踢等），iOS15 日志黑框失效时尤其需要。
        if LiveStreamConfig.App.enableRuntimeLogging {
            NSLog("[Suspect][librtmp] %@", msg)
        }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        var toPrint: String?
        lock.sync {
            if nowMs &- lastOtherMs >= 500 {
                lastOtherMs = nowMs
                toPrint = "libRTMP 内部日志: \(msg)"
            }
        }

        if let line = toPrint {
            SharedLogger.log(line)
        }
    }
}

/// C 回调必须是“顶层 func”或字面量闭包。
private func LibRTMPLogCallback(_ cString: UnsafePointer<CChar>?) {
    LibRTMPLogThrottler.onLog(cString)
}

private struct PendingMediaPacket {
    let timestamp: UInt32
    let order: Int
    let sequence: UInt64
    let packetType: UInt8
    let channelId: UInt32
    let payload: Data
    let logLabel: String
}

private final class LibRTMPSession {
    var onError: ((Error) -> Void)?
    var onAudioStats: ((Int, UInt32) -> Void)?
    private let queue: DispatchQueue
    private let connectQueue = DispatchQueue(label: "rtmp.connect.queue")
    private let url: RTMPURL

    private var bridgeSession: UnsafeMutableRawPointer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt: Int = 0
    private var didStart = false
    private var isOpening = false
    private var loggedWaitingForConnection = false
    private let reconnectBaseDelay: TimeInterval = 0.5
    private let reconnectMaxDelay: TimeInterval = 2.0

    private let tsNormalizer = TimestampNormalizer()
    private var sentMetaData = false
    private var sentAudioConfig = false
    private var sentVideoConfig = false
    private var audioConfig: AACConfig?
    private var currentVideoWidth: Int32 = LiveStreamConfig.Video.width
    private var currentVideoHeight: Int32 = LiveStreamConfig.Video.height
    private var publishedMetaWidth: Int32 = 0
    private var publishedMetaHeight: Int32 = 0
    private var lastAudioSpecificConfig: Data?
    private var lastVideoSPS: Data?
    private var lastVideoPPS: Data?
    private var lastSentVideoConfigSPS: Data?
    private var lastSentVideoConfigPPS: Data?
    private var lastSentVideoConfigMs: UInt32 = 0
    private var videoConfigLogCount: Int = 0
    private var sentPacketCount = 0
    private var pendingTags: [PendingMediaPacket] = []
    private var pendingSequence: UInt64 = 0
    private var maxQueuedTimestamp: UInt32 = 0
    private var lastQueuedTimestampByPacketType: [UInt8: UInt32] = [:]
    private var lastSentTimestampByChannel: [UInt32: UInt32] = [:]
    private var lastSentGlobalTimestamp: UInt32 = 0
    private var adjustedTimestampLogCount: Int = 0
    private var droppedRealtimeVideoTags: Int = 0
    private var sentVideoTagCount = 0
    private var lastVideoLogMs: UInt32 = 0
    private var lastDiagnosticsFlushTime: CFAbsoluteTime = 0
    private let reorderWindowMs: UInt32 = LiveStreamConfig.Mux.reorderWindowMs
    private let maxPendingTagCount: Int = LiveStreamConfig.Mux.maxPendingTagCount
    private var connectedAtWallClock: CFAbsoluteTime = 0

    // 每秒固定汇总日志：只变化计数
    private var statWindowStartMs: UInt32 = 0
    private var statVideoFrames: Int = 0
    private var statVideoKeyFrames: Int = 0
    private var statAudioTags: Int = 0
    private var statLastVideoTs: UInt32 = 0
    private var statLastAudioTs: UInt32 = 0
    private var statLastCTS: Int32 = 0
    private var statPublishedVideoFrames: Int = 0
    private var statPublishedAudioTags: Int = 0
    private var statPublishedLastVideoTs: UInt32 = 0
    private var statPublishedLastAudioTs: UInt32 = 0
    private var audioOnlyStatWindowStartWallClock: CFAbsoluteTime = 0
    private var audioOnlyStatTags: Int = 0
    private var audioOnlyStatLastTs: UInt32 = 0
    private var lastPublishedConnected = false
    private var metadataSignalSent = false
    private var videoSequenceSignalSent = false
    private var audioSequenceSignalSent = false
    private var firstVideoPacketSignalSent = false
    private var firstAudioPacketSignalSent = false
    private var failedPacketLabel: String = ""
    private var failedPacketType: UInt8 = 0
    private var failedPacketTimestamp: UInt32 = 0
    private var failedPacketBytes: Int = 0
    private var failedPacketConnected = false
    private var failedPacketChannelId: UInt32 = 0
    private var failedPacketStreamId: Int32 = 0
    private var failedPacketAt: Double = 0
    private var failedPacketReconnectAttempt: Int = 0
    private var firstVideoPacketSentAt: Double = 0
    private var firstAudioPacketSentAt: Double = 0
    private var audioSequenceSentAt: Double = 0
    private var videoSequenceSentAt: Double = 0
    private var debugVideoAttemptCount: Int = 0
    private var debugVideoFlushCount: Int = 0
    private var debugMediaAttemptCount: Int = 0
    private var audioSendDetailLogCount: Int = 0
    private var audioQueueDetailLogCount: Int = 0
    private var audioPacketResultLogCount: Int = 0
    private var audioBacklogDropCount: Int = 0
    private var latestSentVideoPacketTs: UInt32 = 0
    private var latestSentAudioPacketTs: UInt32 = 0
    private var latestAVDeltaMs: Int32 = 0
    private var videoSendRhythmWindowStartWallClock: CFAbsoluteTime = 0
    private var videoSendRhythmCount: Int = 0
    private var videoSendRhythmTotalGapMs: Double = 0
    private var videoSendRhythmMaxGapMs: Double = 0
    private var videoSendRhythmSlowGapCount: Int = 0
    private var lastVideoSendWallClock: CFAbsoluteTime = 0
    private var lastVideoSendGapMs: Double = 0
    private var firstVideoSendWallClock: CFAbsoluteTime = 0
    private var firstVideoSendTimestamp: UInt32 = 0
    private var latestVideoTimelineDriftMs: Int32 = 0
    private var statWindowStartWallClock: CFAbsoluteTime = 0

    // librtmp 内部日志限流：见 LibRTMPLogThrottler

    init(url: String, queue: DispatchQueue) {
        self.queue = queue
        self.url = RTMPURL.parse(url) ?? RTMPURL(host: "127.0.0.1", port: 1935, app: "live", stream: "stream", query: nil)
    }

    func start() {
        didStart = true
        reconnectAttempt = 0
        droppedRealtimeVideoTags = 0
        lastDiagnosticsFlushTime = 0
        lastPublishedConnected = false
        metadataSignalSent = false
        videoSequenceSignalSent = false
        audioSequenceSignalSent = false
        firstVideoPacketSignalSent = false
        firstAudioPacketSignalSent = false
        failedPacketLabel = ""
        failedPacketType = 0
        failedPacketTimestamp = 0
        failedPacketBytes = 0
        failedPacketConnected = false
        failedPacketChannelId = 0
        failedPacketStreamId = 0
        failedPacketAt = 0
        failedPacketReconnectAttempt = 0
        firstVideoPacketSentAt = 0
        firstAudioPacketSentAt = 0
        audioSequenceSentAt = 0
        videoSequenceSentAt = 0
        debugMediaAttemptCount = 0
        audioSendDetailLogCount = 0
        audioQueueDetailLogCount = 0
        audioPacketResultLogCount = 0
        audioBacklogDropCount = 0
        latestSentVideoPacketTs = 0
        latestSentAudioPacketTs = 0
        latestAVDeltaMs = 0
        videoSendRhythmWindowStartWallClock = 0
        videoSendRhythmCount = 0
        videoSendRhythmTotalGapMs = 0
        videoSendRhythmMaxGapMs = 0
        videoSendRhythmSlowGapCount = 0
        lastVideoSendWallClock = 0
        lastVideoSendGapMs = 0
        firstVideoSendWallClock = 0
        firstVideoSendTimestamp = 0
        latestVideoTimelineDriftMs = 0
        statWindowStartWallClock = 0
        audioOnlyStatWindowStartWallClock = 0
        audioOnlyStatTags = 0
        audioOnlyStatLastTs = 0
        currentVideoWidth = LiveStreamConfig.Video.width
        currentVideoHeight = LiveStreamConfig.Video.height
        publishedMetaWidth = 0
        publishedMetaHeight = 0
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        publishDiagnostics(force: true)
        SharedLogger.log("libRTMP 会话已准备，开始预连接以降低首帧推流延迟")
        startOpenIfNeeded(trigger: "启动")
    }

    func stop() {
        didStart = false
        droppedRealtimeVideoTags = 0
        debugMediaAttemptCount = 0
        audioSendDetailLogCount = 0
        audioQueueDetailLogCount = 0
        audioPacketResultLogCount = 0
        audioBacklogDropCount = 0
        lastPublishedConnected = false
        metadataSignalSent = false
        videoSequenceSignalSent = false
        audioSequenceSignalSent = false
        firstVideoPacketSignalSent = false
        firstAudioPacketSignalSent = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        _ = flushPendingTags(force: true)
        destroyBridge(resetTransportState: true, resetTimelineState: true)
        publishDiagnostics(force: true)
    }

    func sendVideo(data: Data, pts: CMTime, dts: CMTime?, isKeyframe: Bool, sps: Data?, pps: Data?, width: Int32, height: Int32) {
        guard didStart else { return }
        if width > 0, height > 0 {
            currentVideoWidth = width
            currentVideoHeight = height
        }
        if let sps {
            lastVideoSPS = sps
        }
        if let pps {
            lastVideoPPS = pps
        }

        _ = ensureConnected()

        let videoDTS = (dts?.isNumeric == true) ? dts! : pts
        let timestamp = tsNormalizer.timestamp(for: videoDTS, kind: .video)

        let nals = RTMPFLV.splitAnnexB(data)
        // 以 NAL 类型兜底关键帧判断，避免上游 attachments/isKeyframe 不稳定导致服务端一直等不到 keyframe。
        let nalTypes = nals.compactMap { $0.first }.map { $0 & 0x1F }
        let hasIDR = nalTypes.contains(5)
        let key = isKeyframe || hasIDR

        ensureMetaDataSent(timestamp: timestamp, videoWidth: currentVideoWidth, videoHeight: currentVideoHeight)

        if let sps = lastVideoSPS, let pps = lastVideoPPS {
            let wasSent = sentVideoConfig
            let changed = (lastSentVideoConfigSPS != sps) || (lastSentVideoConfigPPS != pps)
            // 在首包 / 参数集变化 / 关键帧前周期性补发 AVCDecoderConfigurationRecord。
            // 相比把 SPS/PPS 混入 AVC NALU 包体，关键帧前补发 sequence header 更符合 FLV/RTMP 约定，
            // 对 SRS 的 HLS/RTC bridge 也更友好。
            let periodic = key && (timestamp &- lastSentVideoConfigMs >= 1900)
            if !wasSent || changed || periodic {
                let config = RTMPVideoConfig(sps: sps, pps: pps)
                let payload = RTMPFLV.makeVideoSequenceHeader(config: config)
                // SequenceHeader 的 timestamp 也必须单调递增，避免落在音频之后导致服务端认为“时间回退”。
                guard enqueueMediaPacket(packetType: 0x09, channelId: 4, timestamp: timestamp, payload: payload, logLabel: "video-seq") else { return }
                sentVideoConfig = true
                lastSentVideoConfigSPS = sps
                lastSentVideoConfigPPS = pps
                lastSentVideoConfigMs = timestamp

                // 关键帧时单独打一条，便于和服务端切片对齐
                if key {
                    SharedLogger.log("RTMP VideoSequenceHeader ts=\(timestamp) beforeKey=1 sps=\(sps.count) pps=\(pps.count)")
                }

                if videoConfigLogCount < 6 {
                    videoConfigLogCount += 1
                    let reason = !wasSent ? "first" : (changed ? "changed" : "periodic-keyframe")
                    SharedLogger.log("RTMP VideoSequenceHeader sent reason=\(reason) ts=\(timestamp) sps=\(sps.count) pps=\(pps.count)")
                    // 码流字节对比：用于直接比对 iOS15 与 iOS16 的 SPS/PPS/AVCDecoderConfigRecord。
                    // payload 前 5 字节是 FLV 视频头(0x17,0x00,0,0,0)，其余即 AVCDecoderConfigRecord。
                    SharedLogger.log("RTMP SPS hex=\(sps.prefixHex(64))")
                    SharedLogger.log("RTMP PPS hex=\(pps.prefixHex(32))")
                    SharedLogger.log("RTMP AVCConfig hex=\(payload.prefixHex(80))")
                    // 同步 NSLog 到 Console，便于 iOS15/iOS16 字节级对比（SharedLogger 的 print 不进 Console）。
                    if LiveStreamConfig.App.enableRuntimeLogging {
                        NSLog("[Suspect][SPS] reason=%@ sps=%@ pps=%@ avc=%@", reason, sps.prefixHex(64), pps.prefixHex(32), payload.prefixHex(80))
                    }
                }
            }
        }

        let ctsMs = RTMPFLV.compositionTimeMs(pts: pts, dts: videoDTS)
        let payload = RTMPFLV.makeVideoNALU(nals: nals, isKeyframe: key, compositionTimeMs: ctsMs)
        _ = enqueueMediaPacket(packetType: 0x09, channelId: 4, timestamp: timestamp, payload: payload, logLabel: key ? "video-key" : "video")

        // 统计
        statVideoFrames += 1
        if key { statVideoKeyFrames += 1 }
        statLastVideoTs = timestamp
        statLastCTS = ctsMs

        // 关键帧日志（保留）
        if key {
            SharedLogger.log("RTMP VideoTag ts=\(timestamp) key=1 cts=\(ctsMs) size=\(payload.count) nals=\(Set(nalTypes).sorted())")
        }

        // 每秒固定汇总日志（避免刷屏）
        if statWindowStartMs == 0 { statWindowStartMs = timestamp }
        if statWindowStartWallClock == 0 { statWindowStartWallClock = CFAbsoluteTimeGetCurrent() }
        if timestamp &- statWindowStartMs >= 1000 {
            SharedLogger.log("RTMP Stats 1s: v=\(statVideoFrames) key=\(statVideoKeyFrames) a=\(statAudioTags) vts=\(statLastVideoTs) ats=\(statLastAudioTs) cts=\(statLastCTS)")
            if LiveStreamConfig.App.enableRuntimeLogging {
                NSLog("[Suspect][RTMP] v=%d key=%d a=%d pending=%d dropped=%d reconnect=%d sent=%d connected=%d vts=%u ats=%u cts=%d",
                      statVideoFrames,
                      statVideoKeyFrames,
                      statAudioTags,
                      pendingTags.count,
                      droppedRealtimeVideoTags,
                      reconnectAttempt,
                      sentPacketCount,
                      bridgeSession.map { LibRTMPSessionIsConnected($0) } ?? false,
                      statLastVideoTs,
                      statLastAudioTs,
                      statLastCTS)
            }
            statPublishedVideoFrames = statVideoFrames
            statPublishedAudioTags = statAudioTags
            statPublishedLastVideoTs = statLastVideoTs
            statPublishedLastAudioTs = statLastAudioTs
            onAudioStats?(statAudioTags, statLastAudioTs)
            publishDiagnostics(force: true)
            statWindowStartMs = timestamp
            statWindowStartWallClock = CFAbsoluteTimeGetCurrent()
            statVideoFrames = 0
            statVideoKeyFrames = 0
            statAudioTags = 0
        }
        publishDiagnosticsIfNeeded()
    }

    func sendAudio(data: Data, pts: CMTime, audioSpecificConfig: Data?) {
        guard didStart else { return }
        if let asc = audioSpecificConfig {
            lastAudioSpecificConfig = asc
            audioConfig = AACConfig.parse(asc: asc)
        }

        _ = ensureConnected()

        let timestamp = tsNormalizer.timestamp(for: pts, kind: .audio)
        audioSendDetailLogCount += 1
        if audioSendDetailLogCount <= 12 || audioSendDetailLogCount % 50 == 0 {
            let connected = bridgeSession.map { LibRTMPSessionIsConnected($0) } ?? false
            SharedLogger.log("RTMP AudioSend entered idx=\(audioSendDetailLogCount) pts=\(pts.debugText) ts=\(timestamp) bytes=\(data.count) asc=\(lastAudioSpecificConfig?.count ?? 0) connected=\(connected ? 1 : 0) pending=\(pendingTags.count)")
        }
        if !sentAudioConfig, let asc = lastAudioSpecificConfig {
            let payload = RTMPFLV.makeAudioSequenceHeader(asc: asc, config: audioConfig)
            // 同 video：AudioSequenceHeader 也用当前 timestamp，确保整体时间不回退。
            guard enqueueMediaPacket(packetType: 0x08, channelId: 5, timestamp: timestamp, payload: payload, logLabel: "audio-seq") else { return }
            sentAudioConfig = true
            audioQueueDetailLogCount += 1
            if audioQueueDetailLogCount <= 12 || audioQueueDetailLogCount % 50 == 0 {
                SharedLogger.log("RTMP AudioSeq queued idx=\(audioQueueDetailLogCount) ts=\(timestamp) bytes=\(payload.count) asc=\(asc.count) pending=\(pendingTags.count)")
            }
        }

        let payload = RTMPFLV.makeAudioRaw(data: data, config: audioConfig)
        _ = enqueueMediaPacket(packetType: 0x08, channelId: 5, timestamp: timestamp, payload: payload, logLabel: "audio")
        audioQueueDetailLogCount += 1
        if audioQueueDetailLogCount <= 12 || audioQueueDetailLogCount % 50 == 0 {
            SharedLogger.log("RTMP AudioRaw queued idx=\(audioQueueDetailLogCount) ts=\(timestamp) bytes=\(payload.count) pending=\(pendingTags.count)")
        }

        statAudioTags += 1
        statLastAudioTs = timestamp
        recordAudioStat(timestamp: timestamp)
        publishDiagnosticsIfNeeded()
    }

    @discardableResult
    private func connectIfNeeded() -> Bool {
        if let bridgeSession, LibRTMPSessionIsConnected(bridgeSession) {
            return true
        }
        if bridgeSession != nil {
            handleDisconnect(reason: "libRTMP 检测到连接已断开")
            return false
        }
        if reconnectWorkItem != nil {
            logWaitingForConnectionOnce()
            return false
        }
        startOpenIfNeeded(trigger: reconnectAttempt > 0 ? "重连" : "首包")
        return false
    }

    private func ensureConnected() -> Bool {
        guard connectIfNeeded() else { return false }
        loggedWaitingForConnection = false
        return true
    }

    private func startOpenIfNeeded(trigger: String) {
        guard didStart else { return }
        guard bridgeSession == nil else { return }
        guard !isOpening else {
            logWaitingForConnectionOnce()
            return
        }

        isOpening = true
        logWaitingForConnectionOnce()

        let playpath = url.playpath
        let tcUrl = url.tcUrl
        let app = url.app

        SharedLogger.log("libRTMP 收到\(trigger)，异步开始建连")
        SharedLogger.log("libRTMP 开始连接: host=\(url.host) port=\(url.port) app=\(app) playpath=\(playpath) tcUrl=\(tcUrl)")
        SharedDiagnostics.update([
            "diag.rtmp.host": url.host,
            "diag.rtmp.app": app,
            "diag.rtmp.stream": url.stream,
            "diag.rtmp.appGroup": LiveStreamConfig.AppGroup.currentID(),
            "diag.rtmp.openState": "opening"
        ])

        connectQueue.async { [weak self] in
            guard let self else { return }

            guard let bridge = Self.makeBridgeSession(host: self.url.host, port: self.url.port, app: app, playpath: playpath, tcUrl: tcUrl) else {
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.isOpening = false
                    SharedDiagnostics.update(["diag.rtmp.openState": "init_failed"])
                    self.scheduleReconnect(reason: "libRTMP 初始化失败")
                }
                return
            }

            let opened = LibRTMPSessionOpen(bridge, LibRTMPLogCallback)
            self.queue.async { [weak self] in
                guard let self else {
                    LibRTMPSessionDestroy(bridge)
                    return
                }

                self.isOpening = false
                
                if opened {
                    self.reconnectWorkItem?.cancel()
                    self.reconnectWorkItem = nil
                    self.reconnectAttempt = 0
                    // 等待分配 bridgeSession 完成后再发包
                    self.bridgeSession = bridge
                    self.connectedAtWallClock = CFAbsoluteTimeGetCurrent()
                    self.loggedWaitingForConnection = false
                    SharedLogger.log("libRTMP 连接成功")
                    SharedDiagnostics.update(["diag.rtmp.openState": "connected"])
                    if !self.pendingTags.isEmpty {
                        SharedLogger.log("libRTMP 连接成功后立即冲刷积压队列 pending=\(self.pendingTags.count)")
                    }
                    _ = self.flushPendingTags(force: true)
                } else {
                    LibRTMPSessionDestroy(bridge)
                    SharedDiagnostics.update(["diag.rtmp.openState": "open_failed"])
                    self.scheduleReconnect(reason: "libRTMP 连接失败或超时")
                }
                
                guard self.didStart else {
                    self.destroyBridge(resetTransportState: true, resetTimelineState: true)
                    return
                }
            }
        }
    }

    private func logWaitingForConnectionOnce() {
        guard !loggedWaitingForConnection else { return }
        loggedWaitingForConnection = true
        SharedLogger.log("libRTMP 尚未连接，当前帧先跳过")
    }

    private func handleDisconnect(reason: String) {
        if LiveStreamConfig.App.enableRuntimeLogging {
            let connected = bridgeSession.map { LibRTMPSessionIsConnected($0) } ?? false
            NSLog("[Suspect][Disconnect] %@", "reason=\(reason) failedLabel=\(failedPacketLabel) failedType=\(failedPacketType) failedTs=\(failedPacketTimestamp) bytes=\(failedPacketBytes) sent=\(sentPacketCount) connectedNow=\(connected ? 1 : 0)")
        }
        destroyBridge(resetTransportState: true, resetTimelineState: false)
        scheduleReconnect(reason: reason)
    }

    private func scheduleReconnect(reason: String) {
        guard didStart else { return }
        guard reconnectWorkItem == nil else { return }

        reconnectAttempt += 1
        let delay = min(reconnectBaseDelay * pow(2.0, Double(max(0, reconnectAttempt - 1))), reconnectMaxDelay)
        SharedLogger.log("\(reason)，将在\(String(format: "%.1f", delay))秒后发起第\(reconnectAttempt)次重连")
        publishDiagnostics(force: true)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.loggedWaitingForConnection = false
            self.startOpenIfNeeded(trigger: "重连#\(self.reconnectAttempt)")
        }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func destroyBridge(resetTransportState: Bool, resetTimelineState: Bool) {
        if let bridgeSession {
            LibRTMPSessionDestroy(bridgeSession)
            self.bridgeSession = nil
        }
        if resetTransportState {
            sentMetaData = false
            sentAudioConfig = false
            sentVideoConfig = false
            lastSentVideoConfigSPS = nil
            lastSentVideoConfigPPS = nil
            lastSentVideoConfigMs = 0
            videoConfigLogCount = 0
            publishedMetaWidth = 0
            publishedMetaHeight = 0
            pendingTags.removeAll(keepingCapacity: true)
            pendingSequence = 0
            maxQueuedTimestamp = 0
            lastQueuedTimestampByPacketType.removeAll(keepingCapacity: true)
            adjustedTimestampLogCount = 0
            LibRTMPLogThrottler.reset()

            statWindowStartMs = 0
            statVideoFrames = 0
            statVideoKeyFrames = 0
            statAudioTags = 0
            statLastVideoTs = 0
            statLastAudioTs = 0
            statLastCTS = 0
            statPublishedVideoFrames = 0
            statPublishedAudioTags = 0
            statPublishedLastVideoTs = 0
            statPublishedLastAudioTs = 0
            metadataSignalSent = false
            videoSequenceSignalSent = false
            audioSequenceSignalSent = false
            firstVideoPacketSignalSent = false
            firstAudioPacketSignalSent = false
            failedPacketLabel = ""
            failedPacketType = 0
            failedPacketTimestamp = 0
            failedPacketBytes = 0
            failedPacketConnected = false
            failedPacketChannelId = 0
            failedPacketStreamId = 0
            failedPacketAt = 0
            failedPacketReconnectAttempt = 0
            firstVideoPacketSentAt = 0
            firstAudioPacketSentAt = 0
            audioSequenceSentAt = 0
            videoSequenceSentAt = 0
            latestSentVideoPacketTs = 0
            latestSentAudioPacketTs = 0
            latestAVDeltaMs = 0
            videoSendRhythmWindowStartWallClock = 0
            videoSendRhythmCount = 0
            videoSendRhythmTotalGapMs = 0
            videoSendRhythmMaxGapMs = 0
            videoSendRhythmSlowGapCount = 0
            lastVideoSendWallClock = 0
            lastVideoSendGapMs = 0
            firstVideoSendWallClock = 0
            firstVideoSendTimestamp = 0
            latestVideoTimelineDriftMs = 0
            statWindowStartWallClock = 0
            audioOnlyStatWindowStartWallClock = 0
            audioOnlyStatTags = 0
            audioOnlyStatLastTs = 0
            connectedAtWallClock = 0
        }
        if resetTimelineState {
            tsNormalizer.reset()
            lastSentTimestampByChannel.removeAll(keepingCapacity: true)
            lastSentGlobalTimestamp = 0
        }
        publishDiagnostics(force: true)
    }

    private func sendRTMPPacket(packetType: UInt8, channelId: UInt32, timestamp: UInt32, payload: Data, logLabel: String) -> Bool {
        guard let bridgeSession else { return false }
        let isVideoPath = logLabel == "video" || logLabel == "video-key"
        let isAudioPath = logLabel == "audio" || logLabel == "audio-seq"
        debugMediaAttemptCount += 1
        let connectedBefore = LibRTMPSessionIsConnected(bridgeSession)
        let streamIdBefore = LibRTMPSessionGetStreamId(bridgeSession)
        let shouldLogMediaNode = debugMediaAttemptCount <= 12
            || (isVideoPath && debugMediaAttemptCount % 30 == 0)
            || (isAudioPath && debugMediaAttemptCount % 60 == 0)
        if shouldLogMediaNode {
            SharedLogger.log("RTMP 发包节点 attempt idx=\(debugMediaAttemptCount) label=\(logLabel) type=\(packetType) channel=\(channelId) ts=\(timestamp) bytes=\(payload.count) connected=\(connectedBefore ? 1 : 0) stream=\(streamIdBefore) pending=\(pendingTags.count)")
        }
        if isVideoPath {
            debugVideoAttemptCount += 1
        }
        let result = payload.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            return LibRTMPSessionSendPacket(bridgeSession, packetType, timestamp, channelId, baseAddress, Int32(payload.count))
        }
        if !result {
            let connected = LibRTMPSessionIsConnected(bridgeSession)
            failedPacketLabel = logLabel
            failedPacketType = packetType
            failedPacketTimestamp = timestamp
            failedPacketBytes = payload.count
            failedPacketConnected = connected
            failedPacketChannelId = channelId
            failedPacketStreamId = LibRTMPSessionGetStreamId(bridgeSession)
            failedPacketAt = Date().timeIntervalSince1970
            failedPacketReconnectAttempt = reconnectAttempt
            if isAudioPath {
                audioPacketResultLogCount += 1
                SharedLogger.log("RTMP AudioPacket failed idx=\(audioPacketResultLogCount) label=\(logLabel) ts=\(timestamp) bytes=\(payload.count) connected=\(connected ? 1 : 0) stream=\(failedPacketStreamId) pending=\(pendingTags.count)")
            }
            SharedLogger.log("RTMP 发包节点 failed idx=\(debugMediaAttemptCount) label=\(logLabel) type=\(packetType) channel=\(channelId) ts=\(timestamp) bytes=\(payload.count) connected=\(connected ? 1 : 0) stream=\(failedPacketStreamId) pending=\(pendingTags.count)")
            SharedLogger.log("libRTMP 发包失败，准备断开，label=\(logLabel) type=\(packetType) ts=\(timestamp) bytes=\(payload.count) connected=\(connected)")
            LiveStreamDarwinSignal.postMediaPacketSendFailed(label: logLabel)
            handleDisconnect(reason: "libRTMP 发包失败")
        } else {
            sentPacketCount += 1
            if logLabel == "video" || logLabel == "video-key" {
                recordVideoSendSuccess(timestamp: timestamp)
            } else if logLabel == "audio" {
                latestSentAudioPacketTs = timestamp
                updateLatestAVDelta()
            }
            if isAudioPath {
                audioPacketResultLogCount += 1
                if audioPacketResultLogCount <= 12 || audioPacketResultLogCount % 50 == 0 {
                    SharedLogger.log("RTMP AudioPacket sent idx=\(audioPacketResultLogCount) label=\(logLabel) ts=\(timestamp) bytes=\(payload.count) sent=\(sentPacketCount) pending=\(pendingTags.count)")
                }
            }
            if shouldLogMediaNode {
                SharedLogger.log("RTMP 发包节点 success idx=\(debugMediaAttemptCount) label=\(logLabel) type=\(packetType) channel=\(channelId) ts=\(timestamp) bytes=\(payload.count) sent=\(sentPacketCount) pending=\(pendingTags.count)")
            }
            if !metadataSignalSent && (logLabel == "metadata" || logLabel == "metadata-update") {
                metadataSignalSent = true
                LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.metadataSent)
            }
            if !videoSequenceSignalSent && logLabel == "video-seq" {
                videoSequenceSignalSent = true
                videoSequenceSentAt = Date().timeIntervalSince1970
                LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.videoSequenceSent)
            }
            if !audioSequenceSignalSent && logLabel == "audio-seq" {
                audioSequenceSignalSent = true
                audioSequenceSentAt = Date().timeIntervalSince1970
                LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.audioSequenceSent)
            }
            if !firstVideoPacketSignalSent && (logLabel == "video" || logLabel == "video-key") {
                firstVideoPacketSignalSent = true
                firstVideoPacketSentAt = Date().timeIntervalSince1970
                LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.firstVideoPacketSent)
            }
            if !firstAudioPacketSignalSent && logLabel == "audio" {
                firstAudioPacketSignalSent = true
                firstAudioPacketSentAt = Date().timeIntervalSince1970
                LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.firstAudioPacketSent)
            }
            if sentPacketCount % 300 == 0 {
                SharedLogger.log("libRTMP 正在发送，已成功累计 \(sentPacketCount) 次发包")
            }
        }
        publishDiagnosticsIfNeeded()
        return result
    }

    private func enqueueMediaPacket(packetType: UInt8, channelId: UInt32, timestamp: UInt32, payload: Data, logLabel: String) -> Bool {
        if pendingTags.count >= maxPendingTagCount {
            if logLabel == "video" {
                droppedRealtimeVideoTags += 1
                if droppedRealtimeVideoTags <= 5 || droppedRealtimeVideoTags % 30 == 0 {
                    SharedLogger.log("RTMP 弱网丢弃非关键视频帧 queue=\(pendingTags.count) dropped=\(droppedRealtimeVideoTags)")
                }
                return true
            }
            if logLabel == "audio" {
                audioBacklogDropCount += 1
                SharedLogger.log("RTMP backlog 超阈值，丢弃音频包 queue=\(pendingTags.count) limit=\(maxPendingTagCount) dropped=\(audioBacklogDropCount)")
                return true
            }
        }

        let order: Int
        if logLabel == "metadata" {
            order = 0
        } else if logLabel == "video-seq" {
            order = 1
        } else if logLabel == "audio-seq" {
            order = 2
        } else if logLabel == "video-key" {
            order = 3
        } else if logLabel == "video" {
            order = 4
        } else {
            order = 5
        }
        let normalizedTimestamp = adjustedTimestampForEnqueue(timestamp, packetType: packetType, logLabel: logLabel)
        let tag = PendingMediaPacket(timestamp: normalizedTimestamp, order: order, sequence: pendingSequence, packetType: packetType, channelId: channelId, payload: payload, logLabel: logLabel)
        pendingSequence &+= 1
        pendingTags.append(tag)
        if pendingTags.count == 1 || normalizedTimestamp > maxQueuedTimestamp {
            maxQueuedTimestamp = normalizedTimestamp
        }
        return flushPendingTags(force: false)
    }

    private func flushPendingTags(force: Bool) -> Bool {
        guard !pendingTags.isEmpty else { return true }
        guard let bridgeSession, LibRTMPSessionIsConnected(bridgeSession) else {
            return true
        }
        pendingTags.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.sequence < $1.sequence
        }

        let cutoff: UInt32 = force ? UInt32.max : (maxQueuedTimestamp > reorderWindowMs ? maxQueuedTimestamp - reorderWindowMs : 0)

        while !pendingTags.isEmpty {
            let tag = pendingTags[0]
            let shouldFlush = force || tag.timestamp <= cutoff || pendingTags.count > maxPendingTagCount
            if !shouldFlush { break }
            let timestamp = adjustedTimestampForSend(tag.timestamp, channelId: tag.channelId, logLabel: tag.logLabel)
            if tag.logLabel == "video" || tag.logLabel == "video-key" {
                debugVideoFlushCount += 1
            }
            if !sendRTMPPacket(packetType: tag.packetType, channelId: tag.channelId, timestamp: timestamp, payload: tag.payload, logLabel: tag.logLabel) { return false }
            pendingTags.removeFirst()
        }

        if pendingTags.isEmpty {
            maxQueuedTimestamp = 0
        } else {
            maxQueuedTimestamp = pendingTags.reduce(0) { max($0, $1.timestamp) }
        }
        return true
    }

    private func adjustedTimestampForEnqueue(_ timestamp: UInt32, packetType: UInt8, logLabel: String) -> UInt32 {
        let lastTimestamp = lastQueuedTimestampByPacketType[packetType] ?? lastSentTimestampByChannel[packetTypeToChannel(packetType)]
        guard let lastTimestamp, timestamp <= lastTimestamp else {
            lastQueuedTimestampByPacketType[packetType] = timestamp
            return timestamp
        }

        let adjusted = lastTimestamp == UInt32.max ? UInt32.max : lastTimestamp + 1
        lastQueuedTimestampByPacketType[packetType] = adjusted
        adjustedTimestampLogCount += 1
        if adjustedTimestampLogCount <= 5 || adjustedTimestampLogCount % 30 == 0 {
            SharedLogger.log("RTMP 入队修正非单调时间戳 type=\(packetType) label=\(logLabel) raw=\(timestamp) adjusted=\(adjusted) count=\(adjustedTimestampLogCount)")
        }
        return adjusted
    }

    private func adjustedTimestampForSend(_ timestamp: UInt32, channelId: UInt32, logLabel: String) -> UInt32 {
        var adjusted = timestamp

        if let lastTimestamp = lastSentTimestampByChannel[channelId], adjusted <= lastTimestamp {
            adjusted = lastTimestamp == UInt32.max ? UInt32.max : lastTimestamp + 1
            adjustedTimestampLogCount += 1
            if adjustedTimestampLogCount <= 5 || adjustedTimestampLogCount % 30 == 0 {
                SharedLogger.log("RTMP 发包修正非单调时间戳 channel=\(channelId) label=\(logLabel) raw=\(timestamp) adjusted=\(adjusted) count=\(adjustedTimestampLogCount)")
            }
        }

        lastSentTimestampByChannel[channelId] = adjusted
        if adjusted > lastSentGlobalTimestamp { lastSentGlobalTimestamp = adjusted }
        return adjusted
    }

    private func packetTypeToChannel(_ packetType: UInt8) -> UInt32 {
        switch packetType {
        case 0x08: return 5
        case 0x09, 0x12: return 4
        default: return 4
        }
    }

    private func publishDiagnosticsIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDiagnosticsFlushTime >= 0.5 else { return }
        lastDiagnosticsFlushTime = now
        publishDiagnostics(force: false)
    }

    private func publishDiagnostics(force: Bool) {
        if force {
            lastDiagnosticsFlushTime = CFAbsoluteTimeGetCurrent()
        }
        let connected = bridgeSession.map { LibRTMPSessionIsConnected($0) } ?? false
        if connected && !lastPublishedConnected {
            LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.rtmpConnected)
        }
        lastPublishedConnected = connected
        SharedDiagnostics.update([
            "diag.rtmp.pendingTags": pendingTags.count,
            "diag.rtmp.droppedVideoTags": droppedRealtimeVideoTags,
            "diag.rtmp.reconnectAttempt": reconnectAttempt,
            "diag.rtmp.isConnected": connected,
            "diag.rtmp.sentPackets": sentPacketCount,
            "diag.rtmp.lastVideoTs": Int(statPublishedLastVideoTs),
            "diag.rtmp.lastAudioTs": Int(statPublishedLastAudioTs),
            "diag.rtmp.videoFramesPerSecond": statPublishedVideoFrames,
            "diag.rtmp.audioTagsPerSecond": statPublishedAudioTags,
            "diag.rtmp.lastUpdateTs": Date().timeIntervalSince1970,
            "diag.rtmp.failedPacketLabel": failedPacketLabel,
            "diag.rtmp.failedPacketType": Int(failedPacketType),
            "diag.rtmp.failedPacketTimestamp": Int(failedPacketTimestamp),
            "diag.rtmp.failedPacketBytes": failedPacketBytes,
            "diag.rtmp.failedPacketConnected": failedPacketConnected,
            "diag.rtmp.failedPacketChannelId": Int(failedPacketChannelId),
            "diag.rtmp.failedPacketStreamId": Int(failedPacketStreamId),
            "diag.rtmp.failedPacketAt": failedPacketAt,
            "diag.rtmp.failedPacketReconnectAttempt": failedPacketReconnectAttempt,
            "diag.rtmp.firstVideoPacketSentAt": firstVideoPacketSentAt,
            "diag.rtmp.firstAudioPacketSentAt": firstAudioPacketSentAt,
            "diag.rtmp.audioSequenceSentAt": audioSequenceSentAt,
            "diag.rtmp.videoSequenceSentAt": videoSequenceSentAt,
            "diag.rtmp.latestSentVideoPacketTs": Int(latestSentVideoPacketTs),
            "diag.rtmp.latestSentAudioPacketTs": Int(latestSentAudioPacketTs),
            "diag.rtmp.latestAVDeltaMs": Int(latestAVDeltaMs),
            "diag.rtmp.lastVideoSendGapMs": Int(lastVideoSendGapMs.rounded()),
            "diag.rtmp.latestVideoTimelineDriftMs": Int(latestVideoTimelineDriftMs)
        ])
    }

    private func recordVideoSendSuccess(timestamp: UInt32) {
        let now = CFAbsoluteTimeGetCurrent()
        latestSentVideoPacketTs = timestamp
        if firstVideoSendWallClock == 0 {
            firstVideoSendWallClock = now
            firstVideoSendTimestamp = timestamp
        }
        if videoSendRhythmWindowStartWallClock == 0 {
            videoSendRhythmWindowStartWallClock = now
        }
        if lastVideoSendWallClock > 0 {
            let gapMs = max(0, (now - lastVideoSendWallClock) * 1000.0)
            lastVideoSendGapMs = gapMs
            videoSendRhythmCount += 1
            videoSendRhythmTotalGapMs += gapMs
            videoSendRhythmMaxGapMs = max(videoSendRhythmMaxGapMs, gapMs)
            if gapMs >= 80 {
                videoSendRhythmSlowGapCount += 1
            }
        }
        lastVideoSendWallClock = now
        if firstVideoSendWallClock > 0 {
            let elapsedWallClockMs = max(0, (now - firstVideoSendWallClock) * 1000.0)
            let elapsedVideoTsMs = Int64(timestamp) - Int64(firstVideoSendTimestamp)
            latestVideoTimelineDriftMs = Int32(elapsedVideoTsMs - Int64(elapsedWallClockMs.rounded()))
        }
        updateLatestAVDelta()
        maybeLogVideoRhythm()
    }

    private func updateLatestAVDelta() {
        guard latestSentVideoPacketTs > 0, latestSentAudioPacketTs > 0 else { return }
        latestAVDeltaMs = Int32(Int64(latestSentAudioPacketTs) - Int64(latestSentVideoPacketTs))
    }

    private func maybeLogVideoRhythm() {
        let now = CFAbsoluteTimeGetCurrent()
        guard videoSendRhythmWindowStartWallClock > 0,
              now - videoSendRhythmWindowStartWallClock >= 1.0 else { return }
        let avgGapMs = videoSendRhythmCount > 0 ? videoSendRhythmTotalGapMs / Double(videoSendRhythmCount) : 0
        let avgGapText = String(format: "%.1f", avgGapMs)
        let maxGapText = String(format: "%.1f", videoSendRhythmMaxGapMs)
        let lastGapText = String(format: "%.1f", lastVideoSendGapMs)
        SharedLogger.log("RTMP VideoRhythm 1s: gaps=\(videoSendRhythmCount) avgGap=\(avgGapText)ms maxGap=\(maxGapText)ms slow80=\(videoSendRhythmSlowGapCount) lastGap=\(lastGapText)ms avDelta=\(latestAVDeltaMs)ms drift=\(latestVideoTimelineDriftMs)ms vts=\(latestSentVideoPacketTs) ats=\(latestSentAudioPacketTs)")
        videoSendRhythmWindowStartWallClock = now
        videoSendRhythmCount = 0
        videoSendRhythmTotalGapMs = 0
        videoSendRhythmMaxGapMs = 0
        videoSendRhythmSlowGapCount = 0
    }

    private func recordAudioStat(timestamp: UInt32) {
        let now = CFAbsoluteTimeGetCurrent()
        if audioOnlyStatWindowStartWallClock == 0 {
            audioOnlyStatWindowStartWallClock = now
        }
        audioOnlyStatTags += 1
        audioOnlyStatLastTs = timestamp
        guard now - audioOnlyStatWindowStartWallClock >= 1.0 else { return }
        let connected = bridgeSession.map { LibRTMPSessionIsConnected($0) } ?? false
        SharedLogger.log("RTMP AudioStats 1s: a=\(audioOnlyStatTags) ats=\(audioOnlyStatLastTs) pending=\(pendingTags.count) connected=\(connected ? 1 : 0) sentPackets=\(sentPacketCount)")
        onAudioStats?(audioOnlyStatTags, audioOnlyStatLastTs)
        audioOnlyStatWindowStartWallClock = now
        audioOnlyStatTags = 0
    }

    private func ensureMetaDataSent(timestamp: UInt32, videoWidth: Int32, videoHeight: Int32) {
        let resolvedWidth = videoWidth > 0 ? videoWidth : LiveStreamConfig.Video.width
        let resolvedHeight = videoHeight > 0 ? videoHeight : LiveStreamConfig.Video.height
        let metadataChanged = publishedMetaWidth != resolvedWidth || publishedMetaHeight != resolvedHeight
        guard !sentMetaData || metadataChanged else { return }

        let payload = RTMPFLV.makePublishMetaData(audioConfig: audioConfig,
                                                  videoWidth: resolvedWidth,
                                                  videoHeight: resolvedHeight)
        let label = sentMetaData ? "metadata-update" : "metadata"
        guard enqueueMediaPacket(packetType: 0x12, channelId: 4, timestamp: timestamp, payload: payload, logLabel: label) else { return }

        sentMetaData = true
        publishedMetaWidth = resolvedWidth
        publishedMetaHeight = resolvedHeight
        SharedLogger.log("RTMP MetaData sent ts=\(timestamp) size=\(resolvedWidth)x\(resolvedHeight) fps=\(LiveStreamConfig.Video.fps) bitrate=\(LiveStreamConfig.Video.bitrate)")
    }

    private static func makeBridgeSession(host: String, port: UInt16, app: String, playpath: String, tcUrl: String) -> UnsafeMutableRawPointer? {
        host.withCString { hostCString in
            app.withCString { appCString in
                playpath.withCString { playpathCString in
                    tcUrl.withCString { tcUrlCString in
                        LibRTMPSessionCreate(hostCString, port, appCString, playpathCString, tcUrlCString)
                    }
                }
            }
        }
    }
}

private extension CMTime {
    var debugText: String {
        guard isNumeric else { return "invalid" }
        return String(format: "%.3f", CMTimeGetSeconds(self))
    }
}

private extension Data {
    /// 取前 n 字节的十六进制字符串（诊断用，避免一次性打印整包）。
    func prefixHex(_ n: Int) -> String {
        prefix(n).map { String(format: "%02X", $0) }.joined()
    }
}

/// 测试阶段：把录屏编码后写成 FLV 文件，方便验证画面/音频是否正确。
final class LocalFLVFileUploader: StreamUploader {
    var onError: ((Error) -> Void)?
    private let queue = DispatchQueue(label: "local.flv.writer.queue")
    private var handle: FileHandle?
    private var fileURL: URL?
    private var wroteHeader = false

    private let tsNormalizer = TimestampNormalizer()
    private var wroteMetaData = false
    private var sentAudioConfig = false
    private var sentVideoConfig = false
    private var lastSentVideoConfigSPS: Data?
    private var lastSentVideoConfigPPS: Data?
    private var lastSentVideoConfigMs: UInt32 = 0
    private var audioConfig: AACConfig?
    private var currentVideoWidth: Int32 = LiveStreamConfig.Video.width
    private var currentVideoHeight: Int32 = LiveStreamConfig.Video.height

    private var wroteAudioTags: Int = 0

    /// 注意：Extension 不能直接写入主 App 的 Documents（不同沙盒）。
    /// 导出动作应由主 App 从 AppGroup 复制到 Documents。

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }

            let defaults = UserDefaults(suiteName: self.appGroupID)

            let dir: URL
            if let groupDir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: self.appGroupID) {
                dir = groupDir
            } else {
                // 如果没有 App Group entitlement，会落到 extension 自己的 Documents（主 App 下载 container 看不到）
                defaults?.set("未配置 App Group，文件可能无法在主 App container 里看到", forKey: "recording.lastError")
                dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            }

            let name = "capture_\(Int(Date().timeIntervalSince1970)).flv"
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
            self.fileURL = url
            self.handle = try? FileHandle(forWritingTo: url)
            self.wroteHeader = false
            self.tsNormalizer.reset()
            self.wroteMetaData = false
            self.sentAudioConfig = false
            self.sentVideoConfig = false
            self.currentVideoWidth = LiveStreamConfig.Video.width
            self.currentVideoHeight = LiveStreamConfig.Video.height
            self.lastSentVideoConfigSPS = nil
            self.lastSentVideoConfigPPS = nil
            self.lastSentVideoConfigMs = 0

            defaults?.set(url.path, forKey: "recording.lastFilePath")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? self.handle?.close()
            self.handle = nil

            // 通知主 App：有新文件需要导出
            let defaults = UserDefaults(suiteName: self.appGroupID)
            defaults?.set(true, forKey: "recording.needsExport")
        }
    }

    func sendVideo(data: Data, pts: CMTime, dts: CMTime?, isKeyframe: Bool, sps: Data?, pps: Data?, width: Int32, height: Int32) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.ensureHeader()
            if width > 0, height > 0 {
                self.currentVideoWidth = width
                self.currentVideoHeight = height
            }
            let videoDTS = (dts?.isNumeric == true) ? dts! : pts
            let ts = self.tsNormalizer.timestamp(for: videoDTS, kind: .video)
            let nals = RTMPFLV.splitAnnexB(data)
            let nalTypes = nals.compactMap { $0.first }.map { $0 & 0x1F }
            let hasIDR = nalTypes.contains(5)
            let key = isKeyframe || hasIDR

            self.ensureMetaData(videoWidth: self.currentVideoWidth, videoHeight: self.currentVideoHeight)

            if let sps = sps, let pps = pps {
                let wasSent = self.sentVideoConfig
                let changed = (self.lastSentVideoConfigSPS != sps) || (self.lastSentVideoConfigPPS != pps)
                let periodic = key && (ts &- self.lastSentVideoConfigMs >= 2000)
                if !wasSent || changed || periodic {
                    let cfg = RTMPVideoConfig(sps: sps, pps: pps)
                    let payload = RTMPFLV.makeVideoSequenceHeader(config: cfg)
                    self.writeFLVTag(tagType: 0x09, timestamp: ts, payload: payload)
                    self.sentVideoConfig = true
                    self.lastSentVideoConfigSPS = sps
                    self.lastSentVideoConfigPPS = pps
                    self.lastSentVideoConfigMs = ts
                }
            }

            let ctsMs = RTMPFLV.compositionTimeMs(pts: pts, dts: videoDTS)
            let payload = RTMPFLV.makeVideoNALU(nals: nals, isKeyframe: key, compositionTimeMs: ctsMs)
            self.writeFLVTag(tagType: 0x09, timestamp: ts, payload: payload)
        }
    }

    func sendAudio(data: Data, pts: CMTime, audioSpecificConfig: Data?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.ensureHeader()
            let ts = self.tsNormalizer.timestamp(for: pts, kind: .audio)

            if let asc = audioSpecificConfig {
                self.audioConfig = AACConfig.parse(asc: asc)
            }

            if !self.sentAudioConfig, let asc = audioSpecificConfig {
                let payload = RTMPFLV.makeAudioSequenceHeader(asc: asc, config: self.audioConfig)
                self.writeFLVTag(tagType: 0x08, timestamp: ts, payload: payload)
                self.sentAudioConfig = true
                self.wroteAudioTags += 1
            }

            let payload = RTMPFLV.makeAudioRaw(data: data, config: self.audioConfig)
            self.writeFLVTag(tagType: 0x08, timestamp: ts, payload: payload)
            self.wroteAudioTags += 1

            if self.wroteAudioTags % 200 == 0 {
                let defaults = UserDefaults(suiteName: self.appGroupID)
                defaults?.set(self.wroteAudioTags, forKey: "diag.audioTags")
            }
        }
    }

    private func ensureHeader() {
        guard !wroteHeader, let h = handle else { return }
        // FLV header
        var header = Data([0x46, 0x4C, 0x56, 0x01, 0x05, 0x00, 0x00, 0x00, 0x09])
        header.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // PreviousTagSize0
        h.write(header)
        wroteHeader = true
    }

    private func ensureMetaData(videoWidth: Int32, videoHeight: Int32) {
        guard !wroteMetaData else { return }
        let payload = RTMPFLV.makeFLVMetaData(audioConfig: audioConfig,
                                              videoWidth: videoWidth,
                                              videoHeight: videoHeight)
        writeFLVTag(tagType: 0x12, timestamp: 0, payload: payload)
        wroteMetaData = true
    }


    private func writeFLVTag(tagType: UInt8, timestamp: UInt32, payload: Data) {
        guard let h = handle else { return }
        let dataSize = payload.count

        var tagHeader = Data()
        tagHeader.append(tagType)
        tagHeader.append(contentsOf: writeUInt24(UInt32(dataSize)))
        tagHeader.append(contentsOf: writeUInt24(timestamp & 0xFFFFFF))
        tagHeader.append(UInt8((timestamp >> 24) & 0xFF))
        tagHeader.append(contentsOf: [0x00, 0x00, 0x00]) // StreamID

        h.write(tagHeader)
        h.write(payload)

        let prevSize = UInt32(11 + dataSize).bigEndian
        h.write(withUnsafeBytes(of: prevSize) { Data($0) })
    }

    private func writeUInt24(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private var appGroupID: String {
        LiveStreamConfig.AppGroup.currentID()
    }

}

// MARK: - RTMP Core

private final class RTMPSession {
    private let queue: DispatchQueue
    private let url: RTMPURL
    private var connection: NWConnection?
    private var reconnectWorkItem: DispatchWorkItem?

    private var buffer = Data()
    private var chunkSize: Int = 128
    private var streamId: UInt32 = 0
    private var txId: Double = 1
    private var readyToSend = false
    private var sentAudioConfig = false
    private var sentVideoConfig = false
    private var audioConfig: AACConfig?

    private var incomingStates: [Int: RTMPChunkMessageState] = [:]

    init(url: String, queue: DispatchQueue) {
        self.queue = queue
        self.url = RTMPURL.parse(url) ?? RTMPURL(host: "127.0.0.1", port: 1935, app: "live", stream: "stream", query: nil)
        
    }

    func start() {
        connect()
    }

    func stop() {
        reconnectWorkItem?.cancel()
        connection?.cancel()
        connection = nil
    }

    func sendVideo(data: Data, pts: CMTime, dts: CMTime?, isKeyframe: Bool, sps: Data?, pps: Data?, width: Int32, height: Int32) {
        guard readyToSend else { return }
        _ = width
        _ = height
        let videoDTS = (dts?.isNumeric == true) ? dts! : pts
        let timestamp = videoDTS.rtmpTimestamp

        let nals = RTMPFLV.splitAnnexB(data)
        let nalTypes = nals.compactMap { $0.first }.map { $0 & 0x1F }
        let hasIDR = nalTypes.contains(5)
        let key = isKeyframe || hasIDR

        if !sentVideoConfig, let sps = sps, let pps = pps {
            let config = RTMPVideoConfig(sps: sps, pps: pps)
            let payload = RTMPFLV.makeVideoSequenceHeader(config: config)
            sendMessage(typeId: 0x09, streamId: streamId, timestamp: 0, payload: payload, csid: 4)
            sentVideoConfig = true
        }

        let ctsMs = RTMPFLV.compositionTimeMs(pts: pts, dts: videoDTS)
        let payload = RTMPFLV.makeVideoNALU(nals: nals, isKeyframe: key, compositionTimeMs: ctsMs)
        sendMessage(typeId: 0x09, streamId: streamId, timestamp: timestamp, payload: payload, csid: 4)
    }

    func sendAudio(data: Data, pts: CMTime, audioSpecificConfig: Data?) {
        guard readyToSend else { return }

        if let asc = audioSpecificConfig {
            audioConfig = AACConfig.parse(asc: asc)
        }

        if !sentAudioConfig, let asc = audioSpecificConfig {
            let payload = RTMPFLV.makeAudioSequenceHeader(asc: asc, config: audioConfig)
            sendMessage(typeId: 0x08, streamId: streamId, timestamp: 0, payload: payload, csid: 5)
            sentAudioConfig = true
        }

        let payload = RTMPFLV.makeAudioRaw(data: data, config: audioConfig)
        sendMessage(typeId: 0x08, streamId: streamId, timestamp: pts.rtmpTimestamp, payload: payload, csid: 5)
    }

    private func connect() {
        // 对于 NWConnection，为了兼容 Extension 网络限制，需要指定具体的参数
        let params = NWParameters.tcp
        // 防止阻止系统休眠，并允许通过蜂窝网络
        params.prohibitExpensivePaths = false
        params.prohibitConstrainedPaths = false
        if #available(iOS 14.2, *) {
            params.multipathServiceType = .handover
        }
        
        let conn = NWConnection(
            host: NWEndpoint.Host(url.host),
            port: NWEndpoint.Port(rawValue: url.port) ?? 1935,
            using: params
        )
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            SharedLogger.log("RTMP状态: \(state)")
            switch state {
            case .ready:
                SharedLogger.log("TCP连接成功, 开始握手"); self?.startHandshake()
            case .failed, .waiting:
                SharedLogger.log("触发重连"); self?.scheduleReconnect()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
            self?.readyToSend = false
            self?.sentAudioConfig = false
            self?.sentVideoConfig = false
            self?.buffer.removeAll()
            self?.incomingStates.removeAll()
            self?.connect()
        }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func startHandshake() {
        guard let conn = connection else { return }
        var c0c1 = Data()
        c0c1.append(0x03)
        var time = UInt32(Date().timeIntervalSince1970).bigEndian
        c0c1.append(contentsOf: withUnsafeBytes(of: &time) { Array($0) })
        c0c1.append(contentsOf: [UInt8](repeating: 0, count: 4))
        c0c1.append(contentsOf: [UInt8](repeating: 0x01, count: 1528))
        conn.send(content: c0c1, completion: .contentProcessed { [weak self] _ in
            self?.receiveHandshake()
        })
    }

    private func receiveHandshake() {
        guard connection != nil else { return }
        SharedLogger.log("等待服务器回传 S0S1S2...")
        self.buffer.removeAll()
        readHandshakeLoop(needed: 3073)
    }

    private func readHandshakeLoop(needed: Int) {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: needed) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let err = error {
                SharedLogger.log("握手接收出错: \(err.localizedDescription)")
                self.scheduleReconnect()
                return
            }
            guard let data = data, !data.isEmpty else {
                SharedLogger.log("服务器主动断开了 TCP 连接！可能是鉴权失败。")
                self.scheduleReconnect()
                return
            }
            self.buffer.append(data)
            SharedLogger.log("收到握手包, 进度 \(self.buffer.count)/3073")
            
            if self.buffer.count >= 3073 {
                // 收到完整的 S0S1S2
                self.buffer.removeFirst(3073)
                var c2 = Data()
                c2.append(contentsOf: [UInt8](repeating: 0x02, count: 1536))
                conn.send(content: c2, completion: .contentProcessed { [weak self] _ in
                    SharedLogger.log("已回复C2, 握手完成!")
                    self?.afterHandshake()
                })
            } else {
                // 还没收完，继续收剩下的
                self.readHandshakeLoop(needed: 3073 - self.buffer.count)
            }
        }
    }

    private func afterHandshake() {
        SharedLogger.log("发基础配置 SetChunkSize...")
        sendSetChunkSize(4096)
        sendWindowAcknowledgementSize(5_000_000)
        sendSetPeerBandwidth(5_000_000, limitType: 2)
        
        SharedLogger.log("发送 Connect(app=\(url.app))...")
        sendConnect()
        startReceiveLoop()
    }

    private func startReceiveLoop() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self = self, error == nil else {
                SharedLogger.log("触发重连"); self?.scheduleReconnect()
                return
            }
            if let data = data, !data.isEmpty {
                SharedLogger.log("接收到网络数据: \(data.count) bytes")
                SharedLogger.log("HEX: \(data.map { String(format: "%02hhX", $0) }.joined().prefix(100))...")
                self.buffer.append(data)
                self.parseIncoming()
            }
            self.startReceiveLoop()
        }
    }

    private func parseIncoming() {
        var previousCount = -1
        // 只要 buffer 长度在减少，就说明我们刚才成功吃掉了一个 Chunk (或者完整消息)。
        // 必须继续解析，因为下一个 Chunk 可能已经一起打包在现在的 buffer 里了！
        while buffer.count != previousCount && !buffer.isEmpty {
            previousCount = buffer.count
            if let result = RTMPChunkParser.parse(buffer: &buffer, chunkSize: chunkSize, states: &incomingStates) {
                handleMessage(result)
            }
        }
    }

    private func handleMessage(_ message: RTMPMessage) {
        SharedLogger.log("解析出完整RTMP包: type=\(message.typeId), size=\(message.payload.count)")
        switch message.typeId {
        case 0x01: // Set Chunk Size
            if message.payload.count >= 4 {
                let size = message.payload.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                SharedLogger.log("收到服务器 ChunkSize: \(size)")
                chunkSize = Int(size)
            }
        case 0x14: // AMF0 Command
            let values = AMF0.decode(message.payload)
            guard let command = values.first?.stringValue else { return }
            SharedLogger.log("收到 AMF0 Command: \(command)")
            
            if command == "_result", values.count >= 4 {
                if let tx = values[1].numberValue {
                    if tx == 1 {
                        sendCreateStream()
                    } else if tx == 2, let streamId = values[3].numberValue {
                        self.streamId = UInt32(streamId)
                        sendPublish()
                        readyToSend = true
                    }
                }
            } else if command == "onStatus" {
                readyToSend = true
            }
        default:
            break
        }
    }

    // MARK: RTMP Commands

    private func sendConnect() {
        let app = url.app
        let tcUrl = url.tcUrl
        SharedLogger.log("tcUrl: \(tcUrl)")
        let obj: [(String, AMF0)] = [
            ("app", .string(app)),
            ("type", .string("nonprivate")),
            ("tcUrl", .string(tcUrl)),
            ("fpad", .bool(false)),
            ("capabilities", .number(15)),
            ("audioCodecs", .number(10)),
            ("videoCodecs", .number(7)),
            ("videoFunction", .number(1)),
            ("flashVer", .string("FMLE/3.0 (compatible; TraeCli)"))
        ]
        let payload = AMF0.encode([.string("connect"), .number(nextTxId()), .object(obj)])
        sendMessage(typeId: 0x14, streamId: 0, timestamp: 0, payload: payload, csid: 3)
    }

    private func sendCreateStream() {
        let payload = AMF0.encode([.string("createStream"), .number(nextTxId()), .null])
        sendMessage(typeId: 0x14, streamId: 0, timestamp: 0, payload: payload, csid: 3)
    }

    private func sendPublish() {
        let payload = AMF0.encode([.string("publish"), .number(nextTxId()), .null, .string(url.playpath), .string("live")])
        sendMessage(typeId: 0x14, streamId: streamId, timestamp: 0, payload: payload, csid: 3)
    }

    private func sendSetChunkSize(_ size: Int) {
        var s = UInt32(size).bigEndian
        let payload = withUnsafeBytes(of: &s) { Data($0) }
        sendMessage(typeId: 0x01, streamId: 0, timestamp: 0, payload: payload, csid: 2)
        chunkSize = size
    }

    private func sendWindowAcknowledgementSize(_ size: Int) {
        var s = UInt32(size).bigEndian
        let payload = withUnsafeBytes(of: &s) { Data($0) }
        sendMessage(typeId: 0x05, streamId: 0, timestamp: 0, payload: payload, csid: 2)
    }

    private func sendSetPeerBandwidth(_ size: Int, limitType: UInt8) {
        var s = UInt32(size).bigEndian
        var payload = withUnsafeBytes(of: &s) { Data($0) }
        payload.append(limitType)
        sendMessage(typeId: 0x06, streamId: 0, timestamp: 0, payload: payload, csid: 2)
    }

    private func sendMessage(typeId: UInt8, streamId: UInt32, timestamp: UInt32, payload: Data, csid: Int) {
        guard let conn = connection else { return }
        let chunkSize = self.chunkSize
        let header = RTMPChunkBuilder.buildHeader(fmt: 0, csid: csid, timestamp: timestamp, messageLength: payload.count, messageTypeId: typeId, messageStreamId: streamId)
        let useExtended = timestamp >= 0xFFFFFF
        var offset = 0
        var out = Data()
        while offset < payload.count {
            let size = min(chunkSize, payload.count - offset)
            if offset == 0 {
                out.append(header)
            } else {
                out.append(RTMPChunkBuilder.basicHeader(fmt: 3, csid: csid))
                if useExtended {
                    var ts = timestamp.bigEndian
                    out.append(contentsOf: withUnsafeBytes(of: &ts) { Data($0) })
                }
            }
            out.append(payload.subdata(in: offset..<offset+size))
            offset += size
        }
        conn.send(content: out, completion: .contentProcessed { _ in })
    }

    private func nextTxId() -> Double {
        txId += 1
        return txId
    }
}

// MARK: - RTMP Helpers

private struct RTMPURL {
    let host: String
    let port: UInt16
    let app: String
    let stream: String
    let query: String?

    var playpath: String {
        guard let query, !query.isEmpty else { return stream }
        return "\(stream)?\(query)"
    }

    var tcUrl: String {
        "rtmp://\(host):\(port)/\(app)"
    }

    static func parse(_ urlString: String) -> RTMPURL? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        let port = UInt16(url.port ?? 1935)
        let comps = url.path.split(separator: "/").map(String.init)
        guard !comps.isEmpty else { return nil }
        let app = comps.first ?? "live"
        let stream = comps.dropFirst().joined(separator: "/")
        let query = url.query?.isEmpty == false ? url.query : nil
        return RTMPURL(host: host, port: port, app: app, stream: stream.isEmpty ? "stream" : stream, query: query)
    }
}

private struct RTMPMessage {
    let typeId: UInt8
    let streamId: UInt32
    let timestamp: UInt32
    let payload: Data
}

private struct RTMPChunkMessageState {
    var header: RTMPMessageHeader
    var received: Int
    var data: Data
}

private struct RTMPMessageHeader {
    var timestamp: UInt32
    var messageLength: Int
    var messageTypeId: UInt8
    var messageStreamId: UInt32
    var timestampDelta: UInt32
}

private enum RTMPChunkParser {
    static func parse(buffer: inout Data, chunkSize: Int, states: inout [Int: RTMPChunkMessageState]) -> RTMPMessage? {
        guard buffer.count >= 1 else { return nil }
        let first = buffer[0]
        let fmt = Int(first >> 6)
        var csid = Int(first & 0x3F)
        var index = 1

        if csid == 0 {
            guard buffer.count >= 2 else { return nil }
            csid = Int(buffer[1]) + 64
            index = 2
        } else if csid == 1 {
            guard buffer.count >= 3 else { return nil }
            csid = Int(buffer[1]) + Int(buffer[2]) * 256 + 64
            index = 3
        }

        var header = states[csid]?.header ?? RTMPMessageHeader(timestamp: 0, messageLength: 0, messageTypeId: 0, messageStreamId: 0, timestampDelta: 0)
        let headerLen = fmt == 0 ? 11 : (fmt == 1 ? 7 : (fmt == 2 ? 3 : 0))
        guard buffer.count >= index + headerLen else { return nil }

        if fmt == 0 {
            header.timestamp = readUInt24(buffer, index)
            header.messageLength = Int(readUInt24(buffer, index + 3))
            header.messageTypeId = buffer[index + 6]
            header.messageStreamId = readUInt32LE(buffer, index + 7)
            header.timestampDelta = 0
        } else if fmt == 1 {
            header.timestampDelta = readUInt24(buffer, index)
            header.timestamp += header.timestampDelta
            header.messageLength = Int(readUInt24(buffer, index + 3))
            header.messageTypeId = buffer[index + 6]
        } else if fmt == 2 {
            header.timestampDelta = readUInt24(buffer, index)
            header.timestamp += header.timestampDelta
        }
        index += headerLen

        if (fmt == 0 && header.timestamp == 0xFFFFFF) || ((fmt == 1 || fmt == 2) && header.timestampDelta == 0xFFFFFF) {
            guard buffer.count >= index + 4 else { 
                SharedLogger.log("等待 extended timestamp")
                return nil 
            }
            let ext = buffer[index..<index+4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            if fmt == 0 {
                header.timestamp = ext
            } else {
                header.timestamp += ext
            }
            index += 4
        }

        let isFirstChunk = (states[csid] == nil || states[csid]?.received == 0)
        
        var state = states[csid] ?? RTMPChunkMessageState(header: header, received: 0, data: Data())
        if isFirstChunk {
            state.header = header
        }

        // 关键修复：这里的 chunkSize 是我们在本地发送数据的 ChunkSize，
        // 对于服务器发过来的数据，应该用服务器的 ChunkSize，但在尚未收到服务器的 SetChunkSize 之前，
        // 默认的接收 ChunkSize 必须是 128！而不是我们在初始化时用于发包的 4096！
        // 如果这里强行使用 4096 作为 need 去切片，会导致包越界解析失败被永远阻塞。
let receiveChunkSize = chunkSize == 4096 ? 128 : chunkSize
        let need = min(receiveChunkSize, state.header.messageLength - state.received)
        
        let remaining = buffer.count - index
        if remaining < need {
            return nil 
        }

        state.data.append(buffer.subdata(in: index..<index+need))
        state.received += need
        buffer.removeSubrange(0..<index+need)

        if state.received >= state.header.messageLength {
            let msg = RTMPMessage(typeId: state.header.messageTypeId, streamId: state.header.messageStreamId, timestamp: state.header.timestamp, payload: state.data)
            // 完整包收齐，清空接收数据但保留 Header 的状态供 fmt=1/2/3 包复用
            state.data = Data()
            state.received = 0
            states[csid] = state
            return msg
        } else {
            states[csid] = state
            return nil
        }
    }

    private static func readUInt24(_ data: Data, _ index: Int) -> UInt32 {
        let b0 = UInt32(data[index])
        let b1 = UInt32(data[index + 1])
        let b2 = UInt32(data[index + 2])
        return (b0 << 16) | (b1 << 8) | b2
    }

    private static func readUInt32LE(_ data: Data, _ index: Int) -> UInt32 {
        let b0 = UInt32(data[index])
        let b1 = UInt32(data[index + 1])
        let b2 = UInt32(data[index + 2])
        let b3 = UInt32(data[index + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}

private enum RTMPChunkBuilder {
    static func basicHeader(fmt: Int, csid: Int) -> Data {
        let b = UInt8((fmt << 6) | (csid & 0x3F))
        return Data([b])
    }

    static func buildHeader(fmt: Int, csid: Int, timestamp: UInt32, messageLength: Int, messageTypeId: UInt8, messageStreamId: UInt32) -> Data {
        var data = Data()
        data.append(basicHeader(fmt: fmt, csid: csid))
        let useExtended = timestamp >= 0xFFFFFF
        data.append(contentsOf: writeUInt24(useExtended ? 0xFFFFFF : timestamp))
        data.append(contentsOf: writeUInt24(UInt32(messageLength)))
        data.append(messageTypeId)
        data.append(contentsOf: writeUInt32LE(messageStreamId))
        if useExtended {
            var ts = timestamp.bigEndian
            data.append(contentsOf: withUnsafeBytes(of: &ts) { Data($0) })
        }
        return data
    }

    private static func writeUInt24(_ value: UInt32) -> [UInt8] {
        return [UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func writeUInt32LE(_ value: UInt32) -> [UInt8] {
        return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
}

private enum AMF0 {
    case number(Double)
    case bool(Bool)
    case string(String)
    case object([(String, AMF0)])
    case ecmaArray([(String, AMF0)])
    case null

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    static func encode(_ values: [AMF0]) -> Data {
        var data = Data()
        for v in values {
            data.append(encodeValue(v))
        }
        return data
    }

    private static func encodeValue(_ value: AMF0) -> Data {
        var data = Data()
        switch value {
        case .number(let n):
            data.append(0x00)
            var bits = n.bitPattern.bigEndian
            data.append(contentsOf: withUnsafeBytes(of: &bits) { Data($0) })
        case .bool(let b):
            data.append(0x01)
            data.append(b ? 1 : 0)
        case .string(let s):
            data.append(0x02)
            let bytes = Array(s.utf8)
            var len = UInt16(bytes.count).bigEndian
            data.append(contentsOf: withUnsafeBytes(of: &len) { Data($0) })
            data.append(contentsOf: bytes)
        case .object(let obj):
            data.append(0x03)
            for (k, v) in obj {
                let keyBytes = Array(k.utf8)
                var len = UInt16(keyBytes.count).bigEndian
                data.append(contentsOf: withUnsafeBytes(of: &len) { Data($0) })
                data.append(contentsOf: keyBytes)
                data.append(encodeValue(v))
            }
            data.append(contentsOf: [0x00, 0x00, 0x09])
        case .ecmaArray(let obj):
            data.append(0x08)
            var count = UInt32(obj.count).bigEndian
            data.append(contentsOf: withUnsafeBytes(of: &count) { Data($0) })
            for (k, v) in obj {
                let keyBytes = Array(k.utf8)
                var len = UInt16(keyBytes.count).bigEndian
                data.append(contentsOf: withUnsafeBytes(of: &len) { Data($0) })
                data.append(contentsOf: keyBytes)
                data.append(encodeValue(v))
            }
            data.append(contentsOf: [0x00, 0x00, 0x09])
        case .null:
            data.append(0x05)
        }
        return data
    }

    static func decode(_ data: Data) -> [AMF0] {
        var index = 0
        var values: [AMF0] = []
        while index < data.count {
            if let v = decodeValue(data, &index) {
                values.append(v)
            } else {
                break
            }
        }
        return values
    }

    private static func decodeValue(_ data: Data, _ index: inout Int) -> AMF0? {
        guard index < data.count else { return nil }
        let type = data[index]
        index += 1
        switch type {
        case 0x00:
            guard index + 8 <= data.count else { return nil }
            let bits = data[index..<index+8].withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            index += 8
            return .number(Double(bitPattern: bits))
        case 0x01:
            guard index < data.count else { return nil }
            let b = data[index] != 0
            index += 1
            return .bool(b)
        case 0x02:
            guard index + 2 <= data.count else { return nil }
            let len = data[index..<index+2].withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            index += 2
            guard index + Int(len) <= data.count else { return nil }
            let s = String(data: data[index..<index+Int(len)], encoding: .utf8) ?? ""
            index += Int(len)
            return .string(s)
        case 0x03:
            var obj: [(String, AMF0)] = []
            while index + 2 <= data.count {
                let len = data[index..<index+2].withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
                index += 2
                if len == 0, index < data.count, data[index] == 0x09 {
                    index += 1
                    break
                }
                guard index + Int(len) <= data.count else { break }
                let key = String(data: data[index..<index+Int(len)], encoding: .utf8) ?? ""
                index += Int(len)
                if let v = decodeValue(data, &index) {
                    obj.append((key, v))
                } else { break }
            }
            return .object(obj)
        case 0x08:
            guard index + 4 <= data.count else { return nil }
            index += 4
            var obj: [(String, AMF0)] = []
            while index + 2 <= data.count {
                let len = data[index..<index+2].withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
                index += 2
                if len == 0, index < data.count, data[index] == 0x09 {
                    index += 1
                    break
                }
                guard index + Int(len) <= data.count else { break }
                let key = String(data: data[index..<index+Int(len)], encoding: .utf8) ?? ""
                index += Int(len)
                if let v = decodeValue(data, &index) {
                    obj.append((key, v))
                } else { break }
            }
            return .ecmaArray(obj)
        case 0x05:
            return .null
        default:
            return nil
        }
    }
}

private enum RTMPFLV {
    /// FLV VideoTag 的 composition time（ms，signed 24-bit）。
    /// - Note: FLV tag timestamp 传 DTS；composition time 传 (PTS-DTS)。
    static func compositionTimeMs(pts: CMTime, dts: CMTime) -> Int32 {
        guard pts.isNumeric, dts.isNumeric else { return 0 }
        let diff = pts.milliseconds - dts.milliseconds
        // 限制在 signed 24-bit，避免极端值导致下游解析异常
        let min24: Int64 = -8_388_608
        let max24: Int64 = 8_388_607
        let clamped = max(min24, min(max24, diff))
        return Int32(clamped)
    }

    /// 写入 FLV composition time（三字节，big-endian，signed 24-bit two's complement）。
    private static func writeCompositionTime(_ ctsMs: Int32, to payload: inout Data) {
        let u = UInt32(bitPattern: ctsMs) & 0x00FF_FFFF
        payload.append(UInt8((u >> 16) & 0xFF))
        payload.append(UInt8((u >> 8) & 0xFF))
        payload.append(UInt8(u & 0xFF))
    }

    static func makePublishMetaData(audioConfig: AACConfig?, videoWidth: Int32, videoHeight: Int32) -> Data {
        AMF0.encode([
            .string("@setDataFrame"),
            .string("onMetaData"),
            .ecmaArray(makeMetaDataProperties(audioConfig: audioConfig,
                                             videoWidth: videoWidth,
                                             videoHeight: videoHeight))
        ])
    }

    static func makeFLVMetaData(audioConfig: AACConfig?, videoWidth: Int32, videoHeight: Int32) -> Data {
        AMF0.encode([
            .string("onMetaData"),
            .ecmaArray(makeMetaDataProperties(audioConfig: audioConfig,
                                             videoWidth: videoWidth,
                                             videoHeight: videoHeight))
        ])
    }

    private static func makeMetaDataProperties(audioConfig: AACConfig?, videoWidth: Int32, videoHeight: Int32) -> [(String, AMF0)] {
        let resolvedWidth = videoWidth > 0 ? videoWidth : LiveStreamConfig.Video.width
        let resolvedHeight = videoHeight > 0 ? videoHeight : LiveStreamConfig.Video.height
        var properties: [(String, AMF0)] = [
            ("width", .number(Double(resolvedWidth))),
            ("height", .number(Double(resolvedHeight))),
            ("videodatarate", .number(Double(LiveStreamConfig.Video.bitrate) / 1000.0)),
            ("framerate", .number(Double(LiveStreamConfig.Video.fps))),
            ("videocodecid", .number(7)),
            ("audiodatarate", .number(Double(LiveStreamConfig.Audio.bitrate) / 1000.0)),
            ("audiosamplesize", .number(16)),
            ("audiocodecid", .number(10)),
            ("encoder", .string("TraeCli"))
        ]

        if let audioConfig {
            properties.append(("audiosamplerate", .number(Double(audioConfig.sampleRate))))
            properties.append(("stereo", .bool(audioConfig.channelConfig > 1)))
        }

        return properties
    }

    static func splitAnnexB(_ data: Data) -> [Data] {
        var nals: [Data] = []
        var start = 0
        var i = 0
        while i + 3 < data.count {
            if data[i] == 0 && data[i+1] == 0 && ((data[i+2] == 1) || (data[i+2] == 0 && data[i+3] == 1)) {
                let scLen = data[i+2] == 1 ? 3 : 4
                if start < i {
                    nals.append(data.subdata(in: start..<i))
                }
                start = i + scLen
                i = start
                continue
            }
            i += 1
        }
        if start < data.count {
            nals.append(data.subdata(in: start..<data.count))
        }
        return nals.filter { !$0.isEmpty }
    }

    static func makeVideoSequenceHeader(config: RTMPVideoConfig) -> Data {
        var payload = Data()
        payload.append(0x17) // keyframe + AVC
        payload.append(0x00) // AVC sequence header
        payload.append(contentsOf: [0, 0, 0]) // composition time
        payload.append(config.avcDecoderConfigRecord)
        return payload
    }

    static func makeVideoNALU(nals: [Data], isKeyframe: Bool, compositionTimeMs: Int32) -> Data {
        var payload = Data()
        payload.append(isKeyframe ? 0x17 : 0x27)
        payload.append(0x01) // AVC NALU
        writeCompositionTime(compositionTimeMs, to: &payload)
        for nal in nals {
            // FLV AVC NALU 包体仅承载当前 access unit 的实际视频 NAL。
            // SPS/PPS 通过单独的 AVC sequence header 周期性补发；AUD 继续过滤避免兼容性问题。
            if let type = nal.first.map({ $0 & 0x1F }), type == 7 || type == 8 || type == 9 { continue }
            var len = UInt32(nal.count).bigEndian
            payload.append(contentsOf: withUnsafeBytes(of: &len) { Data($0) })
            payload.append(nal)
        }
        return payload
    }

    static func makeAudioSequenceHeader(asc: Data, config: AACConfig?) -> Data {
        var payload = Data()
        payload.append(config?.audioHeaderByte ?? 0xAF)
        payload.append(0x00) // AAC sequence header
        payload.append(asc)
        return payload
    }

    static func makeAudioRaw(data: Data, config: AACConfig?) -> Data {
        var payload = Data()
        payload.append(config?.audioHeaderByte ?? 0xAF)
        payload.append(0x01) // AAC raw
        payload.append(data)
        return payload
    }
}

private struct RTMPVideoConfig {
    let sps: Data
    let pps: Data

    private var normalizedSPS: Data {
        H264ParameterSetNormalizer.normalizedSPS(sps, fps: LiveStreamConfig.Video.fps)
    }

    private var normalizedPPS: Data {
        H264ParameterSetNormalizer.normalizedPPS(pps)
    }

    var avcDecoderConfigRecord: Data {
        var data = Data()
        let sps = normalizedSPS
        let pps = normalizedPPS
        let profile = sps.count > 1 ? sps[1] : 0x42
        let compat = sps.count > 2 ? sps[2] : 0x00
        let level = sps.count > 3 ? sps[3] : 0x1E
        data.append(0x01)
        data.append(profile)
        data.append(compat)
        data.append(level)
        data.append(0xFF) // lengthSizeMinusOne = 3
        data.append(0xE1) // num of SPS = 1
        var spsLen = UInt16(sps.count).bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &spsLen) { Data($0) })
        data.append(sps)
        data.append(0x01) // num of PPS = 1
        var ppsLen = UInt16(pps.count).bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &ppsLen) { Data($0) })
        data.append(pps)
        return data
    }
}

private enum H264ParameterSetNormalizer {
    static func normalizedSPS(_ sps: Data, fps: Int32) -> Data {
        let headerNormalized = normalizedNALHeader(sps, nalType: 7)
        guard let rewritten = rewriteSPS(headerNormalized, fps: max(1, Int(fps))) else {
            return headerNormalized
        }
        // 安全网：重写注入 VUI timing 后必须仍能被完整解析，否则回退到仅规整 NAL 头的原始 SPS。
        // 这样即便某个 iOS 版本产出的 SPS 结构触发重写边界问题，也绝不会发出无法解码的 sequence header
        //（无法解码的 AVCDecoderConfigurationRecord 会直接表现为“推流后拉不到流”）。
        guard isParseableSPS(rewritten) else {
            return headerNormalized
        }
        return rewritten
    }

    private static func isParseableSPS(_ sps: Data) -> Bool {
        guard sps.count >= 4 else { return false }
        var reader = BitReader(data: rbspFromEBSP(sps.dropFirst()))
        return ParsedSPS.read(from: &reader) != nil
    }

    static func normalizedPPS(_ pps: Data) -> Data {
        normalizedNALHeader(pps, nalType: 8)
    }

    private static func normalizedNALHeader(_ nal: Data, nalType: UInt8) -> Data {
        guard !nal.isEmpty else { return nal }
        var normalized = nal
        normalized[normalized.startIndex] = 0x60 | nalType
        return normalized
    }

    private static func rewriteSPS(_ sps: Data, fps: Int) -> Data? {
        guard sps.count >= 4 else { return nil }
        let nalHeader = sps[sps.startIndex]
        let rbsp = rbspFromEBSP(sps.dropFirst())
        var reader = BitReader(data: rbsp)
        guard let parsed = ParsedSPS.read(from: &reader) else { return nil }

        var updated = parsed
        var vui = updated.vui ?? ParsedVUI()
        vui.timingInfoPresentFlag = true
        vui.numUnitsInTick = 1
        vui.timeScale = UInt32(max(1, fps) * 2)
        vui.fixedFrameRateFlag = true
        updated.vui = vui

        var writer = BitWriter()
        updated.write(to: &writer)
        writer.writeRBSPTrailingBits()

        var out = Data([nalHeader])
        out.append(ebspFromRBSP(writer.data))
        return out
    }

    private static func rbspFromEBSP<S: Sequence>(_ bytes: S) -> Data where S.Element == UInt8 {
        var data = Data()
        var zeroCount = 0
        for byte in bytes {
            if zeroCount == 2 && byte == 0x03 {
                zeroCount = 0
                continue
            }
            data.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return data
    }

    private static func ebspFromRBSP(_ rbsp: Data) -> Data {
        var data = Data()
        var zeroCount = 0
        for byte in rbsp {
            if zeroCount >= 2 && byte <= 0x03 {
                data.append(0x03)
                zeroCount = 0
            }
            data.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return data
    }

    private struct ParsedSPS {
        var profileIDC: UInt8
        var constraintFlags: UInt8
        var levelIDC: UInt8
        var seqParameterSetID: UInt
        var log2MaxFrameNumMinus4: UInt
        var picOrderCntType: UInt
        var log2MaxPicOrderCntLSBMinus4: UInt?
        var deltaPicOrderAlwaysZeroFlag: Bool = false
        var offsetForNonRefPic: Int = 0
        var offsetForTopToBottomField: Int = 0
        var offsetForRefFrame: [Int] = []
        var maxNumRefFrames: UInt
        var gapsInFrameNumValueAllowedFlag: Bool
        var picWidthInMbsMinus1: UInt
        var picHeightInMapUnitsMinus1: UInt
        var frameMbsOnlyFlag: Bool
        var mbAdaptiveFrameFieldFlag: Bool = false
        var direct8x8InferenceFlag: Bool
        var frameCropping: FrameCropping?
        var vui: ParsedVUI?

        static func read(from reader: inout BitReader) -> ParsedSPS? {
            guard let profileIDC = reader.readBits(8),
                  let constraintFlags = reader.readBits(8),
                  let levelIDC = reader.readBits(8),
                  let seqParameterSetID = reader.readUE() else { return nil }

            // 当前推流固定为 Baseline；若后续 profile 变化到需要 scaling matrix 的档位，先回退到原始 SPS，避免错误重写。
            let advancedProfiles: Set<UInt8> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
            if advancedProfiles.contains(UInt8(profileIDC)) {
                return nil
            }

            guard let log2MaxFrameNumMinus4 = reader.readUE(),
                  let picOrderCntType = reader.readUE() else { return nil }

            var log2MaxPicOrderCntLSBMinus4: UInt?
            var deltaPicOrderAlwaysZeroFlag = false
            var offsetForNonRefPic = 0
            var offsetForTopToBottomField = 0
            var offsetForRefFrame: [Int] = []

            if picOrderCntType == 0 {
                guard let value = reader.readUE() else { return nil }
                log2MaxPicOrderCntLSBMinus4 = value
            } else if picOrderCntType == 1 {
                guard let delta = reader.readBit(),
                      let nonRef = reader.readSE(),
                      let topBottom = reader.readSE(),
                      let cycleCount = reader.readUE() else { return nil }
                deltaPicOrderAlwaysZeroFlag = delta
                offsetForNonRefPic = nonRef
                offsetForTopToBottomField = topBottom
                for _ in 0..<cycleCount {
                    guard let value = reader.readSE() else { return nil }
                    offsetForRefFrame.append(value)
                }
            }

            guard let maxNumRefFrames = reader.readUE(),
                  let gaps = reader.readBit(),
                  let picWidthInMbsMinus1 = reader.readUE(),
                  let picHeightInMapUnitsMinus1 = reader.readUE(),
                  let frameMbsOnlyFlag = reader.readBit() else { return nil }

            var mbAdaptiveFrameFieldFlag = false
            if !frameMbsOnlyFlag {
                guard let mbAdaptive = reader.readBit() else { return nil }
                mbAdaptiveFrameFieldFlag = mbAdaptive
            }

            guard let direct8x8 = reader.readBit(),
                  let frameCroppingFlag = reader.readBit() else { return nil }

            let frameCropping: FrameCropping?
            if frameCroppingFlag {
                guard let left = reader.readUE(),
                      let right = reader.readUE(),
                      let top = reader.readUE(),
                      let bottom = reader.readUE() else { return nil }
                frameCropping = FrameCropping(left: left, right: right, top: top, bottom: bottom)
            } else {
                frameCropping = nil
            }

            guard let vuiPresent = reader.readBit() else { return nil }
            let vui = vuiPresent ? ParsedVUI.read(from: &reader) : ParsedVUI?.none
            if vuiPresent, vui == nil { return nil }

            return ParsedSPS(profileIDC: UInt8(profileIDC),
                             constraintFlags: UInt8(constraintFlags),
                             levelIDC: UInt8(levelIDC),
                             seqParameterSetID: seqParameterSetID,
                             log2MaxFrameNumMinus4: log2MaxFrameNumMinus4,
                             picOrderCntType: picOrderCntType,
                             log2MaxPicOrderCntLSBMinus4: log2MaxPicOrderCntLSBMinus4,
                             deltaPicOrderAlwaysZeroFlag: deltaPicOrderAlwaysZeroFlag,
                             offsetForNonRefPic: offsetForNonRefPic,
                             offsetForTopToBottomField: offsetForTopToBottomField,
                             offsetForRefFrame: offsetForRefFrame,
                             maxNumRefFrames: maxNumRefFrames,
                             gapsInFrameNumValueAllowedFlag: gaps,
                             picWidthInMbsMinus1: picWidthInMbsMinus1,
                             picHeightInMapUnitsMinus1: picHeightInMapUnitsMinus1,
                             frameMbsOnlyFlag: frameMbsOnlyFlag,
                             mbAdaptiveFrameFieldFlag: mbAdaptiveFrameFieldFlag,
                             direct8x8InferenceFlag: direct8x8,
                             frameCropping: frameCropping,
                             vui: vui)
        }

        func write(to writer: inout BitWriter) {
            writer.writeBits(UInt(profileIDC), count: 8)
            writer.writeBits(UInt(constraintFlags), count: 8)
            writer.writeBits(UInt(levelIDC), count: 8)
            writer.writeUE(seqParameterSetID)
            writer.writeUE(log2MaxFrameNumMinus4)
            writer.writeUE(picOrderCntType)
            if picOrderCntType == 0 {
                writer.writeUE(log2MaxPicOrderCntLSBMinus4 ?? 0)
            } else if picOrderCntType == 1 {
                writer.writeBit(deltaPicOrderAlwaysZeroFlag)
                writer.writeSE(offsetForNonRefPic)
                writer.writeSE(offsetForTopToBottomField)
                writer.writeUE(UInt(offsetForRefFrame.count))
                for value in offsetForRefFrame {
                    writer.writeSE(value)
                }
            }
            writer.writeUE(maxNumRefFrames)
            writer.writeBit(gapsInFrameNumValueAllowedFlag)
            writer.writeUE(picWidthInMbsMinus1)
            writer.writeUE(picHeightInMapUnitsMinus1)
            writer.writeBit(frameMbsOnlyFlag)
            if !frameMbsOnlyFlag {
                writer.writeBit(mbAdaptiveFrameFieldFlag)
            }
            writer.writeBit(direct8x8InferenceFlag)
            writer.writeBit(frameCropping != nil)
            if let frameCropping {
                writer.writeUE(frameCropping.left)
                writer.writeUE(frameCropping.right)
                writer.writeUE(frameCropping.top)
                writer.writeUE(frameCropping.bottom)
            }
            writer.writeBit(vui != nil)
            vui?.write(to: &writer)
        }
    }

    private struct FrameCropping {
        let left: UInt
        let right: UInt
        let top: UInt
        let bottom: UInt
    }

    private struct ParsedVUI {
        var aspectRatio: AspectRatio?
        var overscanAppropriateFlag: Bool?
        var videoSignal: VideoSignal?
        var chromaLoc: ChromaLoc?
        var timingInfoPresentFlag = false
        var numUnitsInTick: UInt32 = 1
        var timeScale: UInt32 = 60
        var fixedFrameRateFlag = true
        var nalHRD: HRDParameters?
        var vclHRD: HRDParameters?
        var lowDelayHRDFlag: Bool?
        var picStructPresentFlag = false
        var bitstreamRestriction: BitstreamRestriction?

        static func read(from reader: inout BitReader) -> ParsedVUI? {
            var vui = ParsedVUI()

            guard let aspectRatioPresent = reader.readBit() else { return nil }
            if aspectRatioPresent {
                guard let aspectRatioIDC = reader.readBits(8) else { return nil }
                if aspectRatioIDC == 255 {
                    guard let width = reader.readBits(16), let height = reader.readBits(16) else { return nil }
                    vui.aspectRatio = AspectRatio(idc: UInt8(aspectRatioIDC), sarWidth: UInt16(width), sarHeight: UInt16(height))
                } else {
                    vui.aspectRatio = AspectRatio(idc: UInt8(aspectRatioIDC), sarWidth: nil, sarHeight: nil)
                }
            }

            guard let overscanPresent = reader.readBit() else { return nil }
            if overscanPresent {
                guard let flag = reader.readBit() else { return nil }
                vui.overscanAppropriateFlag = flag
            }

            guard let videoSignalPresent = reader.readBit() else { return nil }
            if videoSignalPresent {
                guard let videoFormat = reader.readBits(3),
                      let fullRange = reader.readBit(),
                      let colourDescriptionPresent = reader.readBit() else { return nil }
                var colourPrimaries: UInt8?
                var transferCharacteristics: UInt8?
                var matrixCoefficients: UInt8?
                if colourDescriptionPresent {
                    guard let cp = reader.readBits(8), let tc = reader.readBits(8), let mc = reader.readBits(8) else { return nil }
                    colourPrimaries = UInt8(cp)
                    transferCharacteristics = UInt8(tc)
                    matrixCoefficients = UInt8(mc)
                }
                vui.videoSignal = VideoSignal(videoFormat: UInt8(videoFormat),
                                              fullRangeFlag: fullRange,
                                              colourPrimaries: colourPrimaries,
                                              transferCharacteristics: transferCharacteristics,
                                              matrixCoefficients: matrixCoefficients)
            }

            guard let chromaLocPresent = reader.readBit() else { return nil }
            if chromaLocPresent {
                guard let top = reader.readUE(), let bottom = reader.readUE() else { return nil }
                vui.chromaLoc = ChromaLoc(topField: top, bottomField: bottom)
            }

            guard let timingInfoPresent = reader.readBit() else { return nil }
            vui.timingInfoPresentFlag = timingInfoPresent
            if timingInfoPresent {
                guard let numUnitsInTick = reader.readBits(32),
                      let timeScale = reader.readBits(32),
                      let fixedFrameRateFlag = reader.readBit() else { return nil }
                vui.numUnitsInTick = UInt32(numUnitsInTick)
                vui.timeScale = UInt32(timeScale)
                vui.fixedFrameRateFlag = fixedFrameRateFlag
            }

            guard let nalHRDPresent = reader.readBit() else { return nil }
            if nalHRDPresent {
                guard let hrd = HRDParameters.read(from: &reader) else { return nil }
                vui.nalHRD = hrd
            }

            guard let vclHRDPresent = reader.readBit() else { return nil }
            if vclHRDPresent {
                guard let hrd = HRDParameters.read(from: &reader) else { return nil }
                vui.vclHRD = hrd
            }

            if vui.nalHRD != nil || vui.vclHRD != nil {
                guard let lowDelay = reader.readBit() else { return nil }
                vui.lowDelayHRDFlag = lowDelay
            }

            guard let picStructPresent = reader.readBit(),
                  let bitstreamRestrictionPresent = reader.readBit() else { return nil }
            vui.picStructPresentFlag = picStructPresent

            if bitstreamRestrictionPresent {
                guard let motionVectors = reader.readBit(),
                      let maxBytesPerPicDenom = reader.readUE(),
                      let maxBitsPerMBDenom = reader.readUE(),
                      let log2MaxMVLengthHorizontal = reader.readUE(),
                      let log2MaxMVLengthVertical = reader.readUE(),
                      let maxNumReorderFrames = reader.readUE(),
                      let maxDecFrameBuffering = reader.readUE() else { return nil }
                vui.bitstreamRestriction = BitstreamRestriction(motionVectorsOverPicBoundariesFlag: motionVectors,
                                                               maxBytesPerPicDenom: maxBytesPerPicDenom,
                                                               maxBitsPerMBDenom: maxBitsPerMBDenom,
                                                               log2MaxMVLengthHorizontal: log2MaxMVLengthHorizontal,
                                                               log2MaxMVLengthVertical: log2MaxMVLengthVertical,
                                                               maxNumReorderFrames: maxNumReorderFrames,
                                                               maxDecFrameBuffering: maxDecFrameBuffering)
            }

            return vui
        }

        func write(to writer: inout BitWriter) {
            writer.writeBit(aspectRatio != nil)
            if let aspectRatio {
                writer.writeBits(UInt(aspectRatio.idc), count: 8)
                if aspectRatio.idc == 255 {
                    writer.writeBits(UInt(aspectRatio.sarWidth ?? 1), count: 16)
                    writer.writeBits(UInt(aspectRatio.sarHeight ?? 1), count: 16)
                }
            }

            writer.writeBit(overscanAppropriateFlag != nil)
            if let overscanAppropriateFlag {
                writer.writeBit(overscanAppropriateFlag)
            }

            writer.writeBit(videoSignal != nil)
            if let videoSignal {
                writer.writeBits(UInt(videoSignal.videoFormat), count: 3)
                writer.writeBit(videoSignal.fullRangeFlag)
                let hasColourDescription = videoSignal.colourPrimaries != nil && videoSignal.transferCharacteristics != nil && videoSignal.matrixCoefficients != nil
                writer.writeBit(hasColourDescription)
                if hasColourDescription {
                    writer.writeBits(UInt(videoSignal.colourPrimaries ?? 2), count: 8)
                    writer.writeBits(UInt(videoSignal.transferCharacteristics ?? 2), count: 8)
                    writer.writeBits(UInt(videoSignal.matrixCoefficients ?? 2), count: 8)
                }
            }

            writer.writeBit(chromaLoc != nil)
            if let chromaLoc {
                writer.writeUE(chromaLoc.topField)
                writer.writeUE(chromaLoc.bottomField)
            }

            writer.writeBit(timingInfoPresentFlag)
            if timingInfoPresentFlag {
                writer.writeBits(UInt(numUnitsInTick), count: 32)
                writer.writeBits(UInt(timeScale), count: 32)
                writer.writeBit(fixedFrameRateFlag)
            }

            writer.writeBit(nalHRD != nil)
            nalHRD?.write(to: &writer)
            writer.writeBit(vclHRD != nil)
            vclHRD?.write(to: &writer)

            if nalHRD != nil || vclHRD != nil {
                writer.writeBit(lowDelayHRDFlag ?? false)
            }

            writer.writeBit(picStructPresentFlag)
            writer.writeBit(bitstreamRestriction != nil)
            bitstreamRestriction?.write(to: &writer)
        }
    }

    private struct AspectRatio {
        let idc: UInt8
        let sarWidth: UInt16?
        let sarHeight: UInt16?
    }

    private struct VideoSignal {
        let videoFormat: UInt8
        let fullRangeFlag: Bool
        let colourPrimaries: UInt8?
        let transferCharacteristics: UInt8?
        let matrixCoefficients: UInt8?
    }

    private struct ChromaLoc {
        let topField: UInt
        let bottomField: UInt
    }

    private struct HRDParameters {
        let cpbCntMinus1: UInt
        let bitRateScale: UInt8
        let cpbSizeScale: UInt8
        let schedSel: [SchedSel]
        let initialCPBRemovalDelayLengthMinus1: UInt8
        let cpbRemovalDelayLengthMinus1: UInt8
        let dpbOutputDelayLengthMinus1: UInt8
        let timeOffsetLength: UInt8

        struct SchedSel {
            let bitRateValueMinus1: UInt
            let cpbSizeValueMinus1: UInt
            let cbrFlag: Bool
        }

        static func read(from reader: inout BitReader) -> HRDParameters? {
            guard let cpbCntMinus1 = reader.readUE(),
                  let bitRateScale = reader.readBits(4),
                  let cpbSizeScale = reader.readBits(4) else { return nil }
            var schedSel: [SchedSel] = []
            for _ in 0...cpbCntMinus1 {
                guard let bitRateValueMinus1 = reader.readUE(),
                      let cpbSizeValueMinus1 = reader.readUE(),
                      let cbrFlag = reader.readBit() else { return nil }
                schedSel.append(SchedSel(bitRateValueMinus1: bitRateValueMinus1,
                                         cpbSizeValueMinus1: cpbSizeValueMinus1,
                                         cbrFlag: cbrFlag))
            }
            guard let initial = reader.readBits(5),
                  let removal = reader.readBits(5),
                  let output = reader.readBits(5),
                  let timeOffset = reader.readBits(5) else { return nil }
            return HRDParameters(cpbCntMinus1: cpbCntMinus1,
                                 bitRateScale: UInt8(bitRateScale),
                                 cpbSizeScale: UInt8(cpbSizeScale),
                                 schedSel: schedSel,
                                 initialCPBRemovalDelayLengthMinus1: UInt8(initial),
                                 cpbRemovalDelayLengthMinus1: UInt8(removal),
                                 dpbOutputDelayLengthMinus1: UInt8(output),
                                 timeOffsetLength: UInt8(timeOffset))
        }

        func write(to writer: inout BitWriter) {
            writer.writeUE(cpbCntMinus1)
            writer.writeBits(UInt(bitRateScale), count: 4)
            writer.writeBits(UInt(cpbSizeScale), count: 4)
            for entry in schedSel {
                writer.writeUE(entry.bitRateValueMinus1)
                writer.writeUE(entry.cpbSizeValueMinus1)
                writer.writeBit(entry.cbrFlag)
            }
            writer.writeBits(UInt(initialCPBRemovalDelayLengthMinus1), count: 5)
            writer.writeBits(UInt(cpbRemovalDelayLengthMinus1), count: 5)
            writer.writeBits(UInt(dpbOutputDelayLengthMinus1), count: 5)
            writer.writeBits(UInt(timeOffsetLength), count: 5)
        }
    }

    private struct BitstreamRestriction {
        let motionVectorsOverPicBoundariesFlag: Bool
        let maxBytesPerPicDenom: UInt
        let maxBitsPerMBDenom: UInt
        let log2MaxMVLengthHorizontal: UInt
        let log2MaxMVLengthVertical: UInt
        let maxNumReorderFrames: UInt
        let maxDecFrameBuffering: UInt

        func write(to writer: inout BitWriter) {
            writer.writeBit(motionVectorsOverPicBoundariesFlag)
            writer.writeUE(maxBytesPerPicDenom)
            writer.writeUE(maxBitsPerMBDenom)
            writer.writeUE(log2MaxMVLengthHorizontal)
            writer.writeUE(log2MaxMVLengthVertical)
            writer.writeUE(maxNumReorderFrames)
            writer.writeUE(maxDecFrameBuffering)
        }
    }

    private struct BitReader {
        let data: Data
        var bitOffset: Int = 0

        mutating func readBit() -> Bool? {
            guard let value = readBits(1) else { return nil }
            return value == 1
        }

        mutating func readBits(_ count: Int) -> UInt? {
            guard count >= 0, bitOffset + count <= data.count * 8 else { return nil }
            var value: UInt = 0
            for _ in 0..<count {
                let byteIndex = bitOffset / 8
                let bitIndex = 7 - (bitOffset % 8)
                value = (value << 1) | UInt((data[byteIndex] >> bitIndex) & 0x01)
                bitOffset += 1
            }
            return value
        }

        mutating func readUE() -> UInt? {
            var zeroCount = 0
            while let bit = readBit() {
                if bit { break }
                zeroCount += 1
            }
            guard zeroCount < 32 else { return nil }
            let suffix = zeroCount > 0 ? (readBits(zeroCount) ?? 0) : 0
            return ((1 << zeroCount) - 1) + suffix
        }

        mutating func readSE() -> Int? {
            guard let codeNum = readUE() else { return nil }
            let magnitude = Int((codeNum + 1) / 2)
            return codeNum % 2 == 0 ? -magnitude : magnitude
        }
    }

    private struct BitWriter {
        private(set) var data = Data()
        private var currentByte: UInt8 = 0
        private var bitsInCurrentByte = 0

        mutating func writeBit(_ value: Bool) {
            currentByte = (currentByte << 1) | (value ? 1 : 0)
            bitsInCurrentByte += 1
            if bitsInCurrentByte == 8 {
                data.append(currentByte)
                currentByte = 0
                bitsInCurrentByte = 0
            }
        }

        mutating func writeBits(_ value: UInt, count: Int) {
            guard count > 0 else { return }
            for shift in stride(from: count - 1, through: 0, by: -1) {
                writeBit(((value >> shift) & 1) == 1)
            }
        }

        mutating func writeUE(_ value: UInt) {
            let codeNum = value + 1
            let bitCount = max(1, Int(UInt.bitWidth - codeNum.leadingZeroBitCount))
            for _ in 0..<(bitCount - 1) {
                writeBit(false)
            }
            writeBits(codeNum, count: bitCount)
        }

        mutating func writeSE(_ value: Int) {
            let codeNum: UInt = value <= 0 ? UInt(-value * 2) : UInt(value * 2 - 1)
            writeUE(codeNum)
        }

        mutating func writeRBSPTrailingBits() {
            writeBit(true)
            while bitsInCurrentByte != 0 {
                writeBit(false)
            }
        }
    }
}

private struct AACConfig {
    let sampleRateIndex: Int
    let channelConfig: Int

    private static let sampleRates: [Int] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    var sampleRate: Int {
        guard AACConfig.sampleRates.indices.contains(sampleRateIndex) else { return 44100 }
        return AACConfig.sampleRates[sampleRateIndex]
    }

    var audioHeaderByte: UInt8 {
        let soundRateBits: UInt8
        switch sampleRateIndex {
        case 0, 1, 2, 3, 4: soundRateBits = 3 // 48k/44.1k
        case 5, 6, 7, 8: soundRateBits = 2    // 32k/24k/22k/16k -> 22k 档
        case 9, 10, 11, 12: soundRateBits = 1 // 12k/11k/8k/7.35k -> 11k 档
        default: soundRateBits = 3
        }
        // FLV SoundFormat(10=AAC) | SoundRate(44/22/11/5.5) | SoundSize(16bit=1) | SoundType(stereo=1)
        let soundType: UInt8 = channelConfig > 1 ? 1 : 0
        let soundSize: UInt8 = 1
        return 0xA0 | (soundRateBits << 2) | (soundSize << 1) | soundType
    }

    static func parse(asc: Data) -> AACConfig? {
        guard asc.count >= 2 else { return nil }
        let byte1 = asc[0]
        let byte2 = asc[1]
        let freqIndex = Int(((byte1 & 0x07) << 1) | (byte2 >> 7))
        let channelConfig = Int((byte2 >> 3) & 0x0F)
        return AACConfig(sampleRateIndex: freqIndex, channelConfig: channelConfig)
    }
}

private extension CMTime {
    var rtmpTimestamp: UInt32 {
        let ms = Int64(CMTimeGetSeconds(self) * 1000.0)
        return UInt32(max(0, ms))
    }

    var isNumeric: Bool {
        if self == .invalid || self == .indefinite { return false }
        let secs = CMTimeGetSeconds(self)
        return secs.isFinite && !secs.isNaN
    }

    var milliseconds: Int64 {
        let t = CMTimeConvertScale(self, timescale: 1000, method: .roundHalfAwayFromZero)
        return Int64(t.value)
    }
}

// MARK: - Timestamp Normalization

private enum MediaKind {
    case audio
    case video
}

/// 统一/修复音视频时间戳：
/// - ReplayKit 的 audio/video PTS 可能来自不同 timebase（一个像 uptime，一个从 0 开始），直接相减会出现 UInt32 wrap。
/// - 某些服务端/封装器要求输入整体时间戳严格单调递增，否则会出现 "backward in time" 并丢弃分片。
private final class TimestampNormalizer {
    private var basePtsMsByKind: [MediaKind: Int64] = [:]
    private var offsetMsByKind: [MediaKind: Int64] = [:]
    private var lastOutMsByKind: [MediaKind: Int64] = [:]
    private var maxAssignedMs: Int64 = -1
    private var logged: Bool = false
    private let resumeResyncThresholdMs: Int64 = 1200

    func reset() {
        basePtsMsByKind.removeAll(keepingCapacity: true)
        offsetMsByKind.removeAll(keepingCapacity: true)
        lastOutMsByKind.removeAll(keepingCapacity: true)
        maxAssignedMs = -1
        logged = false
    }

    func timestamp(for pts: CMTime, kind: MediaKind) -> UInt32 {
        // 核心策略：
        // 1) 各轨道分别以首帧 PTS 为基准保留自己的原始时间节奏。
        // 2) 启动阶段不要按“编码输出到达先后”强行把后到轨道推迟，否则会把编码延迟误当成 A/V 时差。
        // 3) 仅对“同轨道内部”做单调保护；真正的跨轨重排交给上层 reorder window。
        // 4) 只有长时间空闲后的恢复场景，才重新把落后轨道拉回当前公共时间线。

        let relMs: Int64
        if pts.isNumeric {
            let ptsMs = pts.milliseconds
            if basePtsMsByKind[kind] == nil {
                basePtsMsByKind[kind] = ptsMs
            }
            let base = basePtsMsByKind[kind] ?? ptsMs
            relMs = ptsMs - base
        } else {
            // 极少数情况下 PTS 无效：按同轨道继续推进，至少保证不回退。
            relMs = max(0, (lastOutMsByKind[kind] ?? maxAssignedMs) + 1)
        }

        if offsetMsByKind[kind] == nil {
            // 首次出现时直接从各自 0 基准起步，避免把队列/编码延迟固化成 A/V 偏移。
            // 启动阶段短暂的先后到达由上层 pendingTags + reorderWindowMs 负责重排。
            offsetMsByKind[kind] = 0
            if !logged {
                logged = true
                SharedLogger.log("RTMP 时间戳归一化: basePtsMsByKind=\(basePtsMsByKind) offsetMsByKind=\(offsetMsByKind)")
            }
        }

        var outMs = relMs + (offsetMsByKind[kind] ?? 0)
        if let last = lastOutMsByKind[kind], maxAssignedMs > last {
            let idleGap = maxAssignedMs - last
            let lagBehindTimeline = maxAssignedMs - outMs
            if idleGap >= resumeResyncThresholdMs && lagBehindTimeline >= resumeResyncThresholdMs {
                let shift = lagBehindTimeline
                offsetMsByKind[kind] = (offsetMsByKind[kind] ?? 0) + shift
                outMs += shift
                SharedLogger.log("RTMP 时间戳恢复对齐: kind=\(kind) idle=\(idleGap) lag=\(lagBehindTimeline) shift=\(shift)")
            }
        }
        if let last = lastOutMsByKind[kind], outMs <= last {
            outMs = last + 1
        }
        if outMs < 0 { outMs = 0 }
        lastOutMsByKind[kind] = outMs
        if outMs > maxAssignedMs { maxAssignedMs = outMs }

        return outMs >= Int64(UInt32.max) ? UInt32.max : UInt32(outMs)
    }
}
