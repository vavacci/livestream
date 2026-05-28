import ReplayKit
import CoreMedia
import Darwin

private enum LiveStreamDarwinSignal {
    static let started = "com.xxx.livestream.broadcast.started"
    static let pipelineStarted = "com.xxx.livestream.broadcast.pipelineStarted"
    static let firstVideo = "com.xxx.livestream.broadcast.firstVideo"
    static let firstAppAudio = "com.xxx.livestream.broadcast.firstAppAudio"
    static let firstMicAudio = "com.xxx.livestream.broadcast.firstMicAudio"
    static let heartbeat = "com.xxx.livestream.broadcast.heartbeat"
    static let finished = "com.xxx.livestream.broadcast.finished"
    static let failed = "com.xxx.livestream.broadcast.failed"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

/// 注意：该文件应加入 Broadcast Extension 目标（*.appex）
final class BroadcastSampleHandler: RPBroadcastSampleHandler {
    private enum DebugKey {
        static let startedAt = "broadcast.debug.startedAt"
        static let pipelineStartedAt = "broadcast.debug.pipelineStartedAt"
        static let firstVideoAt = "broadcast.debug.firstVideoAt"
        static let firstAppAudioAt = "broadcast.debug.firstAppAudioAt"
        static let firstMicAudioAt = "broadcast.debug.firstMicAudioAt"
        static let finishedAt = "broadcast.debug.finishedAt"
        static let finishReason = "broadcast.debug.finishReason"
        static let lastStage = "broadcast.debug.lastStage"
    }

    private let pipeline = RealtimePipeline()
    private let startupQueue = DispatchQueue(label: "broadcast.startup.queue", qos: .userInitiated)
    private var lastCheckTs: CFAbsoluteTime = 0
    private var lastHeartbeatTs: CFAbsoluteTime = 0
    private var loggedFirstVideo = false
    private var loggedFirstAppAudio = false
    private var loggedFirstMicAudio = false
    private var loggedAudioDisabled = false
    private var isPipelineRunning = false
    private var isFinishing = false
    private var activeAppGroupID = LiveStreamConfig.AppGroup.currentID(refresh: true)

    override init() {
        super.init()
        SharedLogger.log("BroadcastSampleHandler 已实例化")
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        activeAppGroupID = LiveStreamConfig.AppGroup.currentID(refresh: true)
        LiveStreamConfig.AppGroup.select(activeAppGroupID)
        let defaults = UserDefaults(suiteName: appGroupID)
        let startedAt = Date().timeIntervalSince1970
        defaults?.set(startedAt, forKey: DebugKey.startedAt)
        defaults?.removeObject(forKey: DebugKey.pipelineStartedAt)
        defaults?.removeObject(forKey: DebugKey.firstVideoAt)
        defaults?.removeObject(forKey: DebugKey.firstAppAudioAt)
        defaults?.removeObject(forKey: DebugKey.firstMicAudioAt)
        defaults?.removeObject(forKey: DebugKey.finishedAt)
        defaults?.set("", forKey: DebugKey.finishReason)
        defaults?.set("broadcast_started", forKey: DebugKey.lastStage)
        defaults?.set(true, forKey: "recording.isRunning")
        defaults?.set(false, forKey: "cmd_stop_recording")
        defaults?.set("", forKey: "recording.lastError")
        defaults?.synchronize()
        LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.started)
        SharedLogger.clear()
        SharedLogger.log("直播扩展已启动")
        logMemory("broadcast_started")
        SharedLogger.log("开始注册停止通知")
        
