import Foundation
import Testing
@testable import NaviNote

@MainActor
@Suite("Scan coordinator")
struct ScanCoordinatorTests {
    @Test func noCameraReportsUnavailableWithoutAskingPermission() async {
        let h = ScanHarness()
        h.camera.isCameraAvailable = false
        h.camera.authorization = .notDetermined
        let request = h.request()
        h.scanner.start(request, generation: .initial)
        await eventually { !h.sink.events.isEmpty }
        #expect(h.sink.events == [ServiceEvent(requestID: request.id, generation: .initial, payload: .failed(.cameraUnavailable))])
        #expect(h.camera.accessRequests == 0)
        #expect(h.camera.startCount == 0)
    }

    @Test func permissionIsAskedOnlyWhenScanning() async {
        let h = ScanHarness()
        h.camera.authorization = .notDetermined
        await drainMainActor()
        #expect(h.camera.accessRequests == 0, "Nothing is asked before a scan")
        await h.startScanning(h.request())
        #expect(h.camera.accessRequests == 1)
        #expect(h.camera.startCount == 1)
    }

    @Test(arguments: [CameraAuthorization.denied, .restricted])
    func deniedOrRestrictedPermissionIsReported(_ status: CameraAuthorization) async {
        let h = ScanHarness()
        h.camera.authorization = status
        let request = h.request()
        h.scanner.start(request, generation: .initial)
        await eventually { !h.sink.events.isEmpty }
        #expect(h.sink.events.first?.payload == .permissionDenied(.camera))
        #expect(h.camera.startCount == 0)
    }

    @Test func declinedPromptIsReported() async {
        let h = ScanHarness()
        h.camera.authorization = .notDetermined
        h.camera.accessAnswer = false
        h.scanner.start(h.request(), generation: .initial)
        await eventually { !h.sink.events.isEmpty }
        #expect(h.sink.events.first?.payload == .permissionDenied(.camera))
    }

    @Test func cameraStartFailureIsReported() async {
        let h = ScanHarness()
        h.camera.startError = FakeError.failed
        h.scanner.start(h.request(), generation: .initial)
        await eventually { !h.sink.events.isEmpty }
        #expect(h.sink.events.first?.payload == .failed(.cameraUnavailable))
        #expect(h.scanner.status == .idle)
    }

    @Test func stableReadingProducesOneTaggedCandidateAndStopsTheCamera() async {
        let h = ScanHarness()
        let request = h.request(.total, id: 7)
        let generation = SessionGeneration.initial.next()
        h.recognizer.script = Array(repeating: [line("TOTAL 1250 USD", 0.96)], count: 5)
        await h.startScanning(request, generation: generation)
        await h.feedFrames(3)
        await eventually { !h.sink.events.isEmpty }

        let expected = TotalCandidate(
            value: AmountReading(minorUnits: 12_50, currency: .usd),
            source: .camera,
            confidence: confidence(0.96),
            agreeingObservations: 3
        )
        #expect(h.sink.events == [ServiceEvent(requestID: request.id, generation: generation, payload: .totalCandidate(expected))])
        #expect(!h.camera.isRunning, "The camera stops as soon as the scan ends")
        #expect(h.scanner.status == .idle)

        // Nothing more is reported after the result.
        h.camera.sendFrame()
        await drainMainActor()
        #expect(h.sink.events.count == 1)
    }

    @Test func banknoteScansUseTheBanknoteParser() async {
        let h = ScanHarness()
        h.recognizer.script = Array(repeating: [line("NOTE 20 USD")], count: 3)
        await h.startScanning(h.request(.returnedNote))
        await h.feedFrames(3)
        await eventually { !h.sink.events.isEmpty }
        guard case .banknoteCandidate(let candidate) = h.sink.events.first?.payload else {
            Issue.record("Expected a banknote candidate")
            return
        }
        #expect(candidate.value == BanknoteReading(currency: .usd, majorValue: 20))
    }

