//
//  EPGFocusStrip.swift
//  Lume
//
//  The tvOS guide's single real focus target plus its edge sentinels. The
//  engine only consults `shouldUpdateFocus` when a move has a candidate
//  target — with nothing focusable inside the guide, moves towards its
//  interior would be silently ignored. The sentinels hug the strip so every
//  interior direction always yields a proposal; the veto then reads the
//  move's *heading* (not which view the engine picked) and forwards it to the
//  guide's virtual navigation, covering remote presses *and* swipes even when
//  a strong neighbour like the tab bar is the engine's proposed target.
//
//  Two moves leave the guide. Up from the top row hands off to the tab bar
//  directly above: the up sentinel is dropped so the engine's only upward
//  candidate is that full-width neighbour, and the veto yields the move. Left
//  from the channel hub is consumed and opens the category sidebar, matching
//  the leading-card behaviour used by the other browse pages.
//
//  Menu is deliberately *not* handled here. A responder-chain `pressesBegan`
//  loses to an enclosing NavigationStack's own Menu recognizer (focus hops to
//  the tab bar), and a competing recognizer with blanket precedence freezes
//  the engine's directional recognizers. The scroller handles Menu with
//  SwiftUI's `onExitCommand`, which takes the press before the stack does;
//  the sidebar action is deferred out of that focus-engine update.
//

