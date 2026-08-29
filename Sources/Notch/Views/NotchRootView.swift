import SwiftUI

/// The black blob: a tiny pill when idle, an expanding panel with tabs when open.
/// The hosting window is a fixed size (`ScreenMetrics.expandedSize`); this view paints
/// a blob that grows/shrinks within it, so open/close is one smooth SwiftUI animation.
struct NotchRootView: View {
    @EnvironmentObject private var notch: NotchState
    @EnvironmentObject private var claude: ClaudeSessionStore

    /// Shared namespace for `matchedGeometryEffect` on the album art and dancing
    /// bars — lets SwiftUI morph those elements between the peek's small layout
    /// and the music tab's larger layout instead of cross-fading two copies
    /// (which read as a teleport).
    @Namespace private var chromeNS

    // Open is a touch slower than close so the content has time to register on the
    // eye; close feels right at 0.22s.
    private static let openAnim: Animation = .easeOut(duration: 0.32)
    private static let closeAnim: Animation = .easeOut(duration: 0.22)
    private var transitionAnim: Animation { notch.isOpen ? Self.openAnim : Self.closeAnim }

    private var blobSize: CGSize {
        if notch.toast != nil { return ScreenMetrics.toastSize(for: dock) }
        return notch.openBlobSize(sessionRows: claude.sessions.count)
    }
    private var bottomRadius: CGFloat {
        if notch.toast != nil { return 16 }
        let collapsed = ScreenMetrics.collapsedSize(for: dock)
        return notch.isOpen ? 20 : min(10, min(collapsed.width, collapsed.height) / 2)
    }

    private var dock: NotchDock { notch.dock }
    private var dockEdge: Edge {
        switch dock { case .top: .top; case .left: .leading; case .right: .trailing }
    }
    private var dockAlignment: Alignment {
        switch dock { case .top: .top; case .left: .leading; case .right: .trailing }
    }
    private var dockAnchor: UnitPoint {
        switch dock { case .top: .top; case .left: .leading; case .right: .trailing }
    }

    private var blobShape: NotchShape { NotchShape(cornerInset: 8, bottomRadius: bottomRadius, edge: dockEdge) }

    var body: some View {
        ZStack {
            // While a drag is in flight the blob tears off its edge and
            // vanishes; DockDragOverlay draws the droplet and landing ghost.
            // It pops back in on the new edge once the droplet has landed.
            if !notch.isDockDragging {
                dockedBlob
                    .transition(.scale(scale: 0.6, anchor: dockAnchor).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.72), value: notch.isDockDragging)
        .gesture(dockDragGesture)
    }

    /// Click-hold-drag anywhere on the blob that isn't already a control tears
    /// the notch off its edge. The gesture's coordinates are irrelevant — the
    /// drag controller follows the real cursor — it only marks the press's
    /// lifetime. Child gestures (transport, scrubber, gear…) win in their areas.
    private var dockDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { _ in
                if !notch.isDockDragging { AppDelegate.shared?.dockDragBegan() }
            }
            .onEnded { _ in AppDelegate.shared?.dockDragEnded() }
    }

