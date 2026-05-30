import Foundation
import CoreMedia
import AudioToolbox

// High-performance contiguous buffer.
private final class FlatPCMBuffer {
    private var memory: UnsafeMutableRawPointer
    private var capacity: Int
    private let minCapacity: Int
    private(set) var count: Int = 0

    init(capacity: Int = 131072) {
        self.capacity = capacity
        self.minCapacity = capacity
        self.memory = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<UInt8>.alignment)
    }

    deinit {
        memory.deallocate()
    }

    func append(from src: UnsafeRawPointer, length: Int) {
        ensureCapacity(for: length)
        memory.advanced(by: count).copyMemory(from: src, byteCount: length)
        count += length
    }

    func consume(length: Int) {
        guard length <= count else { return }
        let remaining = count - length
        if remaining > 0 {
            memmove(memory, memory.advanced(by: length), remaining)
        }
        count = remaining
        shrinkIfNeeded()
    }

    func getPointer() -> UnsafeMutableRawPointer {
        return memory
    }

    func removeAll() {
        count = 0
        shrinkIfNeeded(force: true)
    }

    func getTailPointer(for length: Int) -> UnsafeMutableRawPointer {
        ensureCapacity(for: length)
        return memory.advanced(by: count)
    }

    func advanceTail(by length: Int) {
        count += length
    }

    private func ensureCapacity(for newLength: Int) {
        if count + newLength > capacity {
            let newCapacity = max(capacity * 2, count + newLength + 65536)
            let newMemory = UnsafeMutableRawPointer.allocate(byteCount: newCapacity, alignment: MemoryLayout<UInt8>.alignment)
            if count > 0 {
                newMemory.copyMemory(from: memory, byteCount: count)
            }
            memory.deallocate()
            memory = newMemory
            capacity = newCapacity
        }
    }

    private func shrinkIfNeeded(force: Bool = false) {
        guard capacity > minCapacity else { return }

        let shouldShrink: Bool
        if force {
            shouldShrink = true
        } else {
            let lowWatermark = max(minCapacity, capacity / 4)
            shouldShrink = count <= lowWatermark && capacity >= minCapacity * 4
        }
        guard shouldShrink else { return }

        let targetCapacity = max(minCapacity, count + 65536)
        guard targetCapacity < capacity else { return }

        let newMemory = UnsafeMutableRawPointer.allocate(byteCount: targetCapacity,
                                                         alignment: MemoryLayout<UInt8>.alignment)
        if count > 0 {
            newMemory.copyMemory(from: memory, byteCount: count)
        }
        memory.deallocate()
        memory = newMemory
        capacity = targetCapacity
    }
}

final class AACEncoder {
    struct EncodedFrame {
        let data: Data
        let pts: CMTime
        let audioSpecificConfig: Data?
    }

    private var converter: AudioConverterRef?
    private var onEncoded: ((EncodedFrame) -> Void)?
    var onError: ((Error) -> Void)?
    private var audioSpecificConfig: Data?

    private var lastSampleRate: Double?
    private var lastChannels: UInt32?
    private var bufferHeadPTS: CMTime?
    private var bufferedFrameCount: Int64 = 0
    private var firstEncodedAt: Double = 0
    private var outputFrameCount: Int = 0
    private var lastEncodeErrorCode: Int = 0
    private var lastEncodeErrorAt: Double = 0
    private var skippedInputLogCount: Int = 0
    private var missingSourceLogCount: Int = 0
    /// Set true once we have emitted at least one full-size AAC packet. Before this we may
    /// see encoder warm-up output (≤7 bytes of garbage/header). After it, even tiny output
    /// is a legitimate silent packet and MUST be emitted, otherwise bufferHeadPTS stalls
    /// and the player sees a PTS jump when audio resumes (see silence-synthesis fix).
    private var aacWarmedUp: Bool = false
    private var aacFilteredSmallCount: Int = 0

