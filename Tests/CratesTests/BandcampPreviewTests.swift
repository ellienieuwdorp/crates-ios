import Testing
import Foundation
@testable import CratesIOS

/// Bandcamp preview: tralbum parsing (pure), the player's resolve branch (stubbed resolver),
/// and a self-gating live resolve against the real synced library.
@MainActor
struct BandcampPreviewTests {

    // MARK: - Parser

    private let sampleHTML = """
    <html><body>
    <script data-tralbum="{&quot;current&quot;:{&quot;title&quot;:&quot;Framework 10&quot;},\
    &quot;trackinfo&quot;:[{&quot;id&quot;:357075818,&quot;file&quot;:{&quot;mp3-128&quot;:\
    &quot;https://t4.bcbits.com/stream/abc123/mp3-128/357075818?p=0&amp;ts=1751648000&quot;}}]}" \
    data-band="{}"></script>
    </body></html>
    """

    @Test func extractsStreamURLFromEntityEncodedTralbum() {
        let url = BandcampResolver.extractStreamURL(fromHTML: sampleHTML)
        #expect(url?.host?.contains("bcbits.com") == true)
        // &amp; must decode to & — a corrupted query string would 403 at the CDN.
        #expect(url?.query?.contains("ts=1751648000") == true)
    }

    @Test func protocolRelativeStreamURLGetsHTTPS() {
        let html = #"<div data-tralbum="{&quot;trackinfo&quot;:[{&quot;file&quot;:{&quot;mp3-128&quot;:&quot;//t4.bcbits.com/stream/x/mp3-128/1&quot;}}]}"></div>"#
        let url = BandcampResolver.extractStreamURL(fromHTML: html)
        #expect(url?.scheme == "https")
    }

    @Test func streamDisabledTrackYieldsNil() {
        // trackinfo present but file null — artist disabled streaming.
        let html = #"<div data-tralbum="{&quot;trackinfo&quot;:[{&quot;id&quot;:1,&quot;file&quot;:null}]}"></div>"#
        #expect(BandcampResolver.extractStreamURL(fromHTML: html) == nil)
    }

    @Test func pagesWithoutTralbumYieldNil() {
        #expect(BandcampResolver.extractStreamURL(fromHTML: "<html><body>nope</body></html>") == nil)
    }

    @Test func nonBcbitsStreamHostIsRejected() {
        // A crafted tralbum aiming AVPlayer at a LAN host must be refused (host-lock).
        let html = #"<div data-tralbum="{&quot;trackinfo&quot;:[{&quot;file&quot;:{&quot;mp3-128&quot;:&quot;http://192.168.1.50:8554/x.mp3&quot;}}]}"></div>"#
        #expect(BandcampResolver.extractStreamURL(fromHTML: html) == nil)
    }

    // MARK: - Host allowlists (fail closed)

    @Test func onlyHTTPSBandcampPagesResolve() {
        func tune(_ page: String?) -> Tune {
            Tune(id: 1, title: "t", artist: "a", source: .bandcamp, pageURL: page, hasServerAudio: false)
        }
        #expect(BandcampResolver.canResolve(tune("https://artist.bandcamp.com/track/x")))
        #expect(!BandcampResolver.canResolve(tune("http://artist.bandcamp.com/track/x")))   // plain http
        #expect(!BandcampResolver.canResolve(tune("http://192.168.1.1/cgi-bin/restart")))    // LAN target
        #expect(!BandcampResolver.canResolve(tune("https://evil.com/bandcamp.com/track")))   // path trick
        #expect(!BandcampResolver.canResolve(tune("https://notbandcamp.com/x")))              // suffix trick
        #expect(!BandcampResolver.canResolve(tune(nil)))
    }

    // MARK: - Player branch (stubbed resolver, no network)

    private func bandcampTune(_ id: Int64, page: String? = "https://artist.bandcamp.com/track/x") -> Tune {
        Tune(id: id, title: "bc\(id)", artist: "a", lengthSeconds: 200,
             source: .bandcamp, pageURL: page, hasServerAudio: false)
    }

    private func makeController() -> PlaybackController {
        let p = PlaybackController()
        p.attach(connection: CratesConnection(host: "127.0.0.1", port: 54735, token: "test"),
                 downloads: DownloadManager())
        return p
    }

    /// A minimal valid WAV so AVPlayer genuinely reaches readyToPlay (a bogus URL fails fast
    /// and the failure path masks the assertion).
    private func silentWAV() throws -> URL {
        let sampleRate: UInt32 = 8000, seconds = 1
        let dataSize = UInt32(Int(sampleRate) * seconds * 2)
        var d = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        append(UInt32(36 + dataSize)); d.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        d.append(contentsOf: "data".utf8); append(dataSize)
        d.append(Data(count: Int(dataSize)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silent-\(UUID().uuidString).wav")
        try d.write(to: url)
        return url
    }

    @Test func previewResolvesAndStartsEngine() async throws {
        let p = makeController()
        let wav = try silentWAV()
        p.previewResolver = { _ in wav }
        p.play([bandcampTune(1)], startingAt: 0)
        #expect(!p.isPlaying) // resolving: honest paused state, never fake-playing
        try await Task.sleep(for: .milliseconds(300))
        #expect(p.isPlaying) // engine spun up from the resolved URL
        #expect(p.playbackError == nil)
    }

    @Test func failedResolutionSurfacesErrorAndAutoAdvances() async throws {
        let p = makeController()
        p.previewResolver = { _ in throw BandcampResolver.ResolveError.notStreamable }
        let playable = Tune(id: 2, title: "ok", artist: "a", lengthSeconds: 100, hasServerAudio: true)
        p.play([bandcampTune(1), playable], startingAt: 0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(p.currentIndex == 1) // auto-skip carried the queue past the dead preview
    }

    @Test func trackChangeCancelsInFlightResolution() async throws {
        let p = makeController()
        let wav = try silentWAV()
        p.previewResolver = { tune in
            if tune.id == 1 { try await Task.sleep(for: .milliseconds(300)) } // slow first resolve
            return wav
        }
        p.play([bandcampTune(1), bandcampTune(2)], startingAt: 0)
        p.next() // user skips while tune 1 is still resolving → its task is cancelled
        try await Task.sleep(for: .milliseconds(600)) // past tune 1's would-be completion
        #expect(p.current?.id == 2)
        #expect(p.isPlaying) // tune 2's engine is live…
        #expect(p.playbackError == nil) // …and the cancelled resolve neither errored nor clobbered it
    }

    @Test func knownUnstreamableWithoutPageStaysDead() {
        let p = makeController()
        p.play([bandcampTune(1, page: nil)], startingAt: 0)
        #expect(p.playbackError != nil) // no preview source: honest failure, not a hang
    }

    // MARK: - Live (self-gating: paired app container + a real bandcamp tune with a page)

    @Test func liveResolveReturnsPlayableCDNURL() async throws {
        guard let tunes = await DiskCache.shared.load("all_tunes", as: [Tune].self),
              let candidate = tunes.first(where: { $0.hasPreviewSource }) else { return }
        do {
            let url = try await BandcampResolver.shared.resolve(candidate)
            #expect(url.host?.contains("bcbits.com") == true)
        } catch {
            // Offline or Bandcamp unreachable is not a code failure; markup changes would
            // surface as notStreamable here — worth knowing, so fail on that specifically.
            if case BandcampResolver.ResolveError.notStreamable = error {
                Issue.record("tralbum parse failed against live Bandcamp — markup may have changed")
            }
        }
    }
}
