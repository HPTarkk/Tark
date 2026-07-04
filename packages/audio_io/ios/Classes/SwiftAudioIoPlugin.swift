import AVFoundation
import Flutter

extension Data {
    init<T>(fromArray values: [T]) {
        self = values.withUnsafeBytes { Data($0) }
    }

    func toArray<T>(type _: T.Type) -> [T] where T: ExpressibleByIntegerLiteral {
        var array = [T](repeating: 0, count: count / MemoryLayout<T>.stride)
        _ = array.withUnsafeMutableBytes { copyBytes(to: $0) }
        return array
    }
}

enum _Constants {
    static let preferedSampleRate = 48000.0
    static let workspaceSamples = 100_000
    static let defaultFrameDuration = 0.003  // (3ms)
    static let defaultMaxFrameJitter = 4.0
    static let processingQueueName = "SwiftAudioIoPluginQueue"
    static let ringBufferSize = 2048
}

enum Methods: String {
    case start
    case stop
    case requestFrameDuration
    case getFrameDuration
    case requestFormat
    case getFormat
}

enum AudioIoError {
    static let permissionDeniedCode = "MICROPHONE_PERMISSION_DENIED"
    static let permissionDeniedMessage = "Microphone permission not granted. This plugin requires microphone access to function. Please request microphone permission using a package like permission_handler before calling start()."
    static let audioSessionCode = "AUDIO_SESSION_ERROR"
    static let audioSessionMessage = "Failed to configure audio session"
    static let engineStartCode = "ENGINE_START_ERROR"
    static let engineStartMessage = "Failed to start audio engine"
}

enum Channels: String {
    case inputChannelName = "com.wearemobilefirst.audio_io.inputAudio"
    case outputChannelName = "com.wearemobilefirst.audio_io.outputAudio"
    case methodChannelName = "com.wearemobilefirst.audio_io"
}

enum AudioDataTypes: String {
    case double
    case float
    case int
}

enum _AudioFormat {
    static let sampleRate = "sampleRate"
    static let dataType = "type"
    static let channels = "channels"
    static let input = "input"
    static let output = "output"
}

class DataBufferPool {
    private var pool: [Data] = []
    private let bufferSize: Int
    private let poolSize: Int
    private let queue = DispatchQueue(label: "DataBufferPool")

    init(bufferSize: Int, poolSize: Int = 8) {
        self.bufferSize = bufferSize
        self.poolSize = poolSize
        for _ in 0..<poolSize {
            pool.append(Data(count: bufferSize))
        }
    }

    func acquire() -> Data {
        return queue.sync {
            if pool.isEmpty {
                return Data(count: bufferSize)
            }
            return pool.removeLast()
        }
    }

    func release(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.pool.count < self.poolSize {
                self.pool.append(data)
            }
        }
    }
}

public class SwiftAudioIoPlugin: NSObject, FlutterPlugin {
    let engine = AVAudioEngine()
    var inputConverter = AVAudioMixerNode()
    var _binaryMessenger: FlutterBinaryMessenger?
    var _frameDuration = _Constants.defaultFrameDuration
    var _sampleRate = _Constants.preferedSampleRate
    var buffer = RingBuffer<Double>(count: 0)
    let maxFrameJitter = _Constants.defaultMaxFrameJitter
    let queue = DispatchQueue(label: _Constants.processingQueueName)
    var _isRunning = false
    var _isPipelineSetup = false
    var _resetting = false
    var bufferPool: DataBufferPool?

    private var sourceNode: AVAudioSourceNode?

    deinit {
        NotificationCenter.default.removeObserver(self)
        engine.stop()
    }

