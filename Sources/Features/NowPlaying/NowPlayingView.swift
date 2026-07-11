import SwiftUI

/// Diagnostic tap for the queue-morph geometry (round-5 wave-2 jolt hunt). Inert unless the
/// app is launched with `-morphLog`; then every sheet-geometry callback and every anchor/
/// detent mutation appends a timestamped line to Documents/morph-log.txt, so a post-settle
/// height reversal shows up as hard evidence in the log tail.
@MainActor enum MorphLog {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-morphLog")
    private static var handle: FileHandle? = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("morph-log.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled, let handle else { return }
        let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, message())
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

/// `-morphLog` companion: a CADisplayLink that logs the sheet's PRESENTATION-layer origin
/// every display tick. The SwiftUI-side geometry callbacks coalesce animated changes to a
/// single model value, so only the render server's view of the sheet can show whether the
/// on-screen surface actually reverses direction after a settle (the reported jolt).
private struct SheetMotionProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ uiView: ProbeView, context: Context) {}

    @MainActor final class ProbeView: UIView {
        private var link: CADisplayLink?
        private var last: [Int: CGRect] = [:]
        private var dumpedChain = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            link?.invalidate()
            link = nil
            guard window != nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        }

        @objc private func tick() {
            var chain: [UIView] = []
            var v: UIView? = superview
            while let cur = v { chain.append(cur); v = cur.superview }
            if !dumpedChain {
                dumpedChain = true
                for (i, view) in chain.enumerated() {
                    MorphLog.log("chain[\(i)] \(String(describing: type(of: view)))")
                }
            }
            for (i, view) in chain.enumerated() {
                guard let pres = view.layer.presentation() else { continue }
                // Presentation frame (superlayer coords): whichever ancestor UIKit actually
                // moves shows the motion in its own local frame — enough to spot a reversal.
                let f = pres.frame
                let prev = last[i] ?? .null
                guard abs(f.origin.y - prev.origin.y) > 0.05
                    || abs(f.height - prev.height) > 0.05 else { continue }
                last[i] = f
                MorphLog.log("visual[\(i)] y=\(f.origin.y) h=\(f.height)")
            }
        }
    }
}

