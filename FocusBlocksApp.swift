import SwiftUI
import ServiceManagement

@main
struct FocusBlocksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timerManager = TimerManager()
    var popover = NSPopover()
    var eventMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            updateMenuBarTitle()
            button.action = #selector(togglePopover)
        }
        
        popover.behavior = .transient

        let contentView = ContentView(
            timerManager: timerManager,
            onUpdate: { [weak self] in
                self?.updateMenuBarTitle()
            },
            onClosePopover: { [weak self] in
                self?.closePopover()
            }
        )

        let hostingController = NSHostingController(rootView: contentView)
        hostingController.view.setFrameSize(hostingController.view.fittingSize)
        popover.contentViewController = hostingController
        
        timerManager.onUpdate = { [weak self] in
            DispatchQueue.main.async {
                self?.updateMenuBarTitle()
            }
        }
        
        timerManager.onShowPopover = { [weak self] in
            DispatchQueue.main.async {
                self?.showPopover()
            }
        }
    }
    
    func showPopover() {
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startEventMonitor()
        }
    }

    func closePopover() {
        popover.performClose(nil)
        stopEventMonitor()
    }

    func startEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover.isShown == true {
                self?.closePopover()
            }
        }
    }

    func stopEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    func updateMenuBarTitle() {
        if let button = statusItem.button {
            let blocks = timerManager.completedBlocks
            let max = timerManager.maxBlocks

            if timerManager.isRunning {
                let remaining = timerManager.remainingTime
                let mins = Int(remaining) / 60
                let secs = Int(remaining) % 60
                let timeString = String(format: "%02d:%02d", mins, secs)
                let fullString = "⏱ \(timeString) (\(blocks)/\(max))"
                button.attributedTitle = attributedMenuTitle(fullString, monoRange: timeString)
            } else if timerManager.isOnBreak {
                let remaining = timerManager.breakRemaining
                let mins = Int(remaining) / 60
                let secs = Int(remaining) % 60
                let timeString = String(format: "%02d:%02d", mins, secs)
                let fullString = "\(timeString) (\(blocks)/\(max))"
                button.attributedTitle = attributedMenuTitle(fullString, monoRange: timeString)
            } else if blocks >= max {
                button.title = "✅ DOST"
            } else {
                button.title = "◻️ \(blocks)/\(max)"
            }
        }
    }

    func attributedMenuTitle(_ text: String, monoRange: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        let monoFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        if let range = text.range(of: monoRange) {
            let nsRange = NSRange(range, in: text)
            attributed.addAttribute(.font, value: monoFont, range: nsRange)
        }
        return attributed
    }
    
    @objc func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }
}
