//
//  VideoPreprocessor.swift
//  TimesliceVideo
//
//  Created on 2025-10-25.
//

import AVFoundation
import AppKit
import CoreMedia
import CoreVideo

/// Service for preprocessing videos that are too long
class VideoPreprocessor {

    /// Maximum video duration in seconds before preprocessing is required
    static let maxDuration: Double = 300.0 // 5 minutes

    /// Speeds up a video to fit within the maximum duration by sampling frames
    /// - Parameters:
    ///   - asset: The source video asset
    ///   - originalURL: The original video URL
    ///   - progressCallback: Called periodically with progress (0.0 to 1.0)
    /// - Returns: URL of the sped-up video file
    static func preprocessLongVideo(
        asset: AVAsset,
        originalURL: URL,
        progressCallback: @escaping (Double) -> Void
    ) async throws -> URL {
        let duration = try await asset.load(.duration).seconds

        // Calculate speed factor needed to make video fit in maxDuration
        let speedFactor = duration / maxDuration

        print("Preprocessing video:")
        print("  Original duration: \(duration)s")
        print("  Target duration: \(maxDuration)s")
        print("  Speed factor: \(speedFactor)x")

        // Get video track properties
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoPreprocessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)

        // Check if video is rotated
        let isPortrait = abs(transform.b) == 1.0 && abs(transform.c) == 1.0
        let width = Int(isPortrait ? naturalSize.height : naturalSize.width)
        let height = Int(isPortrait ? naturalSize.width : naturalSize.height)

        print("  Original dimensions: \(width) × \(height)")
        print("  Original frame rate: \(nominalFrameRate) fps")

        // Calculate frame sampling
        let totalFrames = Int(duration * Double(nominalFrameRate))
        let targetFrames = Int(maxDuration * Double(nominalFrameRate))
        let frameInterval = max(1, Int(round(Double(totalFrames) / Double(targetFrames)))) // Sample every Nth frame
        let outputFrames = totalFrames / frameInterval
        let outputDuration = Double(outputFrames) / Double(nominalFrameRate)

        print("  Total frames: \(totalFrames)")
        print("  Frame interval: \(frameInterval) (sample every \(frameInterval) frames)")
        print("  Output frames: \(outputFrames)")
        print("  Output duration: \(String(format: "%.2f", outputDuration))s")

        // Create temporary output URL
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("preprocessed_\(UUID().uuidString).mp4")

        // Remove existing file if it exists
        try? FileManager.default.removeItem(at: outputURL)

        // Setup reader
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw NSError(domain: "VideoPreprocessor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create asset reader"])
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: false
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        reader.add(readerOutput)

        guard reader.startReading() else {
            let error = reader.error?.localizedDescription ?? "Unknown error"
            throw NSError(domain: "VideoPreprocessor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading: \(error)"])
        }

        // Setup writer
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            throw NSError(domain: "VideoPreprocessor", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create asset writer"])
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 8,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoQualityKey: 0.85
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = transform // Preserve original transform

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        writer.add(writerInput)

        guard writer.startWriting() else {
            throw NSError(domain: "VideoPreprocessor", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not start writing"])
        }

        writer.startSession(atSourceTime: .zero)

        print("Starting frame sampling...")

        // Process frames
        var frameIndex = 0
        var writtenFrames = 0
        let processingStart = CFAbsoluteTimeGetCurrent()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "preprocessor")

            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        // No more frames
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            continuation.resume()
                        }
                        return
                    }

                    defer { CMSampleBufferInvalidate(sampleBuffer) }

                    // Sample frames based on interval
                    if frameIndex % frameInterval == 0 {
                        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                            frameIndex += 1
                            continue
                        }

                        // Create presentation time for output video
                        let presentationTime = CMTime(
                            value: Int64(writtenFrames),
                            timescale: Int32(nominalFrameRate)
                        )

                        // Append the frame
                        pixelBufferAdaptor.append(imageBuffer, withPresentationTime: presentationTime)
                        writtenFrames += 1

                        // Update progress
                        if writtenFrames % 10 == 0 {
                            let progress = Double(writtenFrames) / Double(outputFrames)
                            Task { @MainActor in
                                progressCallback(progress)
                            }
                        }

                        // Log progress
                        if writtenFrames % 100 == 0 {
                            let elapsed = CFAbsoluteTimeGetCurrent() - processingStart
                            let fps = Double(writtenFrames) / elapsed
                            print("  Processed \(writtenFrames)/\(outputFrames) frames (\(String(format: "%.1f", fps)) fps)")
                        }
                    }

                    frameIndex += 1
                }
            }
        }

        reader.cancelReading()

        print("Preprocessing completed successfully")
        print("  Output URL: \(outputURL.path)")
        print("  Written frames: \(writtenFrames)")

        return outputURL
    }

    /// Checks if a video needs preprocessing
    /// - Parameter duration: Video duration in seconds
    /// - Returns: True if video needs preprocessing
    static func needsPreprocessing(duration: Double) -> Bool {
        return duration > maxDuration
    }
}
