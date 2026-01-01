import Foundation
import AppKit
import EventKit

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
    @Published var maxBlocks: Int = 10

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
    private var midnightTimer: Timer?
    private let defaults = UserDefaults.standard
    private let eventStore = EKEventStore()
    private var blockStartTime: Date?

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
        scheduleMidnightReset()
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
        let savedMaxBlocks = defaults.integer(forKey: "maxBlocks")
        focusDurationMinutes = savedFocus > 0 ? savedFocus : 30
        breakDurationMinutes = savedBreak > 0 ? savedBreak : 5
        reminderMinutes = savedReminder > 0 ? savedReminder : 15
        maxBlocks = savedMaxBlocks > 0 ? savedMaxBlocks : 10
    }

    func saveMaxBlocks(_ count: Int) {
        maxBlocks = count
        defaults.set(count, forKey: "maxBlocks")
        onUpdate?()
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
        blockStartTime = Date()

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
        let endTime = Date()
        completedBlockTimes.append(endTime)
        timer?.invalidate()

        enableFocusMode(false)
        endRescueTimeFocus()
        addCalendarEvent(blockNumber: completedBlocks, startTime: blockStartTime, endTime: endTime)

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
        if enable {
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

    // MARK: - Calendar

    func addCalendarEvent(blockNumber: Int, startTime: Date?, endTime: Date) {
        guard let start = startTime else {
            print("Calendar: No start time")
            return
        }

        print("Calendar: Requesting access... macOS version check")

        let status = EKEventStore.authorizationStatus(for: .event)
        print("Calendar: Current status = \(status.rawValue)")

        if #available(macOS 14.0, *) {
            print("Calendar: Using macOS 14+ API")
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                print("Calendar: Full access granted = \(granted), error = \(String(describing: error))")
                if granted {
                    self?.createEvent(blockNumber: blockNumber, start: start, end: endTime)
                }
            }
        } else {
            print("Calendar: Using legacy API")
            eventStore.requestAccess(to: .event) { [weak self] granted, error in
                print("Calendar: Access granted = \(granted), error = \(String(describing: error))")
                if granted {
                    self?.createEvent(blockNumber: blockNumber, start: start, end: endTime)
                }
            }
        }
    }

    private func createEvent(blockNumber: Int, start: Date, end: Date) {
        let event = EKEvent(eventStore: eventStore)
        event.title = "Focus Block \(blockNumber)"
        event.startDate = start
        event.endDate = end
        event.calendar = eventStore.defaultCalendarForNewEvents

        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            print("Failed to save calendar event: \(error)")
        }
    }

    // MARK: - Midnight Reset

    func scheduleMidnightReset() {
        midnightTimer?.invalidate()

        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()),
              let midnight = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: tomorrow) else {
            return
        }

        let timeUntilMidnight = midnight.timeIntervalSinceNow

        midnightTimer = Timer.scheduledTimer(withTimeInterval: timeUntilMidnight, repeats: false) { [weak self] _ in
            self?.performMidnightReset()
        }
    }

    private func performMidnightReset() {
        resetDay()
        scheduleMidnightReset()
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
