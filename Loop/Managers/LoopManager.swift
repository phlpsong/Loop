//
//  LoopManager.swift
//  Loop
//
//  Created by Kai Azim on 2023-08-15.
//

import SwiftUI
import Defaults

class LoopManager: ObservableObject {

    private let accessibilityAccessManager = PermissionsManager()
    private let keybindMonitor = KeybindMonitor.shared

    private let radialMenuController = RadialMenuController()
    private let previewController = PreviewController()

    private var currentlyPressedModifiers: Set<CGKeyCode> = []
    private var isLoopActive: Bool = false
    private var targetWindow: Window?
    private var screenWithMouse: NSScreen?

    private var flagsChangedEventMonitor: EventMonitor?
    private var mouseMovedEventMonitor: EventMonitor?
    private var keyDownEventMonitor: EventMonitor?
    private var middleClickMonitor: EventMonitor?
    private var triggerDelayTimer: DispatchSourceTimer?
    private var lastTriggerKeyClick: Date = Date.now

    @Published var currentResizeDirection: WindowDirection = .noAction
    private var initialMousePosition: CGPoint = CGPoint()
    private var angleToMouse: Angle = Angle(degrees: 0)
    private var distanceToMouse: CGFloat = 0

    func startObservingKeys() {
        self.flagsChangedEventMonitor = NSEventMonitor(
            scope: .global,
            eventMask: .flagsChanged,
            handler: handleLoopKeypress(_:)
        )

        self.mouseMovedEventMonitor = NSEventMonitor(
            scope: .global,
            eventMask: [.mouseMoved, .otherMouseDragged],
            handler: mouseMoved(_:)
        )

        self.middleClickMonitor = CGEventMonitor(
            eventMask: [.otherMouseDragged, .otherMouseUp],
            callback: handleMiddleClick(cgEvent:)
        )

        self.keyDownEventMonitor = NSEventMonitor(
            scope: .global,
            eventMask: .keyDown
        ) { _ in
            if Defaults[.doubleClickToTrigger] &&
                abs(self.lastTriggerKeyClick.timeIntervalSinceNow) < NSEvent.doubleClickInterval {
                self.lastTriggerKeyClick = Date.distantPast
            }
        }

        Notification.Name.forceCloseLoop.onRecieve { _ in
            self.closeLoop(forceClose: true)
        }

        Notification.Name.directionChanged.onRecieve { notification in
            if let direction = notification.userInfo?["direction"] as? WindowDirection {
                self.changeDirection(direction)
            }
        }

        self.flagsChangedEventMonitor!.start()
        self.middleClickMonitor!.start()
        self.keyDownEventMonitor!.start()
    }

    private func mouseMoved(_ event: NSEvent) {
        guard self.isLoopActive else { return }

        let noActionDistance: CGFloat = 10

        let currentMouseLocation = NSEvent.mouseLocation
        let mouseAngle = Angle(radians: initialMousePosition.angle(to: currentMouseLocation))
        let mouseDistance = initialMousePosition.distanceSquared(to: currentMouseLocation)

        // Return if the mouse didn't move
        if (mouseAngle == angleToMouse) && (mouseDistance == distanceToMouse) {
            return
        }

        // Get angle & distance to mouse
        self.angleToMouse = mouseAngle
        self.distanceToMouse = mouseDistance

        var resizeDirection: WindowDirection = .noAction

        // If mouse over 50 points away, select half or quarter positions
        if distanceToMouse > pow(50 - Defaults[.radialMenuThickness], 2) {
            switch Int((angleToMouse.normalized().degrees + 22.5) / 45) {
            case 0, 8: resizeDirection = .cycleRight
            case 1:    resizeDirection = .bottomRightQuarter
            case 2:    resizeDirection = .cycleBottom
            case 3:    resizeDirection = .bottomLeftQuarter
            case 4:    resizeDirection = .cycleLeft
            case 5:    resizeDirection = .topLeftQuarter
            case 6:    resizeDirection = .cycleTop
            case 7:    resizeDirection = .topRightQuarter
            default:   resizeDirection = .noAction
            }
        } else if distanceToMouse < pow(noActionDistance, 2) {
            resizeDirection = .noAction
        } else {
            resizeDirection = .maximize
        }

        if resizeDirection != self.currentResizeDirection.base {
            changeDirection(resizeDirection)
        }
    }

    private func changeDirection(_ direction: WindowDirection) {
        guard self.currentResizeDirection != direction && self.isLoopActive else { return }

        var newDirection = direction
        if newDirection.cyclable {
            newDirection = direction.nextCyclingDirection(from: self.currentResizeDirection)
        }

        if newDirection != currentResizeDirection {
            self.currentResizeDirection = newDirection

            if Defaults[.hideUntilDirectionIsChosen] {
                self.openWindows()
            }

            DispatchQueue.main.async {
                Notification.Name.directionChanged.post(userInfo: ["direction": self.currentResizeDirection])

                if !Defaults[.previewVisibility] {
                    WindowEngine.resize(
                        self.targetWindow!,
                        to: self.currentResizeDirection,
                        self.screenWithMouse!,
                        supressAnimations: true
                    )
                }
            }

            NSHapticFeedbackManager.defaultPerformer.perform(
                NSHapticFeedbackManager.FeedbackPattern.alignment,
                performanceTime: NSHapticFeedbackManager.PerformanceTime.now
            )
        }
    }

