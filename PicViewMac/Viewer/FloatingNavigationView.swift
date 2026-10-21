import AppKit

/// The two auto-hiding previous/next controls at the canvas edges.
///
/// An overlay, and only an overlay: the buttons are constrained *to* the canvas, and the canvas is
/// never constrained to them, so showing or hiding them cannot change the canvas frame, the fit
/// scale, the zoom scale or the centre. Anchoring to the canvas rather than to the window is also
/// what makes the left control follow the canvas's left edge when a pinned drawer has taken its
/// width, and it is what puts the pair at the vertical centre of the *image area* rather than the
/// vertical centre of the window.
///
/// The view spans the canvas but only hit-tests its buttons, so a drag that starts in the middle of
/// the image still reaches the canvas underneath.
public final class FloatingNavigationView: NSView {
    /// The button's own size. Larger than a dock control: this is a target you hit while looking at
    /// the picture, not a strip you aim at.
    public static let buttonSize: CGFloat = 40
    public static let symbolPointSize: CGFloat = 18
    /// How far the buttons sit inside the canvas edges.
    public static let edgeInset: CGFloat = 14
    /// Width of the invisible strip along each canvas edge that reveals the control on that side.
    /// Deliberately generous: the pointer has to be able to find an edge control without aiming.
    public static let revealZoneWidth: CGFloat = 64

    public static let previousSymbol = "chevron.left"
    public static let nextSymbol = "chevron.right"

    public var onPrevious: (() -> Void)?
    public var onNext: (() -> Void)?

    private let previousButton = DockButton(symbol: FloatingNavigationView.previousSymbol,
                                            tooltip: "上一张",
                                            side: buttonSize,
                                            symbolPointSize: symbolPointSize)
    private let nextButton = DockButton(symbol: FloatingNavigationView.nextSymbol,
                                        tooltip: "下一张",
                                        side: buttonSize,
                                        symbolPointSize: symbolPointSize)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // The container is invisible: only its buttons draw.
        wantsLayer = false

        for (button, action) in [(previousButton, #selector(goPrevious)), (nextButton, #selector(goNext))] {
            button.target = self
            button.action = action
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.controlBackgroundColor
                .withAlphaComponent(0.55).cgColor
            button.layer?.cornerRadius = Self.buttonSize / 2
            button.layer?.masksToBounds = false
            addSubview(button)
        }

        // Start genuinely absent: a default NSView is at alpha 1, and a first `setVisible(false,…)`
        // would then find something to fade — which makes "hidden" a state that arrives a fifth of
        // a second later than it should, and makes a test of "hidden chrome does not hit test"
        // depend on how long the run loop happened to run.
        for button in [previousButton, nextButton] {
            button.alphaValue = 0
            button.isHidden = true
        }
        isHidden = true

        NSLayoutConstraint.activate([
            previousButton.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                    constant: Self.edgeInset),
            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                 constant: -Self.edgeInset),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAvailable(previous: false, next: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Only the buttons take clicks. Everything between them belongs to the canvas, so a drag that
    /// starts over the image pans it even though this view is on top.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    @objc private func goPrevious() { onPrevious?() }
    @objc private func goNext() { onNext?() }

    /// Shows the control on a side only when there is somewhere to go. Availability and visibility
    /// are separate questions: a first image has no previous *and* no reason to keep the button's
    /// space warm.
    public func setAvailable(previous: Bool, next: Bool) {
        previousAvailable = previous
        nextAvailable = next
    }

    private(set) var previousAvailable = false
    private(set) var nextAvailable = false

    /// Applies the visibility the model decided. Target-state idempotent, like the dock's: the
    /// viewer feeds this on every pointer move, and re-issuing a fade already in flight would keep
    /// the control from ever settling.
    func setVisible(previous: Bool, next: Bool, animated: Bool = true) {
        let showPrevious = previous && previousAvailable
        let showNext = next && nextAvailable
        // The container leaves the hierarchy with its buttons. It is a full-canvas overlay, and an
        // overlay that stays in the hierarchy at zero opacity is one that can still be hit-tested
        // while being invisible — the failure mode this project has already paid for once.
        if showPrevious || showNext { isHidden = false }
        transition(previousButton, to: showPrevious, animated: animated)
        transition(nextButton, to: showNext, animated: animated)
        if !showPrevious && !showNext { finishContainerHide(animated: animated) }
    }

    private func finishContainerHide(animated: Bool) {
        // Only wait for a fade that is actually happening: two buttons already at zero are gone now,
        // and making the container wait out a fade that is not running leaves an invisible overlay
        // in the hierarchy longer than it needs to be — and makes "is it hidden?" a question whose
        // answer depends on how long the run loop ran.
        let fading = previousButton.alphaValue > 0.01 || nextButton.alphaValue > 0.01
        guard animated, fading, !AccessibilityAppearance.reduceMotion else {
            if previousButton.isHidden, nextButton.isHidden { isHidden = true }
            return
        }
        let duration = AccessibilityAppearance.chromeFadeDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.previousButton.isHidden, self.nextButton.isHidden else { return }
                self.isHidden = true
            }
        }
    }

    private var appliedPreviousVisible: Bool?
    private var appliedNextVisible: Bool?

    private func transition(_ button: DockButton, to visible: Bool, animated: Bool) {
        let applied = button === previousButton ? appliedPreviousVisible : appliedNextVisible
        guard applied != visible else { return }
        if button === previousButton { appliedPreviousVisible = visible } else { appliedNextVisible = visible }

        let reduceMotion = AccessibilityAppearance.reduceMotion
        let duration = (animated && !reduceMotion) ? AccessibilityAppearance.chromeFadeDuration : 0
        if visible {
            button.isHidden = false
            guard duration > 0 else {
                button.alphaValue = 1
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                button.animator().alphaValue = 1
            }
        } else {
            guard duration > 0, button.alphaValue > 0 else {
                button.alphaValue = 0
                button.isHidden = true
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                button.animator().alphaValue = 0
            }
            // Leaving the hierarchy must not depend on the animation callback: it does not run when
            // the window is off screen, and a button left at alpha 0 would still take clicks.
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self, weak button] in
                MainActor.assumeIsolated {
                    guard let self, let button,
                          (button === self.previousButton ? self.appliedPreviousVisible
                                                          : self.appliedNextVisible) == false,
                          button.alphaValue < 0.01 else { return }
                    button.isHidden = true
                }
            }
        }
    }

    /// The reveal strips for a canvas occupying `canvasFrame`, in the coordinate space of the view
    /// that hosts both the canvas and the pointer (the viewer's root view).
    public static func revealZones(canvasFrame: CGRect,
                                   width: CGFloat = FloatingNavigationView.revealZoneWidth)
        -> (previous: CGRect, next: CGRect) {
        guard canvasFrame.width > 0, canvasFrame.height > 0 else { return (.null, .null) }
        let strip = min(width, canvasFrame.width / 2)
        let previous = CGRect(x: canvasFrame.minX, y: canvasFrame.minY,
                              width: strip, height: canvasFrame.height)
        let next = CGRect(x: canvasFrame.maxX - strip, y: canvasFrame.minY,
                          width: strip, height: canvasFrame.height)
        return (previous, next)
    }

    /// The rendered buttons, for tests and the acceptance runner.
    var previousControl: DockButton { previousButton }
    var nextControl: DockButton { nextButton }
}
