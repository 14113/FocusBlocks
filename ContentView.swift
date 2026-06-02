import SwiftUI
import ServiceManagement

struct ContentView: View {
    @ObservedObject var timerManager: TimerManager
    @ObservedObject var syncManager = SyncManager.shared
    var onUpdate: () -> Void
    var onClosePopover: (() -> Void)?
    @State private var shuffledActivities: [String] = []
    @State private var settingsExpanded: Bool = false
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var hoveredBlockIndex: Int? = nil
    @State private var isRemoteTimer: Bool = false

    private var focusMinutesInt: Binding<Int> {
        Binding(
            get: { timerManager.focusDurationMinutes },
            set: { timerManager.saveFocusDuration(max(1, min(60, $0))) }
        )
    }

    private var breakMinutesInt: Binding<Int> {
        Binding(
            get: { timerManager.breakDurationMinutes },
            set: { timerManager.saveBreakDuration(max(1, min(30, $0))) }
        )
    }

    private var reminderMinutesInt: Binding<Int> {
        Binding(
            get: { timerManager.reminderMinutes },
            set: { timerManager.saveReminderDuration(max(1, min(60, $0))) }
        )
    }

    private var apiKey: Binding<String> {
        Binding(
            get: { timerManager.rescueTimeApiKey },
            set: { timerManager.saveApiKey($0) }
        )
    }

    private var maxBlocksInt: Binding<Int> {
        Binding(
            get: { timerManager.maxBlocks },
            set: { timerManager.saveMaxBlocks(max(1, min(10, $0))) }
        )
    }

