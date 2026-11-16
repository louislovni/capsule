import AVFoundation

/// Plays what the emulator queues. The render callback pulls 16-bit stereo from the
/// bridge's ring buffer and hands it to the system as float samples.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var scratch: UnsafeMutablePointer<Int16>?
    private let scratchFrames = 4096

    func start(core: OpaquePointer) {
        guard sourceNode == nil else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)

        let rate = Double(emu_audio_rate(core))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false) else {
            return
        }

        let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: scratchFrames * 2)
        buffer.initialize(repeating: 0, count: scratchFrames * 2)
        scratch = buffer
        let capacity = scratchFrames

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let wanted = Int(frameCount)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let got = Int(emu_audio_read(core, buffer, min(wanted, capacity)))
            let scale: Float = 1.0 / 32768.0
            var index = 0
            while index < got {
                left[index] = Float(buffer[index * 2]) * scale
                right[index] = Float(buffer[index * 2 + 1]) * scale
                index += 1
            }
            while index < wanted {
                left[index] = 0
                right[index] = 0
                index += 1
            }
            return noErr
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try? engine.start()
    }

    /// Restarts playback after an interruption (call, Siri, app in background).
    func resume() {
        guard sourceNode != nil, !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }

    func pause() {
        if engine.isRunning {
            engine.pause()
        }
    }

    /// Must be called before the emulator core is destroyed: the callback reads from it.
    func stop() {
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
        }
        sourceNode = nil
        scratch?.deallocate()
        scratch = nil
    }
}
