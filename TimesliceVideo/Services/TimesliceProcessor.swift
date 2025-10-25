//
//  TimesliceProcessor.swift
//  TimesliceVideo
//
//  Created on 2025-10-24.
//

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// Progress callback for timeslice processing
typealias ProgressCallback = (Double) -> Void

/// Errors that can occur during timeslice processing
enum TimesliceProcessorError: LocalizedError {
    case invalidAsset
    case noVideoTrack
    case readerSetupFailed(String)
    case writerSetupFailed(String)
    case processingFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidAsset:
            return "The video asset is invalid."
        case .noVideoTrack:
            return "No video track found in the video."
        case .readerSetupFailed(let message):
            return "Failed to setup video reader: \(message)"
        case .writerSetupFailed(let message):
            return "Failed to setup video writer: \(message)"
        case .processingFailed(let message):
            return "Processing failed: \(message)"
        case .cancelled:
            return "Processing was cancelled."
        }
    }
}

/// Service responsible for processing full timeslice video transformation
class TimesliceProcessor {

    /// Cancellation flag
    private var isCancelled = false

    /// Processes a video to create timeslice effect
    /// - Parameters:
    ///   - asset: The video asset to process
    ///   - startTime: Start time in seconds
    ///   - endTime: End time in seconds
    ///   - speedFactor: Speed multiplier
    ///   - outputURL: URL where the output video will be saved
    ///   - progressCallback: Callback for progress updates (0.0 to 1.0)
    /// - Returns: The final output URL
    func processVideo(
        asset: AVAsset,
        startTime: Double,
        endTime: Double,
        speedFactor: Double,
        outputURL: URL,
        progressCallback: @escaping ProgressCallback
    ) async throws -> URL {
        let overallStart = CFAbsoluteTimeGetCurrent()
        isCancelled = false

        print("\n=== TIMESLICE PROCESSING STARTED ===")
        print("Output: \(outputURL.path)")

        // Get video track
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw TimesliceProcessorError.noVideoTrack
        }

