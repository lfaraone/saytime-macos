#!/usr/bin/swift

import AppKit // Use AppKit instead of AVFoundation
import Foundation

// --- Configuration ---
let INTERVAL: TimeInterval = 15 * 60 // 900 seconds

// --- Global State ---
let speechSynthesizer = NSSpeechSynthesizer()
let speechDelegate = SpeechDelegate()

let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    formatter.locale = Locale(identifier: "en_GB")
    return formatter
}()

var signalSources: [DispatchSourceSignal] = []
var isShuttingDown = false

// The selected voice is now an 'NSSpeechSynthesizer.VoiceName'
var selectedVoice: NSSpeechSynthesizer.VoiceName?

// MARK: - Speech Delegate

// Use NSSpeechSynthesizerDelegate
class SpeechDelegate: NSObject, NSSpeechSynthesizerDelegate {
    var speechSemaphore: DispatchSemaphore?
    
    // The delegate method is different
    func speechSynthesizer(_ synthesizer: NSSpeechSynthesizer, didFinishSpeaking finished: Bool) {
        speechSemaphore?.signal()
    }
}

// MARK: - Core Functions

func say(_ text: String) {
    let semaphore = DispatchSemaphore(value: 0)
    speechDelegate.speechSemaphore = semaphore
    
    // Set the voice on the synthesizer instance
    if let voice = selectedVoice {
        speechSynthesizer.setVoice(voice)
    } // If nil, it uses the system default
    
    // Start speaking the string (which may now contain SSML)
    speechSynthesizer.startSpeaking(text)
    
    semaphore.wait()
}

func sayTime() {
    // Add a 100ms delay to ensure we are *just past* the mark
    Thread.sleep(forTimeInterval: 0.1)
    
    let now = Date()
    let timeString = timeFormatter.string(from: now)
    
    // --- SSML FIX ---
    // Wrap the time string in SSML to explicitly force the
    // language context to British English (en-GB).
    let announcement = "<?xml version=\"1.0\"?><speak xml:lang=\"en-US\">\(timeString)</speak>"
    // --- END FIX ---
    
    let logTimestamp = now.formatted(
        .dateTime.year().month().day().hour().minute().second()
    )
    // We'll just log the plain time string for simplicity
    print("[\(logTimestamp)] Announcing: \(timeString)")
    
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

// MARK: - Voice Loading (Rewritten for NSSpeechSynthesizer)

func loadPreferredVoice() {
    print("Loading preferred voice using NSSpeechSynthesizer...")
    // This gets the list of voice *identifiers*
    let availableVoices = NSSpeechSynthesizer.availableVoices
    
    // 1. Try to find the Personal Voice (by its identifier prefix)
    let personalVoiceID = availableVoices.first(where: {
        $0.rawValue.starts(with: "com.apple.speech.personal-voice.")
    })
    
    if let voiceID = personalVoiceID {
        // We found it! Get its name for logging.
        let attributes = NSSpeechSynthesizer.attributes(forVoice: voiceID)
        let name = attributes[.name] as? String ?? "Unknown Personal Voice"
        print("-> Success: Using Personal Voice ('\(name)').")
        selectedVoice = voiceID
        return
    }
    
    // 2. If not found, fall back to "Daniel"
    let danielVoiceID = NSSpeechSynthesizer.VoiceName(rawValue: "com.apple.speech.synthesis.voice.daniel")
    if availableVoices.contains(danielVoiceID) {
        print("-> Personal Voice not found. Using 'Daniel'.")
        selectedVoice = danielVoiceID
        return
    }
    
    // 3. Final fallback
    print("-> 'Daniel' not found. Using system default voice.")
    // Setting to nil tells NSSpeechSynthesizer to use the default voice
    selectedVoice = nil
}

// MARK: - Main Script Logic (Top-Level Code)

// 1. Load the voice list. No authorization needed!
loadPreferredVoice()

// 2. Set up global state
speechSynthesizer.delegate = speechDelegate

// 3. Set up signal handlers
trap(signal: SIGINT, handler: handleTerminationSignal)  // Ctrl+C
trap(signal: SIGTERM, handler: handleTerminationSignal) // kill
trap(signal: SIGHUP, handler: handleTerminationSignal)  // Terminal close

// 4. Parse command-line arguments
let args = CommandLine.arguments
let sayNow = args.contains("--now")

// 5. Main Program
if sayNow {
    print("`--now` flag detected. Announcing current time first.")
    DispatchQueue.global().async {
        sayTime()
    }
}

let waitTime = getWaitTimeForAlignment()
print("Alignment complete. Starting main announcement loop.")

let timer = Timer(
    fire: Date().addingTimeInterval(waitTime),
    interval: INTERVAL,
    repeats: true
) { _ in
    
    DispatchQueue.global().async {
        sayTime()
    }
}

// 6. Add the timer to the main RunLoop
RunLoop.main.add(timer, forMode: .common)

// 7. Keep the script alive.
RunLoop.main.run()
