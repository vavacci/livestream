import Foundation
import CoreMedia
import AudioToolbox
import Darwin

final class RealtimePipeline {
    var onError: ((Error) -> Void)?
    private let videoEncoder = H264Encoder()
    private let audioEncoder = AACEncoder()
    /// 测试阶段：先落盘保存（FLV）。需要推流时改回 RTMPUploader。
    private let uploader: StreamUploader = RTMPUploader()

    private let videoQueue = DispatchQueue(label: "capture.video.queue")
    private let audioQueue = DispatchQueue(label: "capture.audio.queue")
    private let diagnosticsLock = NSLock()
    private let audioInflightLock = NSLock()
    // Reuse PCM slots to avoid per-sample malloc/free on the hot path.
    // slotCount is slightly larger than audioInflightDropThreshold to tolerate short bursts.
    private let audioPCMPool = PCMBufferPool(slotCount: 32, initialSlotCapacity: 16_384)
    private let silencePCMPool = PCMBufferPool(slotCount: 4, initialSlotCapacity: 8_192)

    // Silence synthesis: when the audio source goes idle, emit zero-PCM packets at
    // packet cadence so the AAC encoder timeline stays continuous and the player
    // never sees a PTS jump. See iOS15/16 stutter investigation.
    private let silenceTimerQueue = DispatchQueue(label: "audio.silence.timer.queue")
    private let silenceLock = NSLock()
    private var silenceTimer: DispatchSourceTimer?
    private var silenceASBD: AudioStreamBasicDescription?
    private var silenceNextPTS: CMTime?
    private var lastRealAudioInputAt: CFAbsoluteTime = 0
    private let silencePacketFrames: Int = 1024
    private let silenceTickIntervalMs: Int = 40
    private let silenceGapStartMs: Double = 80
    private let silenceMaxEmitPerTick: Int = 6
    private var silenceLifetimeEmitted: Int = 0
    private var silenceWindowEmitted: Int = 0
    private var silenceWindowStart: CFAbsoluteTime = 0

    private var sawAppAudio: Bool = false
    private var firstSendAudioAt: Double = 0
    private var sendAudioCount: Int = 0
    private var lastAppAudioSampleAt: CFAbsoluteTime = 0
    private var lastMicAudioSampleAt: CFAbsoluteTime = 0
    private var lastAudioEncodedAt: CFAbsoluteTime = 0
    private var lastAudioSentAt: CFAbsoluteTime = 0
    private var audioDiagWindowStart: CFAbsoluteTime = 0
    private var audioDiagAppSampleCount: Int = 0
    private var audioDiagMicSampleCount: Int = 0
    private var audioDiagEncodedCount: Int = 0
    private var audioDiagSentCount: Int = 0
    private var peakResidentMemoryMB: UInt64 = 0
    private var rtmpAudioStatWindowStart: CFAbsoluteTime = 0
    private var rtmpAudioSentCount: Int = 0
    private var rtmpAudioSentLastTs: Int = 0
    private var audioQueueWindowStart: CFAbsoluteTime = 0
    private var audioQueueEnqueuedCount: Int = 0
    private var audioQueueProcessedCount: Int = 0
    private var audioQueueDroppedCount: Int = 0
    private var audioQueueMaxWaitMs: Double = 0
    private var audioQueueMaxWorkMs: Double = 0
    private var audioSendDetailLogCount: Int = 0
    private var audioInflightCount: Int = 0
    private let audioInflightDropThreshold: Int = 30

    // Video perf stats (aggregated per 1s to avoid log spam).
    private var videoPerfWindowStart: CFAbsoluteTime = 0
    private var videoPerfEnqueuedCount: Int = 0
    private var videoPerfProcessedCount: Int = 0
    private var videoPerfMaxWaitMs: Double = 0
    private var videoPerfMaxEncodeMs: Double = 0
    private var videoPerfSendCount: Int = 0
    private var videoPerfMaxSendMs: Double = 0
    private var videoPerfSpikeLogCount: Int = 0