        // Get video properties
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)

        // Check if video is rotated
        let isPortrait = abs(transform.b) == 1.0 && abs(transform.c) == 1.0
        let width = Int(isPortrait ? naturalSize.height : naturalSize.width)
        let height = Int(isPortrait ? naturalSize.width : naturalSize.height)

        // Calculate frame parameters
        let duration = endTime - startTime
        let fps = Double(nominalFrameRate)
        let totalFrames = Int(duration * fps)
        let frameInterval = Int(speedFactor)
        let framesToSample = totalFrames / frameInterval

        print("Video properties:")
        print("  Dimensions: \(width) × \(height)")
        print("  Duration: \(String(format: "%.2f", duration))s")
        print("  Frame rate: \(fps) fps")
        print("  Total frames in range: \(totalFrames)")
        print("  Speed factor: \(speedFactor)x")
        print("  Frames to sample: \(framesToSample)")
        print("  Output dimensions: \(framesToSample) × \(height)")

        // Step 1: Read all frame columns into memory (organized by frame)
        print("\n--- Phase 1: Extracting columns from source frames ---")
        let extractStart = CFAbsoluteTimeGetCurrent()

        let frameColumns = try await extractAllFrameColumns(
            asset: asset,
            videoTrack: videoTrack,
            startTime: startTime,
            endTime: endTime,
            width: width,
            height: height,
            frameInterval: frameInterval,
            framesToSample: framesToSample,
            progressCallback: { progress in
                progressCallback(progress * 0.5) // First 50% is extraction
            }
        )

        guard !isCancelled else { throw TimesliceProcessorError.cancelled }

        let extractTime = CFAbsoluteTimeGetCurrent() - extractStart
        print("Extraction complete: \(String(format: "%.2f", extractTime))s")
        print("Extracted \(frameColumns.count) frames × \(width) columns")

        // Step 2: Write output video
        print("\n--- Phase 2: Generating output video ---")
        let writeStart = CFAbsoluteTimeGetCurrent()

        try await writeOutputVideo(
            frameColumns: frameColumns,
            outputURL: outputURL,
            width: framesToSample,
            height: height,
            frameRate: 30.0,
            progressCallback: { progress in
                progressCallback(0.5 + progress * 0.5) // Second 50% is writing
            }
        )

        guard !isCancelled else { throw TimesliceProcessorError.cancelled }

        let writeTime = CFAbsoluteTimeGetCurrent() - writeStart
        print("Writing complete: \(String(format: "%.2f", writeTime))s")

        let totalTime = CFAbsoluteTimeGetCurrent() - overallStart
        print("\n=== PROCESSING COMPLETE ===")
        print("Total time: \(String(format: "%.2f", totalTime))s")
        print("Output saved to: \(outputURL.path)\n")

        return outputURL
    }

    /// Cancels the current processing operation
    func cancel() {
        isCancelled = true
        print("Cancellation requested")
    }

    // MARK: - Private Methods

    /// Extracts all columns from all frames in the time range
    /// Returns array of frames, where each frame is an array of column data
    private func extractAllFrameColumns(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        startTime: Double,
        endTime: Double,
        width: Int,
        height: Int,
        frameInterval: Int,
        framesToSample: Int,
        progressCallback: @escaping ProgressCallback
    ) async throws -> [[Data]] {
        let timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            end: CMTime(seconds: endTime, preferredTimescale: 600)
        )

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw TimesliceProcessorError.readerSetupFailed("Could not create asset reader")
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: false
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        reader.timeRange = timeRange
        reader.add(readerOutput)

        guard reader.startReading() else {
            let error = reader.error?.localizedDescription ?? "Unknown error"
            throw TimesliceProcessorError.readerSetupFailed(error)
        }

        var frameColumns: [[Data]] = []
        var frameIndex = 0
        var sampledCount = 0

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            guard !isCancelled else {
                reader.cancelReading()
                throw TimesliceProcessorError.cancelled
            }

            // Sample frames based on speed factor
            if frameIndex % frameInterval == 0 && sampledCount < framesToSample {
                if let columns = extractAllColumnsFromFrame(sampleBuffer, width: width, height: height) {
                    frameColumns.append(columns)
                    sampledCount += 1

                    // Update progress
                    if sampledCount % 10 == 0 {
                        let progress = Double(sampledCount) / Double(framesToSample)
                        progressCallback(progress)
                    }
                }
            }

            frameIndex += 1

            if sampledCount >= framesToSample {
                break
            }
        }

        reader.cancelReading()
        return frameColumns
    }

    /// Extracts all columns from a single frame
    /// Returns array of column data (one per x-position)
    private func extractAllColumnsFromFrame(_ sampleBuffer: CMSampleBuffer, width: Int, height: Int) -> [Data]? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let bytesPerPixel = 4
        let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

        var columns: [Data] = []

        // Extract each column
        for x in 0..<width {
            var columnData = Data(count: height * bytesPerPixel)

            columnData.withUnsafeMutableBytes { columnPtr in
                guard let columnBase = columnPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }

                for y in 0..<height {
                    let srcOffset = y * bytesPerRow + x * bytesPerPixel
                    let dstOffset = y * bytesPerPixel

                    // Copy BGRA pixel
                    columnBase[dstOffset] = srcPtr[srcOffset]
                    columnBase[dstOffset + 1] = srcPtr[srcOffset + 1]
                    columnBase[dstOffset + 2] = srcPtr[srcOffset + 2]
                    columnBase[dstOffset + 3] = srcPtr[srcOffset + 3]
                }
            }

            columns.append(columnData)
        }

        return columns
    }

    /// Writes the output video from extracted frame columns
    private func writeOutputVideo(
        frameColumns: [[Data]],
        outputURL: URL,
        width: Int,
        height: Int,
        frameRate: Double,
        progressCallback: @escaping ProgressCallback
    ) async throws {
        // Remove existing file
        try? FileManager.default.removeItem(at: outputURL)

        // Setup video writer
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            throw TimesliceProcessorError.writerSetupFailed("Could not create asset writer")
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 8,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoQualityKey: 0.9
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

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
            throw TimesliceProcessorError.writerSetupFailed("Could not start writing")
        }

        writer.startSession(atSourceTime: .zero)

        let totalOutputFrames = frameColumns[0].count // Number of columns in each source frame
        var frameNumber = 0

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "videoWriter")) { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                while writerInput.isReadyForMoreMediaData && frameNumber < totalOutputFrames {
                    guard !self.isCancelled else {
                        writer.cancelWriting()
                        continuation.resume()
                        return
                    }

                    // Create output frame from column x across all source frames
                    if let pixelBuffer = self.createOutputFrame(
                        frameColumns: frameColumns,
                        columnIndex: frameNumber,
                        width: width,
                        height: height,
                        pixelBufferPool: pixelBufferAdaptor.pixelBufferPool
                    ) {
                        let presentationTime = CMTime(
                            value: Int64(frameNumber),
                            timescale: Int32(frameRate)
                        )

                        pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                        frameNumber += 1

                        // Update progress
                        if frameNumber % 10 == 0 {
                            let progress = Double(frameNumber) / Double(totalOutputFrames)
                            progressCallback(progress)
                        }
                    } else {
                        frameNumber += 1
                    }
                }

                if frameNumber >= totalOutputFrames {
                    writerInput.markAsFinished()
                    writer.finishWriting {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Creates a single output frame by assembling column x from all source frames
    private func createOutputFrame(
        frameColumns: [[Data]],
        columnIndex: Int,
        width: Int,
        height: Int,
        pixelBufferPool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool!, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytesPerPixel = 4
        let dstPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

        // Copy column from each source frame into the output frame
        for (frameIndex, columns) in frameColumns.enumerated() {
            guard frameIndex < width, columnIndex < columns.count else { continue }

            let columnData = columns[columnIndex]

            columnData.withUnsafeBytes { columnPtr in
                guard let columnBase = columnPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }

                for y in 0..<height {
                    let srcOffset = y * bytesPerPixel
                    let dstOffset = y * bytesPerRow + frameIndex * bytesPerPixel

                    // Copy BGRA pixel
                    dstPtr[dstOffset] = columnBase[srcOffset]
                    dstPtr[dstOffset + 1] = columnBase[srcOffset + 1]
                    dstPtr[dstOffset + 2] = columnBase[srcOffset + 2]
                    dstPtr[dstOffset + 3] = columnBase[srcOffset + 3]
                }
            }
        }

        return buffer
    }
}