#if os(tvOS)
    import SwiftUI
    import UIKit

    struct EPGFocusStrip: UIViewRepresentable {
        /// Reflects the strip's real (engine) focus.
        @Binding var isFocused: Bool
        /// Whether a left move should leave the guide (channel hub) rather
        /// than navigate virtually (programme cells).
        let exitsLeft: Bool
        /// Whether an up move should leave the guide (top row → tab bar)
        /// rather than navigate virtually to the row above.
        let exitsUp: Bool
        /// Handles a consumed directional move.
        let onMove: (MoveCommandDirection) -> Void
        let onSelect: () -> Void
        let onLongSelect: () -> Void
        let onExitLeft: () -> Void

        func makeUIView(context: Context) -> ContainerView {
            let view = ContainerView()
            apply(to: view, context: context)
            return view
        }

        func updateUIView(_ view: ContainerView, context: Context) {
            apply(to: view, context: context)
        }

        private func apply(to view: ContainerView, context _: Context) {
            view.strip.onFocusChange = { focused in
                Task { @MainActor in
                    isFocused = focused
                }
            }
            view.strip.onMove = onMove
            view.strip.onSelect = onSelect
            view.strip.onLongSelect = onLongSelect
            view.strip.onExitLeft = onExitLeft
            view.setExitsLeft(exitsLeft)
            view.setExitsUp(exitsUp)
        }

        /// The strip and its interior sentinels.
        final class ContainerView: UIView {
            let strip = StripView()
            private var sentinels: [MoveCommandDirection: SentinelView] = [:]

            override init(frame: CGRect) {
                super.init(frame: frame)
                for direction: MoveCommandDirection in [.up, .down, .left, .right] {
                    let sentinel = SentinelView()
                    sentinel.strip = strip
                    sentinels[direction] = sentinel
                    addSubview(sentinel)
                }
                addSubview(strip)
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            func setExitsLeft(_ exits: Bool) {
                strip.exitsLeft = exits
                // Keep the sentinel present so the strip receives a focus
                // proposal it can veto before opening the overlay sidebar.
                sentinels[.left]?.isFocusEnabled = true
            }

            func setExitsUp(_ exits: Bool) {
                strip.exitsUp = exits
                // On the top row the up sentinel yields so an up move finds the
                // tab bar directly above and leaves; on deeper rows it stays as
                // the interior veto that drives row-to-row navigation. No edge
                // guide is needed as for the left exit — the tab bar is a
                // full-width neighbour the engine finds by projecting straight
                // up, where a sidebar handoff is not involved.
                sentinels[.up]?.isFocusEnabled = !exits
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                let inset: CGFloat = 2
                strip.frame = bounds.insetBy(dx: inset, dy: inset)
                sentinels[.up]?.frame = CGRect(x: inset, y: 0, width: bounds.width - 2 * inset, height: inset)
                sentinels[.down]?.frame = CGRect(x: inset, y: bounds.height - inset, width: bounds.width - 2 * inset, height: inset)
                sentinels[.left]?.frame = CGRect(x: 0, y: inset, width: inset, height: bounds.height - 2 * inset)
                sentinels[.right]?.frame = CGRect(x: bounds.width - inset, y: inset, width: inset, height: bounds.height - 2 * inset)
            }
        }

        /// A proposal target the strip vetoes moves onto; never actually
        /// focused. Only a candidate while the strip itself holds focus, so
        /// it guarantees every interior direction has something to move
        /// toward (triggering the veto) without stealing entry focus.
        final class SentinelView: UIView {
            var isFocusEnabled = true
            weak var strip: StripView?

            override init(frame: CGRect) {
                super.init(frame: frame)
                backgroundColor = UIColor.white.withAlphaComponent(0.01)
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            override var canBecomeFocused: Bool {
                isFocusEnabled && strip?.isEngineFocused == true
            }
        }

        final class StripView: UIView {
            var onFocusChange: ((Bool) -> Void)?
            var onMove: ((MoveCommandDirection) -> Void)?
            var onSelect: (() -> Void)?
            var onLongSelect: (() -> Void)?
            var onExitLeft: (() -> Void)?
            /// Whether a left move leaves the guide (hub) or navigates (cell).
            var exitsLeft = false
            /// Whether an up move leaves the guide (top row) or navigates.
            var exitsUp = false

            private(set) var isEngineFocused = false
            private var longPressFired = false
            private var moveConsumed = false

            override init(frame: CGRect) {
                super.init(frame: frame)
                // Near-invisible but non-zero: fully transparent views are
                // dropped from the engine's directional candidacy.
                backgroundColor = UIColor.white.withAlphaComponent(0.01)

                let select = UITapGestureRecognizer(target: self, action: #selector(handleSelect))
                select.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
                addGestureRecognizer(select)

                let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLongSelect(_:)))
                long.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
                long.minimumPressDuration = 0.4
                addGestureRecognizer(long)
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            override var canBecomeFocused: Bool {
                true
            }

            override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
                super.didUpdateFocus(in: context, with: coordinator)
                if context.nextFocusedView === self {
                    isEngineFocused = true
                    onFocusChange?(true)
                } else if context.previouslyFocusedView === self {
                    isEngineFocused = false
                    onFocusChange?(false)
                }
            }

            override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
                guard isEngineFocused, context.previouslyFocusedView === self else { return true }
                // After a veto the engine synchronously retries with further
                // candidates; without this the same press would fire a second
                // action and let the retry carry real focus out of the guide.
                if moveConsumed { return false }
                // Decide from the *heading*, not from which view the engine
                // proposed: near a strong external neighbour (the tab bar
                // above) the engine may target it rather than
                // our edge sentinel, but the move is still ours to interpret.
                guard let direction = Self.direction(from: context.focusHeading) else { return true }
                // Left from the hub opens the overlay sidebar. Keep real focus
                // parked here until the sidebar takes it on the next update.
                if direction == .left, exitsLeft {
                    moveConsumed = true
                    Task { @MainActor in
                        self.moveConsumed = false
                        self.onExitLeft?()
                    }
                    return false
                }
                // Up from the top row leaves the guide: allow the move so the
                // engine carries focus to the tab bar above.
                if direction == .up, exitsUp { return true }
                // Every other direction stays inside: veto and navigate
                // virtually, even when the engine targeted the tab bar.
                moveConsumed = true
                Task { @MainActor in
                    self.moveConsumed = false
                    self.onMove?(direction)
                }
                return false
            }

            private static func direction(from heading: UIFocusHeading) -> MoveCommandDirection? {
                switch heading {
                case .up: .up
                case .down: .down
                case .left: .left
                case .right: .right
                default: nil
                }
            }

            @objc private func handleSelect() {
                guard !longPressFired else {
                    longPressFired = false
                    return
                }
                onSelect?()
            }

            @objc private func handleLongSelect(_ recognizer: UILongPressGestureRecognizer) {
                guard recognizer.state == .began else { return }
                longPressFired = true
                onLongSelect?()
            }
        }
    }
#endif
