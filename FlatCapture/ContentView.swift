//
//  ContentView.swift
//  FlatCapture
//
//  Created by Bill Selak on 11/1/25.
//

import SwiftUI
import Photos
import UIKit

struct ContentView: View {
    @State private var captureMode: CaptureMode = .live
    @State private var pendingImage: UIImage?
    @State private var processingMessage: String?
    @State private var isSaving = false
    @State private var alertState: AlertState?

    var body: some View {
        NavigationStack {
            switch captureMode {
            case .live:
                CameraView { image in
                    processCapture(image)
                }
                .toolbar(.hidden, for: .navigationBar)

            case .processing(let image):
                ProcessingView(image: image)
                    .toolbar(.hidden, for: .navigationBar)

            case .review(let capture):
                ReviewView(
                    capture: capture,
                    processingMessage: processingMessage,
                    isSaving: isSaving,
                    onRetake: handleRetake,
                    onSave: { handleSave(for: capture) }
                )
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .alert(item: $alertState) { state in
            switch state.kind {
            case .saved:
                return Alert(
                    title: Text("Photo Saved"),
                    message: Text("Your corrected photo is ready for the next step."),
                    dismissButton: .default(Text("OK"), action: resetToLive)
                )
            case .error(let message):
                return Alert(
                    title: Text("Save Failed"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func processCapture(_ image: UIImage) {
        pendingImage = image
        processingMessage = nil
        captureMode = .processing(image)

        guard let cgImage = image.cgImage else {
            processingMessage = "Unable to prepare the capture for correction."
            captureMode = .review(
                ProcessedCapture(
                    original: image,
                    corrected: image,
                    didApplyCorrection: false,
                    usedFallback: false
                )
            )
            pendingImage = nil
            return
        }

        let orientation = image.imageOrientation

        Task {
            do {
                let result = try await PerspectiveCorrector.correctedImageAsync(
                    from: cgImage,
                    orientation: orientation
                )
                await completeProcessing(with: result)
            } catch {
                await processingFailed()
            }
        }
    }

    private func handleRetake() {
        pendingImage = nil
        processingMessage = nil
        captureMode = .live
    }

    private func handleSave(for capture: ProcessedCapture) {
        guard !isSaving else { return }

        Task { @MainActor in
            isSaving = true
            do {
                try await PhotoLibrarySaver().save(capture.corrected)
                isSaving = false
                alertState = AlertState(kind: .saved)
            } catch {
                isSaving = false
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                alertState = AlertState(kind: .error(message))
            }
        }
    }

    private func resetToLive() {
        pendingImage = nil
        processingMessage = nil
        captureMode = .live
    }

    @MainActor
    private func completeProcessing(with result: PerspectiveCorrector.Result) {
        guard let original = pendingImage else {
            captureMode = .live
            return
        }

        let corrected = result.didApplyCorrection
            ? UIImage(cgImage: result.image, scale: original.scale, orientation: .up)
            : original

        processingMessage = nil
        captureMode = .review(
            ProcessedCapture(
                original: original,
                corrected: corrected,
                didApplyCorrection: result.didApplyCorrection,
                usedFallback: result.usedFallback
            )
        )
        pendingImage = nil
    }

    @MainActor
    private func processingFailed() {
        guard let original = pendingImage else {
            captureMode = .live
            return
        }

        processingMessage = "We couldn't correct the perspective for this capture."
        captureMode = .review(
            ProcessedCapture(
                original: original,
                corrected: original,
                didApplyCorrection: false,
                usedFallback: false
            )
        )
        pendingImage = nil
    }

    private enum CaptureMode {
        case live
        case processing(UIImage)
        case review(ProcessedCapture)
    }

    private struct AlertState: Identifiable {
        enum Kind {
            case saved
            case error(String)
        }

        let id = UUID()
        let kind: Kind
    }
}

private struct ProcessingView: View {
    let image: UIImage

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                Text("Analyzing perspective…")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct ReviewView: View {
    let capture: ProcessedCapture
    let processingMessage: String?
    let isSaving: Bool
    let onRetake: () -> Void
    let onSave: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            HStack(spacing: 1) {
                CapturePane(image: capture.original, title: "Original")
                CapturePane(image: capture.corrected, title: "Corrected")
                    .overlay {
                        if let overlay = correctedOverlay {
                            NonDestructiveOverlay(title: overlay.title, message: overlay.message)
                        }
                    }
            }
            .ignoresSafeArea()

            if let processingMessage {
                Text(processingMessage)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 24)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            if isSaving {
                SavingOverlay()
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                HStack(spacing: 24) {
                    Button(role: .cancel, action: onRetake) {
                        Text("Retake")
                            .fontWeight(.medium)
                    }
                    .disabled(isSaving)

                    Button(action: onSave) {
                        if isSaving {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private extension ReviewView {
    var correctedOverlay: (title: String, message: String?)? {
        if capture.usedFallback {
            return (
                title: "Adaptive crop preview",
                message: "Centered crop and subtle flatten applied automatically."
            )
        }

        if !capture.didApplyCorrection {
            return (
                title: "Perspective assist unavailable",
                message: "Original capture shown without adjustments."
            )
        }

        return nil
    }
}

private struct CapturePane: View {
    let image: UIImage
    let title: String

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                Text(title.uppercased())
                    .font(.caption)
                    .fontWeight(.semibold)
                    .tracking(1.1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SavingOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
            Text("Saving to Photos…")
                .font(.headline)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct NonDestructiveOverlay: View {
    let title: String
    let message: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)

                if let message {
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

#Preview {
    ContentView()
}
