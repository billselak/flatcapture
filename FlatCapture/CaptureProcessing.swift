//
//  CaptureProcessing.swift
//  FlatCapture
//
//  Created by Codex on 11/1/25.
//

import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

struct ProcessedCapture {
    let original: UIImage
    let corrected: UIImage
    let didApplyCorrection: Bool
    let usedFallback: Bool
}

enum PerspectiveCorrector {
    private static let ciContext = CIContext(options: nil)

    struct Result {
        let image: CGImage
        let didApplyCorrection: Bool
        let usedFallback: Bool
    }

    enum Error: Swift.Error {
        case renderFailure
    }

    static func correctedImage(
        from sourceImage: CGImage,
        orientation: UIImage.Orientation
    ) throws -> Result {
        let exifOrientation = CGImagePropertyOrientation(orientation)
        let ciImage = CIImage(cgImage: sourceImage).oriented(exifOrientation)

        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.3
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.1

        let handler = VNImageRequestHandler(
            cgImage: sourceImage,
            orientation: exifOrientation,
            options: [:]
        )

        try handler.perform([request])

        if let observation = request.results?.first {
            let extent = ciImage.extent

            let topLeft = observation.topLeft.scaled(to: extent.size)
            let topRight = observation.topRight.scaled(to: extent.size)
            let bottomLeft = observation.bottomLeft.scaled(to: extent.size)
            let bottomRight = observation.bottomRight.scaled(to: extent.size)

            let filter = CIFilter.perspectiveCorrection()
            filter.inputImage = ciImage
            filter.topLeft = topLeft
            filter.topRight = topRight
            filter.bottomLeft = bottomLeft
            filter.bottomRight = bottomRight

            guard
                let outputImage = filter.outputImage,
                let correctedCGImage = ciContext.createCGImage(outputImage, from: outputImage.extent)
            else {
                throw Error.renderFailure
            }

            return Result(image: correctedCGImage, didApplyCorrection: true, usedFallback: false)
        }

        if let fallbackImage = fallbackCorrectedImage(from: ciImage, orientation: orientation) {
            return Result(image: fallbackImage, didApplyCorrection: true, usedFallback: true)
        }

        return Result(image: sourceImage, didApplyCorrection: false, usedFallback: false)
    }

    static func correctedImageAsync(
        from sourceImage: CGImage,
        orientation: UIImage.Orientation
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try correctedImage(from: sourceImage, orientation: orientation)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private extension CGPoint {
    func scaled(to size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}

private extension PerspectiveCorrector {
    static func fallbackCorrectedImage(from image: CIImage, orientation: UIImage.Orientation) -> CGImage? {
        let extent = image.extent

        guard extent.width > 0, extent.height > 0 else {
            return nil
        }

        let insetX = extent.width * 0.05
        let insetY = extent.height * 0.05
        let cropRect = extent.insetBy(dx: insetX, dy: insetY)

        guard cropRect.width > 0, cropRect.height > 0 else {
            return nil
        }

        var cropped = image.cropped(to: cropRect)
        let translation = CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y)
        cropped = cropped.transformed(by: translation)

        let size = CGSize(width: cropRect.width, height: cropRect.height)
        let points = fallbackControlPoints(for: size, orientation: orientation)

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = cropped
        filter.topLeft = points.topLeft
        filter.topRight = points.topRight
        filter.bottomLeft = points.bottomLeft
        filter.bottomRight = points.bottomRight

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let outputRect = CGRect(origin: .zero, size: size)
        return ciContext.createCGImage(outputImage, from: outputRect)
    }

    static func fallbackControlPoints(
        for size: CGSize,
        orientation: UIImage.Orientation
    ) -> (topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint) {
        let width = size.width
        let height = size.height
        let horizontalInset = width * 0.04
        let verticalInset = height * 0.04
        let verticalShift = height * 0.02
        let horizontalShift = width * 0.02

        var topLeft = CGPoint(x: 0, y: height)
        var topRight = CGPoint(x: width, y: height)
        var bottomLeft = CGPoint(x: 0, y: 0)
        var bottomRight = CGPoint(x: width, y: 0)

        switch orientation {
        case .up, .upMirrored:
            topLeft.x += horizontalInset
            topRight.x -= horizontalInset
            topLeft.y -= verticalShift
            topRight.y -= verticalShift
        case .down, .downMirrored:
            bottomLeft.x += horizontalInset
            bottomRight.x -= horizontalInset
            bottomLeft.y += verticalShift
            bottomRight.y += verticalShift
        case .left, .leftMirrored:
            topLeft.x += horizontalShift
            bottomLeft.x += horizontalShift
            topLeft.y -= verticalInset
            bottomLeft.y += verticalInset
        case .right, .rightMirrored:
            topRight.x -= horizontalShift
            bottomRight.x -= horizontalShift
            topRight.y -= verticalInset
            bottomRight.y += verticalInset
        @unknown default:
            topLeft.x += horizontalInset
            topRight.x -= horizontalInset
            topLeft.y -= verticalShift
            topRight.y -= verticalShift
        }

        return (topLeft, topRight, bottomLeft, bottomRight)
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}
