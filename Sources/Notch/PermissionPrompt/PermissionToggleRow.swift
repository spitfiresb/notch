import AppKit
import QuartzCore
import Foundation

/// Non-interactive mock of a Settings → Privacy row that demos the action
/// the user must take: find their app in the list and flip its toggle on.
/// The toggle animates off → on → off in a loop, with a soft accent halo
/// to draw attention.
final class PermissionToggleRow: NSView {
    private let hostApp: PermissionPromptHostApp
    private let rowView = NSView()
    private let iconChrome = NSView()
    private let label = NSTextField(labelWithString: "")
    private let toggleTrack = CALayer()
    private let toggleThumb = CALayer()
    private let toggleHalo = CALayer()

    private let toggleSize = NSSize(width: 36, height: 20)
    private let thumbDiameter: CGFloat = 16

    init(hostApp: PermissionPromptHostApp) {
        self.hostApp = hostApp
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    private func setup() {
        wantsLayer = true

        rowView.wantsLayer = true
        rowView.layer?.cornerRadius = 7
        rowView.layer?.borderWidth = 1
        rowView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowView)

        iconChrome.wantsLayer = true
        iconChrome.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        iconChrome.layer?.cornerRadius = 6
        iconChrome.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(iconChrome)

        let iconView = NSImageView(image: hostApp.icon)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconChrome.addSubview(iconView)

        label.stringValue = hostApp.displayName
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        label.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(label)

        let toggleHost = NSView()
        toggleHost.wantsLayer = true
        toggleHost.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(toggleHost)

        toggleHalo.cornerRadius = toggleSize.height / 2 + 4
        toggleHalo.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.0).cgColor
        toggleHalo.frame = CGRect(
            x: -4, y: -4,
            width: toggleSize.width + 8,
            height: toggleSize.height + 8
        )
        toggleHost.layer?.addSublayer(toggleHalo)

        toggleTrack.cornerRadius = toggleSize.height / 2
        toggleTrack.frame = CGRect(origin: .zero, size: toggleSize)
        toggleHost.layer?.addSublayer(toggleTrack)

        toggleThumb.cornerRadius = thumbDiameter / 2
        toggleThumb.backgroundColor = NSColor.white.cgColor
        toggleThumb.frame = CGRect(
            x: (toggleSize.height - thumbDiameter) / 2,
            y: (toggleSize.height - thumbDiameter) / 2,
            width: thumbDiameter,
            height: thumbDiameter
        )
        toggleThumb.shadowColor = NSColor.black.cgColor
        toggleThumb.shadowOpacity = 0.18
        toggleThumb.shadowOffset = CGSize(width: 0, height: -0.5)
        toggleThumb.shadowRadius = 1.5
        toggleTrack.addSublayer(toggleThumb)

        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowView.topAnchor.constraint(equalTo: topAnchor),
            rowView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowView.heightAnchor.constraint(equalToConstant: 43),

            iconChrome.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 10),
            iconChrome.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            iconChrome.widthAnchor.constraint(equalToConstant: 26),
            iconChrome.heightAnchor.constraint(equalToConstant: 26),

            iconView.centerXAnchor.constraint(equalTo: iconChrome.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconChrome.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            label.leadingAnchor.constraint(equalTo: iconChrome.trailingAnchor, constant: 11),
            label.trailingAnchor.constraint(lessThanOrEqualTo: toggleHost.leadingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),

            toggleHost.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -12),
            toggleHost.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            toggleHost.widthAnchor.constraint(equalToConstant: toggleSize.width),
            toggleHost.heightAnchor.constraint(equalToConstant: toggleSize.height)
        ])
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            rowView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            rowView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        } else {
            rowView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor
            rowView.layer?.borderColor = NSColor(
                red: 0.87451,
                green: 0.866667,
                blue: 0.862745,
                alpha: 1
            ).cgColor
        }
        // Resetting the off-state track color follows the system tertiary
        // fill so it reads as a real macOS switch in both appearances.
        if toggleTrack.animation(forKey: "track") == nil {
            toggleTrack.backgroundColor = offTrackColor.cgColor
        }
    }

    private var offTrackColor: NSColor {
        NSColor.tertiaryLabelColor.withAlphaComponent(0.45)
    }

    private var onTrackColor: NSColor {
        NSColor.controlAccentColor
    }

    private func startAnimating() {
        guard toggleTrack.animation(forKey: "track") == nil else { return }

        let off = offTrackColor.cgColor
        let on = onTrackColor.cgColor

        let trackAnim = CAKeyframeAnimation(keyPath: "backgroundColor")
        trackAnim.values = [off, off, on, on, off]
        trackAnim.keyTimes = [0.0, 0.30, 0.55, 0.85, 1.0]
        trackAnim.duration = 2.4
        trackAnim.repeatCount = .infinity
        trackAnim.calculationMode = .linear
        toggleTrack.add(trackAnim, forKey: "track")

        let leadingX = (toggleSize.height - thumbDiameter) / 2
        let trailingX = toggleSize.width - thumbDiameter - leadingX
        let thumbAnim = CAKeyframeAnimation(keyPath: "position.x")
        thumbAnim.values = [
            leadingX + thumbDiameter / 2,
            leadingX + thumbDiameter / 2,
            trailingX + thumbDiameter / 2,
            trailingX + thumbDiameter / 2,
            leadingX + thumbDiameter / 2
        ]
        thumbAnim.keyTimes = [0.0, 0.30, 0.55, 0.85, 1.0]
        thumbAnim.duration = 2.4
        thumbAnim.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        thumbAnim.repeatCount = .infinity
        toggleThumb.add(thumbAnim, forKey: "thumb")

        let haloAnim = CAKeyframeAnimation(keyPath: "backgroundColor")
        let halo = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        let clear = NSColor.controlAccentColor.withAlphaComponent(0.0).cgColor
        haloAnim.values = [clear, halo, clear, clear]
        haloAnim.keyTimes = [0.0, 0.30, 0.55, 1.0]
        haloAnim.duration = 2.4
        haloAnim.repeatCount = .infinity
        toggleHalo.add(haloAnim, forKey: "halo")
    }

    private func stopAnimating() {
        toggleTrack.removeAllAnimations()
        toggleThumb.removeAllAnimations()
        toggleHalo.removeAllAnimations()
    }
}
