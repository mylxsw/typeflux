import CoreAudio
import Testing

@testable import Typeflux

struct AutomaticInputDeviceSelectorTests {
    private typealias Candidate = AutomaticInputDeviceSelector.Candidate

    private let airPods = Candidate(id: 10, transportType: kAudioDeviceTransportTypeBluetooth)
    private let leHeadset = Candidate(id: 11, transportType: kAudioDeviceTransportTypeBluetoothLE)
    private let builtIn = Candidate(id: 20, transportType: kAudioDeviceTransportTypeBuiltIn)
    private let usb = Candidate(id: 30, transportType: kAudioDeviceTransportTypeUSB)
    private let thunderbolt = Candidate(id: 31, transportType: kAudioDeviceTransportTypeThunderbolt)
    private let virtual = Candidate(id: 40, transportType: kAudioDeviceTransportTypeVirtual)
    private let aggregate = Candidate(id: 41, transportType: kAudioDeviceTransportTypeAggregate)
    private let continuity = Candidate(id: 42, transportType: kAudioDeviceTransportTypeContinuityCaptureWireless)

    @Test func nonBluetoothDefaultIsKept() {
        let selected = AutomaticInputDeviceSelector.select(
            systemDefault: usb.id, candidates: [airPods, builtIn, usb], builtInMicrophoneIsUsable: true)
        #expect(selected == usb.id)
    }

    @Test func missingDefaultStaysMissing() {
        let selected = AutomaticInputDeviceSelector.select(
            systemDefault: nil, candidates: [builtIn], builtInMicrophoneIsUsable: true)
        #expect(selected == nil)
    }

    @Test func defaultWithUnknownTransportIsKept() {
        let selected = AutomaticInputDeviceSelector.select(
            systemDefault: 99, candidates: [builtIn], builtInMicrophoneIsUsable: true)
        #expect(selected == 99)
    }

    @Test(arguments: [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE])
    func bluetoothDefaultPrefersBuiltInMicrophone(transportType: UInt32) {
        let headset = Candidate(id: 10, transportType: transportType)
        let selected = AutomaticInputDeviceSelector.select(
            systemDefault: headset.id, candidates: [headset, usb, builtIn], builtInMicrophoneIsUsable: true)
        #expect(selected == builtIn.id)
    }

    @Test func closedLidSkipsBuiltInMicrophoneForWiredInput() {
        let selected = AutomaticInputDeviceSelector.select(
            systemDefault: airPods.id, candidates: [airPods, builtIn, thunderbolt, usb],
            builtInMicrophoneIsUsable: false)
        #expect(selected == usb.id)
    }

    @Test func closedLidWithoutWiredInputKeepsHeadset() {
        let selected = AutomaticInputDeviceSelector.select(
            systemDefault: airPods.id, candidates: [airPods, builtIn], builtInMicrophoneIsUsable: false)
        #expect(selected == airPods.id)
    }

    @Test func virtualAggregateContinuityAndOtherHeadsetsAreNeverSubstituted() {
        let selected = AutomaticInputDeviceSelector.select(
            systemDefault: airPods.id, candidates: [airPods, leHeadset, virtual, aggregate, continuity],
            builtInMicrophoneIsUsable: true)
        #expect(selected == airPods.id)
    }

    @Test func equallyRankedInputsKeepDeviceOrder() {
        let secondUSB = Candidate(id: 32, transportType: kAudioDeviceTransportTypeUSB)
        let selected = AutomaticInputDeviceSelector.select(
            systemDefault: airPods.id, candidates: [airPods, thunderbolt, usb, secondUSB],
            builtInMicrophoneIsUsable: true)
        #expect(selected == usb.id)
    }

