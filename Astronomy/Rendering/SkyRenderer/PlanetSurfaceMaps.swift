//
//  PlanetSurfaceMaps.swift
//  Astronomy
//
//  The bundled global surface maps, loaded into one Metal texture array so a
//  single binding serves every body the point-sprite pass draws.
//
//  Only three bodies have a map, and the omissions are deliberate rather than
//  unfinished (see `DATA_SOURCES.md` for the full argument and the licence of
//  each image):
//
//   * **Mars** and the **Moon** genuinely show surface detail, and both have
//     an explicitly public-domain US Government mosaic.
//   * **Jupiter** shows real cloud structure, and NASA publishes a cylindrical
//     Cassini map of it.
//   * **Venus** and the **ice giants** are featureless in visible light. A map
//     of Venus's *radar* topography would show the user something no telescope
//     can see, which is worse than showing nothing.
//   * **Mercury**'s only public-domain global mosaic is MESSENGER's *enhanced*
//     colour, which is deliberately false-colour. Bundling it would paint
//     Mercury blue and tan.
//   * **Saturn** has no public-domain global colour map that could be
//     verified, so it keeps its procedural rings and flat golden disk.
//
//  Every map is 1024 x 512 equirectangular, spanning -180..+180 degrees east
//  longitude left to right and +90..-90 latitude top to bottom. That size is
//  chosen against the renderer, not against the source: a planet's ceiling is
//  260 points across (`StarAppearance.maximumPointSize`), it shows one
//  hemisphere, and a hemisphere is half the map's width — so 512 texels across
//  ~520 backing pixels on a Retina display is very close to one texel per
//  pixel at maximum zoom. A larger map would cost bundle size for detail no
//  field of view in this app can reach.
//

import Foundation
import Metal
import CoreGraphics
import ImageIO

enum PlanetSurfaceMaps {

    /// One body's map: its slice in the texture array and its bundled file.
    struct Entry {
        let objectID: String
        let resourceName: String
    }

    /// Slice order. **Keep in sync with `kMapMars`/`kMapJupiter`/`kMapMoon` in
    /// `Shaders.metal` and with `kMapMeanColor` there.**
    static let entries: [Entry] = [
        Entry(objectID: "mars", resourceName: "mars_map"),
        Entry(objectID: "jupiter", resourceName: "jupiter_map"),
        Entry(objectID: "moon", resourceName: "moon_map"),
    ]

    static let width = 1024
    static let height = 512

    /// The slice index for a body, or nil if it has no bundled map.
    ///
    /// A body only earns a map if it also has published rotation elements, or
    /// the texture would be drawn at an orientation nobody computed — which is
    /// the exact failure mode `PlanetaryOrientation` exists to avoid.
    static func slice(objectID id: String) -> Int? {
        guard PlanetaryOrientation.hasSurfaceMap(objectID: id) else { return nil }
        return entries.firstIndex { $0.objectID == id }
    }

    /// The value the renderer puts in `PointVertex.param7`: the slice index, or
    /// -1 for "no map, stay procedural".
    static func sliceParameter(objectID id: String) -> Float {
        Float(slice(objectID: id) ?? -1)
    }

    /// Builds the texture array, decoding each bundled JPEG into its slice.
    ///
    /// Returns nil if anything is missing, which the renderer treats as "no
    /// maps" — the procedural disks are a complete fallback, so a failure here
    /// costs appearance and nothing else.
    ///
    /// Called once, off the main thread, from `SkyRenderer`.
    static func makeTextureArray(device: MTLDevice, commandQueue: MTLCommandQueue) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.arrayLength = entries.count
        // Mip levels for a 1024-wide image: 1024, 512, ... 1. The fragment
        // shader picks the level explicitly from the sprite diameter, so these
        // are what keep a small disk from aliasing.
        descriptor.mipmapLevelCount = Int(log2(Double(width))) + 1
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        for (index, entry) in entries.enumerated() {
            guard let pixels = decodeRGBA(resourceName: entry.resourceName) else { return nil }
            pixels.withUnsafeBufferPointer { buffer in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    slice: index,
                    withBytes: buffer.baseAddress!,
                    bytesPerRow: width * 4,
                    bytesPerImage: width * height * 4
                )
            }
        }

        // Only level 0 was uploaded; the rest are filled on the GPU. Waiting
        // here is fine — this whole function runs off the main thread and off
        // the frame loop, once.
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return texture
    }

    /// Decodes a bundled JPEG into tightly-packed, top-row-first RGBA8.
    ///
    /// Drawn through a CoreGraphics bitmap context rather than read out of the
    /// image directly, so the result is a known layout regardless of what the
    /// JPEG's own colour space, orientation or row padding happen to be — and
    /// so a map that is not exactly 1024 x 512 is rescaled rather than
    /// corrupting the slice.
    private static func decodeRGBA(resourceName: String) -> [UInt8]? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        // CoreGraphics' origin is bottom-left and the maps are stored with
        // +90 degrees latitude on the *first* row, so the drawn buffer is
        // upside down relative to the v axis the shader assumes. Flip it here,
        // once at load, rather than costing a subtraction in every fragment.
        var flipped = [UInt8](repeating: 0, count: pixels.count)
        let rowBytes = width * 4
        for row in 0..<height {
            let source = row * rowBytes
            let destination = (height - 1 - row) * rowBytes
            flipped[destination..<(destination + rowBytes)] =
                pixels[source..<(source + rowBytes)]
        }
        return flipped
    }
}