    @Test func singleFramesNeverProduceACandidate() async {
        let h = ScanHarness()
        h.recognizer.script = [[line("TOTAL 1000 USD")], [line("TOTAL 1100 USD")], [line("TOTAL 1200 USD")], [line("TOTAL 1300 USD")]]
        await h.startScanning(h.request())
        await h.feedFrames(4)
        #expect(h.sink.events.isEmpty)
        #expect(h.camera.isRunning)
    }

    @Test func framesAreRecognizedOneAtATime() async {
        let h = ScanHarness()
        await h.startScanning(h.request())
        for _ in 0..<10 { h.camera.sendFrame() }
        await h.feedFrames(5)
        #expect(h.recognizer.maxConcurrent == 1)
    }

    @Test func aFailingFrameDoesNotEndTheScan() async {
        let h = ScanHarness()
        h.recognizer.failNext = true
        h.recognizer.script = Array(repeating: [line("TOTAL 500 USD")], count: 3)
        await h.startScanning(h.request())
        await h.feedFrames(4)
        await eventually { !h.sink.events.isEmpty }
        #expect(h.sink.events.count == 1)
    }

    @Test func withoutAParserScansGuideButNeverPropose() async {
        var timing = ScanTiming.testing
        // Long enough that a busy machine can't time the scan out while the
        // frames are still being fed (seen once under load at 150 ms).
        timing.scanTimeout = .seconds(1)
        let h = ScanHarness(parsers: .none, timing: timing)
        h.recognizer.script = Array(repeating: [line("TOTAL 500 USD")], count: 5)
        let request = h.request()
        await h.startScanning(request)
        await h.feedFrames(5)
        #expect(h.scanner.status == .scanning(.textFound))
        #expect(h.sink.events.isEmpty)
        let deadline = ContinuousClock.now + .seconds(5)
        while h.sink.events.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(h.sink.events == [ServiceEvent(requestID: request.id, generation: .initial, payload: .noResult)])
        #expect(!h.camera.isRunning)
    }

    @Test func cancelStopsTheCameraAndReportsNothing() async {
        let h = ScanHarness()
        let request = h.request()
        await h.startScanning(request)
        h.scanner.cancel(request.id)
        #expect(!h.camera.isRunning)
        #expect(h.scanner.status == .idle)
        h.camera.sendFrame()
        await drainMainActor()
        #expect(h.sink.events.isEmpty)
    }

    @Test func cancellingAnotherRequestDoesNothing() async {
        let h = ScanHarness()
        await h.startScanning(h.request(id: 1))
        h.scanner.cancel(h.request(id: 2).id)
        #expect(h.camera.isRunning)
    }

    @Test func cancelWhileAskingPermissionNeverStartsTheCamera() async {
        let h = ScanHarness()
        h.camera.authorization = .notDetermined
        h.scanner.start(h.request(), generation: .initial)
        h.scanner.cancelAll()
        await drainMainActor()
        #expect(h.camera.startCount == 0)
        #expect(h.sink.events.isEmpty)
    }

    @Test func aNewScanReplacesTheOldOneWithOneCameraSession() async {
        let h = ScanHarness()
        await h.startScanning(h.request(id: 1))
        await h.startScanning(h.request(id: 2))
        #expect(h.camera.startCount == 2)
        #expect(h.camera.stopCount == 1, "The first scan's session was stopped first")
        h.recognizer.script = Array(repeating: [line("TOTAL 500 USD")], count: 3)
        await h.feedFrames(3)
        await eventually { !h.sink.events.isEmpty }
        #expect(h.sink.events.map(\.requestID) == [h.request(id: 2).id])
    }

    @Test func cameraInterruptionEndsTheScanAsInterrupted() async {
        let h = ScanHarness()
        await h.startScanning(h.request())
        h.camera.send(.interrupted)
        await eventually { !h.sink.events.isEmpty }
        #expect(h.sink.events.first?.payload == .failed(.interrupted))
        #expect(!h.camera.isRunning)
    }

    @Test func runtimeErrorEndsTheScan() async {
        let h = ScanHarness()
        await h.startScanning(h.request())
        h.camera.send(.runtimeError)
        await eventually { !h.sink.events.isEmpty }
        #expect(h.sink.events.first?.payload == .failed(.cameraUnavailable))
    }

