import AppKit
import SwiftUI

/// A normal titled window that walks the user through the macOS permissions the notch needs.
@MainActor
final class OnboardingWindowController: NSWindowController {
    private let onFinish: () -> Void

    init(settings: SettingsStore, spotify: SpotifyLibrary,
         openSettings: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
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
}

private enum Step: Int, CaseIterable {
    case welcome, accessibility, spotify, screenshots, library, done
}

struct OnboardingView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var spotify: SpotifyLibrary
    let openSettings: () -> Void
    let finish: () -> Void
    @State private var step: Step = .welcome
    @State private var tick = false   // toggled to re-check live permission state

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
                .id(tick)
            Divider()
            footer.padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 360, height: 420)
        // Re-check permissions whenever the window regains focus.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in tick.toggle() }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            page(icon: "rectangle.topthird.inset.filled",
                 title: "Your Mac's notch",
                 body: "Notch adds a dynamic island to the top of your screen — music controls, a screenshot tray, and clipboard history.\n\nA few macOS permissions make it work. Let's set them up.")
        case .accessibility:
            permissionPage(
                icon: "accessibility",
                title: "Accessibility",
                body: "Lets Notch sit above other windows and respond to your interactions reliably.",
                granted: Permissions.accessibilityTrusted,
                primaryTitle: "Request access",
                primary: { Permissions.requestAccessibility() },
                openSettings: { Permissions.openAccessibilitySettings() })
        case .spotify:
            permissionPage(
                icon: "music.note",
                title: "Control Spotify",
                body: SpotifyBridge.isRunning
                    ? "Lets Notch read the current song and skip / pause from the notch. macOS will ask once — choose “OK”."
                    : "Open the Spotify desktop app first, then come back here and click below to connect.",
                granted: Permissions.spotifyControllable,
                primaryTitle: SpotifyBridge.isRunning ? "Connect Spotify" : "Waiting for Spotify…",
                primary: { Permissions.requestSpotifyAutomation() },
                primaryDisabled: !SpotifyBridge.isRunning,
                openSettings: { Permissions.openAutomationSettings() })
        case .screenshots:
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "camera.viewfinder").font(.system(size: 36)).foregroundStyle(.tint)
                Text("Screenshots").font(.title3.bold())
                Text("New screenshots pop into the notch, ready to drag anywhere.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.routeScreenshotsToFolder {
                    Label("Saving to Pictures › Screenshots", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.headline)
                } else if Permissions.probeScreenshotFolderAccess() {
                    Label("Desktop access granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.headline)
                } else {
                    Button("Use a tidy Screenshots folder") {
                        settings.routeScreenshotsToFolder = true
                        tick.toggle()
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Recommended — saves to ~/Pictures/Screenshots. No permission needed.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Keep saving to the Desktop instead") {
                        Permissions.probeScreenshotFolderAccess()   // triggers the Desktop-access prompt
                        tick.toggle()
                    }
                    .buttonStyle(.link).font(.callout)
                }
                Spacer()
            }
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

    private func permissionPage(icon: String, title: String, body: String, granted: Bool,
                                primaryTitle: String, primary: @escaping () -> Void,
                                primaryDisabled: Bool = false,
                                openSettings: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.system(size: 36)).foregroundStyle(.tint)
            Text(title).font(.title3.bold())
            Text(body).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
            } else {
                Button(primaryTitle) { primary(); tick.toggle() }
                    .buttonStyle(.borderedProminent)
                    .disabled(primaryDisabled)
                Button("Open System Settings", action: openSettings)
                    .buttonStyle(.link).font(.callout)
            }
            Spacer()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(-1) }
            }
            Spacer()
            Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
            if step == .done {
                Button("Finish") { finish() }.buttonStyle(.borderedProminent)
            } else {
                Button(nextTitle) { move(1) }
                    .buttonStyle(.borderedProminent)
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

    private func move(_ delta: Int) {
        let next = max(0, min(Step.allCases.count - 1, step.rawValue + delta))
        withAnimation { step = Step(rawValue: next) ?? step }
    }
}