    private func createSourceNode() -> AVAudioSourceNode {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat64, sampleRate: _sampleRate, channels: 1,
            interleaved: false)!
        return AVAudioSourceNode(
            format: format,
            renderBlock: { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
                guard let self = self else { return noErr }
                let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
                self.queue.sync {
                    for buffer in ablPointer {
                        let buf: UnsafeMutableBufferPointer<Double> = UnsafeMutableBufferPointer(
                            buffer)
                        var i = 0
                        while i < frameCount {
                            buf[i] = self.buffer.read() ?? 0
                            i += 1
                        }
                    }
                }
                return noErr
            })
    }

    private lazy var sinkNode = AVAudioSinkNode { [weak self] _, frames, audioBufferList -> OSStatus in
        guard let self = self else { return noErr }
        let sampleCount = Int(frames)
        guard let ptr = audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }

        let byteCount = sampleCount * MemoryLayout<Double>.stride
        var doubleData = self.bufferPool?.acquire() ?? Data(count: byteCount)

        if doubleData.count != byteCount {
            doubleData = Data(count: byteCount)
        }

        doubleData.withUnsafeMutableBytes { doublePtr in
            let doubles = doublePtr.bindMemory(to: Double.self)
            for i in 0..<sampleCount {
                doubles[i] = Double(ptr[i])
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self._binaryMessenger?.send(
                onChannel: Channels.inputChannelName.rawValue, message: doubleData,
                binaryReply: { [weak self] _ in
                    self?.bufferPool?.release(doubleData)
                })
        }
        return noErr
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: Channels.methodChannelName.rawValue, binaryMessenger: registrar.messenger())
        let instance = SwiftAudioIoPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance._binaryMessenger = registrar.messenger()
        instance._binaryMessenger?.setMessageHandlerOnChannel(
            Channels.outputChannelName.rawValue,
            binaryMessageHandler: { [weak instance] data, _ in
                guard let data = data, let instance = instance else {
                    return
                }
                autoreleasepool {
                    instance.queue.sync {
                        let count = data.count / MemoryLayout<Double>.stride
                        data.withUnsafeBytes { rawPtr in
                            let doubles = rawPtr.bindMemory(to: Double.self)
                            for i in 0..<count {
                                if !instance.buffer.write(doubles[i]) {
                                    break
                                }
                            }
                        }
                    }
                }
            })

        NotificationCenter.default.addObserver(
            instance, selector: #selector(handleConfigChange),
            name: NSNotification.Name.AVAudioEngineConfigurationChange, object: nil)
        NotificationCenter.default.addObserver(
            instance, selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            instance, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case Methods.start.rawValue:
            start(result: result)
        case Methods.stop.rawValue:
            stop()
            result(nil)
        case Methods.requestFrameDuration.rawValue:
            if let requested = call.arguments as? Double {
                _frameDuration = requested
                if _isRunning {
                    do {
                        try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(
                            _frameDuration)
                        buffer = RingBuffer<Double>(
                            count: max(
                                _Constants.ringBufferSize,
                                Int(_frameDuration * _sampleRate * maxFrameJitter)))
                    } catch {
                    }
                }
            }
            result(nil)
        case Methods.getFrameDuration.rawValue:
            result(_frameDuration)
        case Methods.getFormat.rawValue:
            result(getFormat())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func stop() {
        engine.stop()
        _isRunning = false
        buffer.clear()
    }

    public func start(result: @escaping FlutterResult) {
        let permissionStatus = AVAudioSession.sharedInstance().recordPermission

        switch permissionStatus {
        case .denied:
            result(FlutterError(
                code: AudioIoError.permissionDeniedCode,
                message: AudioIoError.permissionDeniedMessage,
                details: nil))
            return
        case .undetermined:
            result(FlutterError(
                code: AudioIoError.permissionDeniedCode,
                message: AudioIoError.permissionDeniedMessage,
                details: nil))
            return
        case .granted:
            break
        @unknown default:
            break
        }

        do {
            try startInternal()
            result(nil)
        } catch let error as NSError {
            result(FlutterError(
                code: error.domain,
                message: error.localizedDescription,
                details: nil))
        }
    }

    private func startInternal() throws {
        buffer = RingBuffer<Double>(
            count: max(
                _Constants.ringBufferSize, Int(_frameDuration * _sampleRate * maxFrameJitter)))

        let expectedFrameSize = Int(_frameDuration * _sampleRate)
        let bufferSize = expectedFrameSize * MemoryLayout<Double>.stride
        bufferPool = DataBufferPool(bufferSize: bufferSize, poolSize: 8)

        try AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(_frameDuration)
        try AVAudioSession.sharedInstance().setPreferredSampleRate(_sampleRate)

        try setupPipelineIfNeeded()

        inputConverter.outputVolume = 1.0

        try engine.start()
        _isRunning = true
    }

    public func setupPipelineIfNeeded() throws {
        if !_isPipelineSetup {
            // Setup engine and node instances
            let input = engine.inputNode
            let output = engine.mainMixerNode
            let inputFormat = input.inputFormat(forBus: 0)
            _sampleRate = inputFormat.sampleRate
            inputConverter.outputVolume = 1.0
            // Connect nodes
            let sourceNode = createSourceNode()
            let processingformat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: _sampleRate, channels: 1,
                interleaved: false)
            engine.attach(inputConverter)
            engine.attach(sinkNode)
            engine.attach(sourceNode)
            engine.connect(input, to: inputConverter, format: inputFormat)
            engine.connect(inputConverter, to: sinkNode, format: processingformat)
            engine.connect(sourceNode, to: output, format: nil)
            self.sourceNode = sourceNode
            _isPipelineSetup = true
        }
    }

    public func detachPipeline() {
        engine.detach(inputConverter)
        engine.detach(sinkNode)
        if let sourceNode = sourceNode {
            engine.detach(sourceNode)
        }
        _isPipelineSetup = false
    }

    @objc func handleConfigChange(notification _: NSNotification) {
        resetAudio()
    }

    @objc func handleInterruption(notification: NSNotification) {
        guard let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue),
            _isRunning
        else {
            return
        }
        switch type {
        case .began:
            break
        case .ended:
            break
        default: ()
        }
    }

    @objc func handleRouteChange(notification: NSNotification) {
        guard let userInfo = notification.userInfo,
            let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else {
            return
        }
        switch reason {
        case .newDeviceAvailable:
            break
        case .oldDeviceUnavailable:
            break
        case .routeConfigurationChange:
            break
        case .categoryChange:
            break
        default: ()
        }
    }

    public func resetAudio() {
        if _isRunning && !_resetting {
            _resetting = true
            engine.stop()
            detachPipeline()
            DispatchQueue.main.async {
                try? self.startInternal()
                self._resetting = false
            }
        }
    }

    public func getFormat() -> [String: Any] {
        let inputDesc: [String: Any] = [
            _AudioFormat.dataType: AudioDataTypes.double.rawValue,
            _AudioFormat.channels: 1,
            _AudioFormat.sampleRate: _sampleRate,
        ]

        let outputDesc: [String: Any] = [
            _AudioFormat.dataType: AudioDataTypes.double.rawValue,
            _AudioFormat.channels: 1,
            _AudioFormat.sampleRate: _sampleRate,
        ]

        return [_AudioFormat.input: inputDesc, _AudioFormat.output: outputDesc]
    }
}

