//
//  CameraView.swift
//  FlatCapture
//
//  Created by Codex on 11/1/25.
//

import SwiftUI
import AVFoundation
import UIKit
import Combine

struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel()
    let onCapture: (UIImage) -> Void
    @State private var isCapturing = false
    @State private var captureErrorMessage: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: viewModel.session)
                .ignoresSafeArea()
                .task {
                    await viewModel.configureIfNeeded()
                }
                .overlay(alignment: .top) {
                    if let message = viewModel.accessMessage {
                        Text(message)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(.black.opacity(0.6))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding()
                    }
                }

            VStack(spacing: 12) {
                if let captureErrorMessage {
                    Text(captureErrorMessage)
                        .font(.callout)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.6))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }

                Button(action: capturePhoto) {
                    ZStack {
                        Circle()
                            .strokeBorder(.white.opacity(isCapturing ? 0.4 : 1), lineWidth: 4)
                            .frame(width: 80, height: 80)
                        Circle()
                            .fill(isCapturing ? .white.opacity(0.4) : .white)
                            .frame(width: 64, height: 64)
                    }
                    .padding(.bottom, 32)
                }
                .disabled(isCapturing || viewModel.accessMessage != nil)
            }
        }
        .onDisappear {
            viewModel.stopSession()
        }
        .animation(.default, value: captureErrorMessage)
    }

    private func capturePhoto() {
        guard !isCapturing else { return }

        isCapturing = true
        captureErrorMessage = nil

        Task {
            let image = await viewModel.capturePhoto()

            await MainActor.run {
                isCapturing = false

                if let image {
                    onCapture(image)
                } else {
                    captureErrorMessage = "Unable to capture photo."
                }
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.videoPreviewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            guard let layer = layer as? AVCaptureVideoPreviewLayer else {
                fatalError("Unexpected layer type for camera preview.")
            }
            return layer
        }
    }
}

@MainActor
final class CameraViewModel: NSObject, ObservableObject {
    @Published var accessMessage: String?

    let session: AVCaptureSession
    private let controller: CameraSessionController

    override init() {
        let session = AVCaptureSession()
        session.sessionPreset = .photo
        self.session = session
        self.controller = CameraSessionController(session: session)
        super.init()
        updateAccessMessage(for: AVCaptureDevice.authorizationStatus(for: .video))
    }

    func configureIfNeeded() async {
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

        if authorizationStatus == .notDetermined {
            accessMessage = "Requesting camera access…"
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            updateAccessMessage(for: granted ? .authorized : .denied)
        } else {
            updateAccessMessage(for: authorizationStatus)
        }

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }

        if let message = await controller.configureSession() {
            accessMessage = message
        } else {
            accessMessage = nil
        }
    }

    func capturePhoto() async -> UIImage? {
        guard accessMessage == nil else { return nil }
        return await controller.capturePhoto()
    }

    func stopSession() {
        Task {
            await controller.stopSession()
        }
    }

    private func updateAccessMessage(for status: AVAuthorizationStatus) {
        switch status {
        case .authorized:
            accessMessage = nil
        case .notDetermined:
            accessMessage = "Requesting camera access…"
        case .denied, .restricted:
            accessMessage = "Camera access is denied. Update your privacy settings to use the camera."
        @unknown default:
            accessMessage = "Unexpected camera authorization state."
        }
    }
}

private actor CameraSessionController {
    let session: AVCaptureSession
    private let photoOutput = AVCapturePhotoOutput()
    private var isSessionConfigured = false
    private var activeDelegate: PhotoCaptureDelegate?

    init(session: AVCaptureSession) {
        self.session = session
    }

    func configureSession() -> String? {
        if isSessionConfigured {
            if !session.isRunning {
                session.startRunning()
            }
            return nil
        }

        session.beginConfiguration()
        var shouldStartSession = false
        defer {
            session.commitConfiguration()
            if shouldStartSession && !session.isRunning {
                session.startRunning()
            }
        }

        for input in session.inputs {
            session.removeInput(input)
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return "Unable to access the back camera."
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                return "Camera input is unavailable."
            }
            session.addInput(input)
        } catch {
            return "Failed to configure camera input: \(error.localizedDescription)"
        }

        guard session.canAddOutput(photoOutput) else {
            return "Camera output is unavailable."
        }

        session.addOutput(photoOutput)

        isSessionConfigured = true
        shouldStartSession = true
        return nil
    }

    func capturePhoto() async -> UIImage? {
        guard isSessionConfigured else { return nil }
        guard activeDelegate == nil else { return nil }

        return await withCheckedContinuation { continuation in
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off

            if #available(iOS 17.0, *) {
                let preferred: AVCapturePhotoOutput.QualityPrioritization = .quality
                let supported = photoOutput.maxPhotoQualityPrioritization
                let clampedRawValue = min(preferred.rawValue, supported.rawValue)
                let clamped = AVCapturePhotoOutput.QualityPrioritization(rawValue: clampedRawValue) ?? preferred
                settings.photoQualityPrioritization = clamped
            }

            let delegate = PhotoCaptureDelegate(
                onCompletion: { image in
                    continuation.resume(returning: image)
                },
                onFinish: {
                    Task { await self.clearActiveDelegate() }
                }
            )

            activeDelegate = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func stopSession() {
        guard isSessionConfigured else { return }
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func clearActiveDelegate() {
        activeDelegate = nil
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let onCompletion: @Sendable (UIImage?) -> Void
    private let onFinish: @Sendable () -> Void
    private var didComplete = false

    init(
        onCompletion: @escaping @Sendable (UIImage?) -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.onCompletion = onCompletion
        self.onFinish = onFinish
        super.init()
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            print("Failed to process photo: \(error.localizedDescription)")
            complete(with: nil)
            return
        }

        let data = photo.fileDataRepresentation()
        let image = data.flatMap(UIImage.init(data:))
        complete(with: image)
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error, !didComplete {
            print("Capture finished with error: \(error.localizedDescription)")
            complete(with: nil)
        }
        onFinish()
    }

    private func complete(with image: UIImage?) {
        guard !didComplete else { return }
        didComplete = true
        onCompletion(image)
    }
}