    @Test func liveSelectionReadsOnlyTheDefaultWhenItIsNotBluetooth() {
        var scanned = false
        var clamshellRead = false
        let selected = AutomaticInputDeviceSelector.select(
            systemDefault: usb.id,
            inputDeviceIDs: {
                scanned = true
                return [usb.id]
            },
            transportType: { $0 == usb.id ? usb.transportType : nil },
            builtInMicrophoneIsUsable: {
                clamshellRead = true
                return true
            })
        #expect(selected == usb.id)
        #expect(!scanned)
        #expect(!clamshellRead)
    }

    @Test func liveSelectionScansDevicesForABluetoothDefault() {
        let transports = [airPods.id: airPods.transportType, builtIn.id: builtIn.transportType]
        let selected = AutomaticInputDeviceSelector.select(
            systemDefault: airPods.id,
            inputDeviceIDs: { [airPods.id, 77, builtIn.id] },
            transportType: { transports[$0] },
            builtInMicrophoneIsUsable: { true })
        #expect(selected == builtIn.id)
    }

    @Test func liveSelectionKeepsAMissingOrUnreadableDefault() {
        #expect(AutomaticInputDeviceSelector.select(
            systemDefault: nil, inputDeviceIDs: { [] }, transportType: { _ in nil },
            builtInMicrophoneIsUsable: { true }) == nil)
        #expect(AutomaticInputDeviceSelector.select(
            systemDefault: 5, inputDeviceIDs: { [] }, transportType: { _ in nil },
            builtInMicrophoneIsUsable: { true }) == 5)
    }

    @Test func substitutionIsLoggedOncePerDistinctChoice() {
        let log = AutomaticInputDeviceSelector.SubstitutionLog()
        #expect(log.message(systemDefault: 10, selected: 10) == nil)
        let first = log.message(systemDefault: 10, selected: 20)
        #expect(first?.contains("10->20") == true)
        #expect(log.message(systemDefault: 10, selected: 20) == nil)
        #expect(log.message(systemDefault: 10, selected: 10) == nil)
        // After returning to the default, the same substitution is reported again.
        #expect(log.message(systemDefault: 10, selected: 20) != nil)
        #expect(log.message(systemDefault: nil, selected: 30)?.contains("<none>->30") == true)
    }

    @Test func classifiesBluetoothTransports() {
        #expect(AutomaticInputDeviceSelector.isBluetooth(kAudioDeviceTransportTypeBluetooth))
        #expect(AutomaticInputDeviceSelector.isBluetooth(kAudioDeviceTransportTypeBluetoothLE))
        #expect(!AutomaticInputDeviceSelector.isBluetooth(kAudioDeviceTransportTypeBuiltIn))
        #expect(!AutomaticInputDeviceSelector.isBluetooth(kAudioDeviceTransportTypeUSB))
    }
}

struct AudioDeviceManagerAutomaticInputTests {
    @Test func automaticInputMatchesANonBluetoothSystemDefault() {
        let manager = AudioDeviceManager()
        let systemDefault = manager.defaultInputDeviceID()
        let automatic = manager.automaticRecordingInputDeviceID()
        if let systemDefault, manager.isBluetoothInputDevice(systemDefault) {
            #expect(automatic != nil)
        } else {
            #expect(automatic == systemDefault)
        }
        _ = AudioDeviceManager.isClamshellClosed()
    }

    @Test func managersWithoutBluetoothSupportFollowTheSystemDefault() {
        let manager = DefaultOnlyDevices()
        #expect(manager.automaticRecordingInputDeviceID() == 42)
        #expect(!manager.isBluetoothInputDevice(42))
    }

    @Test func unknownDeviceIsNotBluetooth() {
        #expect(!AudioDeviceManager().isBluetoothInputDevice(AudioDeviceID(kAudioObjectUnknown)))
    }
}

private struct DefaultOnlyDevices: AudioDeviceManaging {
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func resolveInputDeviceID(for _: String) -> AudioDeviceID? { nil }
    func defaultInputDeviceID() -> AudioDeviceID? { 42 }
    func observeDefaultInputDeviceChanges(_: @escaping @Sendable () -> Void) -> AudioInputDeviceChangeObservation? {
        nil
    }
}
