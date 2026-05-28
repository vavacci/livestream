import Foundation
import Darwin
import VideoToolbox
import CoreMedia
import CoreImage

final class H264Encoder {
    struct EncodedFrame {
        let data: Data
        let pts: CMTime
        let dts: CMTime
        let isKeyframe: Bool
        let sps: Data?
        let pps: Data?
        let width: Int32
        let height: Int32
    }

    fileprivate final class FrameTimingBox {
        let pts: CMTime
        let dts: CMTime
        let enqueueWallClock: CFAbsoluteTime

        init(pts: CMTime, dts: CMTime) {
            self.pts = pts
            self.dts = dts
            self.enqueueWallClock = CFAbsoluteTimeGetCurrent()
        }
    }

    private var session: VTCompressionSession?
    fileprivate var onEncoded: ((EncodedFrame) -> Void)?
    var onError: ((Error) -> Void)?

    private let configuredWidth: Int32 = LiveStreamConfig.Video.width
    private let configuredHeight: Int32 = LiveStreamConfig.Video.height
    private let enableScaling: Bool = LiveStreamConfig.Video.enableScaling
    private let fps: Int32 = LiveStreamConfig.Video.fps
    private let bitrate: Int = LiveStreamConfig.Video.bitrate
    private let minCaptureSpacingFactor: Double = LiveStreamConfig.Video.minCaptureSpacingFactor
    private var forceKeyframeNext: Bool = true
    private var frameIndex: Int64 = 0
    private var lastCapturePTS: CMTime?
    private var lastSubmittedInputPTS: CMTime?
    private var firstSubmittedRawPTS: CMTime?
    private var lastOutputPTS: CMTime?
    private var droppedFrameCount: Int = 0
    private var lastObservedGapMs: Double = 0
    private var resumeEventCount: Int = 0
    private var lastDiagnosticsFlushTime: CFAbsoluteTime = 0
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let scaleColorSpace = CGColorSpaceCreateDeviceRGB()
    // iOS 15 走 CoreImage 缩放时的目标像素格式。
    // 之前用的是 32BGRA（全范围 RGB），喂给 VideoToolbox 后产出的是非标准 full-range/RGB-matrix H.264，
    // 而 iOS 16 的 VTPixelTransferSession 直接保留 ReplayKit 的 video-range NV12。两者格式不一致正是
    // “iOS16 能拉流、iOS15 拉不到流”的根因。这里统一改成 video-range NV12，使两条路径产出一致、标准的码流。
    private let coreImageScaleFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private var scaledPixelBufferPool: CVPixelBufferPool?
    private var scaledPixelBufferFormatType: OSType = 0
    private var pixelTransferSessionRef: CFTypeRef?
    fileprivate var loggedIDRInfoCount: Int = 0
    fileprivate var cachedSPS: Data?
    fileprivate var cachedPPS: Data?
    fileprivate var loggedNALLengthSize: Bool = false
    private var loggedScaleInfo: Bool = false
    private let resumeKeyframeGapMs: Int64 = 1200
    private let diagnosticsQueue = DispatchQueue(label: "h264.encoder.diagnostics")
    private var scaleWindowStart: CFAbsoluteTime = 0
    private var scaleWindowFrameCount: Int = 0
    private var scaleWindowTotalMs: Double = 0
    private var scaleWindowMaxMs: Double = 0
    private var scaleWindowSlowCount: Int = 0
    private var scaleWindowSourceSize: String = ""
    private var totalSubmittedFrames: Int = 0
    private var totalOutputFrames: Int = 0
    private var inputWindowStart: CFAbsoluteTime = 0
    private var inputWindowReceivedFrames: Int = 0
    private var inputWindowSubmittedFrames: Int = 0
    private var inputWindowDroppedDenseFrames: Int = 0
    private var inputWindowSourceSize: String = ""
    private var callbackWindowStart: CFAbsoluteTime = 0
    private var callbackWindowOutputFrames: Int = 0
    private var callbackWindowTotalLatencyMs: Double = 0
    private var callbackWindowMaxLatencyMs: Double = 0
    private var callbackWindowKeyframes: Int = 0
    private var lastCallbackWallClock: CFAbsoluteTime = 0
    private var lastEncodeFailureLogTime: CFAbsoluteTime = 0
    private var lastInputWallClock: CFAbsoluteTime = 0
    private var lastSubmittedWallClock: CFAbsoluteTime = 0
    private var lastInputIdleLogTime: CFAbsoluteTime = 0
    private var lastCallbackIdleLogTime: CFAbsoluteTime = 0
    private var watchdogTimer: DispatchSourceTimer?
    fileprivate var activeEncodeWidth: Int32 = 0
    fileprivate var activeEncodeHeight: Int32 = 0
    private let rebuildLock = NSLock()
    private let dropBacklogThreshold: Int = 12
    private let stallBacklogThreshold: Int = 24
    private let criticalBacklogThreshold: Int = 48
    private let stallIdleThresholdMs: Double = 1200
    private let autoRebuildCooldownSec: Double = 2.0
    private var inputWindowDroppedBacklogFrames: Int = 0
    private var pendingRebuildReason: String?
    private var lastAutoRebuildTime: CFAbsoluteTime = 0
    private var autoRebuildCount: Int = 0
    private var lastBacklogDropLogTime: CFAbsoluteTime = 0
    private var lastMemoryWarn45LogTime: CFAbsoluteTime = 0
    private var lastMemoryWarn48LogTime: CFAbsoluteTime = 0
    fileprivate var outputDetailLogCount: Int = 0

    func start(onEncoded: @escaping (EncodedFrame) -> Void) {
        self.onEncoded = onEncoded

        forceKeyframeNext = true
        frameIndex = 0
        lastCapturePTS = nil
        lastSubmittedInputPTS = nil
        firstSubmittedRawPTS = nil
        lastOutputPTS = nil
        droppedFrameCount = 0
        lastObservedGapMs = 0
        resumeEventCount = 0
        lastDiagnosticsFlushTime = 0
        scaledPixelBufferPool = nil
        scaledPixelBufferFormatType = 0
        pixelTransferSessionRef = nil
        loggedIDRInfoCount = 0
        cachedSPS = nil
        cachedPPS = nil
        loggedNALLengthSize = false
        loggedScaleInfo = false
        activeEncodeWidth = 0
        activeEncodeHeight = 0
        pendingRebuildReason = nil
        lastAutoRebuildTime = 0
        autoRebuildCount = 0
        resetPerformanceStats()
        startWatchdog()
        publishDiagnostics(force: true)

        if enableScaling {
            SharedLogger.log("H264Encoder 开始创建 VTCompressionSession")
            _ = createCompressionSession(width: configuredWidth, height: configuredHeight)
        } else {
            SharedLogger.log("H264Encoder 已关闭缩放，将在首帧按原始分辨率创建编码会话")
        }
    }