    private var dockedBlob: some View {
        ZStack(alignment: dockAlignment) {
            // Directional drop shadow — a blurred dark capsule positioned just
            // past the blob's free edge (below when top-docked, beside when
            // side-docked). The all-around `.shadow()` we used to apply on the
            // blob bled into the 8 pt cornerInset strips, painting them faintly
            // gray; this confines the shadow to where it actually wants to be.
            dockShadow

            blobShape
                .fill(.black)
                // Clip the stroke to the blob so the 1 pt line doesn't render its
                // outer half in the cornerInset strips.
                .overlay(
                    blobShape.stroke(Color.white.opacity(0.06), lineWidth: 1)
                        .clipShape(blobShape)
                )
                .frame(width: blobSize.width, height: blobSize.height)

            content
                .frame(width: blobSize.width, height: blobSize.height)
                .clipShape(blobShape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dockAlignment)
        // Hot-corner overlays (Mission Control / App Exposé): retract the blob
        // past its docked edge — the fixed-size window clips it, so it reads as
        // sliding into the bezel. Visible only because the overlay CGS space
        // sits above the Mission Control transition layer. On exit the window
        // comes back with the content still retracted and the spring drops it
        // back in. dampingFraction must be 1.0: any underdamped spring
        // overshoots past rest, revealing a sliver of screen beyond the blob's
        // flat edge.
        .offset(retractOffset)
        .animation(notch.isSystemOverlayActive
                   ? .easeIn(duration: 0.26)
                   : .spring(response: 0.40, dampingFraction: 1.0),
                   value: notch.isSystemOverlayActive)
        .animation(transitionAnim, value: notch.isOpen)
        .animation(Self.openAnim, value: notch.tab)
        .animation(Self.openAnim, value: notch.musicPanelExpanded)
        .animation(Self.openAnim, value: notch.sessionsPanelExpanded)
        .animation(Self.openAnim, value: claude.sessions.count)
        .animation(transitionAnim, value: notch.toast)
        // Hover open/close is driven by AppDelegate's cursor watcher.
    }

    @ViewBuilder private var dockShadow: some View {
        switch dock {
        case .top:
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.36))
                .frame(width: max(0, blobSize.width - 40), height: 10)
                .blur(radius: 10)
                .offset(y: blobSize.height - 4)
        case .left:
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.36))
                .frame(width: 10, height: max(0, blobSize.height - 40))
                .blur(radius: 10)
                .offset(x: blobSize.width - 4)
        case .right:
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.36))
                .frame(width: 10, height: max(0, blobSize.height - 40))
                .blur(radius: 10)
                .offset(x: -(blobSize.width - 4))
        }
    }

    private var retractOffset: CGSize {
        guard notch.isSystemOverlayActive else { return .zero }
        switch dock {
        case .top:   return CGSize(width: 0, height: -(blobSize.height + 24))
        case .left:  return CGSize(width: -(blobSize.width + 24), height: 0)
        case .right: return CGSize(width: blobSize.width + 24, height: 0)
        }
    }

    /// `if/else` between the peek and the tab (instead of opacity-toggling both)
    /// is what lets `matchedGeometryEffect` morph the album art and bars between
    /// their two layouts during the open/close sweep — when both views were
    /// always in the tree, matched geometry had nothing to interpolate between
    /// and we got the cross-fade teleport.
    @ViewBuilder private var content: some View {
        ZStack {
            // The `.animation(_:value:)` here is what drives the matched-geometry
            // morph during the open/close sweep — the parent-level animation
            // didn't always propagate into the if/else view-tree change.
            Group {
                if notch.toast == nil {
                    if notch.isOpen {
                        // The tab keeps its normal height; the sessions panel
                        // (when unfolded) takes the extra space underneath, so
                        // nothing in the tab moves.
                        VStack(spacing: 0) {
                            tabContent
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .frame(height: notch.sessionsPanelExpanded
                                       ? ScreenMetrics.expandedSize(for: dock).height - 20 : nil)
                                .padding(.horizontal, contentInset)
                                .padding(.top, dock == .top ? 10 : 24)   // strip: clear the gear
                                .padding(.bottom, 10)
                            if notch.sessionsPanelExpanded {
                                SessionsPanel()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                    .padding(.horizontal, contentInset)
                                    .padding(.bottom, 10)
                                    .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .foregroundStyle(.white)
                    } else {
                        CollapsedPeek(namespace: chromeNS, vertical: dock != .top)
                    }
                }
            }
            .animation(transitionAnim, value: notch.isOpen)

            if let toast = notch.toast {
                // Banners are choreographed left-to-right (Clawd runs the width).
                // On a side dock the whole banner is laid out flat at its normal
                // size and turned a quarter turn, so it plays top-to-bottom.
                let flat = ScreenMetrics.toastSize
                Group {
                    switch toast {
                    case .screenshot(let t): ScreenshotToastView(toast: t)
                    case .session(let t):    SessionToastView(toast: t)
                    }
                }
                .padding(.horizontal, 14)
                .foregroundStyle(.white)
                .frame(width: flat.width, height: flat.height)
                .rotationEffect(.degrees(dock == .top ? 0 : 90))
                .frame(width: blobSize.width, height: blobSize.height)
                .transition(.opacity)
            }

            // Claude spinner in the bottom-right corner of the tab area while a
            // session is working; hovering it unfolds the sessions panel.
            // Placed with `offset`, not padding: padding takes part in layout,
            // and an inset taller than the collapsed side pill (216 pt into a
            // 180 pt pill) would inflate the stack and shove the peek out of
            // the clip. Offsets leave layout alone.
            SessionsCorner()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: freeCornerAlignment)
                .offset(x: dock == .right ? 22 : -22, y: SessionsCorner.stripTopInset(for: dock))
                .opacity(notch.isOpen && notch.toast == nil ? 1 : 0)
                .allowsHitTesting(notch.isOpen && notch.toast == nil)
                .animation(.easeOut(duration: 0.22), value: notch.isOpen)

            // Tiny settings gear, top-right of the expanded panel. Sits just past
            // where the music tab's dancing bars end; grows on hover.
            SettingsGearButton { AppDelegate.shared?.showSettingsWindow() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: freeCornerAlignment)
                .offset(x: dock == .right ? 12 : -12, y: 4)
                .opacity(notch.isOpen && notch.toast == nil ? 1 : 0)
                .allowsHitTesting(notch.isOpen && notch.toast == nil)
                .animation(.easeOut(duration: 0.22), value: notch.isOpen)
                .animation(.easeOut(duration: 0.18), value: notch.toast)
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch notch.tab {
        case .music:       MusicTabView(namespace: chromeNS, vertical: dock != .top)
        case .screenshots: ScreenshotTabView(vertical: dock != .top)
        }
    }

    /// Side inset of the tab content. The portrait card is narrower, and gives
    /// the room back to the content so the six-button podcast row still fits.
    private var contentInset: CGFloat { dock == .top ? 22 : 8 }

    /// Corner controls (gear, Claude spinner) sit on the blob's free side — the
    /// right, except when the notch is docked to the right edge and the right
    /// side is the one pressed against the screen.
    private var freeCornerAlignment: Alignment { dock == .right ? .topLeading : .topTrailing }
}

/// Tiny gear in the corner of the expanded notch. Default state is barely there
/// (low opacity, scaled down so it reads as a faint dot); hover scales it up and
/// brightens it so you can confirm what you're aiming at before clicking.
private struct SettingsGearButton: View {
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    /// Hit-area / drag-cancel radius — releasing further than this from the icon
    /// shouldn't fire the action.
    private static let hitRadius: CGFloat = 22

    private var scale: CGFloat {
        let base: CGFloat = hovering ? 1.0 : 0.62
        return pressed ? base * 0.86 : base
    }

    var body: some View {
        Image(systemName: "gear")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.30))
            .scaleEffect(scale)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // DragGesture(minimumDistance: 0) fires reliably on the first click
            // inside a `.nonactivatingPanel`; SwiftUI's `.onTapGesture` here needs
            // a focus-stealing first click before it recognizes a tap.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { value in
                        pressed = false
                        let dx = value.location.x - 9
                        let dy = value.location.y - 9
                        if dx * dx + dy * dy <= Self.hitRadius * Self.hitRadius {
                            action()
                        }
                    }
            )
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: hovering)
            .animation(pressed ? .easeOut(duration: 0.10)
                               : .spring(response: 0.42, dampingFraction: 0.55),
                       value: pressed)
    }
}

