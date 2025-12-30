import Foundation
import AppKit

class TimerManager: ObservableObject {
    @Published var completedBlocks: Int = 0
    @Published var completedBlockTimes: [Date] = []
    @Published var isRunning: Bool = false
    @Published var isOnBreak: Bool = false
    @Published var remainingTime: TimeInterval = 0
    @Published var breakRemaining: TimeInterval = 0
    @Published var rescueTimeApiKey: String = ""
    @Published var focusDurationMinutes: Int = 30
    @Published var breakDurationMinutes: Int = 5
    @Published var reminderMinutes: Int = 15

    let maxBlocks = 10

    var blockDuration: TimeInterval {
        TimeInterval(focusDurationMinutes * 60)
    }

    var breakDuration: TimeInterval {
        TimeInterval(breakDurationMinutes * 60)
    }
    
    var onUpdate: (() -> Void)?
    var onShowPopover: (() -> Void)?
    private var timer: Timer?
    private var reminderTimer: Timer?
    private let defaults = UserDefaults(suiteName: "com.focusblocks.app") ?? UserDefaults.standard

    let activities = [
        "🚶 Procházka",
        "📖 Čtení knihy",
        "🧱 Skládání Lega",
        "👥 Kontaktování přátel",
        "🧘 Yoga",
        "🌬️ Dýchací session",
        "🌱 Práce na zahradě"
    ]

    init() {
        loadState()
        loadApiKey()
        loadDurations()
    }

    func loadApiKey() {
        rescueTimeApiKey = defaults.string(forKey: "rescueTimeApiKey") ?? ""
    }

    func saveApiKey(_ key: String) {
        rescueTimeApiKey = key
        defaults.set(key, forKey: "rescueTimeApiKey")
    }

    func loadDurations() {
        let savedFocus = defaults.integer(forKey: "focusDurationMinutes")
        let savedBreak = defaults.integer(forKey: "breakDurationMinutes")
        let savedReminder = defaults.integer(forKey: "reminderMinutes")
        focusDurationMinutes = savedFocus > 0 ? savedFocus : 30
        breakDurationMinutes = savedBreak > 0 ? savedBreak : 5
        reminderMinutes = savedReminder > 0 ? savedReminder : 15
    }

    func saveFocusDuration(_ minutes: Int) {
        focusDurationMinutes = minutes
        defaults.set(minutes, forKey: "focusDurationMinutes")
    }

    func saveBreakDuration(_ minutes: Int) {
        breakDurationMinutes = minutes
        defaults.set(minutes, forKey: "breakDurationMinutes")
    }

    func saveReminderDuration(_ minutes: Int) {
        reminderMinutes = minutes
        defaults.set(minutes, forKey: "reminderMinutes")
    }
    
    func startBlock() {
        guard completedBlocks < maxBlocks else { return }

        reminderTimer?.invalidate()
        reminderTimer = nil

        isRunning = true
        isOnBreak = false
        remainingTime = blockDuration

        enableFocusMode(true)
        startRescueTimeFocus()
        
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        
        saveState()
        onUpdate?()
    }
    
    func tick() {
        if isRunning {
            remainingTime -= 1
            if remainingTime <= 0 {
                completeBlock()
            }
        } else if isOnBreak {
            breakRemaining -= 1
            if breakRemaining <= 0 {
                endBreak()
            }
        }
        onUpdate?()
    }
    
    func completeBlock() {
        isRunning = false
        completedBlocks += 1
        completedBlockTimes.append(Date())
        timer?.invalidate()

        enableFocusMode(false)
        endRescueTimeFocus()
        
        if completedBlocks >= maxBlocks {
            playSound()
            onShowPopover?()
        } else {
            startBreak()
        }
        
        saveState()
        onUpdate?()
    }
    
    func startBreak() {
        isOnBreak = true
        breakRemaining = breakDuration
        
        playSound()
        onShowPopover?()
        
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }
    
    func endBreak() {
        isOnBreak = false
        timer?.invalidate()

        playSound()
        onShowPopover?()
        onUpdate?()

        startReminderTimer()
    }

    func startReminderTimer() {
        guard completedBlocks < maxBlocks else { return }

        reminderTimer?.invalidate()
        let reminderInterval = TimeInterval(reminderMinutes * 60)
        reminderTimer = Timer.scheduledTimer(withTimeInterval: reminderInterval, repeats: false) { [weak self] _ in
            self?.showReminder()
        }
    }

    func showReminder() {
        guard !isRunning && !isOnBreak && completedBlocks < maxBlocks else { return }
        playSound()
        onShowPopover?()
    }
    
    func stopBlock() {
        isRunning = false
        isOnBreak = false
        timer?.invalidate()
        enableFocusMode(false)
        endRescueTimeFocus()
        onUpdate?()
    }
    
    func resetDay() {
        completedBlocks = 0
        completedBlockTimes = []
        isRunning = false
        isOnBreak = false
        timer?.invalidate()
        reminderTimer?.invalidate()
        reminderTimer = nil
        enableFocusMode(false)
        saveState()
        onUpdate?()
    }
    
    // MARK: - Focus Mode
    
    func enableFocusMode(_ enable: Bool) {
        let script: String
        if enable {
            script = """
            tell application "System Events"
                tell application process "ControlCenter"
                    -- Enable Focus Mode via AppleScript/Shortcuts
                end tell
            end tell
            """
            // Alternative: use shortcuts
            let task = Process()
            task.launchPath = "/usr/bin/shortcuts"
            task.arguments = ["run", "Start Focus"]
            try? task.run()
        } else {
            let task = Process()
            task.launchPath = "/usr/bin/shortcuts"
            task.arguments = ["run", "Stop Focus"]
            try? task.run()
        }
    }
    
    // MARK: - RescueTime Integration
    
    func startRescueTimeFocus() {
        guard !rescueTimeApiKey.isEmpty else { return }
        
        let duration = Int(blockDuration / 60) // convert to minutes
        let urlString = "https://www.rescuetime.com/anapi/start_focustime?key=\(rescueTimeApiKey)&duration=\(duration)"
        
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error = error {
                print("RescueTime start error: \(error)")
            }
        }.resume()
    }
    
    func endRescueTimeFocus() {
        guard !rescueTimeApiKey.isEmpty else { return }
        
        let urlString = "https://www.rescuetime.com/anapi/end_focustime?key=\(rescueTimeApiKey)"
        
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error = error {
                print("RescueTime end error: \(error)")
            }
        }.resume()
    }
    
    // MARK: - Sound
    
    func playSound() {
        NSSound(named: "Glass")?.play()
    }
    
    // MARK: - Persistence
    
    func saveState() {
        let today = Calendar.current.startOfDay(for: Date())
        defaults.set(completedBlocks, forKey: "completedBlocks")
        defaults.set(today.timeIntervalSince1970, forKey: "lastDate")
        let timeIntervals = completedBlockTimes.map { $0.timeIntervalSince1970 }
        defaults.set(timeIntervals, forKey: "completedBlockTimes")
    }

    func loadState() {
        let today = Calendar.current.startOfDay(for: Date())
        let lastDate = Date(timeIntervalSince1970: defaults.double(forKey: "lastDate"))

        if Calendar.current.isDate(today, inSameDayAs: lastDate) {
            completedBlocks = defaults.integer(forKey: "completedBlocks")
            if let timeIntervals = defaults.array(forKey: "completedBlockTimes") as? [Double] {
                completedBlockTimes = timeIntervals.map { Date(timeIntervalSince1970: $0) }
            }
        } else {
            completedBlocks = 0
            completedBlockTimes = []
        }
    }
}
