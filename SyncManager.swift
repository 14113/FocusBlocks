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

            struct Settings: Codable {
                var focusDurationMinutes: Int
                var breakDurationMinutes: Int
                var reminderMinutes: Int
                var maxBlocks: Int
                var openRescueTimeOnComplete: Bool
                var rescueTimeApiKey: String?
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
    }

    func disableSync() {
        isSyncEnabled = false
        syncFolderPath = nil
        stopMonitoring()
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

        return SyncData.FocusBlocksData(
            completedBlockTimes: completedBlockTimes,
            lastDate: lastDate,
            settings: settings
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

            // Notifikovat TimerManager o změně
            NotificationCenter.default.post(name: .syncDataUpdated, object: nil)

            // Uložit aktualizovaná data zpět do souboru
            self.exportCurrentData()

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

    deinit {
        stopMonitoring()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let syncDataUpdated = Notification.Name("syncDataUpdated")
}