    func handleMiddleClick(cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if let event = NSEvent(cgEvent: cgEvent), event.buttonNumber == 2, Defaults[.middleClickTriggersLoop] {
            if event.type == .otherMouseDragged && !self.isLoopActive {
                self.openLoop()
            }

            if event.type == .otherMouseUp && self.isLoopActive {
                self.closeLoop()
            }
        }
        return Unmanaged.passRetained(cgEvent)
    }

    private func cancelTriggerDelayTimer() {
        self.triggerDelayTimer?.cancel()
        self.triggerDelayTimer = nil
    }

    private func startTriggerDelayTimer(seconds: Float, handler: @escaping () -> Void) {
        self.triggerDelayTimer = DispatchSource.makeTimerSource(queue: .main)
        self.triggerDelayTimer!.schedule(deadline: .now() + .milliseconds(Int(seconds * 1000)))
        self.triggerDelayTimer!.setEventHandler {
            handler()
            self.triggerDelayTimer = nil
        }
        self.triggerDelayTimer!.resume()
    }

    private func handleLoopKeypress(_ event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.capsLock) {
            self.closeLoop(forceClose: true)
        }

        if self.currentlyPressedModifiers.contains(event.keyCode) {
            self.currentlyPressedModifiers.remove(event.keyCode)
        } else if event.modifierFlags.rawValue == 256 {
            self.currentlyPressedModifiers = []
        } else {
            self.currentlyPressedModifiers.insert(event.keyCode)
        }

        // Why sort the set? I have no idea. But it works much more reliably when sorted!
        if self.currentlyPressedModifiers.sorted().contains(Defaults[.triggerKey].sorted()) {
            let useTriggerDelay = Defaults[.triggerDelay] > 0.1
            let useDoubleClickTrigger = Defaults[.doubleClickToTrigger]

            if useDoubleClickTrigger {
                if abs(self.lastTriggerKeyClick.timeIntervalSinceNow) < NSEvent.doubleClickInterval {
                    if useTriggerDelay {
                        if self.triggerDelayTimer == nil {
                            self.startTriggerDelayTimer(seconds: Defaults[.triggerDelay]) {
                                self.openLoop()
                            }
                        }
                    } else {
                        self.openLoop()
                    }
                }
            } else if useTriggerDelay {
                if self.triggerDelayTimer == nil {
                    self.startTriggerDelayTimer(seconds: Defaults[.triggerDelay]) {
                        self.openLoop()
                    }
                }
            } else {
                self.openLoop()
            }
            self.lastTriggerKeyClick = Date.now
        } else {
            if self.isLoopActive {
                self.closeLoop()
            }
        }
    }

    private func openLoop() {
        guard self.isLoopActive == false else { return }

        self.currentResizeDirection = .noAction
        self.targetWindow = nil

        // Ensure accessibility access
        guard PermissionsManager.Accessibility.getStatus() else { return }

        self.targetWindow = WindowEngine.getTargetWindow()
        self.initialMousePosition = NSEvent.mouseLocation
        self.screenWithMouse = NSScreen.screenWithMouse
        self.mouseMovedEventMonitor!.start()

        if !Defaults[.hideUntilDirectionIsChosen] {
            self.openWindows()
        }

        self.keybindMonitor.start()

        isLoopActive = true
    }

    private func closeLoop(forceClose: Bool = false) {
        self.cancelTriggerDelayTimer()
        self.closeWindows()

        self.keybindMonitor.resetPressedKeys()
        self.keybindMonitor.stop()
        self.mouseMovedEventMonitor!.stop()

        if self.targetWindow != nil &&
            self.screenWithMouse != nil &&
            forceClose == false &&
            self.currentResizeDirection != .noAction &&
            self.isLoopActive {

            if Defaults[.previewVisibility] {
                WindowEngine.resize(
                    self.targetWindow!,
                    to: self.currentResizeDirection,
                    self.screenWithMouse!
                )
            }

            // This rotates the menubar icon
            Notification.Name.didLoop.post()

            // Icon stuff
            Defaults[.timesLooped] += 1
            IconManager.checkIfUnlockedNewIcon()
        } else {
            if self.targetWindow == nil && isLoopActive {
                NSSound.beep()
            }
        }

        isLoopActive = false
    }

    private func openWindows() {
        if Defaults[.previewVisibility] == true && self.targetWindow != nil {
            self.previewController.open(screen: self.screenWithMouse!, window: targetWindow)
        }
        self.radialMenuController.open(position: self.initialMousePosition, frontmostWindow: targetWindow)
    }

    private func closeWindows() {
        self.radialMenuController.close()
        self.previewController.close()
    }
}
