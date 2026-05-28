import Foundation
import CoreMedia

// One audio extraction result. Value fields + a class handle. When captured by closures, it only
// holds a reference, avoiding per-sample malloc/free like Data would.
struct ExtractedAudioSample {
    let handle: PCMSlotHandle
    let asbd: AudioStreamBasicDescription
    let pts: CMTime
    let frameCount: Int
}

// A borrowed PCM slot from the pool. Automatically returns on deinit to avoid leaking slots.
final class PCMSlotHandle {
    let pointer: UnsafeMutableRawPointer
    let byteCount: Int
    private let pool: PCMBufferPool
    private let slotIndex: Int

    fileprivate init(pool: PCMBufferPool, slotIndex: Int,
                     pointer: UnsafeMutableRawPointer, byteCount: Int) {
        self.pool = pool
        self.slotIndex = slotIndex
        self.pointer = pointer
        self.byteCount = byteCount
    }

    deinit {
        pool.release(slotIndex: slotIndex)
    }
}

// Fixed-slot PCM buffer pool: avoids per-sample malloc/free.
// Slot capacity grows on demand and does not shrink. slotCount should be slightly larger than the
// producer-side drop threshold to tolerate short bursts.
final class PCMBufferPool {
    private struct Slot {
        var pointer: UnsafeMutableRawPointer
        var capacity: Int
        var inUse: Bool
    }

    private var slots: [Slot]
    private let lock = NSLock()
    private var exhaustionLogCount = 0

    init(slotCount: Int = 32, initialSlotCapacity: Int = 16_384) {
        slots = (0..<slotCount).map { _ in
            Slot(pointer: .allocate(byteCount: initialSlotCapacity,
                                    alignment: MemoryLayout<UInt8>.alignment),
                 capacity: initialSlotCapacity,
                 inUse: false)
        }
    }

    deinit {
        // Regardless of inUse status. The only way to reach here is that no handle is alive,
        // because handles retain the pool.
        for s in slots {
            s.pointer.deallocate()
        }
    }

    // Borrow a slot that can hold neededBytes. Returns nil if the pool is exhausted.
    fileprivate func checkout(neededBytes: Int) -> (slotIndex: Int, pointer: UnsafeMutableRawPointer)? {
        lock.lock()
        defer { lock.unlock() }
        for i in slots.indices where !slots[i].inUse {
            slots[i].inUse = true
            if slots[i].capacity < neededBytes {
                slots[i].pointer.deallocate()
                slots[i].pointer = .allocate(byteCount: neededBytes,
                                             alignment: MemoryLayout<UInt8>.alignment)
                slots[i].capacity = neededBytes
            }
            return (i, slots[i].pointer)
        }
        // Pool exhausted. The producer-side inflight threshold should usually drop earlier.
        exhaustionLogCount += 1
        if exhaustionLogCount <= 5 || exhaustionLogCount % 50 == 0 {
            SharedLogger.log("PCMBufferPool exhausted slots=\(slots.count) count=\(exhaustionLogCount)")
        }
        return nil
    }

    fileprivate func release(slotIndex: Int) {
        lock.lock()
        slots[slotIndex].inUse = false
        lock.unlock()
    }

    // Extract PCM synchronously on producer thread. Any failure path releases the borrowed slot.
    func extract(from sample: CMSampleBuffer) -> ExtractedAudioSample? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sample),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let frameCount = CMSampleBufferGetNumSamples(sample)
        guard frameCount > 0 else { return nil }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return nil }

        guard let (slotIndex, pointer) = checkout(neededBytes: totalLength) else {
            return nil
        }

        let status = CMBlockBufferCopyDataBytes(blockBuffer,
                                                atOffset: 0,
                                                dataLength: totalLength,
                                                destination: pointer)
        guard status == noErr else {
            release(slotIndex: slotIndex)
            return nil
        }

        let handle = PCMSlotHandle(pool: self,
                                   slotIndex: slotIndex,
                                   pointer: pointer,
                                   byteCount: totalLength)
        return ExtractedAudioSample(handle: handle,
                                    asbd: asbd,
                                    pts: pts,
                                    frameCount: frameCount)
    }
}
