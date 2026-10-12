// Trains and tests the on-device banknote classifier with Apple's Create ML
// (hybrid recognition, approved 2026-10-09). Runs on this Mac:
//
//   swift scripts/train-banknote-classifier.swift
//
// Photos: TestData/BanknotePhotos/<label>/… (git-ignored). Labels are the
// top-level folders: AED-5 … AED-1000 and not-a-note. Every photo goes to a
// fixed 70% train / 30% test split by a hash of its path, so a photo is
// never in both. The held-back test photos are run through Vision, as on the
// iPhone, to measure accuracy and to choose a threshold from the results.
// Output: TestData/models/BanknoteClassifier.mlmodel and a report.
import CoreML
import CreateML
import CryptoKit
import Foundation
import Vision

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let photos = root.appendingPathComponent("TestData/BanknotePhotos")
let outDir = root.appendingPathComponent("TestData/models")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

struct Photo { let url: URL; let label: String; let valueCovered: Bool; let isTest: Bool }

func isImage(_ url: URL) -> Bool { ["jpg", "jpeg", "heic", "png"].contains(url.pathExtension.lowercased()) }

/// Stable split: the first byte of SHA-256(relative path) decides.
func isTest(_ relative: String) -> Bool {
    let byte = SHA256.hash(data: Data(relative.utf8)).first(where: { _ in true }) ?? 0
    return Int(byte) % 10 < 3
}

var all: [Photo] = []
let labels = try FileManager.default.contentsOfDirectory(atPath: photos.path).filter { !$0.hasPrefix(".") }.sorted()
for label in labels {
    let dir = photos.appendingPathComponent(label)
    guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
    for case let url as URL in walker where isImage(url) && !url.path.contains("/.cache/") {
        let relative = String(url.path.dropFirst(photos.path.count + 1))
        all.append(Photo(url: url, label: label, valueCovered: relative.contains("/value-covered/"), isTest: isTest(relative)))
    }
}
let train = all.filter { !$0.isTest }, test = all.filter(\.isTest)
print("Photos: \(all.count) (train \(train.count), test \(test.count)) across \(Set(all.map(\.label)).count) labels")
for label in labels {
    print("  \(label): train \(train.filter { $0.label == label }.count), test \(test.filter { $0.label == label }.count)")
}
guard Set(train.map(\.label)).count >= 2, !test.isEmpty else {
    print("Not enough photos yet. Add labelled photos under TestData/BanknotePhotos/<label>/."); exit(1)
}

// Train: transfer learning on Apple's scene feature print, with
// augmentation for lighting, angle, blur and crop.
var byLabel: [String: [URL]] = [:]
for photo in train { byLabel[photo.label, default: []].append(photo.url) }
let parameters = MLImageClassifier.ModelParameters(
    validation: .none,
    maxIterations: 40,
    augmentation: [.crop, .rotation, .exposure, .blur, .noise]
)
let started = Date()
let classifier = try MLImageClassifier(trainingData: .filesByLabel(byLabel), parameters: parameters)
print(String(format: "Trained in %.0f s. Training accuracy: %.1f%%", Date().timeIntervalSince(started),
             (1 - classifier.trainingMetrics.classificationError) * 100))

let modelURL = outDir.appendingPathComponent("BanknoteClassifier.mlmodel")
try classifier.write(to: modelURL, metadata: MLModelMetadata(
    author: "NaviNote", shortDescription: "UAE dirham banknote classifier (AED-5…AED-1000, not-a-note)", version: "1"))

// Test the way the iPhone runs it: compiled model through Vision.
let compiled = try MLModel.compileModel(at: modelURL)
let vnModel = try VNCoreMLModel(for: MLModel(contentsOf: compiled))
struct Prediction { let photo: Photo; let label: String; let confidence: Float }
var predictions: [Prediction] = []
for photo in test {
    let request = VNCoreMLRequest(model: vnModel)
    request.imageCropAndScaleOption = .centerCrop
    try VNImageRequestHandler(url: photo.url).perform([request])
    let top = (request.results as? [VNClassificationObservation])?.first
    predictions.append(Prediction(photo: photo, label: top?.identifier ?? "?", confidence: top?.confidence ?? 0))
}

func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "—" : String(format: "%.0f%%", 100 * Double(n) / Double(d)) }
var report = "# Banknote classifier test report\n\nHeld-back test photos: \(test.count). Model output is not a calibrated probability; the threshold below is chosen from these results.\n\n"
let correct = predictions.filter { $0.label == $0.photo.label }
report += "Top-1 accuracy (no threshold): \(pct(correct.count, predictions.count))\n\n"
report += "| Threshold | Answered | Correct of all | **Wrong answers** | Covered: answered | Covered: wrong |\n|---|---|---|---|---|---|\n"
for threshold: Float in [0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95, 0.98] {
    // A "not-a-note" answer is never announced as a note.
    let answered = predictions.filter { $0.confidence >= threshold && $0.label != "not-a-note" }
    let wrong = answered.filter { $0.label != $0.photo.label }
    let covered = predictions.filter(\.photo.valueCovered)
    let coveredAnswered = covered.filter { $0.confidence >= threshold && $0.label != "not-a-note" }
    let coveredWrong = coveredAnswered.filter { $0.label != $0.photo.label }
    report += "| \(threshold) | \(pct(answered.count, predictions.filter { $0.photo.label != "not-a-note" }.count)) | \(pct(answered.count - wrong.count, predictions.count)) | \(wrong.count) | \(pct(coveredAnswered.count, covered.count)) | \(coveredWrong.count) |\n"
}
report += "\n## Confusions\n\n"
for prediction in predictions where prediction.label != prediction.photo.label {
    report += String(format: "- %@ → %@ (%.2f)%@\n", prediction.photo.label, prediction.label, prediction.confidence,
                     prediction.photo.valueCovered ? ", value covered" : "")
}
let reportURL = outDir.appendingPathComponent("report.md")
try report.write(to: reportURL, atomically: true, encoding: .utf8)
print(report)
print("Model: \(modelURL.path)\nReport: \(reportURL.path)")
