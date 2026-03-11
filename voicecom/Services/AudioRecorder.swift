import AVFoundation
import Accelerate

private final class RecorderDelegate: NSObject, AVAudioRecorderDelegate {
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("[voicecom] Recording encode error: \(error?.localizedDescription ?? "unknown")")
    }
}

final class AudioRecorder: @unchecked Sendable {
    private var audioRecorder: AVAudioRecorder?
    private var tempFileURL: URL?
    private let delegate = RecorderDelegate()

    func startRecording() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("voicecom_recording_\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.delegate = delegate
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw AudioRecorderError.recordingFailed
        }

        self.audioRecorder = recorder
        self.tempFileURL = fileURL
    }

    func stopRecording() -> [Float] {
        guard let recorder = audioRecorder, let fileURL = tempFileURL else { return [] }

        let duration = recorder.currentTime
        recorder.stop()
        audioRecorder = nil
        tempFileURL = nil

        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        guard let audioFile = try? AVAudioFile(forReading: fileURL) else {
            print("[voicecom] Failed to read recorded file")
            return []
        }

        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0 else {
            print("[voicecom] Recorded file is empty")
            return []
        }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: frameCount
        ) else {
            print("[voicecom] Failed to create PCM buffer")
            return []
        }

        do {
            try audioFile.read(into: pcmBuffer)
        } catch {
            print("[voicecom] Failed to read audio data: \(error)")
            return []
        }

        let sampleRate = audioFile.processingFormat.sampleRate
        print("[voicecom] Captured \(String(format: "%.1f", duration))s of audio (\(pcmBuffer.frameLength) frames)")

        // Convert to Float array
        let samples: [Float]
        if let floatData = pcmBuffer.floatChannelData {
            samples = Array(UnsafeBufferPointer(start: floatData[0], count: Int(pcmBuffer.frameLength)))
        } else if let int16Data = pcmBuffer.int16ChannelData {
            let count = Int(pcmBuffer.frameLength)
            let raw = UnsafeBufferPointer(start: int16Data[0], count: count)
            samples = raw.map { Float($0) / Float(Int16.max) }
        } else {
            print("[voicecom] Unsupported audio format in file")
            return []
        }

        // Resample to 16kHz if needed
        if abs(sampleRate - 16000) < 1 {
            return samples
        }
        return resampleWithVDSP(samples, from: sampleRate, to: 16000)
    }

    private func resampleWithVDSP(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        let ratio = srcRate / dstRate
        let outputCount = Int(Double(input.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        var control = (0..<outputCount).map { Float(Double($0) * ratio) }
        var inputCopy = input
        vDSP_vlint(&inputCopy, &control, 1, &output, 1, vDSP_Length(outputCount), vDSP_Length(input.count))

        return output
    }
}

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device available"
        case .recordingFailed:
            return "Failed to start recording"
        }
    }
}
