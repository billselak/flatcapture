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
import QuartzCore

struct ProcessedCapture {
    let original: UIImage
    let corrected: UIImage
    let didApplyCorrection: Bool
    let usedFallback: Bool
}

actor CaptureProcessing {
    static let shared = CaptureProcessing()

    private let ciContext = CIContext(options: nil)

    nonisolated private func bestRectangle(from results: [VNObservation]?) -> VNRectangleObservation? {
        guard let rects = results as? [VNRectangleObservation] else { return nil }
        func area(_ r: VNRectangleObservation) -> CGFloat {
            let w = r.boundingBox.width
            let h = r.boundingBox.height
            return w * h
        }
        return rects.max { area($0) < area($1) }
    }

    func correctPerspective(for image: UIImage) async -> UIImage {
        guard let cgImage = image.cgImage else {
            print("Vision rectangle detection skipped: original image missing CGImage backing.")
            return image
        }

        let exifOrientation = CGImagePropertyOrientation(image.imageOrientation)
        let ciImage = CIImage(cgImage: cgImage).oriented(exifOrientation)

        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 8
        request.minimumConfidence = 0.5
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.1

        let start = CACurrentMediaTime()

        do {
            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: exifOrientation,
                options: [:]
            )

            try handler.perform([request])
            let elapsedMs = (CACurrentMediaTime() - start) * 1000.0

            let observations = request.results
            guard let observation = bestRectangle(from: observations) else {
                print(String(format: "Vision rectangle detection returned no candidates (%.2f ms).", elapsedMs))
                return image
            }

            let extent = ciImage.extent
            let filter = CIFilter.perspectiveCorrection()
            filter.inputImage = ciImage
            filter.topLeft = observation.topLeft.scaled(to: extent.size)
            filter.topRight = observation.topRight.scaled(to: extent.size)
            filter.bottomLeft = observation.bottomLeft.scaled(to: extent.size)
            filter.bottomRight = observation.bottomRight.scaled(to: extent.size)

            guard let outputImage = filter.outputImage else {
                print(String(format: "Perspective correction produced no output (confidence: %.2f, %.2f ms).", observation.confidence, elapsedMs))
                return image
            }

            let outputExtent = outputImage.extent
            guard let correctedCGImage = ciContext.createCGImage(outputImage, from: outputExtent) else {
                print(String(format: "CIContext render failed (confidence: %.2f, %.2f ms).", observation.confidence, elapsedMs))
                return image
            }

            print(String(format: "Rectangle detected with confidence %.2f in %.2f ms.", observation.confidence, elapsedMs))
            return UIImage(cgImage: correctedCGImage, scale: image.scale, orientation: .up)
        } catch {
            let elapsedMs = (CACurrentMediaTime() - start) * 1000.0
            print(String(format: "Vision rectangle detection error after %.2f ms: %@", elapsedMs, error.localizedDescription))
            return image
        }
    }
}

private extension CGPoint {
    func scaled(to size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
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
