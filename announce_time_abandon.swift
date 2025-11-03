#!/usr/bin/swift

import Foundation

// --- Configuration ---
let INTERVAL: TimeInterval = 15 * 60 // 900 seconds

// --- Global State ---
let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    formatter.locale = Locale(identifier: "en_GB")
    return formatter
}()

var signalSources: [DispatchSourceSignal] = []
var isShuttingDown = false

// MARK: - Core Functions

/**
 * Executes a shell command synchronously (blocking).
 */
@discardableResult
func shell(_ command: String) -> (output: String, error: String, status: Int32) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-c", command]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    task.standardOutput = outputPipe
    task.standardError = errorPipe

    do {
        try task.run()
        task.waitUntilExit()
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""
        
        return (output, error, task.terminationStatus)
    } catch {
        return ("", error.localizedDescription, -1)
    }
}

/**
 * Speaks the given text using the '/usr/bin/say' command.
 */
func say(_ text: String) {
    // Create a shell-safe version of the text
    let safeText = text.replacingOccurrences(of: "'", with: "'\\''")
    
    // Run 'say' without the -v flag to use the system default voice
    // (which you've confirmed is your Personal Voice).
    shell("/usr/bin/say '\(safeText)'")
}

func sayTime() {
    // Sleep for 500ms (0.5s) to ensure we are safely
    // past the 'xx:xx:59.x' rounding error.
    Thread.sleep(forTimeInterval: 0.5)
    
    let now = Date()
    let timeString = timeFormatter.string(from: now)
    let announcement = timeString
    
    let logTimestamp = now.formatted(
        .dateTime.year().month().day().hour().minute().second()
    )
    print("[\(logTimestamp)] Announcing: \(announcement)")
    
    say(announcement)
}

func getWaitTimeForAlignment() -> TimeInterval {
    let now = Date()
    let calendar = Calendar.current
    
    let components = calendar.dateComponents(
        [.minute, .second, .nanosecond],
        from: now
    )
    
    let minute = components.minute ?? 0
    let second = components.second ?? 0
    let nano = components.nanosecond ?? 0
    
    let secondsPastHour: TimeInterval = (
        TimeInterval(minute * 60 + second) +
        (TimeInterval(nano) / 1_000_000_000.0)
    )
    
    let secondsPastMark = secondsPastHour.truncatingRemainder(dividingBy: INTERVAL)
    let waitSeconds = INTERVAL - secondsPastMark
    
    let timeformat = now.formatted(date: .omitted, time: .standard)
    print("Current time: \(timeformat)")
    print(
        "Waiting \(String(format: "%.2f", waitSeconds)) seconds to align with the next 15-minute mark..."
    )
    
    return waitSeconds
}

// MARK: - Signal Handling

func handleTerminationSignal() {
    guard !isShuttingDown else {
        return
    }
    isShuttingDown = true
    
    print("\nTermination signal received. Stopping time announcer...")
    
    signalSources.forEach { $0.cancel() }
    signalSources.removeAll()
    
    DispatchQueue.global().async {
        say("Stopping time announcer.")
        print("Exiting.")
        exit(0)
    }
}

func trap(signal: Int32, handler: @escaping () -> Void) {
    Foundation.signal(signal, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
    source.setEventHandler {
        handler()
    }
    source.resume()
    signalSources.append(source)
}

// MARK: - Timer Logic

/**
 * This function creates a self-perpetuating chain of one-shot timers.
 * It schedules one announcement and, when it fires, it calls itself
 * to schedule the next one, re-aligning to the clock every time.
 */
func scheduleNextAnnouncement() {
    // 1. Calculate the wait time *from now*.
    let waitTime = getWaitTimeForAlignment()

    // 2. Schedule a *one-shot* timer.
    Timer.scheduledTimer(
        withTimeInterval: waitTime,
        repeats: false // This is the key: NOT repeating
    ) { _ in
        // 3. The timer fired. Do two things:
        
        // a) Announce the time in the background.
        DispatchQueue.global().async {
            sayTime()
        }
        
        // b) Schedule the *next* announcement.
        // This creates a chain of one-shot timers,
        // re-aligning to the clock each time.
        scheduleNextAnnouncement()
    }
}

// MARK: - Main Script Logic (Top-Level Code)

// 1. Set up signal handlers
trap(signal: SIGINT, handler: handleTerminationSignal)  // Ctrl+C
trap(signal: SIGTERM, handler: handleTerminationSignal) // kill
trap(signal: SIGHUP, handler: handleTerminationSignal)  // Terminal close

// 2. Parse command-line arguments
let args = CommandLine.arguments
let sayNow = args.contains("--now")

// 3. Main Program
if sayNow {
    print("`--now` flag detected. Announcing current time first.")
    // We run this in the background so the script
    // can continue immediately to the timer setup.
    DispatchQueue.global().async {
        sayTime()
    }
}

// 4. Start the timer chain.
print("Starting announcement scheduler.")
print("Using system default voice (Personal Voice).")
scheduleNextAnnouncement()

// 5. Keep the script alive.
RunLoop.main.run()
