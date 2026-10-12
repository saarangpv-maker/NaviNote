import CoreVideo
import Foundation
@testable import NaviNote

/// A tiny real pixel buffer so frames look like camera frames.
func makeTestFrame() -> CapturedFrame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
    return CapturedFrame(pixelBuffer: buffer!, orientation: .up)
}

func line(_ text: String, _ score: Double? = 0.95, box: CGRect = CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.1)) -> RecognizedTextLine {
    RecognizedTextLine(text: text, confidence: score.flatMap(RecognitionConfidence.init(score:)), boundingBox: box)
}

@MainActor
final class FakeCamera: CameraControlling {
    var isCameraAvailable = true
    var authorization: CameraAuthorization = .authorized
    var accessAnswer = true
    var startError: Error?
    private(set) var accessRequests = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var frames: AsyncStream<CapturedFrame>.Continuation?
    private var eventContinuation: AsyncStream<CameraEvent>.Continuation?

    var isRunning: Bool { frames != nil }

    func requestAccess() async -> Bool {
        accessRequests += 1
        authorization = accessAnswer ? .authorized : .denied
        return accessAnswer
    }

    func start() async throws -> AsyncStream<CapturedFrame> {
        if let startError { throw startError }
        startCount += 1
        let (stream, continuation) = AsyncStream.makeStream(of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(1))
        frames = continuation
        return stream
    }

    func stop() {
        stopCount += 1
        frames?.finish()
        frames = nil
    }

    func events() -> AsyncStream<CameraEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CameraEvent.self)
        eventContinuation = continuation
        return stream
    }

    var previewSource: CameraPreviewSource? { nil }

    func sendFrame() { frames?.yield(makeTestFrame()) }
    func send(_ event: CameraEvent) { eventContinuation?.yield(event) }
    /// Simulates the capture pipeline stopping by itself.
    func endStream() { frames?.finish() }
}

/// Returns scripted lines for successive frames and records concurrency.
@MainActor
final class FakeTextRecognizer: TextRecognizing {
    var script: [[RecognizedTextLine]] = []
    var failNext = false
    private(set) var calls = 0
    private(set) var maxConcurrent = 0
    private var inFlight = 0

    func recognizeText(in frame: CapturedFrame) async throws -> [RecognizedTextLine] {
        calls += 1
        inFlight += 1
        maxConcurrent = max(maxConcurrent, inFlight)
        defer { inFlight -= 1 }
        await Task.yield()
        if failNext {
            failNext = false
            throw FakeError.failed
        }
        return script.isEmpty ? [] : script.removeFirst()
    }
}

/// "TOTAL 12.50 USD"-style lines → AmountReading, with the line's confidence.
struct FakeTotalParser: ScanReadingParser {
    func parse(_ lines: [RecognizedTextLine]) -> ParsedReading<AmountReading>? {
        for line in lines where line.text.hasPrefix("TOTAL ") {
            let parts = line.text.split(separator: " ")
            guard parts.count == 3, let minor = Int(parts[1]) else { continue }
            return ParsedReading(value: AmountReading(minorUnits: minor, currency: Currency(code: String(parts[2]))), confidence: line.confidence)
        }
        return nil
    }
}

/// "NOTE 20 USD" → BanknoteReading. Ignores currency hints.
struct FakeNoteParser: BanknoteParsing {
    func observe(_ lines: [RecognizedTextLine], currencyHint: CurrencyHint?) -> ScanObservation<BanknoteReading> {
        observe(lines)
    }

    func currencyEvidence(_ lines: [RecognizedTextLine]) -> [Currency: RecognitionConfidence?] { [:] }

    func showsValue(_ lines: [RecognizedTextLine], for currency: Currency) -> Bool { parse(lines) != nil }

    func parse(_ lines: [RecognizedTextLine]) -> ParsedReading<BanknoteReading>? {
        for line in lines where line.text.hasPrefix("NOTE ") {
            let parts = line.text.split(separator: " ")
            guard parts.count == 3, let value = Int(parts[1]), let currency = Currency(code: String(parts[2])) else { continue }
            return ParsedReading(value: BanknoteReading(currency: currency, majorValue: value), confidence: line.confidence)
        }
        return nil
    }
}

@MainActor
struct ScanHarness {
    let camera = FakeCamera()
    let recognizer = FakeTextRecognizer()
    let scanner: ScanCoordinator
    let sink = EventSink()

    init(parsers: ScanParsers = ScanParsers(total: FakeTotalParser(), banknote: FakeNoteParser()), timing: ScanTiming = .testing) {
        scanner = ScanCoordinator(camera: camera, recognizer: recognizer, parsers: parsers, timing: timing)
        let sink = self.sink
        scanner.onEvent = { sink.events.append($0) }
        scanner.onGuidance = { sink.guidance.append($0) }
    }

    func request(_ kind: ScanKind = .total, id: Int = 1) -> PendingRequest {
        PendingRequest(id: RequestID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!), kind: kind)
    }

    /// Starts a scan and waits until the camera is delivering frames.
    func startScanning(_ request: PendingRequest, generation: SessionGeneration = .initial) async {
        scanner.start(request, generation: generation)
        await eventually { camera.isRunning }
    }

    /// Feeds frames one at a time, letting each be processed.
    func feedFrames(_ count: Int) async {
        for _ in 0..<count {
            camera.sendFrame()
            let before = recognizer.calls
            await eventually { recognizer.calls > before || !camera.isRunning }
            await drainMainActor(10)
        }
    }
}

@MainActor
final class EventSink {
    var events: [ServiceEvent] = []
    var guidance: [String] = []
}

extension ScanTiming {
    static let testing = ScanTiming(scanTimeout: .seconds(60), guidanceInterval: .zero)
}
