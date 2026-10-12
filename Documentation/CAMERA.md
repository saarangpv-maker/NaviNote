# NaviNote Camera and On-Device Text Recognition (Phase 5)

## Pipeline

```
Scan pressed ─► NaviNoteStateMachine (.startScan → PendingRequest)
            ─► NaviNoteStore effect ─► ScanCoordinator.start(request, generation)
                 1. camera present?            no  → .failed(.cameraUnavailable)
                 2. camera permission          denied/restricted → .permissionDenied(.camera)
                 3. SystemCamera.start()       (session queue; newest frame only)
                 4. for each frame, one at a time:
                      VisionTextRecognizer     (on-device, off main thread)
                      AimingGuidance           → spoken/shown hint (rate-limited)
                      ScanReadingParser        (Phase 6/7; none yet)
                      StabilityTracker         (≥3 agreeing observations)
                 5. exactly one ServiceEvent   tagged with requestID + generation
                    (candidate | .noResult after 20 s | .failed | .permissionDenied)
                 6. camera stops
            ─► state machine checks request + generation again, gates the
               candidate, and still requires confirmation.
```

Separate pieces, as the brief asks:

| Concern | Where |
|---|---|
| Capture | `SystemCamera` / `CaptureController` (AVCaptureSession on a serial session queue) |
| Frame selection | `AsyncStream` with `.bufferingNewest(1)` + `alwaysDiscardsLateVideoFrames`; frames processed sequentially |
| Orientation | `AVCaptureDevice.RotationCoordinator` → `CGImagePropertyOrientation` for Vision; preview kept upright separately |
| Preprocessing | Vision's own; `.accurate`, no language correction (so digits aren't "corrected") |
| Text recognition | `VisionTextRecognizer` (`VNRecognizeTextRequest`) |
| Amount / currency parsing | `ScanReadingParser` implementations — **Phase 6 (totals) and Phase 7 (banknotes)** |
| Stability | `StabilityTracker` (pure, unit-tested) |
| Confirmation and workflow | `CandidateGate` + `NaviNoteStateMachine` (unchanged) |

## Rules

- The camera runs only while a scan is active; it stops on result, cancel,
  Stop, leaving the screen, backgrounding, interruption or error.
- One capture session. Starting a scan ends any other scan first.
- No camera → no permission prompt.
- One frame is never enough: at least 3 agreeing observations within the
  last 6 frames; each needs a recognizer confidence ≥ 0.70; the candidate
  carries the *lowest* agreeing confidence. `CandidateGate` then applies the
  normal thresholds, and totals and payment notes still need confirmation.
- Frames and recognized text are never stored, logged or uploaded. Logs
  record only counts.
- Nothing restarts on its own after an interruption or returning to the app.
- Manual alternatives: Stop scanning, Continue without camera, Back to Home.
  Manual amount and currency entry arrives with Phase 6.

## Parsers

Totals are read by `ReceiptTotalParser` (Phase 6, see TOTALS.md) and
banknotes by `BanknoteTextParser` (Phase 7, see CURRENCY.md).

## Verification status

| Area | Status |
|---|---|
| ScanCoordinator, StabilityTracker, AimingGuidance, store integration | unit-tested with fakes |
| Camera-unavailable path, scanning-screen accessibility | UI-tested (simulator has no camera) |
| SystemCamera, VisionTextRecognizer, CameraPreview, aiming hints | **physical-device-tested** (iPhone 17 Pro Max, iOS 27): camera works, hints work |

## Physical-iPhone checklist (Phase 5)

1. **Read Currency → Scan with camera**: the camera permission prompt appears
   only now, never earlier.
2. **Allow**: the live preview appears and is upright, in portrait and in
   landscape.
3. **Guidance**: point at a blank wall — "No text in view yet"; point at a
   receipt — "Text found. Hold steady."; move so text touches the edge —
   "Move the camera back a little". Hints aren't repeated constantly.
4. **Close focus**: hold a receipt or banknote about 10–15 cm away; the
   preview should stay sharp (the camera switches to macro automatically).
5. **Timeout**: after about 20 s it says it couldn't read (expected until
   Phase 6).
6. **Stop scanning** stops the camera (the green camera dot disappears).
7. **Back to Home** during a scan stops the camera.
8. **Background** during a scan, then return: the scan ended as interrupted,
   Try again works, and the camera did not restart on its own.
9. **Deny** the camera (Settings › NaviNote › Camera off): Scan shows
   Permission Needed, Open Settings works, Continue without camera returns.
10. **VoiceOver on**: the camera view reads "Camera view" with the current
    guidance; hints are read without interrupting other speech.
11. **Heat and battery**: scan for a minute; note if the phone gets hot.
12. **Stability**: 10 scan / stop cycles with no freeze or crash.