    func stop() {
        if let session = session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        onEncoded = nil
        forceKeyframeNext = true
        frameIndex = 0
        lastCapturePTS = nil
        lastSubmittedInputPTS = nil
        firstSubmittedRawPTS = nil
        lastOutputPTS = nil
        droppedFrameCount = 0
        lastObservedGapMs = 0
        resumeEventCount = 0
        lastDiagnosticsFlushTime = 0
        scaledPixelBufferPool = nil
        scaledPixelBufferFormatType = 0
        pixelTransferSessionRef = nil
        loggedIDRInfoCount = 0
        cachedSPS = nil
        cachedPPS = nil
        loggedNALLengthSize = false
        loggedScaleInfo = false
        activeEncodeWidth = 0
        activeEncodeHeight = 0
        pendingRebuildReason = nil
        lastAutoRebuildTime = 0
        autoRebuildCount = 0
        stopWatchdog()
        resetPerformanceStats()
        publishDiagnostics(force: true)
    }

    func encode(_ sample: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let sourceWidth = Int32(CVPixelBufferGetWidth(imageBuffer))
        let sourceHeight = Int32(CVPixelBufferGetHeight(imageBuffer))

        if session == nil {
            let sessionWidth = enableScaling ? configuredWidth : sourceWidth
            let sessionHeight = enableScaling ? configuredHeight : sourceHeight
            guard createCompressionSession(width: sessionWidth, height: sessionHeight) else { return }
        } else if !enableScaling,
                  (sourceWidth != activeEncodeWidth || sourceHeight != activeEncodeHeight) {
            SharedLogger.log("H264Encoder 检测到源分辨率变化，重建编码会话 src=\(sourceWidth)x\(sourceHeight) old=\(activeEncodeWidth)x\(activeEncodeHeight)")
            if LiveStreamConfig.App.enableRuntimeLogging {
                NSLog("[Suspect][Session] reconfigure src=%dx%d old=%dx%d scaling=0",
                      sourceWidth,
                      sourceHeight,
                      activeEncodeWidth,
                      activeEncodeHeight)
            }
            forceKeyframeNext = true
            guard createCompressionSession(width: sourceWidth, height: sourceHeight) else { return }
        }
        applyPendingRebuildIfNeeded(sourceWidth: sourceWidth, sourceHeight: sourceHeight)

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sample)
        recordInputArrival()
        let callbackBacklog = currentCallbackBacklog()
        let callbackIdleMs = currentCallbackIdleMs()
        if callbackBacklog >= dropBacklogThreshold {
            if callbackBacklog >= stallBacklogThreshold || callbackIdleMs >= stallIdleThresholdMs {
                requestAutoRebuild(reason: "backlog=\(callbackBacklog) callbackIdle=\(Int(callbackIdleMs.rounded()))ms")
                applyPendingRebuildIfNeeded(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
            }
            recordInputFrame(sourceWidth: Int(sourceWidth),
                             sourceHeight: Int(sourceHeight),
                             submitted: false,
                             droppedDense: false,
                             droppedBacklog: true)
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastBacklogDropLogTime >= 0.5 {
                lastBacklogDropLogTime = now
                SharedLogger.log("H264 因编码积压丢帧 backlog=\(callbackBacklog) callbackIdle=\(Int(callbackIdleMs.rounded()))ms threshold=\(dropBacklogThreshold)")
            }
            publishDiagnosticsIfNeeded()
            return
        }
        let rawGapMs: Double?
        if rawPTS.isNumeric, let lastCapturePTS, lastCapturePTS.isNumeric {
            rawGapMs = (CMTimeGetSeconds(rawPTS) - CMTimeGetSeconds(lastCapturePTS)) * 1000.0
        } else {
            rawGapMs = nil
        }
        if let rawGapMs {
            lastObservedGapMs = max(0, rawGapMs)
        }

        let spacingSinceLastSubmittedMs: Double?
        if rawPTS.isNumeric, let lastSubmittedInputPTS, lastSubmittedInputPTS.isNumeric {
            spacingSinceLastSubmittedMs = (CMTimeGetSeconds(rawPTS) - CMTimeGetSeconds(lastSubmittedInputPTS)) * 1000.0
        } else {
            spacingSinceLastSubmittedMs = nil
        }

        if let spacingSinceLastSubmittedMs,
           spacingSinceLastSubmittedMs > 0,
           spacingSinceLastSubmittedMs < minimumCaptureSpacingMs {
            droppedFrameCount += 1
            recordInputFrame(sourceWidth: Int(sourceWidth),
                             sourceHeight: Int(sourceHeight),
                             submitted: false,
                             droppedDense: true,
                             droppedBacklog: false)
            if droppedFrameCount <= 5 || droppedFrameCount % 30 == 0 {
                let formattedGap = String(format: "%.2f", spacingSinceLastSubmittedMs)
                SharedLogger.log("H264 丢弃过密视频帧 gapMs=\(formattedGap) dropped=\(droppedFrameCount)")
            }
            if rawPTS.isNumeric {
                lastCapturePTS = rawPTS
            }
            publishDiagnosticsIfNeeded()
            return
        }

        if let rawGapMs, rawGapMs >= Double(resumeKeyframeGapMs) {
            forceKeyframeNext = true
            resumeEventCount += 1
            SharedLogger.log("H264 检测到视频恢复，强制下一帧关键帧 gapMs=\(Int64(rawGapMs.rounded()))")
        }

        let pts = nextOutputPTS(rawPTS: rawPTS)
        if rawPTS.isNumeric {
            lastCapturePTS = rawPTS
            lastSubmittedInputPTS = rawPTS
        }

        guard let bufferForEncode = makeBufferForEncoding(from: imageBuffer) else {
            SharedLogger.log("H264 缩放失败，丢弃当前视频帧")
            return
        }

        recordInputFrame(sourceWidth: Int(sourceWidth),
                         sourceHeight: Int(sourceHeight),
                         submitted: true,
                         droppedDense: false,
                         droppedBacklog: false)
        encodeFrame(bufferForEncode, pts: pts, duration: nominalFrameDuration, forceKeyframe: forceKeyframeNext)
        forceKeyframeNext = false
        publishDiagnosticsIfNeeded()
    }

    private var nominalFrameDuration: CMTime {
        CMTime(value: 1, timescale: fps)
    }

    private var nominalFrameDurationMs: Double {
        1000.0 / Double(fps)
    }

    private var minimumCaptureSpacingMs: Double {
        nominalFrameDurationMs * minCaptureSpacingFactor
    }

