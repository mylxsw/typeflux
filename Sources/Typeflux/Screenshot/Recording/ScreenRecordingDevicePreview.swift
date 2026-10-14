import AppKit
import AVFoundation
import SwiftUI

protocol ScreenRecordingDevicePreviewing: AnyObject {
    var session: AVCaptureSession { get }
    var level: Float { get }
    func authorizationStatus(for type: AVMediaType) -> AVAuthorizationStatus
    func configure(camera: Bool, microphone: Bool) async
    func stop() async
}

/// Owns setup-only device inputs. Configuration and shutdown use the same serial queue.
final class ScreenRecordingDevicePreview: NSObject, ScreenRecordingDevicePreviewing,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let meter = ScreenRecordingAudioMeter()
    var level: Float {
        meter.level
    }

    private let queue = DispatchQueue(label: "Typeflux.Recording.preview", qos: .userInitiated)
    private var configuration = [Bool]()
    private let samples = DispatchQueue(label: "Typeflux.Recording.preview.samples", qos: .userInitiated)
    private let input: (AVMediaType) -> AVCaptureDeviceInput?
    private let authorization: (AVMediaType) -> AVAuthorizationStatus
    init(input: @escaping (AVMediaType) -> AVCaptureDeviceInput? = ScreenRecordingDevicePreview.makeInput,
         authorization: @escaping (AVMediaType) -> AVAuthorizationStatus = AVCaptureDevice.authorizationStatus) {
        self.input = input; self.authorization = authorization
        super.init()
    }

    private static func makeInput(_ type: AVMediaType) -> AVCaptureDeviceInput? {
        guard let device = AVCaptureDevice.default(for: type) else { return nil }
        return try? AVCaptureDeviceInput(device: device)
    }

    func authorizationStatus(for type: AVMediaType) -> AVAuthorizationStatus {
        authorization(type)
    }

    func configure(camera: Bool, microphone: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                configureOnQueue(camera: camera, microphone: microphone)
                continuation.resume()
            }
        }
    }

    private func configureOnQueue(camera: Bool, microphone: Bool) {
        guard configuration != [camera, microphone] else { return }
        configuration = [camera, microphone]
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        for (type, enabled) in [(AVMediaType.video, camera), (AVMediaType.audio, microphone)] where enabled {
            guard authorizationStatus(for: type) == .authorized,
                  let input = input(type), session.canAddInput(input) else { continue }
            session.addInput(input)
            if type == .audio {
                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: samples)
                if session.canAddOutput(output) {
                    session.addOutput(output)
                }
            }
        }
        if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }
        session.commitConfiguration()
        if !session.inputs.isEmpty {
            session.startRunning()
        }
    }

    func stop() async {
        await configure(camera: false, microphone: false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            samples.async { continuation.resume() }
        }
    }

    func captureOutput(_: AVCaptureOutput, didOutput sample: CMSampleBuffer, from _: AVCaptureConnection) {
        meter.update(sample)
    }
}

struct ScreenRecordingMeterView: View {
    var level: Float
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0 ..< 4) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > Float(index) / 4 ? StudioTheme.success : StudioTheme.textTertiary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }.frame(height: 14).accessibilityLabel(L("recording.microphoneLevel"))
    }
}