    private let ringBuffer = FlatPCMBuffer(capacity: 131072)
    private var outputBuffer = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: MemoryLayout<UInt8>.alignment)

    private let targetFramesPerPacket: UInt32 = LiveStreamConfig.Audio.framesPerPacket

    deinit {
        outputBuffer.deallocate()
    }

    func start(onEncoded: @escaping (EncodedFrame) -> Void) {
        self.onEncoded = onEncoded
        firstEncodedAt = 0
        outputFrameCount = 0
        lastEncodeErrorCode = 0
        lastEncodeErrorAt = 0
        skippedInputLogCount = 0
        missingSourceLogCount = 0
        aacWarmedUp = false
        aacFilteredSmallCount = 0
        publishDiagnostics()
        SharedLogger.log("AACEncoder 已进入待启动状态")
    }

    func stop() {
        if let converter = converter {
            AudioConverterDispose(converter)
        }
        converter = nil
        onEncoded = nil
        lastSampleRate = nil
        lastChannels = nil
        bufferHeadPTS = nil
        bufferedFrameCount = 0
        ringBuffer.removeAll()
        firstEncodedAt = 0
        outputFrameCount = 0
        lastEncodeErrorCode = 0
        lastEncodeErrorAt = 0
        skippedInputLogCount = 0
        missingSourceLogCount = 0
        aacWarmedUp = false
        aacFilteredSmallCount = 0
        publishDiagnostics()
    }

    func encodeExtracted(_ s: ExtractedAudioSample) {
        let srcASBD = s.asbd
        let sampleRate = srcASBD.mSampleRate
        let channels = srcASBD.mChannelsPerFrame
        let inputFormatID = srcASBD.mFormatID
        let samplePTS = s.pts

        guard inputFormatID == kAudioFormatLinearPCM else {
            logSkippedInput("unsupported_format=\(inputFormatID)")
            return
        }

        if converter != nil {
            if lastSampleRate != sampleRate || lastChannels != channels {
                AudioConverterDispose(converter!)
                converter = nil
                audioSpecificConfig = nil
                bufferHeadPTS = nil
                bufferedFrameCount = 0
                ringBuffer.removeAll()
            }
        }

        let isBigEndian = (srcASBD.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let isNonInterleaved = (srcASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerFrame = Int(srcASBD.mBytesPerFrame)
        let bytesPerSample = isNonInterleaved ? bytesPerFrame : bytesPerFrame / Int(channels)

        if converter == nil {
            var normalizedASBD = srcASBD
            normalizedASBD.mFormatFlags &= ~kAudioFormatFlagIsBigEndian
            if isNonInterleaved {
                normalizedASBD.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved
                normalizedASBD.mBytesPerFrame = UInt32(bytesPerSample) * channels
                normalizedASBD.mBytesPerPacket = UInt32(bytesPerSample) * channels
            }

            var dstAsbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
                mBytesPerPacket: 0,
                mFramesPerPacket: targetFramesPerPacket,
                mBytesPerFrame: 0,
                mChannelsPerFrame: channels,
                mBitsPerChannel: 0,
                mReserved: 0
            )

            var hwDesc = AudioClassDescription(
                mType: kAudioEncoderComponentType,
                mSubType: kAudioFormatMPEG4AAC,
                mManufacturer: 1633772404
            )
            var status = AudioConverterNewSpecific(&normalizedASBD, &dstAsbd, 1, &hwDesc, &converter)

            if status != noErr || converter == nil {
                var swDesc = AudioClassDescription(
                    mType: kAudioEncoderComponentType,
                    mSubType: kAudioFormatMPEG4AAC,
                    mManufacturer: 1634758764
                )
                status = AudioConverterNewSpecific(&normalizedASBD, &dstAsbd, 1, &swDesc, &converter)
            }

            if status != noErr || converter == nil {
                status = AudioConverterNew(&normalizedASBD, &dstAsbd, &converter)
            }

            if status != noErr || converter == nil {
                SharedLogger.log("AAC AudioConverterNew failed status=\(status)")
                recordEncodeError(status)
                DispatchQueue.main.async { [weak self] in
                    self?.onError?(NSError(domain: "AudioConverter", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "AACEncoder 初始化失败"]))
                }
                return
            }

            if let converter = converter {
                var bitRate: UInt32 = LiveStreamConfig.Audio.bitrate
                AudioConverterSetProperty(converter,
                                          kAudioConverterEncodeBitRate,
                                          UInt32(MemoryLayout.size(ofValue: bitRate)),
                                          &bitRate)
            }

            audioSpecificConfig = AACEncoder.makeAudioSpecificConfig(sampleRate: sampleRate, channels: channels)
            lastSampleRate = sampleRate
            lastChannels = channels
        }

        guard let converter = converter else { return }

        let framesToProcess = s.frameCount
        guard framesToProcess > 0 else {
            logSkippedInput("empty_sample")
            return
        }

        let targetBytesPerFrame = bytesPerSample * Int(channels)
        let totalConvertedBytes = framesToProcess * targetBytesPerFrame

        let validSrcPtr = UnsafeRawPointer(s.handle.pointer)
        let dstBase = ringBuffer.getTailPointer(for: totalConvertedBytes)

        if !isNonInterleaved {
            if isBigEndian {
                if bytesPerSample == 2 {
                    let srcPtr = validSrcPtr.assumingMemoryBound(to: UInt16.self)
                    let dstPtr = dstBase.assumingMemoryBound(to: UInt16.self)
                    for i in 0..<(framesToProcess * Int(channels)) {
                        dstPtr[i] = srcPtr[i].byteSwapped
                    }
                } else if bytesPerSample == 4 {
                    let srcPtr = validSrcPtr.assumingMemoryBound(to: UInt32.self)
                    let dstPtr = dstBase.assumingMemoryBound(to: UInt32.self)
                    for i in 0..<(framesToProcess * Int(channels)) {
                        dstPtr[i] = srcPtr[i].byteSwapped
                    }
                }
            } else {
                dstBase.copyMemory(from: validSrcPtr, byteCount: totalConvertedBytes)
            }
        } else {
            let channelSize = framesToProcess * bytesPerSample
            for i in 0..<framesToProcess {
                let dst = dstBase.advanced(by: i * targetBytesPerFrame)
                for ch in 0..<Int(channels) {
                    let src = validSrcPtr.advanced(by: ch * channelSize + i * bytesPerSample)
                    if isBigEndian {
                        if bytesPerSample == 2 {
                            dst.advanced(by: ch * bytesPerSample).assumingMemoryBound(to: UInt16.self).pointee = src.assumingMemoryBound(to: UInt16.self).pointee.byteSwapped
                        } else if bytesPerSample == 4 {
                            dst.advanced(by: ch * bytesPerSample).assumingMemoryBound(to: UInt32.self).pointee = src.assumingMemoryBound(to: UInt32.self).pointee.byteSwapped
                        }
                    } else {
                        dst.advanced(by: ch * bytesPerSample).copyMemory(from: src, byteCount: bytesPerSample)
                    }
                }
            }
        }

        ringBuffer.advanceTail(by: totalConvertedBytes)

        updateBufferedAudioTimeline(samplePTS: samplePTS,
                                    sampleRate: sampleRate,
                                    appendedFrames: framesToProcess)

        let bytesRequiredPerPacket = Int(targetFramesPerPacket) * targetBytesPerFrame

        var ioOutputDataPackets: UInt32 = 1
        var outPacketDesc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: 0)
        var convertStatus: OSStatus = noErr
        var outputDataSize: UInt32 = 0

        while ringBuffer.count >= bytesRequiredPerPacket {
            let chunkBaseAddress = ringBuffer.getPointer()

            var ctx = EncoderInputContext(
                dataPtr: chunkBaseAddress,
                dataLength: UInt32(bytesRequiredPerPacket),
                channels: channels,
                bytesPerFrame: UInt32(targetBytesPerFrame),
                hasProvided: false
            )

            ioOutputDataPackets = 1
            outPacketDesc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: 0)
            outputDataSize = 0

            var outputBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: channels,
                                      mDataByteSize: UInt32(8192),
                                      mData: outputBuffer)
            )

            convertStatus = AudioConverterFillComplexBuffer(
                converter,
                aacInputDataProc,
                &ctx,
                &ioOutputDataPackets,
                &outputBufferList,
                &outPacketDesc
            )

            outputDataSize = outPacketDesc.mDataByteSize > 0 ? outPacketDesc.mDataByteSize : outputBufferList.mBuffers.mDataByteSize
            ringBuffer.consume(length: bytesRequiredPerPacket)

            if convertStatus != noErr || outputDataSize == 0 || ioOutputDataPackets == 0 {
                if convertStatus == noErr && outputDataSize <= 7 {
                    // warm-up — only meaningful BEFORE we have produced any real packet.
                } else if convertStatus == 104 {
                    break
                } else {
                    SharedLogger.log("AAC encode failed status=\(convertStatus) outSize=\(outputDataSize) outPackets=\(ioOutputDataPackets)")
                    recordEncodeError(convertStatus)
                    break
                }
            }

            // Pre-warmup: skip tiny (≤7-byte) packets — encoder priming.
            // Post-warmup: a tiny packet is a *legitimate silent AAC frame* and must
            // be emitted; otherwise bufferHeadPTS never advances during silence and
            // the player sees a multi-second PTS jump on audio resume.
            if outputDataSize <= 7 && convertStatus == noErr && !aacWarmedUp {
                aacFilteredSmallCount += 1
                if aacFilteredSmallCount <= 3 || aacFilteredSmallCount % 200 == 0 {
                    NSLog("[Suspect][AAC] pre-warmup skip outSize=%d count=%d", Int(outputDataSize), aacFilteredSmallCount)
                }
                continue
            }

            if outputDataSize > 0 {
                if outputDataSize > 7 { aacWarmedUp = true }
                let pts = nextOutputPTS(sampleRate: sampleRate)
                let outData = Data(bytes: outputBuffer, count: Int(outputDataSize))
                recordEncodedFrame()
                onEncoded?(EncodedFrame(data: outData, pts: pts, audioSpecificConfig: audioSpecificConfig))
            }
        }
    }
}