public struct RingBuffer<T> {
    fileprivate var array: [T?]
    fileprivate var readIndex = 0
    fileprivate var writeIndex = 0

    public init(count: Int) {
        array = [T?](repeating: nil, count: count)
    }

    public mutating func write(_ element: T) -> Bool {
        if !isFull {
            array[writeIndex % array.count] = element
            writeIndex = (writeIndex + 1) % (array.count * 2)
            return true
        } else {
            return false
        }
    }

    public mutating func writeBlock(_ block: [T?]) -> Bool {
        let count = block.count
        guard availableSpaceForWriting >= count else {
            return false
        }

        let writeStartIndex = writeIndex % array.count

        if writeStartIndex + count <= array.count {
            array.replaceSubrange(writeStartIndex..<writeStartIndex + count, with: block)
        } else {
            let firstPartCount = array.count - writeStartIndex
            array.replaceSubrange(
                writeStartIndex..<writeStartIndex + firstPartCount, with: block[..<firstPartCount])
            array.replaceSubrange(0..<count - firstPartCount, with: block[firstPartCount...])
        }

        writeIndex = (writeIndex + count) % (array.count * 2)
        return true
    }

    public mutating func read() -> T? {
        if !isEmpty {
            let element = array[readIndex % array.count]
            readIndex = (readIndex + 1) % (array.count * 2)
            return element
        } else {
            return nil
        }
    }

    public mutating func readBlock(count: Int) -> [T?]? {
        if availableSpaceForReading >= count {
            var result = [T?](repeating: nil, count: count)
            for i in 0..<count {
                result[i] = array[(readIndex + i) % array.count]
            }
            readIndex = (readIndex + count) % (array.count * 2)
            return result
        }
        return nil
    }

    public mutating func clear() {
        readIndex = 0
        writeIndex = 0
    }

    fileprivate var availableSpaceForReading: Int {
        return writeIndex - readIndex
    }

    public var isEmpty: Bool {
        return availableSpaceForReading == 0
    }

    fileprivate var availableSpaceForWriting: Int {
        return array.count - availableSpaceForReading
    }

    public var isFull: Bool {
        return availableSpaceForWriting == 0
    }
}

extension Double {
    public static var random: Double {
        return Double(arc4random()) / 0xFFFF_FFFF
    }

    public static func random(min: Double, max: Double) -> Double {
        return Double.random * (max - min) + min
    }
}