    private func nextOutputPTS(rawPTS: CMTime) -> CMTime {
        if rawPTS.isNumeric {
            if firstSubmittedRawPTS == nil {
                firstSubmittedRawPTS = rawPTS
            }

            let base = firstSubmittedRawPTS ?? rawPTS
            var candidate = rawPTS - base
            if candidate < .zero {
                candidate = .zero
            }
            if let lastOutputPTS, CMTimeCompare(candidate, lastOutputPTS) <= 0 {
                candidate = lastOutputPTS + CMTime(value: 1, timescale: 1000)
            }
            lastOutputPTS = candidate
            return candidate
        }

        let fallback: CMTime
        if let lastOutputPTS {
            fallback = lastOutputPTS + nominalFrameDuration
        } else {
            fallback = .zero
        }
        lastOutputPTS = fallback
        return fallback
    }

    @discardableResult
    private func createCompressionSession(width: Int32, height: Int32) -> Bool {
        guard width > 0, height > 0 else { return false }
        if session != nil, activeEncodeWidth == width, activeEncodeHeight == height {
            return true
        }

        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }

        SharedLogger.log("H264Encoder 开始创建 VTCompressionSession size=\(width)x\(height) scaling=\(enableScaling ? 1 : 0)")
        if LiveStreamConfig.App.enableRuntimeLogging {
            NSLog("[Suspect][Session] create size=%dx%d scaling=%d",
                  width,
                  height,
                  enableScaling ? 1 : 0)
        }
        let status = VTCompressionSessionCreate(allocator: nil,
                                               width: width,
                                               height: height,
                                               codecType: kCMVideoCodecType_H264,
                                               encoderSpecification: nil,
                                               imageBufferAttributes: nil,
                                               compressedDataAllocator: nil,
                                               outputCallback: compressionCallback,
                                               refcon: Unmanaged.passUnretained(self).toOpaque(),
                                               compressionSessionOut: &session)

