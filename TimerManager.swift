import Foundation
import AppKit
import EventKit

class TimerManager: ObservableObject {
    @Published var completedBlocks: Int = 0
    @Published var completedBlocksData: [SyncManager.CompletedBlock] = []
    @Published var isRunning: Bool = false

    // Pomocná property pro zpětnou kompatibilitu - vrací časy dokončení jako Date
    var completedBlockTimes: [Date] {
        completedBlocksData.map { Date(timeIntervalSince1970: $0.completedAt) }
    }
    @Published var isOnBreak: Bool = false
    @Published var remainingTime: TimeInterval = 0
    @Published var breakRemaining: TimeInterval = 0
    @Published var rescueTimeApiKey: String = ""
    @Published var openRescueTimeOnComplete: Bool = true
    @Published var focusDurationMinutes: Int = 30
    @Published var breakDurationMinutes: Int = 5
    @Published var reminderMinutes: Int = 15
    @Published var maxBlocks: Int = 10
    @Published var breakInstruction: String = "Jeden nádech do břicha, zavři oči"

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

    // Unikátní ID tohoto zařízení (sdílené se SyncManager)
    private var deviceId: String {
        if let saved = defaults.string(forKey: "deviceId") {
            return saved
        }
        let newId = UUID().uuidString
        defaults.set(newId, forKey: "deviceId")
        return newId
    }

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
        setupWakeObserver()
        setupSyncObserver()

        // Obnovit běžící timer při startu appky
        restoreRunningTimer()