    private var breakInstructionText: Binding<String> {
        Binding(
            get: { timerManager.breakInstruction },
            set: { timerManager.saveBreakInstruction($0) }
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            // Progress visualization
            EmptyView()
                .onAppear {
                    if shuffledActivities.isEmpty {
                        shuffledActivities = timerManager.activities.shuffled()
                    }
                }
            ZStack(alignment: .bottom) {
                VStack(spacing: 8) {
                    let totalBlocksToShow = max(timerManager.maxBlocks, timerManager.completedBlocks + (timerManager.isRunning ? 1 : 0))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(0..<totalBlocksToShow, id: \.self) { index in
                                let isExtra = index >= timerManager.maxBlocks
                                ZStack {
                                    if index == timerManager.completedBlocks && timerManager.isRunning {
                                        // Active block - focus indicator
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color.orange, Color.orange.opacity(0.8)],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                            .frame(width: 26, height: 26)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(Color.orange.opacity(0.6), lineWidth: 2)
                                            )
                                            .shadow(color: Color.orange.opacity(0.5), radius: 4, x: 0, y: 2)

                                        Image(systemName: "flame.fill")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.white)
                                    } else {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(blockColor(for: index))
                                            .frame(width: 26, height: 26)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(
                                                        index < timerManager.completedBlocks
                                                            ? (isExtra ? Color.purple.opacity(0.5) : Color.green.opacity(0.5))
                                                            : Color.gray.opacity(0.3),
                                                        lineWidth: 1
                                                    )
                                            )
                                            .shadow(
                                                color: index < timerManager.completedBlocks
                                                    ? (isExtra ? Color.purple.opacity(0.3) : Color.green.opacity(0.3))
                                                    : Color.clear,
                                                radius: 2, x: 0, y: 1
                                            )

                                        if index < timerManager.completedBlocks {
                                            Image(systemName: isExtra ? "bolt.fill" : "checkmark")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
                                }
                                .onHover { isHovered in
                                    hoveredBlockIndex = isHovered ? index : nil
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .frame(width: 300)

                    Spacer().frame(height: 16)
                }

                if hoveredBlockIndex != nil {
                    Text(blockTooltip(for: hoveredBlockIndex!))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 300, height: 50)
            
            
            // Timer display
            if timerManager.isRunning {
                VStack(spacing: 12) {
                    Text(formatTime(timerManager.remainingTime))
                        .font(.system(size: 48, weight: .light, design: .monospaced))

                    HStack(spacing: 6) {
                        Text("Focus time")
                            .foregroundColor(.secondary)

                        if isRemoteTimer {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.blue)
                                Text("sync")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.blue)
                            }
                        }
                    }

                    Button(action: {
                        timerManager.stopBlock()
                        onUpdate()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12, weight: .medium))
                            Text("Stop")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.15))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            } else if timerManager.isOnBreak {
                VStack(spacing: 16) {
                    Text(formatTime(timerManager.breakRemaining))
                        .font(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundColor(.green)
                    Text("Pauza")
                        .font(.headline)
                        .foregroundColor(.green)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Co můžeš dělat:")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        ForEach(shuffledActivities.isEmpty ? timerManager.activities : shuffledActivities, id: \.self) { activity in
                            Text(activity)
                                .font(.system(size: 15))
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(12)
                }
            } else if timerManager.completedBlocks >= timerManager.maxBlocks {
                VStack(spacing: 16) {
                    Text("HOTOVO!")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.green)

                    Text("Skvělá práce! Zavři notebook a užij si zbytek dne.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dokončené bloky:")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        HStack(alignment: .top, spacing: 16) {
                            let times = timerManager.completedBlockTimes
                            let half = (times.count + 1) / 2

                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(0..<half, id: \.self) { index in
                                    Text("Blok \(index + 1): \(formatBlockTime(times[index]))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if times.count > half {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(half..<times.count, id: \.self) { index in
                                        Text("Blok \(index + 1): \(formatBlockTime(times[index]))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }

                        Divider()

                        Text("Celkový čas: \(formatTotalTime())")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                }
            }

            // Controls
            if !timerManager.isRunning && !timerManager.isOnBreak {
                let isOvertime = timerManager.completedBlocks >= timerManager.maxBlocks
                Spacer()
                    .frame(height: 16)

                Button(action: {
                    timerManager.startBlock()
                    onUpdate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        onClosePopover?()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: isOvertime ? "bolt.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                        VStack(spacing: 2) {
                            Text(isOvertime ? "Extra blok" : "Start")
                                .font(.system(size: 16, weight: .semibold))
                            if isOvertime {
                                Text("pauza 2x delší")
                                    .font(.system(size: 10))
                                    .opacity(0.85)
                            }
                        }
                    }
                    .foregroundColor(.white)
                    .frame(minWidth: 120, minHeight: 44)
                    .background(
                        LinearGradient(
                            colors: isOvertime
                                ? [Color.purple, Color.purple.opacity(0.8)]
                                : [Color(red: 0.2, green: 0.8, blue: 0.4), Color(red: 0.1, green: 0.6, blue: 0.3)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(12)
                    .shadow(
                        color: (isOvertime ? Color.purple : Color(red: 0.1, green: 0.6, blue: 0.3)).opacity(0.4),
                        radius: 4, x: 0, y: 2
                    )
                }
                .buttonStyle(.plain)

                Spacer()
                    .frame(height: 16)
            }

            // Settings
            Divider()
            
            Button(action: {
                withAnimation {
                    settingsExpanded.toggle()
                }
            }) {
                HStack {
                    Text("Nastavení")
                        .font(.caption)
                    Spacer()
                    Image(systemName: settingsExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if settingsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Focus:")
                            .font(.caption)
                        Spacer()
                        TextField("", value: focusMinutesInt, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                        Text("min")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Pauza:")
                            .font(.caption)
                        Spacer()
                        TextField("", value: breakMinutesInt, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                        Text("min")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Připomenutí:")
                            .font(.caption)
                        Spacer()
                        TextField("", value: reminderMinutesInt, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                        Text("min")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Počet bloků:")
                            .font(.caption)
                        Spacer()
                        TextField("", value: maxBlocksInt, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                        Text("min")
                            .font(.caption)
                            .foregroundColor(.clear)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Text na zámku obrazovky:")
                            .font(.caption)
                        TextField("", text: breakInstructionText)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    // Launch at login
                    Toggle("Spustit při startu", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                print("Failed to update login item: \(error)")
                            }
                        }

                    Divider()

                    // Cloud Synchronization
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Synchronizace dat")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { syncManager.isSyncEnabled },
                                set: { enabled in
                                    if enabled {
                                        selectSyncFolder()
                                    } else {
                                        syncManager.disableSync()
                                    }
                                }
                            ))
                        }

                        if syncManager.isSyncEnabled {
                            VStack(alignment: .leading, spacing: 4) {
                                if let folder = syncManager.syncFolderPath {
                                    Text("Složka: \(folder)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                HStack {
                                    syncStatusView()

                                    Spacer()

                                    Button("Změnit složku") {
                                        selectSyncFolder()
                                    }
                                    .font(.system(size: 10))
                                    .buttonStyle(.plain)
                                    .foregroundColor(.blue)

                                    Button(action: {
                                        syncManager.syncNow()
                                    }) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 10))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.blue)
                                }
                            }
                        } else {
                            Text("Ukládá data do cloudové složky (iCloud, Dropbox, apod.) pro synchronizaci mezi počítači")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    // RescueTime API
                    Text("RescueTime API Key:")
                        .font(.caption)
                    TextField("API Key", text: apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    Toggle("Otevřít RescueTime dashboard po dokončení bloku", isOn: Binding(
                        get: { timerManager.openRescueTimeOnComplete },
                        set: { timerManager.saveOpenRescueTimeOnComplete($0) }
                    ))
                    .font(.caption)
                    Divider()

                    HStack {
                        Button(action: {
                            timerManager.resetDay()
                            onUpdate()
                        }) {
                            Text("Reset")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Quit") {
                            NSApplication.shared.terminate(nil)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(20)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(.thinMaterial)
        .onAppear {
            setupRemoteTimerObserver()
        }
    }

    private func setupRemoteTimerObserver() {
        NotificationCenter.default.addObserver(
            forName: .syncRemoteTimerDetected,
            object: nil,
            queue: .main
        ) { [self] _ in
            isRemoteTimer = true

            // Po 3 sekundách skrýt indikátor
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                isRemoteTimer = false
            }
        }
    }
    
    func blockColor(for index: Int) -> Color {
        if index < timerManager.completedBlocks {
            return index >= timerManager.maxBlocks ? .purple : .green
        } else if index == timerManager.completedBlocks && timerManager.isRunning {
            return .blue
        } else {
            return Color.gray.opacity(0.2)
        }
    }

    func blockTooltip(for index: Int) -> String {
        if index < timerManager.completedBlockTimes.count {
            let date = timerManager.completedBlockTimes[index]
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "Dokončeno v \(formatter.string(from: date))"
        } else if index == timerManager.completedBlocks && timerManager.isRunning {
            return "Probíhá..."
        } else {
            return "Blok \(index + 1)"
        }
    }

    func formatBlockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    func formatTime(_ time: TimeInterval) -> String {
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    func formatTotalTime() -> String {
        let totalSeconds = timerManager.completedBlocksData.reduce(0.0) { sum, block in
            sum + (block.completedAt - block.blockStartTime)
        }
        let totalMinutes = Int(totalSeconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)min"
        } else {
            return "\(minutes)min"
        }
    }

    // MARK: - Sync helpers

    func selectSyncFolder() {
        let panel = NSOpenPanel()
        panel.title = "Vyberte složku pro synchronizaci"
        panel.message = "Vyberte složku v cloudu (iCloud Drive, Dropbox, Google Drive, apod.)"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            syncManager.enableSync(folderPath: url.path)
            onUpdate()
        }
    }

    @ViewBuilder
    func syncStatusView() -> some View {
        HStack(spacing: 4) {
            switch syncManager.syncStatus {
            case .idle:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 10))
                Text("Připraveno")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

            case .syncing:
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 10, height: 10)
                Text("Synchronizuji...")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 10))
                if let date = syncManager.lastSyncDate {
                    Text("Poslední sync: \(formatSyncDate(date))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 10))
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
    }

    func formatSyncDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
