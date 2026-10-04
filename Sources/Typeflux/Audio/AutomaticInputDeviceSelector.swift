import CoreAudio
import Foundation

/// Chooses the microphone for the Automatic setting. Opening a Bluetooth headset
/// microphone switches the headset from its playback profile (A2DP) to its call
/// profile (HFP): the first 1-2 s arrive as digital silence, the speech is narrowband,
/// and playback quality drops while the microphone is open. When the user has not
/// chosen a microphone, record from a wired input instead so the headset never leaves
/// its playback profile. An explicitly selected microphone never reaches this policy.
enum AutomaticInputDeviceSelector {
    struct Candidate: Equatable {
        let id: AudioDeviceID
        let transportType: UInt32
    }

    static func select(
        systemDefault: AudioDeviceID?,
        candidates: [Candidate],
        builtInMicrophoneIsUsable: Bool
    ) -> AudioDeviceID? {
        guard let systemDefault,
              let defaultTransport = candidates.first(where: { $0.id == systemDefault })?.transportType,
              isBluetooth(defaultTransport)
        else {
            return systemDefault
        }

        var best: (rank: Int, id: AudioDeviceID)?
        for candidate in candidates {
            guard let rank = rank(
                transportType: candidate.transportType,
                builtInMicrophoneIsUsable: builtInMicrophoneIsUsable
            ) else { continue }
            if let current = best, current.rank <= rank {
                continue
            }
            best = (rank, candidate.id)
        }
        // Without a usable wired input, the headset is the only microphone left.
        return best?.id ?? systemDefault
    }

    /// Resolves against live devices. Only a Bluetooth default needs the device scan,
    /// so the common path reads a single property.
    static func select(
        systemDefault: AudioDeviceID?,
        inputDeviceIDs: () -> [AudioDeviceID],
        transportType: (AudioDeviceID) -> UInt32?,
        builtInMicrophoneIsUsable: () -> Bool
    ) -> AudioDeviceID? {
        guard let systemDefault,
              let defaultTransport = transportType(systemDefault),
              isBluetooth(defaultTransport)
        else {
            return systemDefault
        }
        let candidates = inputDeviceIDs().compactMap { id in
            transportType(id).map { Candidate(id: id, transportType: $0) }
        }
        return select(
            systemDefault: systemDefault,
            candidates: candidates,
            builtInMicrophoneIsUsable: builtInMicrophoneIsUsable()
        )
    }

    /// Resolution runs on every start and preparation; report each distinct
    /// substitution once instead of logging every resolution.
    final class SubstitutionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var last: String?

        func message(systemDefault: AudioDeviceID?, selected: AudioDeviceID?) -> String? {
            let substitution = systemDefault == selected
                ? nil
                : "\(systemDefault.map(String.init) ?? "<none>")->\(selected.map(String.init) ?? "<none>")"
            let changed = lock.withLock {
                defer { last = substitution }
                return last != substitution
            }
            guard changed, let substitution else { return nil }
            return "[Audio Devices] System default input is a Bluetooth headset; Automatic recording uses \(substitution)."
        }
    }

    static func isBluetooth(_ transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Lower is better. Virtual, aggregate, AirPlay, Continuity and unknown inputs are
    /// never substituted: they may be silent, remote, or another app's private route.
    private static func rank(transportType: UInt32, builtInMicrophoneIsUsable: Bool) -> Int? {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            // A closed MacBook lid leaves the built-in microphone listed but silent.
            builtInMicrophoneIsUsable ? 0 : nil
        case kAudioDeviceTransportTypeUSB:
            1
        case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire:
            2
        default:
            nil
        }
    }
}