        guard status == noErr else {
            SharedLogger.log("VTCompressionSessionCreate 失败: \(status)")
            if LiveStreamConfig.App.enableRuntimeLogging {
                NSLog("[Suspect][SessionError] createStatus=%d size=%dx%d scaling=%d",
                      status,
                      width,
                      height,
                      enableScaling ? 1 : 0)
            }
            session = nil
            DispatchQueue.main.async { [weak self] in
                self?.onError?(NSError(domain: "VTCompression", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "H264Encoder 初始化失败"]))
            }
            return false
        }

        guard let session else {
            SharedLogger.log("VTCompressionSessionCreate 返回成功但 session 为空")
            if LiveStreamConfig.App.enableRuntimeLogging {
                NSLog("[Suspect][SessionError] sessionNil size=%dx%d scaling=%d",
                      width,
                      height,
                      enableScaling ? 1 : 0)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onError?(NSError(domain: "VTCompression", code: -1, userInfo: [NSLocalizedDescriptionKey: "H264Encoder 初始化失败"]))
            }
            return false
        }

        activeEncodeWidth = width
        activeEncodeHeight = height
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // 显式锁定输出色彩为标准 BT.709 video-range，使 SPS VUI 在所有 iOS 版本上一致、可被服务端/播放器正确解码。
        // iOS16 原本隐式产出的就是 709 video-range，这里固定下来不改变其行为；iOS15 配合上面 NV12 输入后也变为标准码流。
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                             value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                             value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                             value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let profileLevel = preferredProfileLevel(width: width, height: height)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: profileLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: bitrate as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: fps as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: LiveStreamConfig.Video.keyframeIntervalFrames as CFTypeRef)
        let keyframeIntervalSeconds = LiveStreamConfig.Video.keyframeIntervalSeconds
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: keyframeIntervalSeconds as CFTypeRef)
        VTCompressionSessionPrepareToEncodeFrames(session)
        SharedLogger.log("H264Encoder 启动完成 size=\(width)x\(height)")
        if LiveStreamConfig.App.enableRuntimeLogging {
            NSLog("[Suspect][Session] ready size=%dx%d scaling=%d fps=%d bitrate=%d",
                  width,
                  height,
                  enableScaling ? 1 : 0,
                  fps,
                  bitrate)
        }
        return true
    }

    private func preferredProfileLevel(width: Int32, height: Int32) -> CFString {
        if enableScaling {
            return kVTProfileLevel_H264_Baseline_3_1
        }
        // 关闭缩放后可能直接编码较高原始分辨率，固定到 3.1 容易产生“分辨率超出 level 约束”的码流，
        // 导致下游桥接/导出端兼容性变差，因此改为让 VT 按实际分辨率自动选择 level。
        if width > configuredWidth || height > configuredHeight {
            return kVTProfileLevel_H264_Baseline_AutoLevel
        }
        return kVTProfileLevel_H264_Baseline_3_1
    }

    private func encodeFrame(_ imageBuffer: CVImageBuffer,
                             pts: CMTime,
                             duration: CMTime,
                             forceKeyframe: Bool,
                             session: VTCompressionSession? = nil) {
        guard let session = session ?? self.session else { return }

        var frameProperties: CFDictionary?
        frameIndex += 1
        if forceKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }

        let timingBox = FrameTimingBox(pts: pts, dts: pts)
        let sourceFrameRefcon = Unmanaged.passRetained(timingBox).toOpaque()
        recordSubmittedFrame()

        let status = VTCompressionSessionEncodeFrame(session,
                                                     imageBuffer: imageBuffer,
                                                     presentationTimeStamp: pts,
                                                     duration: duration,
                                                     frameProperties: frameProperties,
                                                     sourceFrameRefcon: sourceFrameRefcon,
                                                     infoFlagsOut: nil)
        if status != noErr {
            Unmanaged<FrameTimingBox>.fromOpaque(sourceFrameRefcon).release()
            SharedLogger.log("VTCompressionSessionEncodeFrame 失败: \(status)")
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastEncodeFailureLogTime >= 0.5 {
                lastEncodeFailureLogTime = now
                let ptsText = String(format: "%.3f", CMTimeGetSeconds(pts))
                if LiveStreamConfig.App.enableRuntimeLogging {
                    NSLog("[Suspect][EncodeError] status=%d pts=%@ size=%dx%d forceKey=%d",
                          status,
                          ptsText,
                          activeEncodeWidth,
                          activeEncodeHeight,
                          forceKeyframe ? 1 : 0)
                }
            }
        }
    }

    private func makeBufferForEncoding(from imageBuffer: CVImageBuffer) -> CVImageBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(imageBuffer)
        let sourceHeight = CVPixelBufferGetHeight(imageBuffer)
        let targetWidth = Int(configuredWidth)
        let targetHeight = Int(configuredHeight)

        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        if !enableScaling {
            return imageBuffer
        }

        if sourceWidth == targetWidth && sourceHeight == targetHeight {
            return imageBuffer
        }

        let scaleStart = CFAbsoluteTimeGetCurrent()

        let pixelFormatType = CVPixelBufferGetPixelFormatType(imageBuffer)
        let scaledBuffer: CVPixelBuffer?
        if #available(iOS 16.0, *) {
            scaledBuffer = makeBufferForEncodingUsingPixelTransfer(from: imageBuffer,
                                                                  sourceWidth: sourceWidth,
                                                                  sourceHeight: sourceHeight,
                                                                  targetWidth: targetWidth,
                                                                  targetHeight: targetHeight,
                                                                  pixelFormatType: pixelFormatType)
        } else {
            scaledBuffer = makeBufferForEncodingUsingCoreImage(from: imageBuffer,
                                                               sourceWidth: sourceWidth,
                                                               sourceHeight: sourceHeight,
                                                               targetWidth: targetWidth,
                                                               targetHeight: targetHeight)
        }
        guard let scaledBuffer else { return nil }

        let scaleCostMs = (CFAbsoluteTimeGetCurrent() - scaleStart) * 1000.0
        recordScaleCost(scaleCostMs,
                        sourceWidth: sourceWidth,
                        sourceHeight: sourceHeight,
                        targetWidth: targetWidth,
                        targetHeight: targetHeight)

        return scaledBuffer
    }

    @available(iOS 16.0, *)
    private func makeBufferForEncodingUsingPixelTransfer(from imageBuffer: CVImageBuffer,
                                                         sourceWidth: Int,
                                                         sourceHeight: Int,
                                                         targetWidth: Int,
                                                         targetHeight: Int,
                                                         pixelFormatType: OSType) -> CVPixelBuffer? {
        guard ensureScalingResourcesForPixelTransfer(pixelFormatType: pixelFormatType) else { return nil }
        guard let scaledPixelBufferPool else { return nil }

        var scaledBuffer: CVPixelBuffer?
        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(nil, scaledPixelBufferPool, &scaledBuffer)
        guard poolStatus == kCVReturnSuccess, let scaledBuffer else {
            SharedLogger.log("H264 缩放缓冲区申请失败 status=\(poolStatus)")
            return nil
        }
        guard let pixelTransferSessionRef else { return nil }
        let pixelTransferSession = unsafeBitCast(pixelTransferSessionRef, to: VTPixelTransferSession.self)
        let transferStatus = VTPixelTransferSessionTransferImage(pixelTransferSession, from: imageBuffer, to: scaledBuffer)
        guard transferStatus == noErr else {
            SharedLogger.log("H264 像素传输缩放失败 status=\(transferStatus) fmt=\(pixelFormatType)")
            return nil
        }

        if !loggedScaleInfo {
            loggedScaleInfo = true
            SharedLogger.log("H264 改用 VTPixelTransferSession 缩放: \(sourceWidth)x\(sourceHeight) -> \(targetWidth)x\(targetHeight) fmt=\(pixelFormatType)")
        }
        return scaledBuffer
    }

    private func makeBufferForEncodingUsingCoreImage(from imageBuffer: CVImageBuffer,
                                                     sourceWidth: Int,
                                                     sourceHeight: Int,
                                                     targetWidth: Int,
                                                     targetHeight: Int) -> CVPixelBuffer? {
        guard ensureScalingResourcesForCoreImage() else { return nil }
        guard let scaledPixelBufferPool else { return nil }

        var scaledBuffer: CVPixelBuffer?
        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(nil, scaledPixelBufferPool, &scaledBuffer)
        guard poolStatus == kCVReturnSuccess, let scaledBuffer else {
            SharedLogger.log("H264 缩放缓冲区申请失败 status=\(poolStatus)")
            return nil
        }

        // 给目标 NV12 缓冲打上标准 BT.709 video-range 标签：
        // 1) Core Image 据此完成 RGB→YCbCr 的矩阵/范围转换；
        // 2) 下游编码器/服务端拿到与 iOS16 一致的标准色彩信息，避免 full-range/RGB-matrix 码流拉不到流。
        attachStandardColorTags(to: scaledBuffer)

        let sourceImage = CIImage(cvPixelBuffer: imageBuffer)
        let scale = min(CGFloat(targetWidth) / CGFloat(sourceWidth), CGFloat(targetHeight) / CGFloat(sourceHeight))
        let scaledWidth = CGFloat(sourceWidth) * scale
        let scaledHeight = CGFloat(sourceHeight) * scale
        let x = (CGFloat(targetWidth) - scaledWidth) * 0.5
        let y = (CGFloat(targetHeight) - scaledHeight) * 0.5
        let outputRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)

        let transformedImage = sourceImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
        let outputImage = transformedImage
            .composited(over: CIImage(color: .black).cropped(to: outputRect))
            .cropped(to: outputRect)

        ciContext.render(outputImage, to: scaledBuffer, bounds: outputRect, colorSpace: scaleColorSpace)

        if !loggedScaleInfo {
            loggedScaleInfo = true
            SharedLogger.log("H264 使用 CIContext 缩放(NV12 video-range): \(sourceWidth)x\(sourceHeight) -> \(targetWidth)x\(targetHeight) fmt=\(coreImageScaleFormat)")
        }
        return scaledBuffer
    }

    @available(iOS 16.0, *)
    private func ensureScalingResourcesForPixelTransfer(pixelFormatType: OSType) -> Bool {
        if scaledPixelBufferPool != nil,
           pixelTransferSessionRef != nil,
           scaledPixelBufferFormatType == pixelFormatType {
            return true
        }
        scaledPixelBufferPool = nil
        scaledPixelBufferFormatType = 0
        pixelTransferSessionRef = nil

        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormatType,
            kCVPixelBufferWidthKey: Int(configuredWidth),
            kCVPixelBufferHeightKey: Int(configuredHeight),
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        var newPool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(nil, nil, pixelBufferAttributes as CFDictionary, &newPool)
        guard poolStatus == kCVReturnSuccess, let newPool else {
            SharedLogger.log("H264 创建缩放缓冲池失败 status=\(poolStatus)")
            return false
        }

        scaledPixelBufferPool = newPool
        scaledPixelBufferFormatType = pixelFormatType

        var newTransferSession: VTPixelTransferSession?
        let sessionStatus = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &newTransferSession)
        guard sessionStatus == noErr, let newTransferSession else {
            SharedLogger.log("H264 创建像素传输会话失败 status=\(sessionStatus)")
            scaledPixelBufferPool = nil
            scaledPixelBufferFormatType = 0
            return false
        }
        pixelTransferSessionRef = newTransferSession
        VTSessionSetProperty(newTransferSession,
                             key: kVTPixelTransferPropertyKey_ScalingMode,
                             value: kVTScalingMode_Letterbox)
        return true
    }

    private func ensureScalingResourcesForCoreImage() -> Bool {
        if scaledPixelBufferPool != nil, scaledPixelBufferFormatType == coreImageScaleFormat {
            return true
        }
        scaledPixelBufferPool = nil
        scaledPixelBufferFormatType = 0
        pixelTransferSessionRef = nil

        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: coreImageScaleFormat,
            kCVPixelBufferWidthKey: Int(configuredWidth),
            kCVPixelBufferHeightKey: Int(configuredHeight),
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        var newPool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(nil, nil, pixelBufferAttributes as CFDictionary, &newPool)
        guard poolStatus == kCVReturnSuccess, let newPool else {
            SharedLogger.log("H264 创建 CoreImage 缩放缓冲池失败 status=\(poolStatus)")
            return false
        }
        scaledPixelBufferPool = newPool
        scaledPixelBufferFormatType = coreImageScaleFormat
        return true
    }

    private func attachStandardColorTags(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    private func publishDiagnosticsIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDiagnosticsFlushTime >= 0.5 else { return }
        lastDiagnosticsFlushTime = now
        publishDiagnostics(force: false)
    }

    private func publishDiagnostics(force: Bool) {
        if force {
            SharedDiagnostics.update([
                "diag.h264.targetFps": Int(fps),
                "diag.h264.lastGapMs": lastObservedGapMs,
                "diag.h264.droppedDenseFrames": droppedFrameCount,
                "diag.h264.resumeEvents": resumeEventCount,
                "diag.h264.lastUpdateTs": Date().timeIntervalSince1970
            ])
            return
        }

        SharedDiagnostics.update([
            "diag.h264.targetFps": Int(fps),
            "diag.h264.lastGapMs": lastObservedGapMs,
            "diag.h264.droppedDenseFrames": droppedFrameCount,
            "diag.h264.resumeEvents": resumeEventCount,
            "diag.h264.lastUpdateTs": Date().timeIntervalSince1970
        ])
    }

    private func resetPerformanceStats() {
        diagnosticsQueue.sync {
            scaleWindowStart = 0
            scaleWindowFrameCount = 0
            scaleWindowTotalMs = 0
            scaleWindowMaxMs = 0
            scaleWindowSlowCount = 0
            scaleWindowSourceSize = ""
            totalSubmittedFrames = 0
            totalOutputFrames = 0
            inputWindowStart = 0
            inputWindowReceivedFrames = 0
            inputWindowSubmittedFrames = 0
            inputWindowDroppedDenseFrames = 0
            inputWindowDroppedBacklogFrames = 0
            inputWindowSourceSize = ""
            callbackWindowStart = 0
            callbackWindowOutputFrames = 0
            callbackWindowTotalLatencyMs = 0
            callbackWindowMaxLatencyMs = 0
            callbackWindowKeyframes = 0
            lastCallbackWallClock = 0
            lastInputWallClock = 0
            lastSubmittedWallClock = 0
            lastInputIdleLogTime = 0
            lastCallbackIdleLogTime = 0
        }
        lastEncodeFailureLogTime = 0
        lastBacklogDropLogTime = 0
        lastMemoryWarn45LogTime = 0
        lastMemoryWarn48LogTime = 0
        outputDetailLogCount = 0
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: diagnosticsQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.checkForStall()
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdogTimer?.setEventHandler {}
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func recordInputArrival() {
        diagnosticsQueue.sync {
            lastInputWallClock = CFAbsoluteTimeGetCurrent()
        }
    }

    private func recordSubmittedFrame() {
        diagnosticsQueue.sync {
            totalSubmittedFrames += 1
            lastSubmittedWallClock = CFAbsoluteTimeGetCurrent()
        }
    }

    private func recordInputFrame(sourceWidth: Int,
                                  sourceHeight: Int,
                                  submitted: Bool,
                                  droppedDense: Bool,
                                  droppedBacklog: Bool) {
        diagnosticsQueue.sync {
            let now = CFAbsoluteTimeGetCurrent()
            if inputWindowStart == 0 {
                inputWindowStart = now
                inputWindowSourceSize = "\(sourceWidth)x\(sourceHeight)"
            }

            inputWindowReceivedFrames += 1
            if submitted {
                inputWindowSubmittedFrames += 1
            }
            if droppedDense {
                inputWindowDroppedDenseFrames += 1
            }
            if droppedBacklog {
                inputWindowDroppedBacklogFrames += 1
            }
            inputWindowSourceSize = "\(sourceWidth)x\(sourceHeight)"

            if now - inputWindowStart >= 1.0 {
                let callbackBacklog = max(0, totalSubmittedFrames - totalOutputFrames)
                let callbackAgeText: String
                if lastCallbackWallClock > 0 {
                    callbackAgeText = String(format: "%.0f", (now - lastCallbackWallClock) * 1000.0)
                } else {
                    callbackAgeText = "none"
                }
                let sessionSizeText: String
                if activeEncodeWidth > 0, activeEncodeHeight > 0 {
                    sessionSizeText = "\(activeEncodeWidth)x\(activeEncodeHeight)"
                } else {
                    sessionSizeText = "none"
                }

                SharedLogger.log("H264 输入1s: in=\(inputWindowReceivedFrames) submit=\(inputWindowSubmittedFrames) denseDrop=\(inputWindowDroppedDenseFrames) backlogDrop=\(inputWindowDroppedBacklogFrames) backlog=\(callbackBacklog) cbAgo=\(callbackAgeText)ms src=\(inputWindowSourceSize) enc=\(sessionSizeText)")
                if LiveStreamConfig.App.enableRuntimeLogging {
                    NSLog("[Suspect][Input] in=%d submit=%d denseDrop=%d backlogDrop=%d backlog=%d cbAgo=%@ms src=%@ enc=%@ scaling=%d",
                          inputWindowReceivedFrames,
                          inputWindowSubmittedFrames,
                          inputWindowDroppedDenseFrames,
                          inputWindowDroppedBacklogFrames,
                          callbackBacklog,
                          callbackAgeText,
                          inputWindowSourceSize,
                          sessionSizeText,
                          enableScaling ? 1 : 0)
                }

                if inputWindowSubmittedFrames > 0,
                   (lastCallbackWallClock == 0 || now - lastCallbackWallClock >= 1.0) {
                    if LiveStreamConfig.App.enableRuntimeLogging {
                        NSLog("[Suspect][EncodeStall] submit=%d out=%d backlog=%d sinceLastCallback=%@ms enc=%@ scaling=%d",
                              totalSubmittedFrames,
                              totalOutputFrames,
                              callbackBacklog,
                              callbackAgeText,
                              sessionSizeText,
                              enableScaling ? 1 : 0)
                    }
                }

                inputWindowStart = now
                inputWindowReceivedFrames = 0
                inputWindowSubmittedFrames = 0
                inputWindowDroppedDenseFrames = 0
                inputWindowDroppedBacklogFrames = 0
            }
        }
    }

    private func recordScaleCost(_ costMs: Double,
                                 sourceWidth: Int,
                                 sourceHeight: Int,
                                 targetWidth: Int,
                                 targetHeight: Int) {
        diagnosticsQueue.sync {
            let now = CFAbsoluteTimeGetCurrent()
            if scaleWindowStart == 0 {
                scaleWindowStart = now
                scaleWindowSourceSize = "\(sourceWidth)x\(sourceHeight)->\(targetWidth)x\(targetHeight)"
            }

            scaleWindowFrameCount += 1
            scaleWindowTotalMs += costMs
            scaleWindowMaxMs = max(scaleWindowMaxMs, costMs)
            if costMs >= 12 {
                scaleWindowSlowCount += 1
            }

            if costMs >= 20 {
                let costText = String(format: "%.1f", costMs)
                SharedLogger.log("H264 缩放耗时偏高 cost=\(costText)ms src=\(sourceWidth)x\(sourceHeight) dst=\(targetWidth)x\(targetHeight)")
            }

            if now - scaleWindowStart >= 1.0 {
                let avgMs = scaleWindowTotalMs / Double(max(1, scaleWindowFrameCount))
                let avgText = String(format: "%.1f", avgMs)
                let maxText = String(format: "%.1f", scaleWindowMaxMs)
                SharedLogger.log("H264 缩放1s: frames=\(scaleWindowFrameCount) avg=\(avgText)ms max=\(maxText)ms slow12ms=\(scaleWindowSlowCount) size=\(scaleWindowSourceSize)")
                if LiveStreamConfig.App.enableRuntimeLogging {
                    NSLog("[Suspect][Scale] frames=%d avg=%@ms max=%@ms slow12ms=%d size=%@",
                          scaleWindowFrameCount,
                          avgText,
                          maxText,
                          scaleWindowSlowCount,
                          scaleWindowSourceSize)
                }
                scaleWindowStart = now
                scaleWindowFrameCount = 0
                scaleWindowTotalMs = 0
                scaleWindowMaxMs = 0
                scaleWindowSlowCount = 0
                scaleWindowSourceSize = "\(sourceWidth)x\(sourceHeight)->\(targetWidth)x\(targetHeight)"
            }
        }
    }

    fileprivate func recordOutputCallback(latencyMs: Double,
                                          dataSize: Int,
                                          pts: CMTime,
                                          isKeyframe: Bool,
                                          nalTypes: [UInt8]) {
        diagnosticsQueue.sync {
            let now = CFAbsoluteTimeGetCurrent()
            totalOutputFrames += 1
            lastCallbackWallClock = now
            if callbackWindowStart == 0 {
                callbackWindowStart = now
            }

            callbackWindowOutputFrames += 1
            callbackWindowTotalLatencyMs += latencyMs
            callbackWindowMaxLatencyMs = max(callbackWindowMaxLatencyMs, latencyMs)
            if isKeyframe {
                callbackWindowKeyframes += 1
            }

            let callbackBacklog = max(0, totalSubmittedFrames - totalOutputFrames)
            if latencyMs >= 50 || callbackBacklog >= 3 {
                let latencyText = String(format: "%.1f", latencyMs)
                SharedLogger.log("H264 输出回调偏慢 latency=\(latencyText)ms backlog=\(callbackBacklog) bytes=\(dataSize) key=\(isKeyframe ? 1 : 0) nals=\(Array(Set(nalTypes)).sorted())")
            }

            if now - callbackWindowStart >= 1.0 {
                let avgLatencyMs = callbackWindowTotalLatencyMs / Double(max(1, callbackWindowOutputFrames))
                let avgLatencyText = String(format: "%.1f", avgLatencyMs)
                let maxLatencyText = String(format: "%.1f", callbackWindowMaxLatencyMs)
                let ptsText = String(format: "%.3f", CMTimeGetSeconds(pts))
                SharedLogger.log("H264 输出回调1s: out=\(callbackWindowOutputFrames) key=\(callbackWindowKeyframes) avgLatency=\(avgLatencyText)ms maxLatency=\(maxLatencyText)ms backlog=\(callbackBacklog) lastPts=\(ptsText) size=\(dataSize)")
                if LiveStreamConfig.App.enableRuntimeLogging {
                    NSLog("[Suspect][Encode] out=%d key=%d avgLatency=%@ms maxLatency=%@ms backlog=%d lastPts=%@ size=%d",
                          callbackWindowOutputFrames,
                          callbackWindowKeyframes,
                          avgLatencyText,
                          maxLatencyText,
                          callbackBacklog,
                          ptsText,
                          dataSize)
                }
                callbackWindowStart = now
                callbackWindowOutputFrames = 0
                callbackWindowTotalLatencyMs = 0
                callbackWindowMaxLatencyMs = 0
                callbackWindowKeyframes = 0
            }
        }
    }

    private func checkForStall() {
        let now = CFAbsoluteTimeGetCurrent()
        let callbackBacklog = max(0, totalSubmittedFrames - totalOutputFrames)
        let sessionSizeText: String
        if activeEncodeWidth > 0, activeEncodeHeight > 0 {
            sessionSizeText = "\(activeEncodeWidth)x\(activeEncodeHeight)"
        } else {
            sessionSizeText = "none"
        }
        let residentMB = Self.currentResidentMemoryMB()
        if residentMB >= 45 && now - lastMemoryWarn45LogTime >= 1.0 {
            lastMemoryWarn45LogTime = now
            SharedLogger.log("H264 内存高水位 warning=45MB current=\(residentMB)MB backlog=\(callbackBacklog) submit=\(totalSubmittedFrames) output=\(totalOutputFrames) enc=\(sessionSizeText)")
        }
        if residentMB >= 48 && now - lastMemoryWarn48LogTime >= 1.0 {
            lastMemoryWarn48LogTime = now
            SharedLogger.log("H264 内存高水位 warning=48MB current=\(residentMB)MB backlog=\(callbackBacklog) submit=\(totalSubmittedFrames) output=\(totalOutputFrames) enc=\(sessionSizeText)")
        }

        if lastInputWallClock > 0 {
            let inputIdleMs = (now - lastInputWallClock) * 1000.0
            if inputIdleMs >= 1500,
               totalSubmittedFrames > 0,
               now - lastInputIdleLogTime >= 1.0 {
                lastInputIdleLogTime = now
                let inputIdleText = String(format: "%.0f", inputIdleMs)
                SharedLogger.log("H264 输入空窗 idle=\(inputIdleText)ms backlog=\(callbackBacklog) submitted=\(totalSubmittedFrames) output=\(totalOutputFrames) enc=\(sessionSizeText)")
                if LiveStreamConfig.App.enableRuntimeLogging {
                    NSLog("[Suspect][InputIdle] idle=%@ms backlog=%d submit=%d out=%d enc=%@ scaling=%d",
                          inputIdleText,
                          callbackBacklog,
                          totalSubmittedFrames,
                          totalOutputFrames,
                          sessionSizeText,
                          enableScaling ? 1 : 0)
                }
            }
        }

        if lastSubmittedWallClock > 0,
           callbackBacklog > 0 {
            let callbackIdleMs: Double
            if lastCallbackWallClock > 0 {
                callbackIdleMs = (now - lastCallbackWallClock) * 1000.0
            } else {
                callbackIdleMs = (now - lastSubmittedWallClock) * 1000.0
            }
            let submittedAgoMs = (now - lastSubmittedWallClock) * 1000.0
            if callbackIdleMs >= 1000,
               now - lastCallbackIdleLogTime >= 1.0 {
                lastCallbackIdleLogTime = now
                let callbackIdleText = String(format: "%.0f", callbackIdleMs)
                let submittedAgoText = String(format: "%.0f", submittedAgoMs)
                SharedLogger.log("H264 输出空窗 idle=\(callbackIdleText)ms submitAgo=\(submittedAgoText)ms backlog=\(callbackBacklog) submitted=\(totalSubmittedFrames) output=\(totalOutputFrames) enc=\(sessionSizeText)")
                if LiveStreamConfig.App.enableRuntimeLogging {
                    NSLog("[Suspect][CallbackIdle] idle=%@ms submitAgo=%@ms backlog=%d submit=%d out=%d enc=%@ scaling=%d",
                          callbackIdleText,
                          submittedAgoText,
                          callbackBacklog,
                          totalSubmittedFrames,
                          totalOutputFrames,
                          sessionSizeText,
                          enableScaling ? 1 : 0)
                }
            }
            if callbackIdleMs >= stallIdleThresholdMs,
               callbackBacklog >= stallBacklogThreshold {
                requestAutoRebuild(reason: "watchdog idle=\(Int(callbackIdleMs.rounded()))ms backlog=\(callbackBacklog) mem=\(residentMB)MB")
            } else if callbackBacklog >= criticalBacklogThreshold {
                requestAutoRebuild(reason: "watchdog criticalBacklog=\(callbackBacklog) idle=\(Int(callbackIdleMs.rounded()))ms mem=\(residentMB)MB")
            }
        }
    }

    private func currentCallbackBacklog() -> Int {
        diagnosticsQueue.sync {
            max(0, totalSubmittedFrames - totalOutputFrames)
        }
    }

    private func currentCallbackIdleMs() -> Double {
        diagnosticsQueue.sync {
            let now = CFAbsoluteTimeGetCurrent()
            if lastCallbackWallClock > 0 {
                return max(0, (now - lastCallbackWallClock) * 1000.0)
            }
            if lastSubmittedWallClock > 0 {
                return max(0, (now - lastSubmittedWallClock) * 1000.0)
            }
            return 0
        }
    }

    private func requestAutoRebuild(reason: String) {
        let now = CFAbsoluteTimeGetCurrent()
        var shouldLog = false
        rebuildLock.withLock {
            guard pendingRebuildReason == nil else { return }
            guard now - lastAutoRebuildTime >= autoRebuildCooldownSec else { return }
            pendingRebuildReason = reason
            shouldLog = true
        }
        if shouldLog {
            SharedLogger.log("H264 已计划自动重建 reason=\(reason)")
        }
    }

    private func applyPendingRebuildIfNeeded(sourceWidth: Int32, sourceHeight: Int32) {
        let reason: String? = rebuildLock.withLock {
            guard let reason = pendingRebuildReason else { return nil }
            pendingRebuildReason = nil
            lastAutoRebuildTime = CFAbsoluteTimeGetCurrent()
            autoRebuildCount += 1
            return reason
        }
        guard let reason else { return }
        forceKeyframeNext = true
        resetBacklogStateForAutoRebuild()
        let sessionWidth = enableScaling ? configuredWidth : sourceWidth
        let sessionHeight = enableScaling ? configuredHeight : sourceHeight
        let residentMB = Self.currentResidentMemoryMB()
        SharedLogger.log("H264 自动重建编码器 reason=\(reason) count=\(autoRebuildCount) size=\(sessionWidth)x\(sessionHeight) mem=\(residentMB)MB")
        _ = createCompressionSession(width: sessionWidth, height: sessionHeight)
    }

    private func resetBacklogStateForAutoRebuild() {
        diagnosticsQueue.sync {
            totalSubmittedFrames = 0
            totalOutputFrames = 0
            callbackWindowStart = 0
            callbackWindowOutputFrames = 0
            callbackWindowTotalLatencyMs = 0
            callbackWindowMaxLatencyMs = 0
            callbackWindowKeyframes = 0
            lastCallbackWallClock = 0
            lastSubmittedWallClock = 0
            lastCallbackIdleLogTime = 0
        }
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

private let compressionCallback: VTCompressionOutputCallback = { refcon, sourceFrameRefCon, status, _, sampleBuffer in
    guard let refcon = refcon else {
        SharedLogger.log("H264 输出回调缺少 encoder refcon")
        return
    }

    guard status == noErr else {
        SharedLogger.log("H264 输出回调失败 status=\(status)")
        if let sourceFrameRefCon {
            Unmanaged<H264Encoder.FrameTimingBox>.fromOpaque(sourceFrameRefCon).release()
        }
        return
    }

    guard let sampleBuffer = sampleBuffer else {
        SharedLogger.log("H264 输出回调 sampleBuffer 为空")
        if let sourceFrameRefCon {
            Unmanaged<H264Encoder.FrameTimingBox>.fromOpaque(sourceFrameRefCon).release()
        }
        return
    }

    guard CMSampleBufferDataIsReady(sampleBuffer) else {
        SharedLogger.log("H264 输出回调 sampleBuffer 未就绪")
        if let sourceFrameRefCon {
            Unmanaged<H264Encoder.FrameTimingBox>.fromOpaque(sourceFrameRefCon).release()
        }
        return
    }

    let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
    let timingBox = sourceFrameRefCon.map { Unmanaged<H264Encoder.FrameTimingBox>.fromOpaque($0).takeRetainedValue() }

    if !encoder.loggedNALLengthSize, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
        encoder.loggedNALLengthSize = true
        var nalLengthSize: Int32 = 0
        _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: &nalLengthSize
        )
        SharedLogger.log("H264 nalLengthSize=\(nalLengthSize)")
    }

    // 先把编码输出转成 AnnexB，然后用 NAL 类型判断是否为 IDR。
    // 不能只依赖 attachments 的 NotSync：某些情况下该标记不稳定，会导致服务端/桥接侧不认关键帧，从而表现为“视频只动 1 秒”。
    guard let data = H264Encoder.convertToAnnexB(sampleBuffer: sampleBuffer) else { return }
    let nalTypes = H264Encoder.annexBNALUTypes(from: data)
    let isIDR = nalTypes.contains(5)

    if isIDR, encoder.loggedIDRInfoCount < 5 {
        encoder.loggedIDRInfoCount += 1
        let uniqueTypes = Array(Set(nalTypes)).sorted()
        SharedLogger.log("H264 IDR 诊断: nals=\(uniqueTypes) bytes=\(data.count)")
    }

    // SPS/PPS：优先用 format description 提取（对解码/封装最稳定）。
    // 为了确保下游能尽快拿到配置，这里在首帧/关键帧尝试提取并缓存。
    if encoder.cachedSPS == nil || encoder.cachedPPS == nil || isIDR || nalTypes.contains(7) || nalTypes.contains(8) {
        if let pair = H264Encoder.extractSpsPpsPair(from: sampleBuffer) {
            encoder.cachedSPS = pair.sps
            encoder.cachedPPS = pair.pps
        }
    }

    let pts = timingBox?.pts ?? CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    var dts = timingBox?.dts ?? CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
    if dts == .invalid || dts == .indefinite { dts = pts }
    let callbackLatencyMs = timingBox.map { (CFAbsoluteTimeGetCurrent() - $0.enqueueWallClock) * 1000.0 } ?? 0
    encoder.outputDetailLogCount += 1
    let shouldLogOutputDetail = encoder.outputDetailLogCount <= 6 || encoder.outputDetailLogCount % 30 == 0
    if shouldLogOutputDetail {
        let ptsText = String(format: "%.3f", CMTimeGetSeconds(pts))
        let dtsText = String(format: "%.3f", CMTimeGetSeconds(dts))
        let latencyText = String(format: "%.1f", callbackLatencyMs)
        SharedLogger.log("H264 输出节点 callbackEntered idx=\(encoder.outputDetailLogCount) pts=\(ptsText) dts=\(dtsText) latency=\(latencyText)ms size=\(data.count) key=\(isIDR ? 1 : 0) nals=\(Array(Set(nalTypes)).sorted())")
    }
    encoder.recordOutputCallback(latencyMs: callbackLatencyMs,
                                 dataSize: data.count,
                                 pts: pts,
                                 isKeyframe: isIDR,
                                 nalTypes: nalTypes)
    if shouldLogOutputDetail {
        let ptsText = String(format: "%.3f", CMTimeGetSeconds(pts))
        SharedLogger.log("H264 输出节点 dispatchToUploader idx=\(encoder.outputDetailLogCount) pts=\(ptsText) bytes=\(data.count) key=\(isIDR ? 1 : 0) sps=\(encoder.cachedSPS?.count ?? 0) pps=\(encoder.cachedPPS?.count ?? 0)")
    }
    encoder.onEncoded?(H264Encoder.EncodedFrame(data: data,
                                                pts: pts,
                                                dts: dts,
                                                isKeyframe: isIDR,
                                                sps: encoder.cachedSPS,
                                                pps: encoder.cachedPPS,
                                                width: encoder.activeEncodeWidth,
                                                height: encoder.activeEncodeHeight))
}