/// Full-screen player (Idea #4 v3 — see docs/design/now-playing-redesign.md). Two in-place
/// states on a two-detent sheet, no popups:
///
///   • collapsed — the sheet HUGS the content (measured detent): art, title, scrubber, one
///     transport row, and the Up Next glass pill. iOS 26 floats partial sheets inset with
///     Liquid Glass corners automatically.
///   • expanded — tap the pill or drag the sheet up: the header morphs into a compact
///     art+title row and the queue unfolds, split into "Added to Queue" (manual) and
///     "From <context>" (auto). The system sheet drag IS the expand/collapse gesture.
///
/// Layout rules: one 24pt gutter for everything (the "transport axis"), 8pt-grid spacing,
/// transport controls in equal-width slots so the play button is structurally centered, and
/// exactly one glass element (the handle pill) per HIG layering.
struct NowPlayingView: View {
    @Environment(PlaybackController.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var queueExpanded = false
    @State private var editMode: EditMode = .inactive
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    /// Measured height of the hugging collapsed stack — drives the collapsed detent. Seeded
    /// with a realistic value so the first frame doesn't flash a sliver-height sheet.
    @State private var collapsedHeight: CGFloat = 560

    // MARK: Continuous morph driver (Ellie, 2026-07-10: queue faded on its own curve)
    //
    // The sheet's content height changes LIVE while a detent drag is in flight, but
    // `queueExpanded` only flips when the drag settles — anything keyed to the boolean
    // animates on its own discrete curve after the finger already moved. So the morph is
    // driven by `morphProgress`, derived every frame from the measured sheet height; the
    // boolean keeps settled-state semantics only (hit-testing, edit-mode exit, dismissal,
    // detent measurement guard, the collapse chevron).

    /// Live height of the sheet root — tracks the finger during a detent drag.
    @State private var sheetHeight: CGFloat = 0
    /// Live width — a change means rotation/resize, which invalidates the height anchors.
    @State private var sheetWidth: CGFloat = 0
    /// Constant offset between the root's measured height and the collapsed detent value
    /// (sheet chrome / safe-area delta). Min-ratcheted at settled rests: a mid-drag hold can
    /// only sit ABOVE the collapsed rest, so a too-large candidate is always rejected.
    @State private var collapsedChrome: CGFloat?
    /// Root height at the settled `.large` detent. Max-ratcheted at settled rests: a mid-drag
    /// hold can only sit BELOW the large rest, so a too-small candidate is always rejected.
    @State private var expandedSheetHeight: CGFloat?
    /// Debounce for anchor capture — only a height that has been still for a beat is a
    /// settled detent (drag and animation heights stream continuously, rests are silent).
    @State private var anchorSettleTask: Task<Void, Never>?
    /// A collapsed-content measurement that arrived mid-morph. `onGeometryChange` fires only
    /// on CHANGE, so a rejected measurement would otherwise be lost forever and the detent
    /// stuck on a stale height (hit at accessibility sizes, where the very first measurement
    /// lands while the estimated progress is briefly non-zero). Applied at the next rest.
    @State private var pendingCollapsedHeight: CGFloat?

    // Haptic triggers (TODO §6 haptics pass — subtle, standard styles).
    @State private var transportPulse = 0 // play/pause, next, previous → light impact
    @State private var modePulse = 0      // shuffle, repeat — mode selection → selection tick
    @State private var queuePulse = 0     // queue row jump / remove / reorder → light impact

    private let inset: CGFloat = 24

    /// The settled `.large` sheet height is device/orientation-constant, but `@State` dies
    /// with each presentation — cache it so a re-opened player's very first drag already has
    /// the true morph span instead of the estimated one.
    @MainActor private enum SheetAnchorCache {
        static var expandedHeight: CGFloat?
    }

    /// 0 = settled collapsed, 1 = settled expanded, tracking the FINGER, not the detent.
    /// Every cross-fade/opacity/shadow in the morph keys off this one value so the player
    /// header and the queue fade as a single surface under the drag, both directions.
    private var morphProgress: CGFloat {
        let floor = collapsedHeight + (collapsedChrome ?? 0)
        // 175: measured .large-vs-collapsed content span on iPhone 17 Pro — only the very
        // first drag of a launch ever uses it; the first expanded geometry callback captures
        // the true value inline (riding that callback's own transaction, so a seed miss still
        // glides — calibration never starts an animation of its own).
        let ceiling = expandedSheetHeight ?? SheetAnchorCache.expandedHeight ?? (floor + 175)
        guard ceiling - floor > 1 else { return queueExpanded ? 1 : 0 }
        return min(1, max(0, (sheetHeight - floor) / (ceiling - floor)))
    }

    /// Discrete layout swaps that can't interpolate (HStack↔VStack, artwork 264↔64, the
    /// 8pt-grid padding steps) flip at the morph midpoint — with their own animation — so
    /// they also happen under the finger, symmetrically in both directions.
    private var layoutExpanded: Bool { morphProgress >= 0.5 }

    /// Collapsed hero art: 264pt, scaled well down at accessibility type sizes so the
    /// collapsed stack still fits on screen (TODO §6 residual — the text growth is what
    /// earns the room; the sheet also caps its type at accessibility2, see body).
    private var collapsedArtSize: CGFloat { dynamicTypeSize.isAccessibilitySize ? 112 : 264 }

    private var collapsedDetent: PresentationDetent { .height(collapsedHeight) }
    /// Derived, never stored: PresentationDetent identity is value-based, so the selection must
    /// always be recomputed from state or a re-measure would orphan it (runtime warning + snap).
    private var detentSelection: Binding<PresentationDetent> {
        Binding(
            get: { queueExpanded ? .large : collapsedDetent },
            set: { newValue in
                // Fires once when a user drag settles — animate our content morph in sync.
                MorphLog.log("detentSettle large=\(newValue == .large)")
                withAnimation(.snappy(duration: 0.35)) {
                    queueExpanded = (newValue == .large)
                    if !queueExpanded { editMode = .inactive } // drag-collapse must exit edit like tap-collapse
                }
            }
        )
    }

    var body: some View {
        Group {
            if let tune = player.current {
                playerLayout(tune)
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
            }
        }
        // The collapsed player is a fixed vertical stack: past accessibility2 it cannot
        // physically fit any screen (a content-hugging detent taller than `.large` clips
        // the transport off screen). Capping here keeps every control reachable — the HIG's
        // "adjust layout when text can't be accommodated" escape hatch.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .presentationDetents([collapsedDetent, .large], selection: detentSelection)
        .presentationDragIndicator(.visible)
        // Expanded: a hard downward fling settles at the collapsed detent instead of blowing
        // through it and dismissing the player. Collapsed: swipe-down still dismisses.
        .interactiveDismissDisabled(queueExpanded)
        .sensoryFeedback(.impact(weight: .light), trigger: transportPulse)
        .sensoryFeedback(.selection, trigger: modePulse)
        .sensoryFeedback(.impact(weight: .light), trigger: queuePulse)
        .background { if MorphLog.enabled { SheetMotionProbe() } }
    }

    /// Feeds the morph driver from the sheet root's live size and captures the two height
    /// anchors, but only once a height has been still for a beat (a settled detent) — see
    /// the ratchet notes on the properties for why a mid-drag finger hold is harmless.
    private func trackSheetSize(_ size: CGSize) {
        if size.width != sheetWidth {
            // Rotation/resize: both anchors describe the old geometry.
            sheetWidth = size.width
            collapsedChrome = nil
            expandedSheetHeight = nil
            SheetAnchorCache.expandedHeight = nil
        }
        MorphLog.log("sheet h=\(size.height) progress=\(morphProgress)")
        sheetHeight = size.height
        // Expanded anchor, captured inline: while `queueExpanded` the model height is the
        // settled `.large` value (tap changes coalesce to it instantly; a collapse drag only
        // goes below it, and the max-ratchet rejects that). No withAnimation — if this
        // callback rides an animated transaction (the tap-expand resize), the fades that key
        // off morphProgress glide with that same transaction; calibration itself must never
        // START an animation (round-5 wave-2: post-settle animated corrections ARE the jolt).
        if queueExpanded, size.height > (expandedSheetHeight ?? 0) {
            MorphLog.log("anchor inline expandedSheetHeight=\(size.height)")
            expandedSheetHeight = size.height
            SheetAnchorCache.expandedHeight = size.height
        }
        scheduleAnchorCapture()
    }

    /// Also called when `queueExpanded` settles: an overdrag past `.large` clamps the content
    /// at its final size EARLY, so the settle itself produces no geometry callback — without
    /// this the expanded anchor would never be captured on a from-collapsed overdrag.
    private func scheduleAnchorCapture() {
        anchorSettleTask?.cancel()
        anchorSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            // THE STEADY-STATE RULE (round-5 wave-2, Ellie's "extra up-down jolt"): once a
            // detent has settled, nothing here may start a layout-affecting animation.
            // Calibration values feed only the progress mapping for FUTURE drags — they apply
            // bare, with no transaction. The one thing that may still move layout is a real
            // content-height change (parked below), and only when it actually differs.
            if queueExpanded {
                let anchored = max(expandedSheetHeight ?? 0, sheetHeight)
                MorphLog.log("anchor expandedSheetHeight=\(anchored) (was \(String(describing: expandedSheetHeight)))")
                expandedSheetHeight = anchored
                SheetAnchorCache.expandedHeight = anchored
            } else if let pending = pendingCollapsedHeight {
                // A measurement parked mid-morph: honor it at rest — but only if the content
                // is genuinely different from the current detent. After a plain collapse the
                // remeasure lands back on the same height, and re-applying it would animate
                // the ACTIVE detent right after the settle (the drag-path jolt).
                pendingCollapsedHeight = nil
                if abs(pending - collapsedHeight) >= 1 {
                    MorphLog.log("anchor applyPendingCollapsed=\(pending) (collapsedHeight was \(collapsedHeight))")
                    withAnimation(.smooth(duration: 0.3)) { collapsedHeight = pending }
                }
            } else if sheetHeight > 0 {
                let chrome = min(collapsedChrome ?? .infinity, sheetHeight - collapsedHeight)
                MorphLog.log("anchor chrome=\(chrome) (was \(String(describing: collapsedChrome)))")
                collapsedChrome = chrome
            }
        }
    }

