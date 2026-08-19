//
//  RingVertexBuffer.swift
//  Astronomy
//
//  A small ring of reusable Metal vertex buffers.
//
//  The renderer used to call `device.makeBuffer(bytes:length:options:)` once
//  per vertex stream per frame. That is a fresh allocation — allocator, VM
//  mapping, and eventually a deallocation — sixty times a second on the one
//  thread in the app with a hard deadline. It is a classic source of the
//  occasional long frame, because most of those calls are cheap and then one
//  of them is not.
//
//  Instead each stream keeps a few buffers, grown to the high-water mark and
//  written in place. Why more than one: a buffer handed to the GPU is not
//  finished with when the next frame begins encoding, so writing into the
//  same storage immediately would tear the geometry mid-flight. Cycling
//  through `slotCount` of them gives the GPU that many frames of slack, which
//  matches the depth MetalKit's own drawable rotation implies.
//

import Foundation
import Metal

struct RingVertexBuffer {

    private var buffers: [MTLBuffer?]
    private var next = 0

    init(slotCount: Int) {
        buffers = Array(repeating: nil, count: max(1, slotCount))
    }

    /// A buffer containing `vertices`, reusing existing storage when it is
    /// large enough. Returns nil only if allocation genuinely fails.
    ///
    /// Growth is by doubling with a floor, so a sky that briefly gets busier
    /// does not reallocate on every frame of the transition.
    mutating func buffer<Vertex>(for vertices: [Vertex], device: MTLDevice) -> MTLBuffer? {
        guard !vertices.isEmpty else { return nil }
        let length = MemoryLayout<Vertex>.stride * vertices.count

        let slot = next
        next = (next + 1) % buffers.count

        var buffer = buffers[slot]
        if buffer == nil || buffer!.length < length {
            let capacity = max(length * 2, 64 * 1024)
            buffer = device.makeBuffer(length: capacity, options: .storageModeShared)
            buffers[slot] = buffer
        }
        guard let buffer else { return nil }

        vertices.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: length)
        }
        return buffer
    }
}
