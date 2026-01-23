import Foundation
import Combine

/// Spravuje synchronizaci dat přes Dropbox složku
class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published var isSyncEnabled = false
    @Published var syncFolderPath: String?
    @Published var lastSyncDate: Date?
    @Published var syncStatus: SyncStatus = .idle

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private var fileMonitor: DispatchSourceFileSystemObject?
    private let syncQueue = DispatchQueue(label: "com.focusblocks.sync", qos: .utility)
    private var periodicSyncTimer: Timer?

    // Unikátní ID tohoto zařízení
    private var deviceId: String {
        if let saved = defaults.string(forKey: "deviceId") {
            return saved
        }
        let newId = UUID().uuidString
        defaults.set(newId, forKey: "deviceId")
        return newId
    }

    enum SyncStatus {
        case idle
        case syncing
        case error(String)
        case success
    }

    struct SyncData: Codable {
        let version: Int
        let lastModified: Date
        let deviceId: String
        let data: FocusBlocksData

        struct FocusBlocksData: Codable {
            var completedBlockTimes: [TimeInterval]
            var lastDate: TimeInterval
            var settings: Settings
            var timerState: TimerState?

            struct Settings: Codable {
                var focusDurationMinutes: Int
                var breakDurationMinutes: Int
                var reminderMinutes: Int
                var maxBlocks: Int
                var openRescueTimeOnComplete: Bool
                var rescueTimeApiKey: String?
            }

            struct TimerState: Codable {
                var isRunning: Bool
                var isOnBreak: Bool
                var blockStartTime: TimeInterval?
                var breakStartTime: TimeInterval?
                var sourceDeviceId: String
                var stateUpdatedAt: TimeInterval
            }
        }
    }

    private init() {
        loadSyncSettings()
    }

    // MARK: - Configuration

    func enableSync(folderPath: String) {
        guard fileManager.fileExists(atPath: folderPath) else {
            syncStatus = .error("Složka neexistuje")
            return
        }

        syncFolderPath = folderPath
        isSyncEnabled = true
        saveSyncSettings()

        // První synchronizace
        performInitialSync()

        // Spustit sledování změn
        startMonitoring()

        // Spustit periodickou synchronizaci pro real-time timer
        startPeriodicSync()
    }

    func disableSync() {
        isSyncEnabled = false
        syncFolderPath = nil
        stopMonitoring()
        stopPeriodicSync()
        saveSyncSettings()
    }

    private func saveSyncSettings() {
        defaults.set(isSyncEnabled, forKey: "syncEnabled")
        defaults.set(syncFolderPath, forKey: "syncFolderPath")
    }

    private func loadSyncSettings() {
        isSyncEnabled = defaults.bool(forKey: "syncEnabled")
        syncFolderPath = defaults.string(forKey: "syncFolderPath")

        if isSyncEnabled, syncFolderPath != nil {
            startMonitoring()
            startPeriodicSync()
        }
    }

    // MARK: - File Operations

    private var syncFilePath: String? {
        guard let folder = syncFolderPath else { return nil }
        return (folder as NSString).appendingPathComponent("focusblocks-data.json")
    }

    private func performInitialSync() {
        guard let filePath = syncFilePath else { return }

        syncStatus = .syncing

        syncQueue.async { [weak self] in
            guard let self = self else { return }

            if self.fileManager.fileExists(atPath: filePath) {
                // Soubor existuje - načíst a mergovat
                self.loadAndMerge()
            } else {
                // Soubor neexistuje - vytvořit z lokálních dat
                self.exportCurrentData()
            }

            DispatchQueue.main.async {
                self.syncStatus = .success
                self.lastSyncDate = Date()
            }
        }
    }

    func exportCurrentData() {
        guard let filePath = syncFilePath else { return }

        let currentData = collectCurrentData()
        let syncData = SyncData(
            version: 1,
            lastModified: Date(),
            deviceId: deviceId,
            data: currentData
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(syncData)
            try jsonData.write(to: URL(fileURLWithPath: filePath))

            print("✓ Data exportována do: \(filePath)")
        } catch {
            print("✗ Chyba při exportu: \(error)")
            DispatchQueue.main.async {
                self.syncStatus = .error("Export selhal: \(error.localizedDescription)")
            }
        }
    }

    func loadAndMerge() {
        guard let filePath = syncFilePath else { return }

        do {
            let jsonData = try Data(contentsOf: URL(fileURLWithPath: filePath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let syncData = try decoder.decode(SyncData.self, from: jsonData)

            // Sloučit data
            mergeData(remote: syncData)

            print("✓ Data načtena a sloučena ze: \(filePath)")
        } catch {
            print("✗ Chyba při načítání: \(error)")
            DispatchQueue.main.async {
                self.syncStatus = .error("Import selhal: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Data Collection

    private func collectCurrentData() -> SyncData.FocusBlocksData {
        let completedBlockTimes = (defaults.array(forKey: "completedBlockTimes") as? [TimeInterval]) ?? []
        let lastDate = defaults.double(forKey: "lastDate")

        let settings = SyncData.FocusBlocksData.Settings(
            focusDurationMinutes: defaults.integer(forKey: "focusDurationMinutes") != 0 ?
                defaults.integer(forKey: "focusDurationMinutes") : 30,
            breakDurationMinutes: defaults.integer(forKey: "breakDurationMinutes") != 0 ?
                defaults.integer(forKey: "breakDurationMinutes") : 5,
            reminderMinutes: defaults.integer(forKey: "reminderMinutes") != 0 ?
                defaults.integer(forKey: "reminderMinutes") : 15,
            maxBlocks: defaults.integer(forKey: "maxBlocks") != 0 ?
                defaults.integer(forKey: "maxBlocks") : 10,
            openRescueTimeOnComplete: defaults.bool(forKey: "openRescueTimeOnComplete"),
            rescueTimeApiKey: defaults.string(forKey: "rescueTimeApiKey")
        )

        // Načíst timer state
        let timerState = collectTimerState()

        return SyncData.FocusBlocksData(
            completedBlockTimes: completedBlockTimes,
            lastDate: lastDate,
            settings: settings,
            timerState: timerState
        )
    }

    private func collectTimerState() -> SyncData.FocusBlocksData.TimerState? {
        let isRunning = defaults.bool(forKey: "syncTimerIsRunning")
        let isOnBreak = defaults.bool(forKey: "syncTimerIsOnBreak")

        // Pokud timer neběží, nevracet state
        guard isRunning || isOnBreak else { return nil }

        let blockStartTime = defaults.object(forKey: "syncTimerBlockStartTime") as? TimeInterval
        let breakStartTime = defaults.object(forKey: "syncTimerBreakStartTime") as? TimeInterval
        let stateUpdatedAt = defaults.double(forKey: "syncTimerStateUpdatedAt")

        return SyncData.FocusBlocksData.TimerState(
            isRunning: isRunning,
            isOnBreak: isOnBreak,
            blockStartTime: blockStartTime,
            breakStartTime: breakStartTime,
            sourceDeviceId: deviceId,
            stateUpdatedAt: stateUpdatedAt > 0 ? stateUpdatedAt : Date().timeIntervalSince1970
        )
    }

    // MARK: - Conflict Resolution

    private func mergeData(remote: SyncData) {
        let local = collectCurrentData()

        // 1. MERGE completedBlockTimes - spojit a odstranit duplikáty
        var mergedTimes = Set(local.completedBlockTimes)
        mergedTimes.formUnion(remote.data.completedBlockTimes)
        let sortedTimes = mergedTimes.sorted()

        // Filtrovat pouze dnešní bloky
        let today = Calendar.current.startOfDay(for: Date())
        let todayTimes = sortedTimes.filter { timestamp in
            let date = Date(timeIntervalSince1970: timestamp)
            return Calendar.current.isDate(date, inSameDayAs: Date())
        }

        // 2. Vzít novější lastDate
        let mergedLastDate = max(local.lastDate, remote.data.lastDate)

        // 3. LAST-WRITE-WINS pro nastavení
        // Pokud remote je novější (lastModified), použít remote nastavení
        let useRemoteSettings = remote.lastModified > (lastSyncDate ?? Date.distantPast)
        let mergedSettings = useRemoteSettings ? remote.data.settings : local.settings

        // 4. Timer state - použít novější a z jiného zařízení
        var mergedTimerState: SyncData.FocusBlocksData.TimerState? = nil
        let shouldUseRemoteTimer = shouldSyncRemoteTimer(local: local.timerState, remote: remote.data.timerState)

        if shouldUseRemoteTimer, let remoteTimer = remote.data.timerState {
            mergedTimerState = remoteTimer
        } else {
            mergedTimerState = local.timerState
        }

        // Uložit sloučená data
        DispatchQueue.main.async {
            self.defaults.set(todayTimes, forKey: "completedBlockTimes")
            self.defaults.set(todayTimes.count, forKey: "completedBlocks")
            self.defaults.set(mergedLastDate, forKey: "lastDate")

            self.defaults.set(mergedSettings.focusDurationMinutes, forKey: "focusDurationMinutes")
            self.defaults.set(mergedSettings.breakDurationMinutes, forKey: "breakDurationMinutes")
            self.defaults.set(mergedSettings.reminderMinutes, forKey: "reminderMinutes")
            self.defaults.set(mergedSettings.maxBlocks, forKey: "maxBlocks")
            self.defaults.set(mergedSettings.openRescueTimeOnComplete, forKey: "openRescueTimeOnComplete")
            if let apiKey = mergedSettings.rescueTimeApiKey {
                self.defaults.set(apiKey, forKey: "rescueTimeApiKey")
            }

            // Uložit timer state
            if let timerState = mergedTimerState {
                self.defaults.set(timerState.isRunning, forKey: "syncTimerIsRunning")
                self.defaults.set(timerState.isOnBreak, forKey: "syncTimerIsOnBreak")
                self.defaults.set(timerState.blockStartTime, forKey: "syncTimerBlockStartTime")
                self.defaults.set(timerState.breakStartTime, forKey: "syncTimerBreakStartTime")
                self.defaults.set(timerState.stateUpdatedAt, forKey: "syncTimerStateUpdatedAt")
            } else {
                // Žádný aktivní timer
                self.defaults.set(false, forKey: "syncTimerIsRunning")
                self.defaults.set(false, forKey: "syncTimerIsOnBreak")
            }

            // Notifikovat TimerManager o změně
            NotificationCenter.default.post(name: .syncDataUpdated, object: nil)

            // Pokud se synchronizoval běžící timer z jiného zařízení, poslat speciální notifikaci
            if shouldUseRemoteTimer, let remoteTimer = remote.data.timerState,
               remoteTimer.sourceDeviceId != self.deviceId {
                NotificationCenter.default.post(name: .syncRemoteTimerDetected, object: mergedTimerState)
            }

            // NEEXPORTOVAT zpět - pouze jsme četli
            // Export se děje pouze když lokálně změníme stav (updateTimerState, saveState)

            self.lastSyncDate = Date()

            if useRemoteSettings {
                self.showSettingsChangedNotification()
            }
        }
    }

    private func showSettingsChangedNotification() {
        // Zobrazit macOS notifikaci
        let notification = NSUserNotification()
        notification.title = "FocusBlocks"
        notification.informativeText = "Nastavení byla synchronizována z druhého počítače"
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func shouldSyncRemoteTimer(local: SyncData.FocusBlocksData.TimerState?,
                                      remote: SyncData.FocusBlocksData.TimerState?) -> Bool {
        // Pokud není žádný remote timer, nepoužívat
        guard let remoteTimer = remote else { return false }

        // Pokud remote timer je z tohoto zařízení, nepoužívat (je to náš vlastní)
        if remoteTimer.sourceDeviceId == deviceId {
            return false
        }

        // Pokud není lokální timer, použít remote
        guard let localTimer = local else { return true }

        // Použít novější timer state
        return remoteTimer.stateUpdatedAt > localTimer.stateUpdatedAt
    }

    // MARK: - Periodic Sync

    private func startPeriodicSync() {
        stopPeriodicSync()

        // Periodicky ČÍST změny každých 10 sekund (bez zápisu)
        DispatchQueue.main.async {
            self.periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                self?.periodicRead()
            }
        }

        print("✓ Periodická synchronizace spuštěna (každých 10s)")
    }

    /// Periodické čtení bez zápisu - pouze načte změny z Dropboxu
    private func periodicRead() {
        guard isSyncEnabled, syncFolderPath != nil else { return }

        // Pokud lokálně běží timer, není potřeba číst
        let localTimerRunning = defaults.bool(forKey: "syncTimerIsRunning") ||
                               defaults.bool(forKey: "syncTimerIsOnBreak")

        if localTimerRunning {
            // Timer už běží lokálně, nepotřebujeme číst
            return
        }

        // Pouze načíst a mergovat (žádný zápis)
        loadAndMerge()
    }

    private func stopPeriodicSync() {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
        print("✓ Periodická synchronizace zastavena")
    }

    // MARK: - File Monitoring

    private func startMonitoring() {
        guard let filePath = syncFilePath else { return }

        // Pokud soubor neexistuje, vytvořit ho
        if !fileManager.fileExists(atPath: filePath) {
            // Vytvořit parent složku pokud neexistuje
            let parentFolder = (filePath as NSString).deletingLastPathComponent
            try? fileManager.createDirectory(atPath: parentFolder, withIntermediateDirectories: true)
            exportCurrentData()
        }

        let fileDescriptor = open(filePath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("✗ Nelze sledovat soubor: \(filePath)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: syncQueue
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            print("📁 Detekována změna v sync souboru")

            // Počkat 500ms aby Dropbox dokončil zápis
            Thread.sleep(forTimeInterval: 0.5)

            DispatchQueue.main.async {
                self.syncStatus = .syncing
            }

            self.loadAndMerge()

            DispatchQueue.main.async {
                self.syncStatus = .success
            }
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        self.fileMonitor = source

        print("✓ Sledování synchronizačního souboru spuštěno")
    }

    private func stopMonitoring() {
        fileMonitor?.cancel()
        fileMonitor = nil
    }

    // MARK: - Public API

    func syncNow() {
        guard isSyncEnabled, syncFolderPath != nil else { return }
        exportCurrentData()
    }

    /// Aktualizuje stav timeru pro synchronizaci
    func updateTimerState(isRunning: Bool, isOnBreak: Bool, blockStartTime: Date?, breakStartTime: Date?) {
        guard isSyncEnabled else { return }

        defaults.set(isRunning, forKey: "syncTimerIsRunning")
        defaults.set(isOnBreak, forKey: "syncTimerIsOnBreak")
        defaults.set(blockStartTime?.timeIntervalSince1970, forKey: "syncTimerBlockStartTime")
        defaults.set(breakStartTime?.timeIntervalSince1970, forKey: "syncTimerBreakStartTime")
        defaults.set(Date().timeIntervalSince1970, forKey: "syncTimerStateUpdatedAt")

        // Okamžitě synchronizovat při změně stavu timeru
        syncNow()
    }

    deinit {
        stopMonitoring()
        stopPeriodicSync()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let syncDataUpdated = Notification.Name("syncDataUpdated")
    static let syncRemoteTimerDetected = Notification.Name("syncRemoteTimerDetected")
}
