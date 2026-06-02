import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

/// Tvrdý zámek obrazovky během pauzy.
/// Pokrývá všechny monitory černým fullscreen oknem, blokuje globální klávesové zkratky.
/// Po `minimumLockSeconds` se odemkne tlačítko Přeskočit.
final class BreakLockController {
    static let shared = BreakLockController()

    private var windows: [NSWindow] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var startedAt: Date?
    private weak var timerManager: TimerManager?
    private var screenChangeObserver: NSObjectProtocol?
    private var currentMinimumLockSeconds: TimeInterval = 60

    var isShowing: Bool { !windows.isEmpty }

    func show(durationSeconds: TimeInterval, minimumLockSeconds: TimeInterval = 60, timerManager: TimerManager) {
        guard !isShowing else { return }
        self.timerManager = timerManager
        self.startedAt = Date()
        self.currentMinimumLockSeconds = minimumLockSeconds

        buildWindows(durationSeconds: durationSeconds, instruction: timerManager.breakInstruction)

        // Sledovat změny konfigurace monitorů (přepojení displeje atd.)
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildWindows(durationSeconds: durationSeconds, instruction: timerManager.breakInstruction)
        }

        NSApp.activate(ignoringOtherApps: true)
        installEventTap()
    }

    func hide() {
        removeEventTap()
        for w in windows {
            w.orderOut(nil)
            w.close()
        }
        windows.removeAll()
        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            screenChangeObserver = nil
        }
        startedAt = nil
    }

    private func buildWindows(durationSeconds: TimeInterval, instruction: String) {
        for screen in NSScreen.screens {
            let window = BreakLockWindow(screen: screen)
            let view = BreakLockView(
                totalDuration: durationSeconds,
                minimumLockSeconds: currentMinimumLockSeconds,
                startedAt: startedAt ?? Date(),
                instruction: instruction,
                onSkip: { [weak self] in self?.skip() }
            )
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
    }

    private func rebuildWindows(durationSeconds: TimeInterval, instruction: String) {
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
        buildWindows(durationSeconds: durationSeconds, instruction: instruction)
    }

    private func skip() {
        guard let start = startedAt,
              Date().timeIntervalSince(start) >= currentMinimumLockSeconds else { return }
        timerManager?.endBreak()
    }

    // MARK: - Event tap (blokování systémových zkratek)

    private func installEventTap() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            let flags = event.flags
            let cmd = flags.contains(.maskCommand)
            let ctrl = flags.contains(.maskControl)
            let opt = flags.contains(.maskAlternate)

            // Polkne vše s modifikátory (Cmd+Tab, Cmd+Q, Cmd+Space, Ctrl+Šipky atd.)
            if cmd || ctrl || opt {
                return nil
            }

            // Polkne i samostatné funkční klávesy pro Mission Control / Spotlight
            if type == .keyDown {
                let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
                let blockedKeys: Set<Int> = [
                    kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                    kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                    kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
                    kVK_Escape
                ]
                if blockedKeys.contains(key) {
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil
        ) else {
            print("⚠️ Nelze vytvořit event tap pro lock screen (chybí Accessibility permission?)")
            promptAccessibilityIfNeeded()
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = src
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func promptAccessibilityIfNeeded() {
        let opts: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}

// MARK: - Window

private final class BreakLockWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.isOpaque = true
        self.backgroundColor = .black
        self.hasShadow = false
        self.isMovable = false
        self.isReleasedWhenClosed = false
        self.acceptsMouseMovedEvents = false
        self.setFrame(screen.frame, display: true)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View

private struct BreakLockView: View {
    let totalDuration: TimeInterval
    let minimumLockSeconds: TimeInterval
    let startedAt: Date
    let instruction: String
    let onSkip: () -> Void

    @State private var now: Date = Date()

    private var elapsed: TimeInterval { max(0, now.timeIntervalSince(startedAt)) }
    private var remaining: TimeInterval { max(0, totalDuration - elapsed) }
    private var unlockIn: TimeInterval { max(0, minimumLockSeconds - elapsed) }

    private var formattedTime: String {
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Text(instruction)
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.white.opacity(0.95))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 80)

            VStack {
                Spacer()
                VStack(spacing: 10) {
                    Text(formattedTime)
                        .font(.system(size: 22, weight: .ultraLight, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                        .kerning(1)

                    if unlockIn > 0 {
                        Text("odemčení za \(Int(unlockIn)) s")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.22))
                    } else {
                        Button(action: onSkip) {
                            Text("Přeskočit")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
    }
}