    func start() {
        SharedLogger.log("准备启动上传器与编码器")
        firstSendAudioAt = 0
        sendAudioCount = 0
        resetAudioDiagnostics()
        resetSilenceState()
        startSilenceFiller()
        SharedDiagnostics.update([
            "diag.pipeline.firstSendAudioAt": 0,
            "diag.pipeline.sendAudioCount": 0,
            "diag.pipeline.audioPushDisabled": LiveStreamConfig.RTMP.isAudioPushDisabled
        ])
        uploader.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.onError?(error)
            }
        }
        videoEncoder.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.onError?(error)
            }
        }
        audioEncoder.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.onError?(error)
            }
        }
        uploader.start()
        if let uploader = uploader as? RTMPUploader {
            uploader.onAudioStats = { [weak self] count, lastTs in
                self?.noteRTMPAudioSent(count: count, lastTs: lastTs)
            }
        }
        videoEncoder.start { [weak self] frame in
            guard let self else { return }
            let sendStart = CFAbsoluteTimeGetCurrent()
            self.uploader.sendVideo(data: frame.data,
                                    pts: frame.pts,
                                    dts: frame.dts,
                                    isKeyframe: frame.isKeyframe,
                                    sps: frame.sps,
                                    pps: frame.pps,
                                    width: frame.width,
                                    height: frame.height)
            let sendMs = max(0, (CFAbsoluteTimeGetCurrent() - sendStart) * 1000.0)
            self.recordVideoSend(workMs: sendMs)
            self.logVideoPerfIfNeeded(trigger: "send")
        }
        audioEncoder.start { [weak self] frame in
            guard let self else { return }
            self.noteAudioEncodedFrame()
            if LiveStreamConfig.RTMP.isAudioPushDisabled {
                SharedDiagnostics.update([
                    "diag.pipeline.audioPushDisabled": true
                ])
                return
            }
            self.recordAudioSend()
            self.logAudioSendDetail(frame)
            self.uploader.sendAudio(data: frame.data, pts: frame.pts, audioSpecificConfig: frame.audioSpecificConfig)
        }
        SharedLogger.log("编码器启动完成")
    }

    func stop() {
        SharedLogger.log("停止 RealtimePipeline")
        stopSilenceFiller()
        logAudioDiagnostics(force: true)
        logVideoPerfIfNeeded(trigger: "stop", force: true)
        videoEncoder.stop()
        audioEncoder.stop()
        uploader.stop()
        SharedDiagnostics.update([
            "diag.pipeline.audioPushDisabled": LiveStreamConfig.RTMP.isAudioPushDisabled
        ])
    }

    func handleVideo(_ sample: CMSampleBuffer) {
        let enqueuedAt = CFAbsoluteTimeGetCurrent()
        diagnosticsLock.withLock {
            videoPerfEnqueuedCount += 1
            if videoPerfWindowStart == 0 { videoPerfWindowStart = enqueuedAt }
        }
        videoQueue.async { [weak self] in
            guard let self else { return }
            let startAt = CFAbsoluteTimeGetCurrent()
            let waitMs = max(0, (startAt - enqueuedAt) * 1000.0)

            // Keep audio diagnostics alive even when video dominates the CPU.
            self.logAudioDiagnostics(force: false)

            let encodeStart = CFAbsoluteTimeGetCurrent()
            self.videoEncoder.encode(sample)
            let encodeMs = max(0, (CFAbsoluteTimeGetCurrent() - encodeStart) * 1000.0)

            self.recordVideoProcessed(waitMs: waitMs, encodeMs: encodeMs)
            self.logVideoPerfIfNeeded(trigger: "video")

            // Emit a sparse spike log to help root-cause rare stutters.
            if waitMs >= 80 || encodeMs >= 40 {
                self.videoPerfSpikeLogCount += 1
                if self.videoPerfSpikeLogCount <= 5 || self.videoPerfSpikeLogCount % 50 == 0 {
                    SharedLogger.log("Perf Video spike wait=\(String(format: "%.1f", waitMs))ms encode=\(String(format: "%.1f", encodeMs))ms pts=\(CMSampleBufferGetPresentationTimeStamp(sample).debugText) count=\(self.videoPerfSpikeLogCount)")
                }
            }
        }
    }

    func handleAppAudio(_ sample: CMSampleBuffer) {
        if LiveStreamConfig.RTMP.isAudioPushDisabled {
            recordAudioQueueDropped()
            logAudioQueueStatsIfNeeded(trigger: "app-disabled")
            SharedDiagnostics.update([
                "diag.pipeline.audioPushDisabled": true
            ])
            return
        }

        // Drop before extraction when overloaded, to avoid wasting CPU copying PCM.
        if audioInflightSnapshot >= audioInflightDropThreshold {
            recordAudioQueueDropped()
            logAudioQueueStatsIfNeeded(trigger: "app-overflow-pre-extract")
            return
        }

        // Extract PCM on producer thread so CMSampleBuffer can be released immediately.
        guard let extracted = audioPCMPool.extract(from: sample) else {
            recordAudioQueueDropped()
            logAudioQueueStatsIfNeeded(trigger: "app-extract-failed")
            return
        }
        noteAppAudioSample(frameCount: extracted.frameCount)
        if extracted.frameCount > 0 { sawAppAudio = true }
        noteRealAudioArrival(extracted)

        enqueueAudioWork(kind: "app") { [weak self] in
            guard let self else { return }
            if LiveStreamConfig.RTMP.isAudioPushDisabled {
                SharedDiagnostics.update([
                    "diag.pipeline.audioPushDisabled": true
                ])
                return
            }
            self.audioEncoder.encodeExtracted(extracted)
        }
    }

    func handleMicAudio(_ sample: CMSampleBuffer) {
        // 优先使用应用内音频（.audioApp）。
        // 避免把 .audioApp/.audioMic 两路不同格式的音频混喂给同一个 AAC 编码器，导致“只开头有声”。
        if LiveStreamConfig.RTMP.isAudioPushDisabled {
            recordAudioQueueDropped()
            logAudioQueueStatsIfNeeded(trigger: "mic-disabled")
            SharedDiagnostics.update([
                "diag.pipeline.audioPushDisabled": true
            ])
            return
        }

        if audioInflightSnapshot >= audioInflightDropThreshold {
            recordAudioQueueDropped()
            logAudioQueueStatsIfNeeded(trigger: "mic-overflow-pre-extract")
            return
        }

        guard let extracted = audioPCMPool.extract(from: sample) else {
            recordAudioQueueDropped()
            logAudioQueueStatsIfNeeded(trigger: "mic-extract-failed")
            return
        }

        noteMicAudioSample(frameCount: extracted.frameCount)
        // Only seed silence anchor from mic if app audio hasn't taken over (mic is the
        // active feed only while sawAppAudio is false; otherwise the closure below drops it).
        if !sawAppAudio {
            noteRealAudioArrival(extracted)
        }

        enqueueAudioWork(kind: "mic") {
            guard self.sawAppAudio == false else { return }
            if LiveStreamConfig.RTMP.isAudioPushDisabled {
                SharedDiagnostics.update([
                    "diag.pipeline.audioPushDisabled": true
                ])
                return
            }
            self.audioEncoder.encodeExtracted(extracted)
        }
    }

    private func recordAudioSend() {
        sendAudioCount += 1
        if firstSendAudioAt == 0 {
            firstSendAudioAt = Date().timeIntervalSince1970
        }
        noteAudioSent()
        SharedDiagnostics.update([
            "diag.pipeline.firstSendAudioAt": firstSendAudioAt,
            "diag.pipeline.sendAudioCount": sendAudioCount,
            "diag.pipeline.audioPushDisabled": false
        ])
    }

    private func logAudioSendDetail(_ frame: AACEncoder.EncodedFrame) {
        audioSendDetailLogCount += 1
        guard audioSendDetailLogCount <= 12 || audioSendDetailLogCount % 50 == 0 else { return }
        let ascBytes = frame.audioSpecificConfig?.count ?? 0
        SharedLogger.log("Pipeline AudioSend idx=\(audioSendDetailLogCount) pts=\(frame.pts.debugText) bytes=\(frame.data.count) asc=\(ascBytes) sendCount=\(sendAudioCount)")
    }

    private func resetAudioDiagnostics() {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        lastAppAudioSampleAt = 0
        lastMicAudioSampleAt = 0
        lastAudioEncodedAt = 0
        lastAudioSentAt = 0
        audioDiagWindowStart = 0
        audioDiagAppSampleCount = 0
        audioDiagMicSampleCount = 0
        audioDiagEncodedCount = 0
        audioDiagSentCount = 0
        peakResidentMemoryMB = 0
        rtmpAudioStatWindowStart = 0
        rtmpAudioSentCount = 0
        rtmpAudioSentLastTs = 0
        audioQueueWindowStart = 0
        audioQueueEnqueuedCount = 0
        audioQueueProcessedCount = 0
        audioQueueDroppedCount = 0
        audioQueueMaxWaitMs = 0
        audioQueueMaxWorkMs = 0
        audioSendDetailLogCount = 0
        resetAudioInflight()

        videoPerfWindowStart = 0
        videoPerfEnqueuedCount = 0
        videoPerfProcessedCount = 0
        videoPerfMaxWaitMs = 0
        videoPerfMaxEncodeMs = 0
        videoPerfSendCount = 0
        videoPerfMaxSendMs = 0
        videoPerfSpikeLogCount = 0
    }

    private func noteAppAudioSample(frameCount: Int) {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        lastAppAudioSampleAt = CFAbsoluteTimeGetCurrent()
        if frameCount > 0 {
            audioDiagAppSampleCount += 1
        }
    }

    private func noteMicAudioSample(frameCount: Int) {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        lastMicAudioSampleAt = CFAbsoluteTimeGetCurrent()
        if frameCount > 0 {
            audioDiagMicSampleCount += 1
        }
    }

    private var audioInflightSnapshot: Int {
        audioInflightLock.withLock { audioInflightCount }
    }

    private func noteAudioEncodedFrame() {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        lastAudioEncodedAt = CFAbsoluteTimeGetCurrent()
        audioDiagEncodedCount += 1
    }

    private func noteAudioSent() {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        lastAudioSentAt = CFAbsoluteTimeGetCurrent()
        audioDiagSentCount += 1
    }

    private func noteRTMPAudioSent(count: Int, lastTs: UInt32) {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        rtmpAudioSentCount += count
        rtmpAudioSentLastTs = Int(lastTs)
        if rtmpAudioStatWindowStart == 0 {
            rtmpAudioStatWindowStart = CFAbsoluteTimeGetCurrent()
        }
    }

    private func enqueueAudioWork(kind: String, work: @escaping () -> Void) {
        let inflightNow = incrementAudioInflight()
        if inflightNow > audioInflightDropThreshold {
            decrementAudioInflight()
            recordAudioQueueDropped()
            logAudioQueueStatsIfNeeded(trigger: "\(kind)-overflow")
            return
        }

        let enqueuedAt = CFAbsoluteTimeGetCurrent()
        diagnosticsLock.withLock {
            audioQueueEnqueuedCount += 1
            if audioQueueWindowStart == 0 {
                audioQueueWindowStart = enqueuedAt
            }
        }
        audioQueue.async {
            let startAt = CFAbsoluteTimeGetCurrent()
            let waitMs = max(0, (startAt - enqueuedAt) * 1000.0)
            defer { self.decrementAudioInflight() }
            work()
            let workMs = max(0, (CFAbsoluteTimeGetCurrent() - startAt) * 1000.0)
            self.recordAudioQueueProcessed(waitMs: waitMs, workMs: workMs)
            self.logAudioQueueStatsIfNeeded(trigger: kind)
        }
    }

    private func recordAudioQueueProcessed(waitMs: Double, workMs: Double) {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        audioQueueProcessedCount += 1
        audioQueueMaxWaitMs = max(audioQueueMaxWaitMs, waitMs)
        audioQueueMaxWorkMs = max(audioQueueMaxWorkMs, workMs)
    }

    private func recordAudioQueueDropped() {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        audioQueueDroppedCount += 1
        if audioQueueWindowStart == 0 {
            audioQueueWindowStart = CFAbsoluteTimeGetCurrent()
        }
    }

    private func resetAudioInflight() {
        audioInflightLock.withLock {
            audioInflightCount = 0
        }
    }

    private func incrementAudioInflight() -> Int {
        audioInflightLock.withLock {
            audioInflightCount += 1
            return audioInflightCount
        }
    }

    private func decrementAudioInflight() {
        audioInflightLock.withLock {
            if audioInflightCount > 0 {
                audioInflightCount -= 1
            }
        }
    }

    private func recordVideoProcessed(waitMs: Double, encodeMs: Double) {
        diagnosticsLock.withLock {
            videoPerfProcessedCount += 1
            videoPerfMaxWaitMs = max(videoPerfMaxWaitMs, waitMs)
            videoPerfMaxEncodeMs = max(videoPerfMaxEncodeMs, encodeMs)
        }
    }

    private func recordVideoSend(workMs: Double) {
        diagnosticsLock.withLock {
            videoPerfSendCount += 1
            videoPerfMaxSendMs = max(videoPerfMaxSendMs, workMs)
        }
    }

    private func logVideoPerfIfNeeded(trigger: String, force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        let logLine: String? = diagnosticsLock.withLock {
            if videoPerfWindowStart == 0 { videoPerfWindowStart = now }
            guard force || now - videoPerfWindowStart >= 1.0 else { return nil }
            let maxWait = String(format: "%.1f", videoPerfMaxWaitMs)
            let maxEncode = String(format: "%.1f", videoPerfMaxEncodeMs)
            let maxSend = String(format: "%.1f", videoPerfMaxSendMs)
            let residentMB = Self.currentResidentMemoryMB()
            let line = "VideoPerf 1s: trigger=\(trigger) enq=\(videoPerfEnqueuedCount) proc=\(videoPerfProcessedCount) send=\(videoPerfSendCount) maxWait=\(maxWait)ms maxEncode=\(maxEncode)ms maxSend=\(maxSend)ms mem=\(residentMB)MB"
            videoPerfWindowStart = now
            videoPerfEnqueuedCount = 0
            videoPerfProcessedCount = 0
            videoPerfSendCount = 0
            videoPerfMaxWaitMs = 0
            videoPerfMaxEncodeMs = 0
            videoPerfMaxSendMs = 0
            return line
        }
        if let logLine { SharedLogger.log(logLine) }
    }

    private func logAudioQueueStatsIfNeeded(trigger: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let logLine: String? = diagnosticsLock.withLock {
            if audioQueueWindowStart == 0 {
                audioQueueWindowStart = now
            }
            guard now - audioQueueWindowStart >= 1.0 else { return nil }
            let maxWait = String(format: "%.1f", audioQueueMaxWaitMs)
            let maxWork = String(format: "%.1f", audioQueueMaxWorkMs)
            let line = "AudioQueue 1s: trigger=\(trigger) enqueued=\(audioQueueEnqueuedCount) processed=\(audioQueueProcessedCount) dropped=\(audioQueueDroppedCount) maxWait=\(maxWait)ms maxWork=\(maxWork)ms"
            audioQueueWindowStart = now
            audioQueueEnqueuedCount = 0
            audioQueueProcessedCount = 0
            audioQueueDroppedCount = 0
            audioQueueMaxWaitMs = 0
            audioQueueMaxWorkMs = 0
            return line
        }
        if let logLine {
            SharedLogger.log(logLine)
        }
    }

    private func logAudioDiagnostics(force: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        let logLine: String? = diagnosticsLock.withLock {
            if audioDiagWindowStart == 0 {
                audioDiagWindowStart = now
            }
            guard force || now - audioDiagWindowStart >= 1.0 else { return nil }

            let appAgeMs = ageMsString(now: now, last: lastAppAudioSampleAt)
            let micAgeMs = ageMsString(now: now, last: lastMicAudioSampleAt)
            let encAgeMs = ageMsString(now: now, last: lastAudioEncodedAt)
            let sendAgeMs = ageMsString(now: now, last: lastAudioSentAt)

            let activeSource: String
            let appActive = lastAppAudioSampleAt > 0 && (now - lastAppAudioSampleAt) < 1.5
            let micActive = lastMicAudioSampleAt > 0 && (now - lastMicAudioSampleAt) < 1.5
            if appActive {
                activeSource = "app"
            } else if micActive {
                activeSource = "mic"
            } else {
                activeSource = "idle"
            }

            let residentMB = Self.currentResidentMemoryMB()
            peakResidentMemoryMB = max(peakResidentMemoryMB, residentMB)
            let micBlocked = sawAppAudio ? 1 : 0

            let line = "AudioSource 1s: active=\(activeSource) appAge=\(appAgeMs) micAge=\(micAgeMs) encAge=\(encAgeMs) sendAge=\(sendAgeMs) appSamples=\(audioDiagAppSampleCount) micSamples=\(audioDiagMicSampleCount) encoded=\(audioDiagEncodedCount) sent=\(audioDiagSentCount) rtmpAudio=\(rtmpAudioSentCount) rtmpLastTs=\(rtmpAudioSentLastTs) sawApp=\(sawAppAudio ? 1 : 0) micBlocked=\(micBlocked) mem=\(residentMB)MB peak=\(peakResidentMemoryMB)MB"

            audioDiagWindowStart = now
            audioDiagAppSampleCount = 0
            audioDiagMicSampleCount = 0
            audioDiagEncodedCount = 0
            audioDiagSentCount = 0
            rtmpAudioStatWindowStart = now
            rtmpAudioSentCount = 0
            return line
        }

        if let logLine {
            SharedLogger.log(logLine)
        }
    }

    private func ageMsString(now: CFAbsoluteTime, last: CFAbsoluteTime) -> String {
        guard last > 0 else { return "none" }
        return String(format: "%.0fms", (now - last) * 1000.0)
    }

    private static func currentResidentMemoryMB() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size) / (1024 * 1024)
    }
}

