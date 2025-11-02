//
//  PhotoLibrarySaver.swift
//  FlatCapture
//
//  Created by Codex on 11/1/25.
//

import Foundation
import Photos
import UIKit

@MainActor
struct PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case unauthorized
        case encodingFailed
        case unknown

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "FlatCapture needs permission to save photos. Please update your settings and try again."
            case .encodingFailed:
                return "Unable to prepare the image for saving."
            case .unknown:
                return "Something went wrong while saving your photo."
            }
        }
    }

    func save(_ image: UIImage) async throws {
        try await ensureAuthorization()
        let data = try makeJPEGData(from: image)
        try await persist(data: data)
    }

    private func ensureAuthorization() async throws {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        switch currentStatus {
        case .authorized, .limited:
            return
        case .notDetermined:
            let newStatus = await requestAuthorization()
            guard newStatus == .authorized || newStatus == .limited else {
                throw SaveError.unauthorized
            }
        default:
            throw SaveError.unauthorized
        }
    }

    private func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func makeJPEGData(from image: UIImage) throws -> Data {
        guard let data = image.jpegData(compressionQuality: 0.92) else {
            throw SaveError.encodingFailed
        }
        return data
    }

    private func persist(data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: SaveError.unknown)
                }
            })
        }
    }
}
