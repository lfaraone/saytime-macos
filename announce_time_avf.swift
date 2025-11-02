#!/usr/bin/swift

import Foundation
import AVFoundation

// --- Configuration ---
let INTERVAL: TimeInterval = 15 * 60 // 900 seconds

// --- Global State ---
let speechSynthesizer = AVSpeechSynthesizer()
let speechDelegate = SpeechDelegate()

let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    // --- CHANGE 1: Use 24-hour clock format ---
    formatter.dateFormat = "HH:mm"
    // We can keep the locale, it doesn't hurt
    formatter.locale = Locale(identifier: "en_GB")
    return formatter
}()

var signalSources: [DispatchSourceSignal] = []
var isShuttingDown = false
var selectedVoice: AVSpeechSynthesisVoice?

// MARK: - Speech Delegate

class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var speechSemaphore: DispatchSemaphore?
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speechSemaphore?.signal()
    }
}

// MARK: - Core Functions

func say(_ text: String) {
    let semaphore = DispatchSemaphore(value: 0)
    speechDelegate.speechSemaphore = semaphore
    
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = selectedVoice

    speechSynthesizer.speak(utterance)
    semaphore.wait()
}

/**
 * Gets the current time, formats it, and announces it.
 */
func sayTime() {
    // Add a 100ms delay to ensure we are *just past* the mark,
    // preventing the "too soon" rounding error (e.g., 20:59:59.998)
    Thread.sleep(forTimeInterval: 0.1)
    
    let now = Date()
    let timeString = timeFormatter.string(from: now)
    
    // --- CHANGE 2: Drop "The time is" ---
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

// MARK: - Voice Loading and Authorization

func enumeratePersonalVoices() {
    print("Enumerating available Personal Voices...")
    print("(Note: Personal Voice is supported for English, Spanish, and Mandarin Chinese.)")
    
    let availableVoices = AVSpeechSynthesisVoice.speechVoices()
    let personalVoices = availableVoices.filter { $0.voiceTraits.contains(.isPersonalVoice) }
    
    if personalVoices.isEmpty {
        print("-> No Personal Voices found.")
    } else {
        for voice in personalVoices {
            print("-> Found: \(voice.name) (Language: \(voice.language), ID: \(voice.identifier))")
        }
    }
}

func checkPersonalVoiceAuthorization() {
    let status = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    
    switch status {
    case .notDetermined:
        print("Personal Voice authorization not yet requested. Asking...")
        let semaphore = DispatchSemaphore(value: 0)
        
        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { (status) in
            if status == .authorized {
                print("Authorization granted.")
                enumeratePersonalVoices()
            } else {
                print("Authorization denied by user. Falling back to standard voice.")
            }
            semaphore.signal()
        }
        semaphore.wait()
        
    case .denied:
        print("Personal Voice authorization was denied. Falling back to standard voice.")
        print("To enable, go to System Settings > Accessibility > Personal Voice.")
        
    case .authorized:
        print("Personal Voice authorization already granted.")
        enumeratePersonalVoices()

    case .unsupported:
         print("Personal Voice is not supported on this device. Falling back to standard voice.")

    @unknown default:
        print("Unknown authorization status. Falling back to standard voice.")
    }
}

func loadPreferredVoice() {
    print("Loading preferred voice...")
    let availableVoices = AVSpeechSynthesisVoice.speechVoices()
    
    let englishPersonalVoice = availableVoices.first(where: {
        $0.voiceTraits.contains(.isPersonalVoice) // && $0.language.hasPrefix("es")
    })

    
    if let voice = englishPersonalVoice {
        print("-> Success: Using English Personal Voice ('\(voice.name)').")
        selectedVoice = voice
        return
    }
    
    let danielVoiceID = "com.apple.speech.synthesis.voice.daniel"
    if let danielVoice = AVSpeechSynthesisVoice(identifier: danielVoiceID) {
        print("-> English Personal Voice not found. Using 'Daniel'.")
        selectedVoice = danielVoice
        return
    }
    
    print("-> 'Daniel' not found. Using system default voice.")
    selectedVoice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
}

// MARK: - Main Script Logic (Top-Level Code)

// 1. Authorize *first*.
checkPersonalVoiceAuthorization()

// 2. Load the voice list *second*.
loadPreferredVoice()

// 3. Set up global state
speechSynthesizer.delegate = speechDelegate

// 4. Set up signal handlers
trap(signal: SIGINT, handler: handleTerminationSignal)  // Ctrl+C
trap(signal: SIGTERM, handler: handleTerminationSignal) // kill
trap(signal: SIGHUP, handler: handleTerminationSignal)  // Terminal close

// 5. Parse command-line arguments
let args = CommandLine.arguments
let sayNow = args.contains("--now")

// 6. Main Program
if sayNow {
    print("Announcing current time first.")
    DispatchQueue.global().async {
        sayTime()
    }
}

let waitTime = getWaitTimeForAlignment()

let timer = Timer(
    fire: Date().addingTimeInterval(waitTime),
    interval: INTERVAL,
    repeats: true
) { _ in
    
    DispatchQueue.global().async {
        sayTime()
    }
}

// 7. Add the timer to the main RunLoop
RunLoop.main.add(timer, forMode: .common)

// 8. Keep the script alive.
RunLoop.main.run()