        // 注册 Darwin 级别的系统通知，用于接收无 UI 的后台关闭指令
        let notificationName = "com.xxx.livestream.stopBroadcast" as CFString
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let handler = Unmanaged<BroadcastSampleHandler>.fromOpaque(observer).takeUnretainedValue()
                handler.handleStopNotification()
            },
            notificationName,
            nil,
            .deliverImmediately
        )

        SharedLogger.log("停止通知注册完成，异步启动 Pipeline")
        startupQueue.async { [weak self] in
            guard let self else { return }
            let defaults = UserDefaults(suiteName: self.appGroupID)
            defaults?.set("pipeline_starting", forKey: DebugKey.lastStage)
            defaults?.synchronize()
            SharedLogger.log("进入异步启动阶段")
            self.pipeline.onError = { [weak self] error in
                DispatchQueue.main.async {
                    self?.requestFinish(error)
                }
            }
            self.pipeline.start()
            self.isPipelineRunning = true
            defaults?.set(Date().timeIntervalSince1970, forKey: DebugKey.pipelineStartedAt)
            defaults?.set("pipeline_started", forKey: DebugKey.lastStage)
            defaults?.synchronize()
            LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.pipelineStarted)
            SharedLogger.log("RealtimePipeline 已启动")
            self.logMemory("pipeline_started")
        }
        startupQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.isFinishing == false else { return }
            let defaults = UserDefaults(suiteName: self.appGroupID)
            defaults?.set("alive_after_1s", forKey: DebugKey.lastStage)
            defaults?.synchronize()
            SharedLogger.log("扩展启动后 1s 仍存活，pipelineRunning=\(self.isPipelineRunning)")
            self.logMemory("alive_after_1s")
        }
    }

    private func handleStopNotification() {
        SharedLogger.log("收到 Darwin 停止通知")
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set("stop_notification_received", forKey: DebugKey.lastStage)
        defaults?.set(false, forKey: "cmd_stop_recording")
        defaults?.synchronize()
        
        requestFinish(nil)
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {}

    override func broadcastFinished() {
        SharedLogger.log("broadcastFinished 回调")
        isFinishing = true
        if isPipelineRunning {
            pipeline.stop()
            isPipelineRunning = false
        }
        
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName("com.xxx.livestream.stopBroadcast" as CFString),
            nil
        )

        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set("broadcast_finished", forKey: DebugKey.lastStage)
        defaults?.set(Date().timeIntervalSince1970, forKey: DebugKey.finishedAt)
        defaults?.set("broadcastFinished", forKey: DebugKey.finishReason)
        defaults?.set(false, forKey: "recording.isRunning")
        defaults?.synchronize()
        LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.finished)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                       with sampleBufferType: RPSampleBufferType) {
        
        // 轮询检查是否需要停止录屏
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastHeartbeatTs >= 1.0 {
            lastHeartbeatTs = now
            let defaults = UserDefaults(suiteName: appGroupID)
            defaults?.set("heartbeat", forKey: DebugKey.lastStage)
            defaults?.synchronize()
            LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.heartbeat)
        }
        if now - lastCheckTs >= 1.0 {
            lastCheckTs = now
            let defaults = UserDefaults(suiteName: appGroupID)
            if defaults?.bool(forKey: "cmd_stop_recording") == true {
                // 清除标志位
                defaults?.set(false, forKey: "cmd_stop_recording")
                defaults?.synchronize()
                
                // 抛出错误以结束系统的录屏进程

                SharedLogger.log("轮询检测到停止标志")
                defaults?.set("stop_flag_detected", forKey: DebugKey.lastStage)
                defaults?.synchronize()
                requestFinish(nil)
                return
            }
        }
        
        switch sampleBufferType {
        case .video:
            if !loggedFirstVideo {
                loggedFirstVideo = true
                let defaults = UserDefaults(suiteName: appGroupID)
                defaults?.set(Date().timeIntervalSince1970, forKey: DebugKey.firstVideoAt)
                defaults?.set("first_video_received", forKey: DebugKey.lastStage)
                defaults?.synchronize()
                LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.firstVideo)
                SharedLogger.log("收到首个视频 sample")
                logMemory("first_video_sample")
                if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    let dims = CMVideoFormatDescriptionGetDimensions(fmt)
                    let pixelFmt = CMFormatDescriptionGetMediaSubType(fmt)
                    SharedLogger.log("首个视频 sample 源尺寸=\(dims.width)x\(dims.height) pixelFmt=\(pixelFmt)")
                }
            }
            pipeline.handleVideo(sampleBuffer)
        case .audioApp:
            if LiveStreamConfig.RTMP.isAudioPushDisabled {
                if !loggedAudioDisabled {
                    loggedAudioDisabled = true
                    SharedLogger.log("音频默认关闭，跳过 App/Mic 音频采集与推送")
                }
                return
            }
            if !loggedFirstAppAudio {
                loggedFirstAppAudio = true
                let defaults = UserDefaults(suiteName: appGroupID)
                defaults?.set(Date().timeIntervalSince1970, forKey: DebugKey.firstAppAudioAt)
                defaults?.set("first_app_audio_received", forKey: DebugKey.lastStage)
                defaults?.synchronize()
                LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.firstAppAudio)
                SharedLogger.log("收到首个 App 音频 sample")
            }
            pipeline.handleAppAudio(sampleBuffer)
        case .audioMic:
            if LiveStreamConfig.RTMP.isAudioPushDisabled {
                if !loggedAudioDisabled {
                    loggedAudioDisabled = true
                    SharedLogger.log("音频默认关闭，跳过 App/Mic 音频采集与推送")
                }
                return
            }
            if !loggedFirstMicAudio {
                loggedFirstMicAudio = true
                let defaults = UserDefaults(suiteName: appGroupID)
                defaults?.set(Date().timeIntervalSince1970, forKey: DebugKey.firstMicAudioAt)
                defaults?.set("first_mic_audio_received", forKey: DebugKey.lastStage)
                defaults?.synchronize()
                LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.firstMicAudio)
                SharedLogger.log("收到首个 Mic 音频 sample")
            }
            pipeline.handleMicAudio(sampleBuffer)
        @unknown default:
            break
        }
    }

    override func finishBroadcastWithError(_ error: Error?) {
        isFinishing = true
        SharedLogger.log("录像结束. Error: \(String(describing: error))")
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set("finish_with_error_called", forKey: DebugKey.lastStage)
        defaults?.set(Date().timeIntervalSince1970, forKey: DebugKey.finishedAt)
        defaults?.set(false, forKey: "recording.isRunning")
        if let err = error {
            defaults?.set(err.localizedDescription, forKey: "recording.lastError")
            defaults?.set(err.localizedDescription, forKey: DebugKey.finishReason)
            defaults?.synchronize()
            LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.failed)
            super.finishBroadcastWithError(err)
        } else {
            defaults?.set("正常停止", forKey: "recording.lastError")
            defaults?.set("normal_stop", forKey: DebugKey.finishReason)
            defaults?.synchronize()
            LiveStreamDarwinSignal.post(LiveStreamDarwinSignal.finished)
            super.finishBroadcastWithError(NSError(domain: "com.xxx.livestream.broadcast", code: 0, userInfo: nil))
        }
    }

    private func requestFinish(_ error: Error?) {
        guard isFinishing == false else { return }
        finishBroadcastWithError(error)
    }

    private func logMemory(_ stage: String) {
        // Broadcast Upload Extension 内存上限约 50MB，超限会被系统直接 jetsam 杀掉。
        // 在关键阶段记录 resident 内存，用于判断 iOS15 是否在启动阶段就被内存压垮。
        SharedLogger.log("MEM stage=\(stage) resident=\(Self.currentResidentMemoryMB())MB")
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

    private var appGroupID: String {
        activeAppGroupID
    }
}