        // Pokud nic neběží, rozjet připomínky (i po splnění všech plánovaných bloků)
        if !isRunning && !isOnBreak {
            startReminderTimer()
        }
    }

    private func setupSyncObserver() {
        // Observer pro běžné data změny
        NotificationCenter.default.addObserver(
            forName: .syncDataUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Data byla sloučena ze vzdáleného zdroje
            self?.loadState()
            self?.loadApiKey()
            self?.loadDurations()
            self?.onUpdate?()
        }

        // Observer pro remote timer detection
        NotificationCenter.default.addObserver(
            forName: .syncRemoteTimerDetected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Běžící timer z jiného zařízení
            self?.handleRemoteTimer(notification)
        }
    }

    private func handleRemoteTimer(_ notification: Notification) {
        guard let timerState = notification.object as? SyncManager.SyncData.FocusBlocksData.TimerState else {
            return
        }

        // Pokud už běží lokální timer, ignorovat remote (preferovat lokální)
        if isRunning || isOnBreak {
            print("⚠️ Ignoruji vzdálený timer - lokální timer již běží")
            return
        }

        // Načíst remote timer state
        if timerState.isRunning, let startTime = timerState.blockStartTime {
            let elapsed = Date().timeIntervalSince1970 - startTime
            let remaining = blockDuration - elapsed

            // Pokud timer ještě neexpiroval, spustit ho
            if remaining > 0 {
                print("🔄 Synchronizuji běžící timer z jiného zařízení")
                isRunning = true
                remainingTime = remaining
                blockStartTime = Date(timeIntervalSince1970: startTime)

                startSyncedTimer()
                onUpdate?()
            }
        } else if timerState.isOnBreak, let breakStart = timerState.breakStartTime {
            let elapsed = Date().timeIntervalSince1970 - breakStart
            let remaining = breakDuration - elapsed

            // Pokud pauza ještě neexpirovala
            if remaining > 0 {
                print("🔄 Synchronizuji pauzu z jiného zařízení")
                isOnBreak = true
                breakRemaining = remaining

                startSyncedBreak()
                BreakLockController.shared.show(durationSeconds: remaining, timerManager: self)
                onUpdate?()
            }
        }
    }

    private func startSyncedTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func startSyncedBreak() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func setupWakeObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkTimerAfterWake()
            self?.checkForNewDay()
        }
    }

    private func checkTimerAfterWake() {
        // Pokud běží focus blok, zkontrolovat jestli neexpiroval během spánku
        if isRunning, let startTime = blockStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = blockDuration - elapsed

            if remaining <= 0 {
                // Timer expiroval během spánku - dokončit blok
                print("⏰ Timer expiroval během spánku notebooku - dokončuji blok")
                timer?.invalidate()
                completeExpiredBlock()
            } else {
                // Timer ještě běží - aktualizovat zbývající čas
                print("🔄 Aktualizuji timer po probuzení (\(Int(remaining))s zbývá)")
                remainingTime = remaining
                onUpdate?()
            }
        }
        // Pokud běží pauza, zkontrolovat jestli neexpirovala během spánku
        else if isOnBreak {
            if let breakStartInterval = defaults.object(forKey: "syncTimerBreakStartTime") as? TimeInterval {
                let breakStart = Date(timeIntervalSince1970: breakStartInterval)
                let elapsed = Date().timeIntervalSince(breakStart)
                let storedBreakDuration = defaults.double(forKey: "syncTimerBreakDuration")
                let effectiveBreakDuration = storedBreakDuration > 0 ? storedBreakDuration : breakDuration
                let remaining = effectiveBreakDuration - elapsed

                if remaining <= 0 {
                    // Pauza expirovala během spánku - ukončit ji
                    print("⏸ Pauza expirovala během spánku notebooku - ukončuji")
                    timer?.invalidate()
                    completeExpiredBreak()
                } else {
                    // Pauza ještě běží - aktualizovat zbývající čas
                    print("🔄 Aktualizuji pauzu po probuzení (\(Int(remaining))s zbývá)")
                    breakRemaining = remaining
                    onUpdate?()
                }
            }
        }
    }

    private func checkForNewDay() {
        let today = Calendar.current.startOfDay(for: Date())
        let lastDate = Date(timeIntervalSince1970: defaults.double(forKey: "lastDate"))

        if !Calendar.current.isDate(today, inSameDayAs: lastDate) {
            resetDay()
        }

        // Reschedule midnight timer in case it was missed
        scheduleMidnightReset()
    }

    func loadApiKey() {
        rescueTimeApiKey = defaults.string(forKey: "rescueTimeApiKey") ?? ""
    }

    func saveApiKey(_ key: String) {
        rescueTimeApiKey = key
        defaults.set(key, forKey: "rescueTimeApiKey")
        SyncManager.shared.syncNow()
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

        if let savedInstruction = defaults.string(forKey: "breakInstruction"), !savedInstruction.isEmpty {
            breakInstruction = savedInstruction
        } else {
            breakInstruction = "Jeden nádech do břicha, zavři oči"
        }

        if defaults.object(forKey: "openRescueTimeOnComplete") != nil {
            openRescueTimeOnComplete = defaults.bool(forKey: "openRescueTimeOnComplete")
        } else {
            openRescueTimeOnComplete = true
        }
    }

    func saveOpenRescueTimeOnComplete(_ value: Bool) {
        openRescueTimeOnComplete = value
        defaults.set(value, forKey: "openRescueTimeOnComplete")
        SyncManager.shared.syncNow()
    }

    func saveMaxBlocks(_ count: Int) {
        maxBlocks = count
        defaults.set(count, forKey: "maxBlocks")
        SyncManager.shared.syncNow()
        onUpdate?()
    }

    func saveFocusDuration(_ minutes: Int) {
        focusDurationMinutes = minutes
        defaults.set(minutes, forKey: "focusDurationMinutes")
        SyncManager.shared.syncNow()
    }

    func saveBreakDuration(_ minutes: Int) {
        breakDurationMinutes = minutes
        defaults.set(minutes, forKey: "breakDurationMinutes")
        SyncManager.shared.syncNow()
    }

    func saveReminderDuration(_ minutes: Int) {
        reminderMinutes = minutes
        defaults.set(minutes, forKey: "reminderMinutes")
        SyncManager.shared.syncNow()
    }

    func saveBreakInstruction(_ text: String) {
        breakInstruction = text
        defaults.set(text, forKey: "breakInstruction")
        SyncManager.shared.syncNow()
    }
    
    func startBlock() {
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
        RunLoop.main.add(timer!, forMode: .common)

        saveState()

        // Uložit timer state lokálně
        saveTimerState(isRunning: true, isOnBreak: false, blockStart: blockStartTime, breakStart: nil)

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
        timer?.invalidate()
        isRunning = false

        guard let startTime = blockStartTime else {
            print("⚠️ Nelze dokončit blok - chybí blockStartTime")
            enableFocusMode(false)
            endRescueTimeFocus()
            saveTimerState(isRunning: false, isOnBreak: false, blockStart: nil, breakStart: nil)
            onUpdate?()
            return
        }

        let startTimeInterval = startTime.timeIntervalSince1970
        let endTime = startTime.addingTimeInterval(blockDuration)

        // Zkontrolovat, jestli blok s tímto blockStartTime už neexistuje (mohl být dokončen na jiném zařízení)
        let alreadyCompleted = completedBlocksData.contains { existingBlock in
            abs(existingBlock.blockStartTime - startTimeInterval) < 1
        }

        if alreadyCompleted {
            print("⚠️ Blok se startTime \(startTime) už byl dokončen na jiném zařízení - přeskakuji")
            enableFocusMode(false)
            endRescueTimeFocus()
            saveTimerState(isRunning: false, isOnBreak: false, blockStart: nil, breakStart: nil)
            // Načíst aktuální stav ze SYNC (completedBlocks může být vyšší)
            loadState()
            onUpdate?()
            return
        }

        // Vytvořit nový CompletedBlock
        let completedBlock = SyncManager.CompletedBlock(
            blockStartTime: startTimeInterval,
            completedAt: endTime.timeIntervalSince1970,
            deviceId: deviceId
        )

        completedBlocks += 1
        completedBlocksData.append(completedBlock)
        print("✅ Blok dokončen: startTime=\(startTime), deviceId=\(deviceId)")

        enableFocusMode(false)
        endRescueTimeFocus()
        addCalendarEvent(blockNumber: completedBlocks, startTime: blockStartTime, endTime: endTime)
        if openRescueTimeOnComplete {
            openRescueTimeDashboard()
        }

        let isNowOvertime = completedBlocks >= maxBlocks
        let actualBreakDuration = isNowOvertime ? breakDuration * 2 : breakDuration

        playSound()
        onShowPopover?()
        startBreak(duration: actualBreakDuration)

        saveState()
        onUpdate?()
    }
    
    func startBreak(duration: TimeInterval? = nil) {
        let actualDuration = duration ?? breakDuration
        isOnBreak = true
        breakRemaining = actualDuration
        let breakStart = Date()

        // Uložit skutečnou délku pauzy pro správné obnovení po restartu/spánku
        defaults.set(actualDuration, forKey: "syncTimerBreakDuration")

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)

        // Uložit break state
        saveTimerState(isRunning: false, isOnBreak: true, blockStart: nil, breakStart: breakStart)

        // Tvrdý zámek obrazovky - extra bloky mají dvojnásobný minimální zámek (2 min)
        let minimumLock: TimeInterval = actualDuration > breakDuration ? 120 : 60
        BreakLockController.shared.show(durationSeconds: actualDuration, minimumLockSeconds: minimumLock, timerManager: self)
    }

    func endBreak() {
        isOnBreak = false
        timer?.invalidate()

        BreakLockController.shared.hide()

        playSound()
        onShowPopover?()

        // Vymazat timer state
        saveTimerState(isRunning: false, isOnBreak: false, blockStart: nil, breakStart: nil)

        onUpdate?()

        startReminderTimer()
    }

    func startReminderTimer() {
        reminderTimer?.invalidate()
        let reminderInterval = TimeInterval(reminderMinutes * 60)
        reminderTimer = Timer.scheduledTimer(withTimeInterval: reminderInterval, repeats: true) { [weak self] _ in
            self?.showReminder()
        }
        RunLoop.main.add(reminderTimer!, forMode: .common)
    }

    func showReminder() {
        guard !isRunning && !isOnBreak else { return }

        // Připomínky pouze od 5:00 (bez horního limitu - overtime bloky mohou být i po 18:00)
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 5 else { return }

        playSound()
        onShowPopover?()
    }
    
    func stopBlock() {
        isRunning = false
        isOnBreak = false
        timer?.invalidate()
        BreakLockController.shared.hide()
        enableFocusMode(false)
        endRescueTimeFocus()

        // Vymazat timer state
        saveTimerState(isRunning: false, isOnBreak: false, blockStart: nil, breakStart: nil)

        onUpdate?()
    }
    
    func resetDay() {
        completedBlocks = 0
        completedBlocksData = []
        isRunning = false
        isOnBreak = false
        timer?.invalidate()
        reminderTimer?.invalidate()
        reminderTimer = nil
        BreakLockController.shared.hide()
        enableFocusMode(false)
        saveState()
        onUpdate?()

        // Začít připomínat hned od rána, aby uživatel nezmeškal start prvního bloku
        startReminderTimer()
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

    // MARK: - Open RescueTime Dashboard

    func openRescueTimeDashboard() {
        if let url = URL(string: "https://www.rescuetime.com/dashboard") {
            NSWorkspace.shared.open(url)
        }
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
        RunLoop.main.add(midnightTimer!, forMode: .common)
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

        // Nový formát - CompletedBlock jako JSON
        if let encoded = try? JSONEncoder().encode(completedBlocksData) {
            defaults.set(encoded, forKey: "completedBlocksData")
        }

        // Synchronizovat do Dropboxu
        SyncManager.shared.syncNow()
    }

    func loadState() {
        let today = Calendar.current.startOfDay(for: Date())
        let lastDate = Date(timeIntervalSince1970: defaults.double(forKey: "lastDate"))

        if Calendar.current.isDate(today, inSameDayAs: lastDate) {
            completedBlocks = defaults.integer(forKey: "completedBlocks")

            // Načíst nový formát CompletedBlock
            if let data = defaults.data(forKey: "completedBlocksData"),
               let decoded = try? JSONDecoder().decode([SyncManager.CompletedBlock].self, from: data) {
                completedBlocksData = decoded
            } else {
                completedBlocksData = []
            }
        } else {
            completedBlocks = 0
            completedBlocksData = []
        }
    }

    private func saveTimerState(isRunning: Bool, isOnBreak: Bool, blockStart: Date?, breakStart: Date?) {
        defaults.set(isRunning, forKey: "syncTimerIsRunning")
        defaults.set(isOnBreak, forKey: "syncTimerIsOnBreak")
        defaults.set(blockStart?.timeIntervalSince1970, forKey: "syncTimerBlockStartTime")
        defaults.set(breakStart?.timeIntervalSince1970, forKey: "syncTimerBreakStartTime")
        defaults.set(Date().timeIntervalSince1970, forKey: "syncTimerStateUpdatedAt")

        // Synchronizovat do Dropboxu (pokud je zapnutý sync)
        SyncManager.shared.updateTimerState(
            isRunning: isRunning,
            isOnBreak: isOnBreak,
            blockStartTime: blockStart,
            breakStartTime: breakStart
        )
    }

    private func restoreRunningTimer() {
        let timerIsRunning = defaults.bool(forKey: "syncTimerIsRunning")
        let timerIsOnBreak = defaults.bool(forKey: "syncTimerIsOnBreak")

        // Pokud timer běží, obnovit ho
        if timerIsRunning, let startTimeInterval = defaults.object(forKey: "syncTimerBlockStartTime") as? TimeInterval {
            let startTime = Date(timeIntervalSince1970: startTimeInterval)
            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = blockDuration - elapsed

            // Pokud timer ještě neexpiroval, spustit ho
            if remaining > 0 {
                print("🔄 Obnovuji běžící timer (\(Int(remaining))s zbývá)")
                isRunning = true
                remainingTime = remaining
                blockStartTime = startTime

                // Spustit focus mode
                enableFocusMode(true)

                // Spustit timer
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.tick()
                }
                RunLoop.main.add(timer!, forMode: .common)
                onUpdate?()
            } else {
                // Timer expiroval - dokončit blok bezpečně (bez dalších akcí)
                print("⏱ Timer expiroval během vypnutí appky - dokončuji blok")
                completeExpiredBlock()
            }
        } else if timerIsOnBreak, let breakStartInterval = defaults.object(forKey: "syncTimerBreakStartTime") as? TimeInterval {
            let breakStart = Date(timeIntervalSince1970: breakStartInterval)
            let elapsed = Date().timeIntervalSince(breakStart)
            let storedBreakDuration = defaults.double(forKey: "syncTimerBreakDuration")
            let effectiveBreakDuration = storedBreakDuration > 0 ? storedBreakDuration : breakDuration
            let remaining = effectiveBreakDuration - elapsed

            // Pokud pauza ještě neexpirovala
            if remaining > 0 {
                print("🔄 Obnovuji pauzu (\(Int(remaining))s zbývá)")
                isOnBreak = true
                breakRemaining = remaining

                // Spustit timer
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.tick()
                }
                RunLoop.main.add(timer!, forMode: .common)
                let minimumLock: TimeInterval = effectiveBreakDuration > breakDuration ? 120 : 60
                BreakLockController.shared.show(durationSeconds: remaining, minimumLockSeconds: minimumLock, timerManager: self)
                onUpdate?()
            } else {
                // Pauza expirovala - ukončit ji bezpečně
                print("⏸ Pauza expirovala během vypnutí appky - ukončuji")
                completeExpiredBreak()
            }
        }
    }

    private func completeExpiredBlock() {
        // Bezpečně dokončit expirovaný blok bez otevírání popoverů a zvuků

        // Zkontrolovat, že máme startTime pro výpočet času expirace
        guard let startTime = blockStartTime else {
            print("⚠️ Nelze dokončit expirovaný blok - chybí startTime")
            isRunning = false
            saveTimerState(isRunning: false, isOnBreak: false, blockStart: nil, breakStart: nil)
            onUpdate?()
            return
        }

        let startTimeInterval = startTime.timeIntervalSince1970
        let endTime = startTime.addingTimeInterval(blockDuration)

        // Zkontrolovat, jestli blok s tímto blockStartTime už neexistuje (mohl být dokončen na jiném zařízení)
        let alreadyCompleted = completedBlocksData.contains { existingBlock in
            abs(existingBlock.blockStartTime - startTimeInterval) < 1
        }

        if alreadyCompleted {
            print("⚠️ Blok se startTime \(startTime) už byl dokončen (pravděpodobně na jiném zařízení) - přeskakuji")
            isRunning = false
            saveTimerState(isRunning: false, isOnBreak: false, blockStart: nil, breakStart: nil)
            loadState()  // Načíst aktuální stav ze SYNC
            onUpdate?()
            return
        }

        // Vytvořit nový CompletedBlock
        let completedBlock = SyncManager.CompletedBlock(
            blockStartTime: startTimeInterval,
            completedAt: endTime.timeIntervalSince1970,
            deviceId: deviceId
        )

        isRunning = false
        completedBlocks += 1
        completedBlocksData.append(completedBlock)
        print("✅ Expirovaný blok dokončen: startTime=\(startTime), deviceId=\(deviceId)")

        enableFocusMode(false)

        // Přidat do kalendáře
        addCalendarEvent(blockNumber: completedBlocks, startTime: startTime, endTime: endTime)

        // Extra bloky mají dvojnásobnou pauzu
        let isNowOvertime = completedBlocks >= maxBlocks
        let actualBreakDuration = isNowOvertime ? breakDuration * 2 : breakDuration
        let expectedBreakEnd = endTime.addingTimeInterval(actualBreakDuration)

        if Date() > expectedBreakEnd {
            print("⏸ Pauza také expirovala během vypnutí appky")
            saveTimerState(isRunning: false, isOnBreak: false, blockStart: nil, breakStart: nil)
            startReminderTimer()
        } else {
            let breakElapsed = Date().timeIntervalSince(endTime)
            let breakRemainingTime = actualBreakDuration - breakElapsed

            if breakRemainingTime > 0 {
                print("🔄 Spouštím zbývající pauzu (\(Int(breakRemainingTime))s)")
                isOnBreak = true
                self.breakRemaining = breakRemainingTime

                defaults.set(actualBreakDuration, forKey: "syncTimerBreakDuration")
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.tick()
                }
                RunLoop.main.add(timer!, forMode: .common)

                saveTimerState(isRunning: false, isOnBreak: true, blockStart: nil, breakStart: endTime)
                let minimumLock: TimeInterval = actualBreakDuration > breakDuration ? 120 : 60
                BreakLockController.shared.show(durationSeconds: breakRemainingTime, minimumLockSeconds: minimumLock, timerManager: self)
            } else {
                saveTimerState(isRunning: false, isOnBreak: false, blockStart: nil, breakStart: nil)
                startReminderTimer()
            }
        }

        saveState()
        onUpdate?()
    }

    private func completeExpiredBreak() {
        // Bezpečně ukončit expirovanou pauzu
        isOnBreak = false
        BreakLockController.shared.hide()

        // Vymazat timer state
        saveTimerState(isRunning: false, isOnBreak: false, blockStart: nil, breakStart: nil)

        onUpdate?()
        startReminderTimer()
    }
}
