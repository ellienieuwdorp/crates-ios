import UIKit
import ImageIO

/// Two-tier album-art cache (dogfood round 4, I3).
///
/// Memory: decoded UIImages in an NSCache — deliberately OUTSIDE actor isolation (NSCache is
/// documented thread-safe) so views get a SYNCHRONOUS hit and cached art renders in the first
/// body pass: no placeholder frame, no fade, no pop.
///
/// Disk: original JPEG bytes as served, one file per coverID under Caches/Artwork. The real
/// corpus measures ~112MB (1803 covers, 62KB average), so the 200MB cap holds everything —
/// LRU eviction is a safety valve, not a working limit. Caches/ is system-purgeable and
/// unauthenticated-refetchable, which is exactly right for this data.
///
/// Server reality (verified live): `?size=<int>` is REJECTED with 400 — only `thumb` (100px,
/// unreliable) and `original` exist. So: fetch the original once, downsample on-device with
/// ImageIO into variant buckets. One network fetch + one disk file serves every size.
actor ArtworkStore {
    static let shared = ArtworkStore()

    /// Downsample buckets, not raw pixel sizes — 40/48/64pt rows share one decode.
    enum Variant: String, Sendable {
        case row      // ≤192px (64pt @3x)
        case display  // ≤800px (player art, lock screen)

        var maxPixel: CGFloat {
            switch self {
            case .row: 192
            case .display: 800
            }
        }
    }

    /// Thread-safe by documentation (hence nonisolated(unsafe) — the compiler can't see NSCache's
    /// internal locking); nonisolated so MainActor views can hit it synchronously.
    private nonisolated(unsafe) let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024 // decoded-pixel bytes
        return cache
    }()

    private var connection: CratesConnection?
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// coverID → last failure time; stops offline scrolling from re-issuing doomed fetches.
    private var failedAt: [Int64: Date] = [:]
    private var bytesWrittenSinceSweep: Int = 0

    private static let diskCap = 200 * 1024 * 1024
    private static let retryInterval: TimeInterval = 60

    private nonisolated static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
    }

    func update(connection: CratesConnection) {
        self.connection = connection
        failedAt = [:]
    }

    /// Synchronous memory-tier lookup for first-frame renders. MainActor-callable.
    nonisolated func cachedImage(coverID: Int64, variant: Variant) -> UIImage? {
        memory.object(forKey: Self.key(coverID, variant))
    }

    /// Full pipeline: memory → disk (+decode) → network (+persist +decode). Coalesced per key.
    func image(coverID: Int64, variant: Variant) async -> UIImage? {
        let key = Self.key(coverID, variant)
        if let hit = memory.object(forKey: key) { return hit }
        if let existing = inFlight[key as String] { return await existing.value }
        if let failed = failedAt[coverID], Date().timeIntervalSince(failed) < Self.retryInterval {
            return nil
        }

        let task = Task<UIImage?, Never> { [connection] in
            // Disk tier: original bytes downsampled to the requested variant.
            let fileURL = Self.directory.appendingPathComponent("\(coverID).jpg")
            if let data = try? Data(contentsOf: fileURL),
               let image = Self.downsample(data: data, maxPixel: variant.maxPixel) {
                Self.touch(fileURL)
                return image
            }
            // Network tier: fetch the original once.
            guard let url = connection?.coverURL(coverID: coverID, size: .original) else { return nil }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = Self.downsample(data: data, maxPixel: variant.maxPixel) else { return nil }
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try? data.write(to: fileURL)
            return image
        }
        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil

        if let image {
            memory.setObject(image, forKey: key, cost: Self.cost(of: image))
            failedAt[coverID] = nil
            bytesWrittenSinceSweep += 64 * 1024 // coarse; exact size irrelevant to the valve
            if bytesWrittenSinceSweep > 20 * 1024 * 1024 {
                bytesWrittenSinceSweep = 0
                sweepDisk()
            }
        } else {
            failedAt[coverID] = Date()
        }
        return image
    }

    /// Warm covers ahead of need (queue-driven, or the full-corpus trickle from Settings).
    nonisolated func prefetch(coverIDs: [Int64], variant: Variant) {
        Task(priority: .utility) {
            for id in coverIDs {
                _ = await self.image(coverID: id, variant: variant)
            }
        }
    }

    /// Delta sync reported changed covers: drop both tiers so the next render refetches.
    /// NEVER call with a full sync's Covers table — that's the entire corpus.
    func invalidate(coverIDs: [Int64]) {
        for id in coverIDs {
            memory.removeObject(forKey: Self.key(id, .row))
            memory.removeObject(forKey: Self.key(id, .display))
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("\(id).jpg"))
            failedAt[id] = nil
        }
    }

    func clear() {
        memory.removeAllObjects()
        inFlight = [:]
        failedAt = [:]
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: - Internals

    private nonisolated static func key(_ coverID: Int64, _ variant: Variant) -> NSString {
        "\(coverID)-\(variant.rawValue)" as NSString
    }

    private nonisolated static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    /// ImageIO downsample: decodes at most maxPixel on the long edge, cached immediately —
    /// never inflates the full original into memory.
    private nonisolated static func downsample(data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cg)
    }

    private nonisolated static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// LRU safety valve: evict oldest-touched files down to 90% of the cap.
    private nonisolated func sweepDisk() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.directory,
                                                      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > Self.diskCap else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > Self.diskCap * 9 / 10 else { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
