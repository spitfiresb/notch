import AppKit
import Foundation

enum PermissionOverlayVariant {
    case dragToList
    case toggleInList
}

/// A borderless, non-activating panel that floats just below the System
/// Settings privacy pane and shows the user exactly what to do there —
/// either drag the app row into the list, or flip the (mock, animated) toggle.
final class PermissionOverlayWindowController: NSWindowController {
    private let windowSize = NSSize(width: 530, height: 109)

    init(
        hostApp: PermissionPromptHostApp,
        prompt: PermissionPrompt,
        variant: PermissionOverlayVariant,
        onBack: @escaping () -> Void
    ) {
        let window = PassiveOverlayPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configureWindow(window)
        window.contentView = PermissionOverlayContentView(
            hostApp: hostApp,
            prompt: prompt,
            variant: variant,
            onBack: onBack
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        window?.orderOut(nil)
        super.close()
    }

    func present(settingsFrame: CGRect, visibleFrame: CGRect) {
        guard let window else { return }
        let targetOrigin = anchoredOrigin(for: settingsFrame, visibleFrame: visibleFrame)
        let targetFrame = NSRect(origin: targetOrigin, size: windowSize)

        window.alphaValue = 1
        window.setFrame(targetFrame, display: false)
        window.orderFrontRegardless()
    }

    func updatePosition(with settingsFrame: CGRect, visibleFrame: CGRect) {
        guard let window else { return }
        let origin = anchoredOrigin(for: settingsFrame, visibleFrame: visibleFrame)
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func configureWindow(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.animationBehavior = .none
    }

    private func anchoredOrigin(for settingsFrame: CGRect, visibleFrame: CGRect) -> NSPoint {
        let sidebarWidth: CGFloat = 170
        let contentMinX = settingsFrame.minX + sidebarWidth
        let contentWidth = max(settingsFrame.width - sidebarWidth, windowSize.width)
        let preferredX = contentMinX + ((contentWidth - windowSize.width) / 2) - 8
        let preferredY = settingsFrame.minY + 14
        let minX = visibleFrame.minX + 8
        let maxX = visibleFrame.maxX - windowSize.width - 8
        let minY = visibleFrame.minY + 8
        let maxY = visibleFrame.maxY - windowSize.height - 8

        return NSPoint(
            x: min(max(preferredX, minX), maxX),
            y: min(max(preferredY, minY), maxY)
        )
    }
}

private final class PassiveOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PermissionOverlayContentView: NSView {
    private let onBack: () -> Void

    init(
        hostApp: PermissionPromptHostApp,
        prompt: PermissionPrompt,
        variant: PermissionOverlayVariant,
        onBack: @escaping () -> Void
    ) {
        self.onBack = onBack
        super.init(frame: NSRect(x: 0, y: 0, width: 530, height: 109))
        translatesAutoresizingMaskIntoConstraints = false
        setup(hostApp: hostApp, prompt: prompt, variant: variant)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(
        hostApp: PermissionPromptHostApp,
        prompt: PermissionPrompt,
        variant: PermissionOverlayVariant
    ) {
        let materialView = NSVisualEffectView()
        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 18
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 0.5
        materialView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        addSubview(materialView)

        let tintView = NSView()
        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.78).cgColor
        materialView.addSubview(tintView)

        let backChrome = NSView()
        backChrome.translatesAutoresizingMaskIntoConstraints = false
        backChrome.wantsLayer = true
        backChrome.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor
        backChrome.layer?.cornerRadius = 16
        materialView.addSubview(backChrome)

        let backButton = NSButton()
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.isBordered = false
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.contentTintColor = NSColor.labelColor.withAlphaComponent(0.72)
        backButton.target = self
        backButton.action = #selector(backPressed)
        if let cell = backButton.cell as? NSButtonCell {
            cell.imagePosition = .imageOnly
        }
        backChrome.addSubview(backButton)

        let brandBadge = NSImageView()
        brandBadge.translatesAutoresizingMaskIntoConstraints = false
        brandBadge.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: nil)
        brandBadge.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        brandBadge.contentTintColor = NSColor.controlAccentColor.withAlphaComponent(0.85)
        materialView.addSubview(brandBadge)

        let arrowView = NSImageView()
        arrowView.translatesAutoresizingMaskIntoConstraints = false
        arrowView.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        arrowView.symbolConfiguration = .init(pointSize: 28, weight: .bold)
        arrowView.contentTintColor = NSColor.controlAccentColor
        materialView.addSubview(arrowView)

        let titleLabel = NSTextField(labelWithAttributedString: title(hostApp: hostApp, prompt: prompt, variant: variant))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        materialView.addSubview(titleLabel)

        let bottomRow: NSView
        switch variant {
        case .dragToList:
            bottomRow = PermissionDragRow(hostApp: hostApp)
        case .toggleInList:
            bottomRow = PermissionToggleRow(hostApp: hostApp)
        }
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        materialView.addSubview(bottomRow)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 530),
            heightAnchor.constraint(equalToConstant: 109),

            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: materialView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: materialView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: materialView.bottomAnchor),

            backChrome.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 18),
            backChrome.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 52),
            backChrome.widthAnchor.constraint(equalToConstant: 32),
            backChrome.heightAnchor.constraint(equalToConstant: 32),

            backButton.centerXAnchor.constraint(equalTo: backChrome.centerXAnchor),
            backButton.centerYAnchor.constraint(equalTo: backChrome.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 14),
            backButton.heightAnchor.constraint(equalToConstant: 14),

            arrowView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 35),
            arrowView.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 10),
            arrowView.widthAnchor.constraint(equalToConstant: 28),
            arrowView.heightAnchor.constraint(equalToConstant: 28),

            brandBadge.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -18),
            brandBadge.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 15),
            brandBadge.widthAnchor.constraint(equalToConstant: 18),
            brandBadge.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: arrowView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: arrowView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: brandBadge.leadingAnchor, constant: -8),

            bottomRow.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 64),
            bottomRow.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -21),
            bottomRow.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 47),
            bottomRow.heightAnchor.constraint(equalToConstant: 43)
        ])
    }

    private func title(
        hostApp: PermissionPromptHostApp,
        prompt: PermissionPrompt,
        variant: PermissionOverlayVariant
    ) -> NSAttributedString {
        let copy: String
        switch variant {
        case .dragToList:
            copy = "Drag \(hostApp.displayName) into the list to allow \(prompt.title)"
        case .toggleInList:
            copy = "Find \(hostApp.displayName) above and flip the \(prompt.toggleLabel) toggle on"
        }
        return NSAttributedString(
            string: copy,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.82)
            ]
        )
    }

    @objc
    private func backPressed() {
        onBack()
    }
}
