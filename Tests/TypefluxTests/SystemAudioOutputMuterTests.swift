import CoreAudio
@testable import Typeflux
import XCTest

final class SystemAudioOutputMuterTests: XCTestCase {
    private let monitorID: AudioDeviceID = 171
    private let builtInID: AudioDeviceID = 157

    func testMutesDefaultOutputWithoutSwitchingWhenItHasMuteControl() {
        let devices = FakeAudioOutputDevices(defaultID: builtInID, builtInID: builtInID, muteStates: [builtInID: 0])
        let muter = SystemAudioOutputMuter(devices: devices)

        muter.beginMutedSession()

        XCTAssertEqual(devices.muteStates[builtInID], 1)
        XCTAssertEqual(devices.setDefaultCalls, [])

        muter.endMutedSession()

        XCTAssertEqual(devices.muteStates[builtInID], 0)
        XCTAssertEqual(devices.setDefaultCalls, [])
    }

    func testDoesNotSwitchWhenExternalDefaultOutputHasMuteControl() {
        let devices = FakeAudioOutputDevices(
            defaultID: monitorID,
            builtInID: builtInID,
            muteStates: [monitorID: 0, builtInID: 0]
        )
        let muter = SystemAudioOutputMuter(devices: devices)

        muter.beginMutedSession()

        XCTAssertEqual(devices.muteStates[monitorID], 1)
        XCTAssertEqual(devices.muteStates[builtInID], 0)
        XCTAssertEqual(devices.setDefaultCalls, [])
    }

    func testSwitchesToMutedBuiltInOutputWhenDefaultOutputHasNoMuteControl() {
        let devices = FakeAudioOutputDevices(defaultID: monitorID, builtInID: builtInID, muteStates: [builtInID: 0])
        let muter = SystemAudioOutputMuter(devices: devices)

        muter.beginMutedSession()

        XCTAssertEqual(devices.defaultID, builtInID)
        XCTAssertEqual(devices.muteStates[builtInID], 1)
        // The built-in output must be muted before it becomes the default output.
        XCTAssertEqual(devices.events, ["mute \(builtInID)=1", "setDefault \(builtInID)"])
    }

    func testRestoresOriginalOutputAndMuteStateWhenSessionEnds() {
        let devices = FakeAudioOutputDevices(defaultID: monitorID, builtInID: builtInID, muteStates: [builtInID: 0])
        let muter = SystemAudioOutputMuter(devices: devices)

        muter.beginMutedSession()
        devices.events.removeAll()
        muter.endMutedSession()

        XCTAssertEqual(devices.defaultID, monitorID)
        XCTAssertEqual(devices.muteStates[builtInID], 0)
        // The original output must be restored before the built-in output is unmuted.
        XCTAssertEqual(devices.events, ["setDefault \(monitorID)", "mute \(builtInID)=0"])
    }

    func testKeepsBuiltInOutputMutedWhenItWasAlreadyMuted() {
        let devices = FakeAudioOutputDevices(defaultID: monitorID, builtInID: builtInID, muteStates: [builtInID: 1])
        let muter = SystemAudioOutputMuter(devices: devices)

        muter.beginMutedSession()
        muter.endMutedSession()

        XCTAssertEqual(devices.defaultID, monitorID)
        XCTAssertEqual(devices.muteStates[builtInID], 1)
    }

    func testRestoresMuteStateWhenSwitchingDefaultOutputFails() {
        let devices = FakeAudioOutputDevices(defaultID: monitorID, builtInID: builtInID, muteStates: [builtInID: 0])
        devices.setDefaultSucceeds = false
        let muter = SystemAudioOutputMuter(devices: devices)

        muter.beginMutedSession()

        XCTAssertEqual(devices.defaultID, monitorID)
        XCTAssertEqual(devices.muteStates[builtInID], 0)

        // A failed begin must not leave state behind that changes anything on end.
        devices.events.removeAll()
        muter.endMutedSession()
        XCTAssertEqual(devices.events, [])
    }