private extension RealtimePipeline {
    /// Called synchronously from the broadcast-handler thread when a real audio sample
    /// is extracted. Seeds the silence anchor so the ticker knows when audio went idle
    /// and where the next packet should logically start.
    func noteRealAudioArrival(_ extracted: ExtractedAudioSample) {
        silenceLock.lock()
        defer { silenceLock.unlock() }
        silenceASBD = extracted.asbd
        if extracted.pts.isNumeric, extracted.frameCount > 0 {
            let sr = max(1.0, extracted.asbd.mSampleRate)
            let timescale = Int32(max(1, Int(sr.rounded())))
            let frameDur = CMTime(value: Int64(extracted.frameCount), timescale: timescale)
            silenceNextPTS = extracted.pts + frameDur
        }
        lastRealAudioInputAt = CFAbsoluteTimeGetCurrent()
    }

    func resetSilenceState() {
        silenceLock.lock()
        defer { silenceLock.unlock() }
        silenceASBD = nil
        silenceNextPTS = nil
        lastRealAudioInputAt = 0
        silenceLifetimeEmitted = 0
        silenceWindowEmitted = 0
        silenceWindowStart = 0
    }

    func startSilenceFiller() {
        stopSilenceFiller()
        let timer = DispatchSource.makeTimerSource(queue: silenceTimerQueue)
        timer.schedule(deadline: .now() + .milliseconds(silenceTickIntervalMs),
                       repeating: .milliseconds(silenceTickIntervalMs),
                       leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.tickSilenceFiller()
        }
        timer.resume()
        silenceTimer = timer
    }