    // MARK: - One layout for both detents
    //
    // A single tree whose header morphs — never an if/else branch swap. Two view identities
    // linked by matchedGeometryEffect can't hero-morph while UIKit animates the sheet's own
    // coordinate space (stale anchors, double artwork, placeholder flashes — dogfood round 3,
    // W2). With one Artwork and stable scrubber/transport/list identities, the only SwiftUI-
    // animated deltas are small local motions; the detent animation carries the rest.

    private func playerLayout(_ tune: Tune) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    morphingHeader(tune)
                        .padding(.top, layoutExpanded ? 24 : 28)
                    scrubber
                        .padding(.top, layoutExpanded ? 16 : 20)
                    transport(scrollProxy: proxy)
                        .padding(.top, layoutExpanded ? 8 : 12)
                    queueHandle
                        .padding(.top, layoutExpanded ? 12 : 16)
                        .padding(.bottom, layoutExpanded ? 0 : 4)
                }
                .padding(.horizontal, inset)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true) // hug intrinsic height for measurement
                // Animates the mid-drag threshold flips (layout swap, art size, paddings);
                // the continuous progress-driven fades never pass through here.
                .animation(.snappy(duration: 0.35), value: layoutExpanded)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    // Only the settled collapsed SHAPE defines the detent: mid-morph the art/
                    // paddings are in flight (threshold-keyed), and measuring them would feed
                    // the detent back into the very drag that's moving it.
                    guard !queueExpanded, !layoutExpanded else { return }
                    let measured = height.rounded(.up)
                    guard abs(measured - collapsedHeight) >= 1 else { return } // ignore float jitter
                    if collapsedChrome == nil {
                        // Presentation phase: no rest has calibrated the anchors yet, so this
                        // is the seed being corrected while the open animation is still in
                        // flight. Fold it into that animation by re-targeting the detent NOW,
                        // with no transaction of our own — deferring it used to bump the sheet
                        // a beat AFTER the open settled (round-5 wave-2 item 2, the every-open
                        // jolt: the @State seed dies with each presentation, so every open
                        // measured ~605 against the 560 seed and animated the late correction).
                        MorphLog.log("measure applyCollapsedPresenting=\(measured) (was \(collapsedHeight))")
                        collapsedHeight = measured
                    } else if morphProgress < 0.02 {
                        // Settled collapsed rest: genuine content growth (title wrap, error
                        // line appearing). The one legitimate post-settle layout move —
                        // smooth, so a real change glides without a bounce.
                        MorphLog.log("measure applyCollapsed=\(measured) (was \(collapsedHeight))")
                        withAnimation(.smooth(duration: 0.3)) { collapsedHeight = measured }
                    } else {
                        // Mid-morph: park it — scheduleAnchorCapture applies it at rest, and
                        // only if it still differs from the detent by then.
                        MorphLog.log("measure parkCollapsed=\(measured) progress=\(morphProgress)")
                        pendingCollapsedHeight = measured
                    }
                }

                queueList
                    .opacity(morphProgress) // fades in lockstep with the header cross-fade
                    .allowsHitTesting(queueExpanded) // clipped below the fold when collapsed
                    .overlay(alignment: .bottomTrailing) {
                        // One-handed collapse: the system already turns a list-top pull into a
                        // detent drag, but mid-list you'd have to scroll up first — this floats
                        // in the thumb zone instead.
                        if queueExpanded {
                            Button { setQueue(expanded: false) } label: {
                                Image(systemName: "chevron.down")
                                    .font(.body.weight(.semibold))
                                    .frame(width: 44, height: 44)
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .padding(.trailing, inset)
                            .padding(.bottom, 12)
                            .accessibilityLabel("Collapse queue")
                            .accessibilityIdentifier("queueCollapseChevron")
                        }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The morph driver: this root fills the sheet, so its size IS the sheet's live
            // size — the system updates it every frame of a detent drag.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { trackSheetSize($0) }
            .onChange(of: queueExpanded) { scheduleAnchorCapture() }
        }
    }

    /// The one Artwork, morphing 264↔64 inside an AnyLayout (VStack under ↔ HStack beside);
    /// the two text blocks cross-fade in place (both always laid out, so the header height
    /// never snaps at transition end). All fades ride `morphProgress` continuously; only the
    /// non-interpolable layout swap keys off the mid-drag threshold.
    private func morphingHeader(_ tune: Tune) -> some View {
        let p = morphProgress
        let layout = layoutExpanded
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            : AnyLayout(VStackLayout(spacing: 16))
        return layout {
            Artwork(tune: tune, size: layoutExpanded ? 64 : collapsedArtSize)
                .shadow(color: .black.opacity(0.22 - 0.10 * p),
                        radius: 20 - 12 * p, y: 10 - 6 * p)
            ZStack(alignment: .leading) {
                titleBlock(tune)
                    .frame(maxWidth: .infinity)
                    .opacity(1 - p)
                    .accessibilityHidden(queueExpanded)
                compactTitles(tune)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(p)
                    .accessibilityHidden(!queueExpanded)
            }
        }
        .geometryGroup()
    }

    private func titleBlock(_ tune: Tune) -> some View {
        VStack(spacing: 4) {
            Text(tune.displayTitle).font(.title2.bold()).multilineTextAlignment(.center).lineLimit(2)
            HStack(spacing: 6) {
                SourceBadge(source: tune.source)
                Text(tune.displayArtist).font(.title3).foregroundStyle(CratesColor.textSecondary)
            }
            metaLine(tune)
        }
    }

    /// Third line of the title block: the playback error takes the genre line's slot, so an
    /// error appearing never shifts the rest of the layout.
    @ViewBuilder private func metaLine(_ tune: Tune) -> some View {
        if let error = player.playbackError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(CratesColor.red)
                .lineLimit(2).multilineTextAlignment(.center)
        } else if !metaText(tune).isEmpty {
            Text(metaText(tune))
                .font(.footnote).foregroundStyle(CratesColor.textSecondary)
        }
    }

    /// "Techno · 132 BPM · A♭m" with missing parts dropped — never a dangling separator.
    private func metaText(_ tune: Tune) -> String {
        [tune.genre, tune.bpm.map { "\($0) BPM" }, tune.key]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Text-only compact block (art lives in morphingHeader).
    private func compactTitles(_ tune: Tune) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tune.displayTitle).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                SourceBadge(source: tune.source)
                Text(tune.displayArtist).font(.subheadline)
                    .foregroundStyle(CratesColor.textSecondary).lineLimit(1)
            }
            if let error = player.playbackError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(CratesColor.red)
                    .lineLimit(2) // the error is the one line that must stay readable
            } else if !metaText(tune).isEmpty {
                Text(metaText(tune))
                    .font(.caption).foregroundStyle(CratesColor.textSecondary).lineLimit(1)
            }
        }
    }

    // MARK: - Scrubber & transport (shared, never move during the morph)

    /// Thumbless Apple-Music-style progress bar: a capsule that thickens while dragging.
    /// The stock Slider's oversized thumb overhung the track start and read template-y.
    private var scrubber: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let duration = max(player.duration, 1)
                let shown = isScrubbing ? scrubValue : player.currentTime
                let fraction = min(1, max(0, shown / duration))
                ZStack(alignment: .leading) {
                    Capsule().fill(CratesColor.textSecondary.opacity(0.22))
                    Capsule().fill(CratesColor.accent)
                        .frame(width: max(geo.size.width * fraction, fraction > 0 ? 6 : 0))
                }
                .frame(height: isScrubbing ? 12 : 6)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            let fraction = min(1, max(0, value.location.x / max(geo.size.width, 1)))
                            scrubValue = fraction * duration
                        }
                        .onEnded { _ in
                            player.seek(to: scrubValue)
                            isScrubbing = false
                        }
                )
            }
            .frame(height: 24) // full-height hit area around the thin bar
            .animation(.snappy(duration: 0.2), value: isScrubbing)

            HStack {
                Text(timeLabel(isScrubbing ? scrubValue : player.currentTime))
                Spacer()
                Text("-" + timeLabel(max(0, player.duration - (isScrubbing ? scrubValue : player.currentTime))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(CratesColor.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(timeLabel(player.currentTime))
        .accessibilityAdjustableAction { direction in
            let delta: Double = direction == .increment ? 15 : -15
            player.seek(to: min(max(0, player.currentTime + delta), player.duration))
        }
    }

    /// Five equal-width slots: the play button is structurally on the sheet's center axis
    /// (Spacer-based centering only holds when flank glyph widths happen to match). One icon
    /// treatment throughout — primary when off, accent when on — so shuffle/repeat don't read
    /// as disabled next to the filled prev/next glyphs. Sizes identical in both detents so the
    /// morph doesn't re-scale the controls.
    private func transport(scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            Button {
                modePulse += 1
                // Same transaction for the reorder, the edit-mode exit, and the scroll: rows
                // travel to their new slots instead of the list snapping (dogfood round 4, I5).
                withAnimation(.snappy(duration: 0.35)) {
                    editMode = .inactive // mutating under an in-flight reorder drag is a glitch source
                    player.toggleShuffle()
                    if queueExpanded, let first = upNextEntries.first?.id {
                        scrollProxy.scrollTo(first, anchor: .top)
                    }
                }
            } label: {
                Image(systemName: "shuffle").font(.title3.weight(.semibold))
                    .foregroundStyle(player.isShuffled ? CratesColor.accent : .primary)
            }
            .frame(maxWidth: .infinity)
            Button { transportPulse += 1; player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                .frame(maxWidth: .infinity)
            Button { transportPulse += 1; player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 62))
                    .foregroundStyle(CratesColor.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("playerPlayPause") // stable hook for UI tests (state-independent)
            Button { transportPulse += 1; player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                .frame(maxWidth: .infinity)
            Button { modePulse += 1; cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3.weight(.semibold))
                    .foregroundStyle(player.repeatMode == .off ? .primary : CratesColor.accent)
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.primary)
        .tint(CratesColor.accent)
    }

    // MARK: - Up Next handle (the one glass element on this screen)

    /// A single centered pill on the transport's center axis — nothing else shares its row, so
    /// a near-miss can't hit a different control (Edit lives in the queue's section header).
    /// Tap toggles; the system sheet drag between detents is the swipe gesture (a custom
    /// DragGesture would fight it).
    ///
    /// Hit-testing is asymmetric on purpose (round-5 wave-2 item 4): while COLLAPSED the whole
    /// row expands the queue (a generous target for a small pill), but while EXPANDED only the
    /// pill itself collapses — the full-width rect used to sit exactly where a finger reaches
    /// for the queue header, so a missed Edit tap instantly hid the list being edited. Blank
    /// space never collapses; collapse stays on the pill, the floating chevron, and the drag.
    private var queueHandle: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.compact.up")
                .font(.body.weight(.semibold))
                .rotationEffect(.degrees(180 * morphProgress)) // flips continuously with the drag
            // No count: "Queue · 2000" after playing a big crate is noise, not information.
            Text("Queue").font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect) // the pill's own ≥44pt target — the inner gesture wins over the row's
        .onTapGesture { setQueue(expanded: !queueExpanded) }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onTapGesture { if !queueExpanded { setQueue(expanded: true) } } // blank space: expand-only
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(queueExpanded ? "Collapse queue" : "Expand queue")
        .accessibilityIdentifier("queueHandle")
        .accessibilityAdjustableAction { direction in
            setQueue(expanded: direction == .increment)
        }
    }

    private var queueList: some View {
        List {
            if !manualBlock.isEmpty {
                Section {
                    queueRows(manualBlock, baseIndex: upNextStart, isLastSection: contextBlock.isEmpty)
                } header: {
                    sectionHeader("Added to Queue", showsEdit: true)
                }
                .listSectionMargins(.top, 0)
            }
            if !contextBlock.isEmpty {
                Section {
                    queueRows(contextBlock, baseIndex: upNextStart + manualBlock.count, isLastSection: true)
                } header: {
                    sectionHeader(contextHeader, showsEdit: manualBlock.isEmpty)
                }
                .listSectionMargins(.top, manualBlock.isEmpty ? 0 : 8)
            }
            if upNextEntries.isEmpty {
                Text("Nothing up next — swipe right on any track to queue it.")
                    .font(.footnote).foregroundStyle(CratesColor.textSecondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 12, leading: inset, bottom: 12, trailing: inset))
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("queueList") // scope for UI-test queries (crate rows share titles)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .listSectionSpacing(8)
        .environment(\.defaultMinListHeaderHeight, 1)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .environment(\.editMode, $editMode)
    }

    /// Section header row: title leading, Edit/Done trailing (classic iOS grammar — the Edit
    /// control lives with the list it edits, not inside the drag pill's tap area). The button
    /// is a real labeled control with a ≥44pt hit target (round-5 wave-2 item 4: the old
    /// footnote-sized text was easy to miss, and missing it used to collapse the queue).
    private func sectionHeader(_ title: String, showsEdit: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.footnote.smallCaps().weight(.semibold))
                .foregroundStyle(CratesColor.textSecondary)
            Spacer()
            if showsEdit {
                Button {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                } label: {
                    Text(editMode == .active ? "Done" : "Edit")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(CratesColor.accent)
                .accessibilityIdentifier("queueEdit")
            }
        }
        .textCase(nil)
        .listRowInsets(.init(top: 0, leading: inset, bottom: showsEdit ? 0 : 4, trailing: inset))
    }

    private func queueRows(_ block: [QueueEntry], baseIndex: Int, isLastSection: Bool) -> some View {
        ForEach(block) { entry in
            QueueRow(tune: entry.tune)
                .contentShape(.rect)
                .onTapGesture {
                    if let i = player.entries.firstIndex(where: { $0.id == entry.id }) {
                        queuePulse += 1
                        player.jump(to: i)
                    }
                }
                .listRowInsets(.init(top: 8, leading: inset, bottom: 8, trailing: inset))
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                .listRowSeparator(
                    isLastSection && entry.id == block.last?.id ? .hidden : .automatic,
                    edges: .bottom) // no dangling separator under the final row
        }
        .onDelete { offsets in
            queuePulse += 1
            player.removeFromQueue(at: IndexSet(offsets.map { $0 + baseIndex }))
        }
        .onMove { source, destination in
            queuePulse += 1
            player.moveInQueue(from: IndexSet(source.map { $0 + baseIndex }),
                               to: destination + baseIndex)
        }
    }

    private var contextHeader: String {
        player.contextName.map { "From \($0)" } ?? "Up Next"
    }

    private func setQueue(expanded: Bool) {
        MorphLog.log("setQueue expanded=\(expanded)")
        withAnimation(.snappy(duration: 0.35)) {
            queueExpanded = expanded
            if !expanded { editMode = .inactive }
        }
    }

    // MARK: - Queue slices

    private var upNextStart: Int { (player.currentIndex ?? -1) + 1 }
    private var upNextEntries: [QueueEntry] { Array(player.entries.dropFirst(upNextStart)) }
    /// Manual additions (play-next + queued) directly after the current track — the controller
    /// keeps them ahead of the remaining context (see PlaybackController's ordering invariant).
    private var manualBlock: [QueueEntry] { Array(upNextEntries.prefix(while: { $0.origin != .context })) }
    private var contextBlock: [QueueEntry] { Array(upNextEntries.dropFirst(manualBlock.count)) }

    private func cycleRepeat() {
        player.repeatMode = switch player.repeatMode {
        case .off: .all; case .all: .one; case .one: .off
        }
    }

    private func timeLabel(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
}