private extension AACEncoder {
    func logSkippedInput(_ reason: String) {
        skippedInputLogCount += 1
        if skippedInputLogCount <= 5 || skippedInputLogCount % 50 == 0 {
            SharedLogger.log("AAC 跳过输入 reason=\(reason) count=\(skippedInputLogCount)")
        }
    }

    func recordEncodedFrame() {
        outputFrameCount += 1
        if firstEncodedAt == 0 {
            firstEncodedAt = Date().timeIntervalSince1970
        }
        publishDiagnostics()
    }

    func recordEncodeError(_ status: OSStatus) {
        lastEncodeErrorCode = Int(status)
        lastEncodeErrorAt = Date().timeIntervalSince1970
        publishDiagnostics()
    }

    func publishDiagnostics() {
        SharedDiagnostics.update([
            "diag.aac.firstEncodedAt": firstEncodedAt,
            "diag.aac.outputFrameCount": outputFrameCount,
            "diag.aac.lastEncodeErrorCode": lastEncodeErrorCode,
            "diag.aac.lastEncodeErrorAt": lastEncodeErrorAt
        ])
    }

    func nextOutputPTS(sampleRate: Double) -> CMTime {
        let normalizedSampleRate = Int32(max(1, Int(sampleRate.rounded())))
        let frameDuration = CMTime(value: Int64(targetFramesPerPacket), timescale: normalizedSampleRate)

        let pts = bufferHeadPTS ?? .zero
        if pts.isNumeric {
            bufferHeadPTS = pts + frameDuration
        } else {
            bufferHeadPTS = frameDuration
        }
        bufferedFrameCount = max(0, bufferedFrameCount - Int64(targetFramesPerPacket))
        return pts
    }