private extension H264Encoder {
    /// 从 AnnexB 数据里解析 NALU type（只做轻量扫描，避免复杂解析开销）
    static func annexBNALUTypes(from data: Data) -> [UInt8] {
        var types: [UInt8] = []
        var i = 0
        func isStartCode3(_ idx: Int) -> Bool {
            idx + 2 < data.count && data[idx] == 0 && data[idx + 1] == 0 && data[idx + 2] == 1
        }
        func isStartCode4(_ idx: Int) -> Bool {
            idx + 3 < data.count && data[idx] == 0 && data[idx + 1] == 0 && data[idx + 2] == 0 && data[idx + 3] == 1
        }

        while i < data.count {
            let scLen: Int
            if isStartCode3(i) {
                scLen = 3
            } else if isStartCode4(i) {
                scLen = 4
            } else {
                i += 1
                continue
            }

            let nalHeaderIndex = i + scLen
            if nalHeaderIndex < data.count {
                let nalType = data[nalHeaderIndex] & 0x1F
                types.append(nalType)
            }
            i = nalHeaderIndex
        }
        return types
    }

    static func convertToAnnexB(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        // 关键：CMBlockBuffer 内存不保证连续，必须显式拷贝到连续缓冲区。
        // 否则直接用 CMBlockBufferGetDataPointer + totalLength 读，会越界读到无关内存，导致后续帧 AVCC 被破坏。
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        guard totalLength > 0 else { return nil }
        var raw = Data(count: totalLength)
        let copyStatus: OSStatus = raw.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalLength, destination: dst)
        }
        guard copyStatus == noErr else {
            SharedLogger.log("H264 输出节点 annexBCopyFailed status=\(copyStatus) total=\(totalLength)")
            return nil
        }

        // 获取实际的 NAL length 字段长度（可能是 1/2/4 字节）
        var nalLengthSize: Int32 = 4
        // nalUnitHeaderLengthOut 会给出 length 字段长度
        _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: &nalLengthSize
        )
        let nls = Int(max(1, min(4, nalLengthSize)))

        var output = Data()
        output.reserveCapacity(totalLength + (totalLength / 1024) * 4)

        var offset = 0
        while offset + nls <= totalLength {
            let nalLen: Int
            switch nls {
            case 1:
                nalLen = Int(raw[offset])
            case 2:
                let b0 = Int(raw[offset])
                let b1 = Int(raw[offset + 1])
                nalLen = (b0 << 8) | b1
            default:
                let b0 = UInt32(raw[offset])
                let b1 = UInt32(raw[offset + 1])
                let b2 = UInt32(raw[offset + 2])
                let b3 = UInt32(raw[offset + 3])
                nalLen = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            }

            offset += nls
            guard nalLen > 0, offset + nalLen <= totalLength else { break }

            output.append(contentsOf: [0, 0, 0, 1])
            output.append(raw.subdata(in: offset..<(offset + nalLen)))
            offset += nalLen
        }
        if output.isEmpty {
            SharedLogger.log("H264 输出节点 annexBEmpty total=\(totalLength) nls=\(nls)")
        }
        return output
    }

    static func extractSpsPpsPair(from sampleBuffer: CMSampleBuffer) -> (sps: Data, pps: Data)? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize: Int = 0
        var spsCount: Int = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize: Int = 0
        var ppsCount: Int = 0

        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: nil)

        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: &ppsCount,
            nalUnitHeaderLengthOut: nil)

        guard spsStatus == noErr, ppsStatus == noErr,
              let sps = spsPointer, let pps = ppsPointer else { return nil }

        return (Data(bytes: sps, count: spsSize), Data(bytes: pps, count: ppsSize))
    }
}

private extension CMSampleBuffer {
    var isKeyframe: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return false }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }
}