    func testDoesNothingWhenNoOutputHasMuteControl() {
        let devices = FakeAudioOutputDevices(defaultID: monitorID, builtInID: builtInID, muteStates: [:])
        let muter = SystemAudioOutputMuter(devices: devices)

        muter.beginMutedSession()
        muter.endMutedSession()

        XCTAssertEqual(devices.events, [])
        XCTAssertEqual(devices.defaultID, monitorID)
    }

    func testDoesNothingWhenThereIsNoBuiltInOutput() {
        let devices = FakeAudioOutputDevices(defaultID: monitorID, builtInID: nil, muteStates: [:])
        let muter = SystemAudioOutputMuter(devices: devices)

        muter.beginMutedSession()
        muter.endMutedSession()

        XCTAssertEqual(devices.events, [])
    }

    func testDoesNothingWhenDefaultOutputIsUnavailable() {
        let devices = FakeAudioOutputDevices(defaultID: nil, builtInID: builtInID, muteStates: [builtInID: 0])
        let muter = SystemAudioOutputMuter(devices: devices)

        muter.beginMutedSession()
        muter.endMutedSession()

        XCTAssertEqual(devices.events, [])
    }

    func testSecondBeginDuringActiveSessionIsIgnored() {
        let devices = FakeAudioOutputDevices(defaultID: monitorID, builtInID: builtInID, muteStates: [builtInID: 0])
        let muter = SystemAudioOutputMuter(devices: devices)

        muter.beginMutedSession()
        let eventsAfterFirstBegin = devices.events
        muter.beginMutedSession()

        XCTAssertEqual(devices.events, eventsAfterFirstBegin)
    }

    func testEndWithoutBeginDoesNothing() {
        let devices = FakeAudioOutputDevices(defaultID: monitorID, builtInID: builtInID, muteStates: [builtInID: 0])
        let muter = SystemAudioOutputMuter(devices: devices)

        muter.endMutedSession()

        XCTAssertEqual(devices.events, [])
    }

    func testSessionCanBeRepeatedAfterEnd() {
        let devices = FakeAudioOutputDevices(defaultID: monitorID, builtInID: builtInID, muteStates: [builtInID: 0])
        let muter = SystemAudioOutputMuter(devices: devices)

        muter.beginMutedSession()
        muter.endMutedSession()
        muter.beginMutedSession()

        XCTAssertEqual(devices.defaultID, builtInID)
        XCTAssertEqual(devices.muteStates[builtInID], 1)

        muter.endMutedSession()

        XCTAssertEqual(devices.defaultID, monitorID)
        XCTAssertEqual(devices.muteStates[builtInID], 0)
    }
}

private final class FakeAudioOutputDevices: AudioOutputDeviceAccessing {
    var defaultID: AudioDeviceID?
    let builtInID: AudioDeviceID?
    var muteStates: [AudioDeviceID: UInt32]
    var setDefaultSucceeds = true
    private(set) var setDefaultCalls: [AudioDeviceID] = []
    var events: [String] = []

    init(defaultID: AudioDeviceID?, builtInID: AudioDeviceID?, muteStates: [AudioDeviceID: UInt32]) {
        self.defaultID = defaultID
        self.builtInID = builtInID
        self.muteStates = muteStates
    }

    func defaultOutputDeviceID() -> AudioDeviceID? { defaultID }

    func setDefaultOutputDeviceID(_ deviceID: AudioDeviceID) -> Bool {
        setDefaultCalls.append(deviceID)
        guard setDefaultSucceeds else { return false }
        events.append("setDefault \(deviceID)")
        defaultID = deviceID
        return true
    }

    func builtInOutputDeviceID() -> AudioDeviceID? { builtInID }

    func currentMuteState(for deviceID: AudioDeviceID) -> UInt32? { muteStates[deviceID] }

    func setMute(_ isMuted: Bool, for deviceID: AudioDeviceID) -> Bool {
        guard muteStates[deviceID] != nil else { return false }
        events.append("mute \(deviceID)=\(isMuted ? 1 : 0)")
        muteStates[deviceID] = isMuted ? 1 : 0
        return true
    }
}