    func updateBufferedAudioTimeline(samplePTS: CMTime, sampleRate: Double, appendedFrames: Int) {
        guard appendedFrames > 0 else { return }
        let normalizedSampleRate = Int32(max(1, Int(sampleRate.rounded())))

        if bufferHeadPTS == nil {
            bufferHeadPTS = samplePTS.isNumeric ? samplePTS : .zero
            bufferedFrameCount = Int64(appendedFrames)
            return
        }

        // Only re-anchor on real gaps > 1s. Small scheduling jitter should advance by frame count.
        if let head = bufferHeadPTS, samplePTS.isNumeric {
            let expectedNextSampleStart = head + CMTime(value: bufferedFrameCount,
                                                        timescale: normalizedSampleRate)
            let gapMs = (CMTimeGetSeconds(samplePTS) - CMTimeGetSeconds(expectedNextSampleStart)) * 1000.0
            if gapMs > 1000 || gapMs < -1000 {
                SharedLogger.log("AAC 检测大 gap，重锚 PTS gapMs=\(Int(gapMs.rounded())) buffered=\(bufferedFrameCount)")
                bufferHeadPTS = samplePTS
                bufferedFrameCount = Int64(appendedFrames)
                return
            }
        }

        bufferedFrameCount += Int64(appendedFrames)
    }

    static func makeAudioSpecificConfig(sampleRate: Float64, channels: UInt32) -> Data? {
        let rates: [Float64] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        guard let index = rates.firstIndex(where: { abs($0 - sampleRate) < 1 }) else { return nil }
        let objectType = 2 // AAC LC
        let freqIndex = index
        let chanConfig = Int(channels)
        let byte1 = UInt8((objectType << 3) | (freqIndex >> 1))
        let byte2 = UInt8(((freqIndex & 1) << 7) | (chanConfig << 3))
        return Data([byte1, byte2])
    }
}

private struct EncoderInputContext {
    let dataPtr: UnsafeMutableRawPointer
    let dataLength: UInt32
    let channels: UInt32
    let bytesPerFrame: UInt32
    var hasProvided: Bool
}

private let aacInputDataProc: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, _, inUserData in
    guard let inUserData else { return -1 }
    let context = inUserData.assumingMemoryBound(to: EncoderInputContext.self)

    if context.pointee.hasProvided {
        ioNumberDataPackets.pointee = 0
        return 104
    }

    context.pointee.hasProvided = true
    let framesToProvide = context.pointee.dataLength / context.pointee.bytesPerFrame
    ioNumberDataPackets.pointee = min(ioNumberDataPackets.pointee, framesToProvide)

    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers = AudioBuffer(
        mNumberChannels: context.pointee.channels,
        mDataByteSize: context.pointee.dataLength,
        mData: context.pointee.dataPtr
    )

    return noErr
}
