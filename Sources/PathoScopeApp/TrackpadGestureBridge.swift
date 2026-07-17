import AppKit
import SwiftUI

struct TrackpadGestureBridge: NSViewRepresentable {
    var selectedROIRect: CGRect?
    var isROIPlacementActive: Bool
    var onMagnificationChanged: (CGFloat) -> Void
    var onMagnificationEnded: (CGFloat) -> Void
    var onPanChanged: (CGSize) -> Void
    var onPanEnded: (CGSize) -> Void
    var onROIMoveChanged: (CGSize) -> Void
    var onROIMoveEnded: () -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> TrackpadGestureNSView {
        let view = TrackpadGestureNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: TrackpadGestureNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: TrackpadGestureNSView) {
        view.selectedROIRect = selectedROIRect
        view.isROIPlacementActive = isROIPlacementActive
        view.onMagnificationChanged = onMagnificationChanged
        view.onMagnificationEnded = onMagnificationEnded
        view.onPanChanged = onPanChanged
        view.onPanEnded = onPanEnded
        view.onROIMoveChanged = onROIMoveChanged
        view.onROIMoveEnded = onROIMoveEnded
        view.onReset = onReset
    }
}

final class TrackpadGestureNSView: NSView {
    var selectedROIRect: CGRect?
    var isROIPlacementActive = false
    var onMagnificationChanged: ((CGFloat) -> Void)?
    var onMagnificationEnded: ((CGFloat) -> Void)?
    var onPanChanged: ((CGSize) -> Void)?
    var onPanEnded: ((CGSize) -> Void)?
    var onROIMoveChanged: ((CGSize) -> Void)?
    var onROIMoveEnded: (() -> Void)?
    var onReset: (() -> Void)?
    private var magnification: CGFloat = 1
    private var pan = CGSize.zero
    private var pendingPanCommit: DispatchWorkItem?
    private var isMovingROI = false
    private var lastROIDragLocation: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func magnify(with event: NSEvent) {
        if event.phase == .began { magnification = 1 }
        magnification = min(max(magnification * (1 + event.magnification), 0.2), 8)
        onMagnificationChanged?(magnification)
        if event.phase == .ended || event.phase == .cancelled {
            onMagnificationEnded?(magnification)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase == .began {
            pendingPanCommit?.cancel()
            pan = .zero
        }
        if event.momentumPhase == .began {
            pendingPanCommit?.cancel()
        }
        pan.width += event.scrollingDeltaX
        pan.height += event.scrollingDeltaY
        onPanChanged?(pan)

        if event.momentumPhase == .ended || event.phase == .cancelled {
            commitPan()
        } else if event.phase == .ended {
            schedulePanCommit()
        } else if event.phase.isEmpty, event.momentumPhase.isEmpty {
            schedulePanCommit(after: 0.09)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if !isROIPlacementActive,
           event.clickCount == 1,
           selectedROIRect?.contains(location) == true {
            pendingPanCommit?.cancel()
            isMovingROI = true
            lastROIDragLocation = location
            window?.makeFirstResponder(self)
        } else if event.clickCount == 2 {
            onReset?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isMovingROI, let previous = lastROIDragLocation else {
            super.mouseDragged(with: event)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        onROIMoveChanged?(CGSize(
            width: location.x - previous.x,
            height: location.y - previous.y
        ))
        lastROIDragLocation = location
    }

    override func mouseUp(with event: NSEvent) {
        if isMovingROI {
            isMovingROI = false
            lastROIDragLocation = nil
            onROIMoveEnded?()
        } else {
            super.mouseUp(with: event)
        }
    }

    private func schedulePanCommit(after delay: TimeInterval = 0.055) {
        pendingPanCommit?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitPan() }
        pendingPanCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func commitPan() {
        pendingPanCommit?.cancel()
        pendingPanCommit = nil
        onPanEnded?(pan)
    }
}
