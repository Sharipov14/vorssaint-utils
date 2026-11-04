// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import QuartzCore
import SwiftUI

/// What a moving ruler reads, shared with the clock beside it. The chosen
/// duration is saved only when the ruler comes to rest: every preference write
/// makes the whole app sync its settings, too slow for each mark going past.
final class NotchTimerRulerReading: ObservableObject {
    @Published var seconds: Int?
    fileprivate var finish: (() -> Int?)?

    /// Saves a moving ruler's reading now and returns it, or nil if at rest.
    func commitNow() -> Int? { finish?() }
}

/// A native duration ruler, including mouse dragging on desktop.
struct NotchTimerRuler: NSViewRepresentable {
    @Binding var seconds: Int
    let step: Int
    let reading: NotchTimerRulerReading
    let label: String
    let locale: Locale

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NotchTimerRulerControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? NotchLayout.timerRulerHeight)
    }

    func makeNSView(context: Context) -> NotchTimerRulerControl {
        let control = NotchTimerRulerControl()
        let coordinator = context.coordinator
        control.focusRingType = .none
        control.minValue = 60
        control.maxValue = Double(NotchTimerRulerScale.limit)
        control.altIncrementValue = 60
        control.moved = { [weak coordinator] in coordinator?.moved(to: $0) }
        // Held strongly: a ruler removed mid-glide saves after it has gone.
        control.landed = { coordinator.landed(on: $0) }
        return control
    }

    func updateNSView(_ control: NotchTimerRulerControl, context: Context) {
        context.coordinator.parent = self
        reading.finish = { [weak control] in control?.finishNow() }
        control.durationLocale = locale
        control.step = NotchTimerRulerScale.sanitizedStep(step)
        control.reduceMotion = context.environment.accessibilityReduceMotion
        control.synchronize(seconds: seconds)
        control.isEnabled = context.environment.isEnabled
        control.increasedContrast = context.environment.colorSchemeContrast == .increased
        control.setAccessibilityLabel(label)
        control.setAccessibilityValueDescription(NotchTimerSupport.spokenText(seconds: control.integerValue, locale: locale))
        control.needsDisplay = true
    }

    final class Coordinator: NSObject {
        /// Fast movement passes marks quicker than a haptic can be felt.
        private static let hapticInterval: CFTimeInterval = 0.1
        var parent: NotchTimerRuler
        private var lastHaptic: CFTimeInterval = 0
        init(_ parent: NotchTimerRuler) { self.parent = parent }

        func moved(to second: Int) {
            parent.reading.seconds = second
            let now = CACurrentMediaTime()
            guard now - lastHaptic >= Self.hapticInterval else { return }
            lastHaptic = now
            NotchService.shared.provideHapticFeedback()
        }

        func landed(on second: Int) {
            if parent.seconds != second { parent.seconds = second }
            parent.reading.seconds = nil
        }
    }
}

final class NotchTimerRulerControl: NSSlider {
    /// How long a stream of precise events may pause before the ruler settles;
    /// one with phases ends itself and only needs covering for a lost end.
    private static let quietStream: CFTimeInterval = 0.12
    private static let quietGesture: CFTimeInterval = 1
    /// A pause this long before the release means the pointer had stopped.
    private static let throwWindow: TimeInterval = 0.05
    private static let visible = NSHashTable<NotchTimerRulerControl>.weakObjects()

    var increasedContrast = false
    var durationLocale = Locale.current
    var reduceMotion = false
    var step = 60 {
        didSet {
            guard step != oldValue else { return }
            minValue = Double(NotchTimerRulerScale.tick(step: step))
            motion = NotchTimerRulerMotion(position: motion.target, step: step)
            needsDisplay = true
        }
    }
    var moved: ((Int) -> Void)?
    var landed: ((Int) -> Void)?