/// What's visible when the notch is collapsed — album art on the left, dancing bars
/// on the right. The artwork and bars are tagged with `matchedGeometryEffect`
/// against the music tab's matching elements (same ids in the shared namespace),
/// so SwiftUI morphs their size and position when the notch opens/closes rather
/// than cross-fading two separate copies.
private struct CollapsedPeek: View {
    let namespace: Namespace.ID
    /// Side-docked pills stand upright, so the peek stacks vertically.
    var vertical: Bool = false
    @EnvironmentObject private var music: NowPlayingManager
    @EnvironmentObject private var claude: ClaudeSessionStore
    @EnvironmentObject private var notch: NotchState

    /// Show whenever there's *any* track loaded; we just freeze the bars when paused
    /// so the user can still see what's playing at a glance.
    private var showing: Bool { music.info.hasContent }

    private static let trackFade: Animation = .easeInOut(duration: 0.34)

    var body: some View {
        Group {
            if vertical { verticalPeek } else { horizontalPeek }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: claude.anyActive)
        .animation(Self.trackFade, value: music.displayKey)
        .animation(Self.trackFade, value: music.displayAccent)
    }

    private var horizontalPeek: some View {
        HStack(spacing: 0) {
            artwork
                .frame(width: 14, height: 14)
                .clipShape(Rectangle())
                .matchedGeometryEffect(id: "chromeArt", in: namespace)
                .opacity(showing && music.displayArt != nil ? 1 : 0)
            Spacer(minLength: 0)
            DancingBars(color: music.displayAccent,
                        isPlaying: music.info.isPlaying)
                .frame(width: 20, height: 14)
                .matchedGeometryEffect(id: "chromeBars", in: namespace)
                .opacity(showing ? 1 : 0)
            // While a Claude session is working, its spinner slides in at the
            // right edge and nudges the bars left; gone again when it finishes.
            if claude.anyActive {
                ClaudeSpinner(state: claude.headlineState, size: 13)
                    // The asterisk glyphs carry more ink below centre, so a
                    // geometrically centred spinner reads low next to the bars.
                    .offset(y: -1)
                    .padding(.leading, 8)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 22)
    }

    /// Upright pill, top-to-bottom: art at the head, a meter the same size as
    /// the top pill's turned to run along the length, and the Claude spinner
    /// at the foot when a session is working.
    private var verticalPeek: some View {
        VStack(spacing: 0) {
            artwork
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .matchedGeometryEffect(id: "chromeArt", in: namespace)
                .opacity(showing && music.displayArt != nil ? 1 : 0)
            Spacer(minLength: 0)
            LengthwiseBars(color: music.displayAccent, isPlaying: music.info.isPlaying,
                           reach: 14, barWidth: 1.8, spacing: 1.3, fromRight: notch.dock == .right)
                .matchedGeometryEffect(id: "chromeBars", in: namespace)
                .opacity(showing ? 1 : 0)
            // Like the top pill, the spinner slides in past the bars at the far
            // end and nudges them inward; gone again when the session finishes.
            if claude.anyActive {
                ClaudeSpinner(state: claude.headlineState, size: 13)
                    .padding(.top, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.vertical, 18)
    }

    @ViewBuilder private var artwork: some View {
        // No `.id`/`.transition` here — that pair runs its own opacity fade-in
        // when the artwork view is inserted (which happens at the same moment
        // as the matched-geometry morph), and the two animations were fighting
        // each other and reading as a snap-then-settle.
        // Also no `.aspectRatio` constraint — `Image` with an aspect-ratio
        // layout fights matched-geometry's frame interpolation, so we let the
        // image stretch to whatever frame matched is currently morphing through.
        // Album art is square in practice so the visual is unchanged.
        if let image = music.displayArt {
            Image(nsImage: image).resizable()
        } else {
            Color.clear
        }
    }
}