    @Test func frameStreamEndingUnexpectedlyIsReported() async {
        let h = ScanHarness()
        await h.startScanning(h.request())
        h.camera.endStream()
        await eventually { !h.sink.events.isEmpty }
        #expect(h.sink.events.first?.payload == .failed(.cameraUnavailable))
    }

    @Test func backgroundingEndsTheScanAsInterrupted() async {
        let h = ScanHarness()
        await h.startScanning(h.request())
        h.scanner.lifecycleChanged(to: .background)
        #expect(h.sink.events.first?.payload == .failed(.interrupted))
        #expect(!h.camera.isRunning)
        h.scanner.lifecycleChanged(to: .active)
        await drainMainActor()
        #expect(h.camera.startCount == 1, "Returning never restarts the camera by itself")
    }

    @Test func guidanceIsSpokenWhenItChanges() async {
        let h = ScanHarness(parsers: .none)
        h.recognizer.script = [[], [line("hello")], [line("hello")], [line("edge", box: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.1))]]
        await h.startScanning(h.request())
        await h.feedFrames(4)
        #expect(h.sink.guidance == [
            AimingGuidance.lookingForText.spokenText,
            AimingGuidance.textFound.spokenText,
            AimingGuidance.textAtEdge.spokenText,
        ])
    }

    @Test func guidanceIsRateLimited() async {
        var timing = ScanTiming.testing
        timing.guidanceInterval = .seconds(60)
        let h = ScanHarness(parsers: .none, timing: timing)
        h.recognizer.script = [[line("a")], [], [line("b")]]
        await h.startScanning(h.request())
        await h.feedFrames(3)
        #expect(h.sink.guidance.isEmpty, "No hint within the interval after starting")
    }
}

@MainActor
@Suite("Store and scanning")
struct StoreScanningTests {
    private func makeStore(_ scan: ScanHarness) -> NaviNoteStore {
        let audio = AudioHarness(voiceOver: true)
        return NaviNoteStore(audio: audio.coordinator, scanner: scan.scanner, haptics: SilentTestHaptics())
    }

    @Test func aStableScanBecomesAProposalThatStillNeedsConfirmation() async {
        let scan = ScanHarness()
        let store = makeStore(scan)
        store.send(.startCheckout)
        store.send(.continueCheckout)
        scan.recognizer.script = Array(repeating: [line("TOTAL 4200 AED")], count: 3)
        store.send(.startScan)
        await eventually { scan.camera.isRunning }
        await scan.feedFrames(3)
        await eventually { store.state.phase == .confirmingTotal }
        #expect(store.state.proposedTotal == ProposedAmount(minorUnits: 42_00, currency: .aed, source: .camera))
        #expect(store.state.checkout.confirmedTotal == nil)
    }

    @Test func stopScanStopsTheCamera() async {
        let scan = ScanHarness()
        let store = makeStore(scan)
        store.send(.startReadingCurrency)
        store.send(.startScan)
        await eventually { scan.camera.isRunning }
        store.send(.stopScan)
        #expect(!scan.camera.isRunning)
        #expect(!store.state.isScanning)
    }

    @Test func cancelStopsTheCamera() async {
        let scan = ScanHarness()
        let store = makeStore(scan)
        store.send(.startReadingCurrency)
        store.send(.startScan)
        await eventually { scan.camera.isRunning }
        store.send(.cancel)
        #expect(!scan.camera.isRunning)
        #expect(store.state.phase == .home)
    }

    @Test func deniedCameraLeadsToThePermissionNoticeAndBack() async {
        let scan = ScanHarness()
        scan.camera.authorization = .denied
        let store = makeStore(scan)
        store.send(.startReadingCurrency)
        store.send(.startScan)
        await eventually { store.state.phase == .permissionDenied(.camera) }
        #expect(store.state.phase == .permissionDenied(.camera))
        store.send(.dismissPermissionNotice)
        #expect(store.state.phase == .readingCurrency)
    }
}

@MainActor
final class SilentTestHaptics: HapticsPlaying {
    func play(_ event: HapticEvent) {}
}