    private var motion = NotchTimerRulerMotion()
    private var wheel = NotchTimerRulerWheel()
    private lazy var clock = NotchDecorativeClock(rate: 120) { [weak self] time in self?.frame(at: time) }
    private var lastFrame: CFTimeInterval = 0
    /// Input is placing the ruler directly and its end has not come yet.
    private var following = false
    private var followingGesture = false
    private var lastInput: CFTimeInterval = 0
    private var drag: (x: CGFloat, time: TimeInterval, velocity: Double)?
    private var didDrag = false
    private var showsKeyboardFocus = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }

    private var isActive: Bool { motion.isMoving || following || drag != nil }

    private var selectionX: CGFloat {
        bounds.minX + CGFloat(NotchTimerRulerScale.selectionX(position: motion.position, width: Double(bounds.width), step: step))
    }

    /// Whether the pointer is over a ruler now. Asked for every wheel event by
    /// Smooth Scrolling, on the main thread, whatever is under the pointer.
    static func wheelIsOverRuler() -> Bool {
        guard visible.count > 0 else { return false }
        let pointer = NSEvent.mouseLocation
        return visible.allObjects.contains { ruler in
            guard ruler.isEnabled, let window = ruler.window, window.isVisible else { return false }
            return window.convertToScreen(ruler.convert(ruler.bounds, to: nil)).contains(pointer)
        }
    }

    /// A change from outside applies at rest. While moving, the person wins,
    /// and the value they land on is saved over it.
    func synchronize(seconds: Int) {
        guard !isActive else { return }
        let bounded = NotchTimerRulerScale.second(Double(seconds), step: step)
        guard integerValue != bounded || motion.position != Double(bounded) else { return }
        integerValue = bounded
        motion.place(at: Double(bounded))
    }

    /// Ends the movement at what the clock shows, saved before this returns.
    func finishNow() -> Int? {
        guard isActive else { return nil }
        let second = integerValue
        settle(on: second)
        return second
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            Self.visible.add(self)
        } else {
            Self.visible.remove(self)
            guard isActive else { return }
            // Removal happens inside a SwiftUI update, which must not write
            // state, and a flick that was cut off still meant its destination.
            let second = NotchTimerRulerScale.snapped(motion.target, step: step)
            clock.stop()
            following = false
            drag = nil
            motion.place(at: Double(second))
            integerValue = second
            let landed = self.landed
            DispatchQueue.main.async { landed?(second) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        showsKeyboardFocus = false
        needsDisplay = true
        clock.stop()
        following = false
        motion.place(at: motion.position)
        drag = (convert(event.locationInWindow, from: nil).x, event.timestamp, 0)
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let previous = drag else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let before = motion.position
        motion.place(at: NotchTimerRulerScale.moving(before, by: Double(x - previous.x), step: step))
        let elapsed = event.timestamp - previous.time
        let instant = elapsed > 0 ? (motion.position - before) / elapsed : previous.velocity
        drag = (x, event.timestamp, previous.velocity * 0.4 + instant * 0.6)
        didDrag = true
        show()
    }

    override func mouseUp(with event: NSEvent) {
        guard let released = drag else { return }
        drag = nil
        guard isEnabled else { return settle(on: integerValue) }
        if didDrag {
            let moving = event.timestamp - released.time <= Self.throwWindow && !reduceMotion
            go(to: motion.thrownMark(velocity: moving ? released.velocity : 0),
               feel: moving ? .thrown : .wheel)
        } else {
            let offset = convert(event.locationInWindow, from: nil).x - selectionX
            go(to: NotchTimerRulerScale.snapped(
                NotchTimerRulerScale.moving(motion.position, by: -Double(offset), step: step), step: step))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled, drag == nil else { return }
        let sideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        if event.hasPreciseScrollingDeltas {
            follow(points: Double(sideways ? event.scrollingDeltaX : event.scrollingDeltaY), event: event)
        } else {
            let marks = wheel.marks(ticks: Self.wheelTicks(event, sideways: sideways),
                                    timestamp: event.timestamp, step: step)
            if marks != 0 { nudge(marks) }
        }
    }

    /// A trackpad, its momentum, or a wheel whose driver reports it as
    /// continuous: the ruler stays under the input and settles when it ends.
    private func follow(points: Double, event: NSEvent) {
        following = true
        followingGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        lastInput = CACurrentMediaTime()
        motion.place(at: NotchTimerRulerScale.moving(motion.position, by: points, step: step))
        show()
        // A lift hands over to momentum if any comes, which takes the ruler
        // back from wherever the settling has got to.
        if !event.phase.intersection([.ended, .cancelled]).isEmpty || event.momentumPhase.contains(.ended) {
            following = false
            go(to: NotchTimerRulerScale.snapped(motion.position, step: step))
        } else {
            startClock()
        }
    }

    /// One whole notch per event, whatever speed macOS scaled it to.
    private static func wheelTicks(_ event: NSEvent, sideways: Bool) -> Double {
        let delta = Double(sideways ? event.scrollingDeltaX : event.scrollingDeltaY)
        guard let cg = event.cgEvent else { return delta == 0 ? 0 : (delta > 0 ? 1 : -1) }
        return ScrollWheelSupport.discreteTicks(
            line: cg.getIntegerValueField(sideways ? .scrollWheelEventDeltaAxis2 : .scrollWheelEventDeltaAxis1),
            fixedPoint: cg.getDoubleValueField(sideways ? .scrollWheelEventFixedPtDeltaAxis2 : .scrollWheelEventFixedPtDeltaAxis1),
            point: cg.getIntegerValueField(sideways ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventPointDeltaAxis1))
    }

    /// Moves along the marks, adding to a glide going the same way and
    /// starting from where the ruler is drawn when it turns back.
    private func nudge(_ marks: Int) {
        let ahead = motion.isMoving && (motion.target - motion.position) * Double(marks) > 0
        go(to: NotchTimerRulerScale.stepped(from: ahead ? motion.target : motion.position, notches: marks, step: step))
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.modifierFlags.intersection([.command, .control]).isEmpty else {
            super.keyDown(with: event); return
        }
        showsKeyboardFocus = true
        needsDisplay = true
        switch event.keyCode {
        case 123, 125: nudge(-1)
        case 124, 126: nudge(1)
        case 115: go(to: Int(minValue))
        case 119: go(to: Int(maxValue))
        default: super.keyDown(with: event)
        }
    }

    override func setAccessibilityValue(_ value: Any?) {
        guard isEnabled, let number = value as? NSNumber, number.doubleValue.isFinite else { return }
        go(to: NotchTimerRulerScale.snapped(number.doubleValue, step: step))
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        nudge(1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        nudge(-1)
        return true
    }

    private func go(to second: Int, feel: NotchTimerRulerMotion.Feel = .wheel) {
        following = false
        motion.glide(to: Double(second), feel: feel)
        guard !reduceMotion, window != nil, motion.isMoving else { return settle(on: second) }
        startClock()
    }

    private func startClock() {
        guard !clock.isRunning else { return }
        lastFrame = CACurrentMediaTime()
        clock.start(in: self)
    }

    private func frame(at time: CFTimeInterval) {
        let elapsed = max(0, time - lastFrame)
        lastFrame = time
        if following {
            let quiet = followingGesture ? Self.quietGesture : Self.quietStream
            if CACurrentMediaTime() - lastInput > quiet {
                following = false
                go(to: NotchTimerRulerScale.snapped(motion.position, step: step))
            }
            return
        }
        motion.advance(elapsed: elapsed)
        if motion.isMoving { show() } else { settle(on: Int(motion.target)) }
    }

    /// Redraws and moves the reading to the mark nearest the ruler, never away
    /// from where the ruler is heading: a value left between marks would
    /// otherwise step back to its nearest mark on the way forward.
    private func show() {
        needsDisplay = true
        var second = NotchTimerRulerScale.snapped(motion.position, step: step)
        if motion.target > Double(integerValue) { second = max(second, integerValue) }
        if motion.target < Double(integerValue) { second = min(second, integerValue) }
        select(second)
    }

    private func select(_ second: Int) {
        guard integerValue != second else { return }
        integerValue = second
        setAccessibilityValueDescription(NotchTimerSupport.spokenText(seconds: second, locale: durationLocale))
        moved?(second)
    }

    private func settle(on second: Int) {
        clock.stop()
        following = false
        drag = nil
        motion.place(at: Double(second))
        needsDisplay = true
        select(second)
        landed?(second)
    }

    override func draw(_ dirtyRect: NSRect) {
        let edgeFade = max(1, bounds.width * 0.12)
        // Drawn for the full ruler height; a shorter island compresses the
        // ticks and pointer below the labels instead of cutting them off.
        let scale = bounds.height / NotchLayout.timerRulerHeight
        let position = motion.position
        let selectionX = self.selectionX
        let rest = increasedContrast ? 0.65 : 0.35
        let tick = NotchTimerRulerScale.tick(step: step)
        for second in stride(from: tick, through: NotchTimerRulerScale.limit, by: tick) {
            let x = selectionX + CGFloat(NotchTimerRulerScale.offset(of: second, position: position, step: step))
            guard x >= bounds.minX - 16, x <= bounds.maxX + 16 else { continue }
            let distance = (Double(second) - position) / Double(tick)
            let fade = abs(distance) < 0.5 ? 1 : min(1, max(0, min(x - bounds.minX, bounds.maxX - x) / edgeFade))
            // A tick lights as the pointer reaches it rather than popping on.
            let strength = rest + (1 - rest) * min(1, max(0, 1 - distance))
            let color = NSColor.systemOrange.withAlphaComponent(fade * strength * (isEnabled ? 1 : 0.4))
            color.setFill()
            let long = NotchTimerRulerScale.isLong(second, step: step)
            let height = (long ? 38 : 20) * scale
            let y = (26 + (long ? 0 : 9)) * scale
            NSBezierPath(roundedRect: NSRect(x: x - 2, y: y, width: 4, height: height), xRadius: 2, yRadius: 2).fill()
            if NotchTimerRulerScale.hasLabel(second, step: step) {
                let title = NSAttributedString(string: NotchTimerRulerScale.label(for: second / 60), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium), .foregroundColor: color
                ])
                title.draw(at: NSPoint(x: x - title.size().width / 2, y: 0))
            }
        }
        let pointer = NSBezierPath()
        pointer.move(to: NSPoint(x: selectionX, y: 70 * scale))
        pointer.line(to: NSPoint(x: selectionX + 6, y: 80 * scale))
        pointer.line(to: NSPoint(x: selectionX - 6, y: 80 * scale))
        pointer.close()
        NSColor.systemOrange.withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
        pointer.fill()
        if window?.firstResponder === self, showsKeyboardFocus {
            NSColor.systemOrange.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            focus.lineWidth = 1
            focus.stroke()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        showsKeyboardFocus = accepted
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }
}
