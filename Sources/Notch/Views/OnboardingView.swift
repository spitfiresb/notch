import AppKit
import SwiftUI

/// A normal titled window that walks the user through the macOS permissions the notch needs.
@MainActor
final class OnboardingWindowController: NSWindowController {
    private let onFinish: () -> Void

    init(settings: SettingsStore, spotify: SpotifyLibrary,
         openSettings: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Welcome to Notch"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(settings: settings, spotify: spotify,
                                     openSettings: openSettings) { [weak self] in
                self?.close()
                self?.onFinish()
            })
    }

    required init?(coder: NSCoder) { fatalError() }

    override func close() {
        // Don't leave an orphaned "drag Notch into the list" overlay behind.
        PermissionPromptAssistant.shared.dismiss()
        super.close()
    }
}

private enum Step: Int, CaseIterable {
    case welcome, permissions, library, done
}

struct OnboardingView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var spotify: SpotifyLibrary
    let openSettings: () -> Void
    let finish: () -> Void
    @State private var step: Step = .welcome
    @State private var snapshot = Permissions.snapshot()
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content
                    .id(step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)
            Divider()
            footer.padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 360, height: 440)
        .onAppear {
            // Live-poll so rows flip to "granted" the moment the user acts in
            // System Settings or a consent dialog — no window focus needed.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in snapshot = Permissions.snapshot() }
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .trailing)),
            removal: .opacity.combined(with: .move(edge: .leading))
        )
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            page(icon: "rectangle.topthird.inset.filled",
                 title: "Your Mac's notch",
                 body: "Notch adds a dynamic island to the top of your screen — music controls, a screenshot tray, and clipboard history.\n\nA few macOS permissions make it work. Let's set them up.")
        case .permissions:
            permissionsStep
        case .library:
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "heart.text.square").font(.system(size: 36)).foregroundStyle(.tint)
                Text("Spotify Library").font(.title3.bold())
                Text("Optional: see whether the current song is Liked and which playlists it's in, and add or remove it from the notch.\n\nNeeds a Spotify login and a free developer app of your own — Settings walks you through it. Skip this and everything else still works.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if spotify.state == .connected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.headline)
                } else {
                    Button("Set up Spotify Library…") { openSettings() }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
        case .done:
            page(icon: "checkmark.circle.fill",
                 title: "All set",
                 body: "Hover over the notch any time to open it. You can re-run this setup later from the gear tab.")
        }
    }

    // MARK: Permissions step (one page, live-updating rows)

    private var permissionsStep: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 30)).foregroundStyle(.tint)
                Text("Permissions").font(.title3.bold())
                Text("Notch guides you through each one — click Grant and follow along.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            permissionRow(
                title: "Accessibility",
                explainer: "Keeps the notch above other windows and interactive.",
                granted: snapshot.accessibility == .granted) {
                Button("Grant") { requestAndRefresh(.accessibility) }
                    .buttonStyle(.bordered).controlSize(.small)
            }

            permissionRow(
                title: "Control Spotify",
                explainer: snapshot.spotifyRunning
                    ? "Show the current song and skip / pause from the notch."
                    : "Open the Spotify app first, then connect from here.",
                granted: snapshot.automation == .granted) {
                if snapshot.spotifyRunning {
                    Button("Connect") { requestAndRefresh(.automation) }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("Open Spotify", action: launchSpotify)
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }

            permissionRow(
                title: "Screenshots",
                explainer: settings.routeScreenshotsToFolder
                    ? "Saving to Pictures › Screenshots."
                    : "New screenshots pop into the notch's tray.",
                granted: settings.routeScreenshotsToFolder || snapshot.screenshots == .granted) {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Use folder") { settings.routeScreenshotsToFolder = true }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Recommended — saves to ~/Pictures/Screenshots. No permission needed.")
                    Button("Keep Desktop") { requestAndRefresh(.filesAndFolders) }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                        .help("Keep saving to the Desktop — needs folder access.")
                }
            }

            Spacer(minLength: 0)

            if snapshot.accessibility != .granted {
                Text("Accessibility is required — the rest can wait.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func permissionRow<Actions: View>(
        title: String, explainer: String, granted: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(explainer).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !granted { actions() }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func requestAndRefresh(_ prompt: PermissionPrompt) {
        PermissionPromptAssistant.shared.request(prompt)
        snapshot = Permissions.snapshot()
    }

    private func launchSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyBridge.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func page(icon: String, title: String, body: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.tint)
            Text(title).font(.title2.bold())
            Text(body).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: s == step ? 16 : 6, height: 6)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
                }
            }
            HStack {
                if step != .welcome {
                    Button("Back") { move(-1) }
                }
                Spacer()
                if step == .done {
                    Button("Finish") { finish() }.buttonStyle(.borderedProminent)
                } else {
                    Button(nextTitle) { move(1) }
                        .buttonStyle(.borderedProminent)
                        .disabled(nextDisabled)
                }
            }
        }
    }

    private var nextTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .library: return spotify.state == .connected ? "Next" : "Skip"
        default:       return "Next"
        }
    }

    private var nextDisabled: Bool {
        step == .permissions && !snapshot.allRequiredGranted
    }

    private func move(_ delta: Int) {
        if step == .permissions { PermissionPromptAssistant.shared.dismiss() }
        let next = max(0, min(Step.allCases.count - 1, step.rawValue + delta))
        withAnimation { step = Step(rawValue: next) ?? step }
    }
}