    func stopSilenceFiller() {
        silenceTimer?.cancel()
        silenceTimer = nil
    }

    func tickSilenceFiller() {
        if LiveStreamConfig.RTMP.isAudioPushDisabled { return }

        let snapshotASBD: AudioStreamBasicDescription?
        let snapshotNextPTS: CMTime?
        let snapshotLastInput: CFAbsoluteTime
        silenceLock.lock()
        snapshotASBD = silenceASBD
        snapshotNextPTS = silenceNextPTS
        snapshotLastInput = lastRealAudioInputAt
        silenceLock.unlock()

        guard let asbd = snapshotASBD,
              let firstNextPTS = snapshotNextPTS,
              snapshotLastInput > 0 else {
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let gapSec = now - snapshotLastInput
        let gapMs = gapSec * 1000.0
        guard gapMs >= silenceGapStartMs else { return }

        let sampleRate = max(1.0, asbd.mSampleRate)
        let packetDurSec = Double(silencePacketFrames) / sampleRate
        guard packetDurSec > 0 else { return }
        let packetsToCover = Int(gapSec / packetDurSec)
        guard packetsToCover > 0 else { return }
        let toEmit = min(packetsToCover, silenceMaxEmitPerTick)

        let timescale = Int32(max(1, Int(sampleRate.rounded())))
        let frameDur = CMTime(value: Int64(silencePacketFrames), timescale: timescale)

        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerSample: Int
        if isNonInterleaved {
            bytesPerSample = bytesPerFrame
        } else if channels > 0 {
            bytesPerSample = max(1, bytesPerFrame / channels)
        } else {
            bytesPerSample = bytesPerFrame
        }
        let totalBytes = silencePacketFrames * channels * bytesPerSample
        guard totalBytes > 0 else { return }

        var pts = firstNextPTS
        var emitted = 0
        for _ in 0..<toEmit {
            guard let silenceSample = silencePCMPool.makeZeroedSample(asbd: asbd,
                                                                     pts: pts,
                                                                     frameCount: silencePacketFrames,
                                                                     totalBytes: totalBytes) else {
                break
            }
            audioQueue.async { [weak self] in
                guard let self = self else { return }
                if LiveStreamConfig.RTMP.isAudioPushDisabled { return }
                self.audioEncoder.encodeExtracted(silenceSample)
            }
            pts = pts + frameDur
            emitted += 1
        }

        guard emitted > 0 else { return }

        var maybeLog: String? = nil
        silenceLock.lock()
        silenceNextPTS = pts
        // Advance lastRealAudioInputAt by what we covered, so subsequent ticks
        // measure gap against the last *covered* moment, not the original silence start.
        lastRealAudioInputAt = snapshotLastInput + (Double(emitted) * packetDurSec)
        silenceLifetimeEmitted += emitted
        silenceWindowEmitted += emitted
        if silenceWindowStart == 0 { silenceWindowStart = now }
        if now - silenceWindowStart >= 1.0 {
            maybeLog = "Silence 1s: emitted=\(silenceWindowEmitted) lifetime=\(silenceLifetimeEmitted) gapMs=\(Int(gapMs))"
            silenceWindowStart = now
            silenceWindowEmitted = 0
        }
        silenceLock.unlock()

        if let logLine = maybeLog {
            SharedLogger.log(logLine)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension CMTime {
    var debugText: String {
        guard isNumeric else { return "invalid" }
        return String(format: "%.3f", CMTimeGetSeconds(self))
    }
}
