import SwiftUI
import ServiceManagement

struct ContentView: View {
    @ObservedObject var timerManager: TimerManager
    var onUpdate: () -> Void
    var onClosePopover: (() -> Void)?
    @State private var shuffledActivities: [String] = []
    @State private var settingsExpanded: Bool = false
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var hoveredBlockIndex: Int? = nil

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
            set: { timerManager.saveMaxBlocks(max(1, min(15, $0))) }
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
                    HStack(spacing: 6) {
                        ForEach(0..<timerManager.maxBlocks, id: \.self) { index in
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
                                                .stroke(index < timerManager.completedBlocks ? Color.green.opacity(0.5) : Color.gray.opacity(0.3), lineWidth: 1)
                                        )
                                        .shadow(color: index < timerManager.completedBlocks ? Color.green.opacity(0.3) : Color.clear, radius: 2, x: 0, y: 1)

                                    if index < timerManager.completedBlocks {
                                        Image(systemName: "checkmark")
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
                    Text("Focus time")
                        .foregroundColor(.secondary)

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
                        Text("Co teď:")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        ForEach(timerManager.activities, id: \.self) { activity in
                            HStack(spacing: 8) {
                                Text(activity)
                                    .font(.body)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(12)

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
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                }
            }

            // Controls
            if !timerManager.isRunning && !timerManager.isOnBreak && timerManager.completedBlocks < timerManager.maxBlocks {
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
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Start")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(minWidth: 120, minHeight: 44)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.2, green: 0.8, blue: 0.4), Color(red: 0.1, green: 0.6, blue: 0.3)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(12)
                    .shadow(color: Color(red: 0.1, green: 0.6, blue: 0.3).opacity(0.4), radius: 4, x: 0, y: 2)
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

                    // RescueTime API
                    Text("RescueTime API Key:")
                        .font(.caption)
                    TextField("API Key", text: apiKey)
                        .textFieldStyle(.roundedBorder)
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
    }
    
    func blockColor(for index: Int) -> Color {
        if index < timerManager.completedBlocks {
            return .green
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
}
