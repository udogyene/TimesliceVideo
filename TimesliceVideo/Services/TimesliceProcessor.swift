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

/// Thread-safe frame buffer for parallel frame assembly
private class FrameBuffer {
    private var frames: [Int: CVPixelBuffer] = [:]
    private let lock = NSLock()

    func store(_ frame: CVPixelBuffer, at index: Int) {
        lock.lock()
        frames[index] = frame
        lock.unlock()
    }

    func retrieve(at index: Int) -> CVPixelBuffer? {
        lock.lock()
        let frame = frames[index]
        frames[index] = nil // Free memory
        lock.unlock()
        return frame
    }

    func contains(index: Int) -> Bool {
        lock.lock()
        let exists = frames[index] != nil
        lock.unlock()
        return exists
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

        // Step 1: Read video ONCE (single pass through video)
        print("\n--- Phase 1: Reading video frames ---")
        let extractStart = CFAbsoluteTimeGetCurrent()

        let (flatBuffer, actualFrameCount) = try await extractAllFrames(
            asset: asset,
            videoTrack: videoTrack,
            startTime: startTime,
            endTime: endTime,
            width: width,
            height: height,
            frameInterval: frameInterval,
            framesToSample: framesToSample,
            progressCallback: { progress in
                progressCallback(progress * 0.4) // First 40% is extraction
            }
        )

        guard !isCancelled else { throw TimesliceProcessorError.cancelled }

        let extractTime = CFAbsoluteTimeGetCurrent() - extractStart
        let extractFps = Double(actualFrameCount) / extractTime
        print("Video read complete: \(String(format: "%.2f", extractTime))s (\(String(format: "%.1f", extractFps)) fps)")
        print("  Read \(actualFrameCount) frames into \(String(format: "%.2f", Double(flatBuffer.count) / (1024*1024*1024))) GB buffer")

        // Step 2: Transpose from row-major to column-major for output assembly
        print("\n--- Phase 2: Transposing to column-major order ---")
        let transposeStart = CFAbsoluteTimeGetCurrent()

        let columnsByX = transposeFromFlatBuffer(flatBuffer: flatBuffer, width: width, height: height, numFrames: actualFrameCount)
        progressCallback(0.5) // 50% after transpose

        guard !isCancelled else { throw TimesliceProcessorError.cancelled }

        let transposeTime = CFAbsoluteTimeGetCurrent() - transposeStart
        print("Transpose complete: \(String(format: "%.2f", transposeTime))s")
        print("  Organized \(width) x-positions × \(framesToSample) frames")

        // Step 3: Write output video
        print("\n--- Phase 3: Generating output video ---")
        let writeStart = CFAbsoluteTimeGetCurrent()

        try await writeOutputVideo(
            columnsByX: columnsByX,
            outputURL: outputURL,
            width: framesToSample,
            height: height,
            frameRate: 30.0,
            progressCallback: { progress in
                progressCallback(0.5 + progress * 0.5) // Last 50% is writing
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

    /// Extracts all frames into a flat buffer (row-major order)
    /// Returns the flat buffer and actual frame count
    private func extractAllFrames(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        startTime: Double,
        endTime: Double,
        width: Int,
        height: Int,
        frameInterval: Int,
        framesToSample: Int,
        progressCallback: @escaping ProgressCallback
    ) async throws -> (Data, Int) {
        let timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            end: CMTime(seconds: endTime, preferredTimescale: 600)
        )

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw TimesliceProcessorError.readerSetupFailed("Could not create asset reader")
        }

        // Use BGRA format for color output
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

        // PRE-ALLOCATE single contiguous buffer - eliminates ~2 million allocations!
        let bytesPerPixel = 4 // BGRA = 4 bytes per pixel
        let totalBytes = width * height * framesToSample * bytesPerPixel
        var flatBuffer = Data(count: totalBytes)

        print("  Allocated single buffer: \(String(format: "%.2f", Double(totalBytes) / (1024*1024*1024))) GB")

        var frameIndex = 0
        var sampledCount = 0
        let extractionStart = CFAbsoluteTimeGetCurrent()

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            guard !isCancelled else {
                reader.cancelReading()
                throw TimesliceProcessorError.cancelled
            }

            // Sample frames based on speed factor
            if frameIndex % frameInterval == 0 && sampledCount < framesToSample {
                // Extract directly into flat buffer at calculated offset
                extractAllColumnsIntoBuffer(
                    sampleBuffer,
                    width: width,
                    height: height,
                    frameIndex: sampledCount,
                    buffer: &flatBuffer
                )
                sampledCount += 1

                // Update progress
                if sampledCount % 10 == 0 {
                    let progress = Double(sampledCount) / Double(framesToSample)
                    progressCallback(progress)
                }

                // Log progress every 100 frames
                if sampledCount % 100 == 0 {
                    let elapsed = CFAbsoluteTimeGetCurrent() - extractionStart
                    let fps = Double(sampledCount) / elapsed
                    print("  Extracted \(sampledCount)/\(framesToSample) frames (\(String(format: "%.1f", fps)) fps)")
                }
            }

            frameIndex += 1

            if sampledCount >= framesToSample {
                break
            }
        }

        reader.cancelReading()

        return (flatBuffer, sampledCount)
    }

    /// Extracts all columns from a frame directly into flat buffer (zero intermediate allocations!)
    private func extractAllColumnsIntoBuffer(
        _ sampleBuffer: CMSampleBuffer,
        width: Int,
        height: Int,
        frameIndex: Int,
        buffer: inout Data
    ) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
            return
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let bytesPerPixel = 4 // BGRA
        let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

        // Copy entire frame as-is (row-major BGRA order)
        // We'll handle the transpose later. This is MUCH faster than column extraction.
        buffer.withUnsafeMutableBytes { bufferPtr in
            guard let bufferBase = bufferPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }

            let baseOffset = frameIndex * width * height * bytesPerPixel
            let dstPtr = bufferBase + baseOffset

            // Copy entire frame row by row (sequential, cache-friendly)
            for y in 0..<height {
                let srcRow = srcPtr + (y * bytesPerRow)
                let dstRow = dstPtr + (y * width * bytesPerPixel)
                // Use memcpy for bulk transfer (fastest possible)
                memcpy(dstRow, srcRow, width * bytesPerPixel)
            }
        }
    }

    /// Transposes from flat buffer (row-major) to column-major for output assembly
    /// Converts frames[row][col] to columns[x][frame_data]
    private func transposeFromFlatBuffer(flatBuffer: Data, width: Int, height: Int, numFrames: Int) -> [[Data]] {
        let bytesPerPixel = 4 // BGRA

        // Pre-allocate storage for all columns
        var columnsByX: [[Data]] = Array(repeating: [], count: width)
        for x in 0..<width {
            columnsByX[x] = Array(repeating: Data(), count: numFrames)
        }

        flatBuffer.withUnsafeBytes { bufferPtr in
            guard let bufferBase = bufferPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }

            // Process frames in parallel batches
            DispatchQueue.concurrentPerform(iterations: numFrames) { frame in
                let frameOffset = frame * width * height * bytesPerPixel

                // Extract all columns for this frame
                for x in 0..<width {
                    var columnData = Data(count: height * bytesPerPixel)

                    columnData.withUnsafeMutableBytes { columnPtr in
                        guard let columnBase = columnPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                            return
                        }

                        // Extract column from row-major BGRA data
                        for y in 0..<height {
                            let srcIndex = frameOffset + (y * width + x) * bytesPerPixel
                            let dstIndex = y * bytesPerPixel

                            // Copy 4 bytes (BGRA pixel)
                            columnBase[dstIndex] = bufferBase[srcIndex]
                            columnBase[dstIndex + 1] = bufferBase[srcIndex + 1]
                            columnBase[dstIndex + 2] = bufferBase[srcIndex + 2]
                            columnBase[dstIndex + 3] = bufferBase[srcIndex + 3]
                        }
                    }

                    columnsByX[x][frame] = columnData
                }

                // Log progress every 100 frames
                if frame % 100 == 0 {
                    print("  Transposed frame \(frame)/\(numFrames)")
                }
            }
        }

        return columnsByX
    }

    /// Writes the output video from transposed column data (organized by x-position)
    private func writeOutputVideo(
        columnsByX: [[Data]],
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
                AVVideoAverageBitRateKey: width * height * 4, // Reduced bitrate for faster encoding
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel, // Baseline is much faster than High
                AVVideoMaxKeyFrameIntervalKey: 30, // Keyframe every 30 frames
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCAVLC // Faster than CABAC
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        // Use BGRA format with hardware acceleration
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
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

        let totalOutputFrames = columnsByX.count // One output frame per x-position in original video
        let processStart = CFAbsoluteTimeGetCurrent()

        // Parallel frame assembly configuration
        let batchSize = 100 // Assemble frames in batches (increased for better parallelism)
        let frameBuffer = FrameBuffer()
        let encodingQueue = DispatchQueue(label: "videoWriter")

        var nextFrameToEncode = 0

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: encodingQueue) { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                while writerInput.isReadyForMoreMediaData && nextFrameToEncode < totalOutputFrames {
                    guard !self.isCancelled else {
                        writer.cancelWriting()
                        continuation.resume()
                        return
                    }

                    // Pre-assemble next batch of frames in parallel if needed
                    let currentBatchStart = (nextFrameToEncode / batchSize) * batchSize
                    let nextBatchStart = currentBatchStart + batchSize

                    let hasCurrentFrame = frameBuffer.contains(index: nextFrameToEncode)
                    let needsNextBatch = !frameBuffer.contains(index: nextBatchStart) && nextBatchStart < totalOutputFrames

                    // Trigger assembly of next batch
                    if needsNextBatch {
                        let batchStart = nextBatchStart
                        let batchEnd = min(batchStart + batchSize, totalOutputFrames)

                        DispatchQueue.concurrentPerform(iterations: batchEnd - batchStart) { index in
                            let frameIndex = batchStart + index

                            if let pixelBuffer = self.createOutputFrame(
                                columnsForX: columnsByX[frameIndex],
                                width: width,
                                height: height,
                                pixelBufferPool: pixelBufferAdaptor.pixelBufferPool
                            ) {
                                frameBuffer.store(pixelBuffer, at: frameIndex)
                            }
                        }
                    }

                    // Wait for current frame if not ready yet
                    if !hasCurrentFrame {
                        let frameIndex = nextFrameToEncode
                        if let pixelBuffer = self.createOutputFrame(
                            columnsForX: columnsByX[frameIndex],
                            width: width,
                            height: height,
                            pixelBufferPool: pixelBufferAdaptor.pixelBufferPool
                        ) {
                            frameBuffer.store(pixelBuffer, at: frameIndex)
                        }
                    }

                    // Encode current frame
                    if let pixelBuffer = frameBuffer.retrieve(at: nextFrameToEncode) {
                        let presentationTime = CMTime(
                            value: Int64(nextFrameToEncode),
                            timescale: Int32(frameRate)
                        )

                        pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                        nextFrameToEncode += 1

                        // Update progress and log performance
                        if nextFrameToEncode % 10 == 0 {
                            let progress = Double(nextFrameToEncode) / Double(totalOutputFrames)
                            progressCallback(progress)
                        }

                        if nextFrameToEncode % 100 == 0 {
                            let elapsed = CFAbsoluteTimeGetCurrent() - processStart
                            let fps = Double(nextFrameToEncode) / elapsed
                            print("  Assembled \(nextFrameToEncode)/\(totalOutputFrames) frames (\(String(format: "%.1f", fps)) fps)")
                        }
                    } else {
                        nextFrameToEncode += 1
                    }
                }

                if nextFrameToEncode >= totalOutputFrames {
                    writerInput.markAsFinished()
                    writer.finishWriting {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Creates a single output frame by assembling columns horizontally (BGRA format)
    /// All columns for a specific x-position are provided, making assembly efficient
    private func createOutputFrame(
        columnsForX: [Data],
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
        
        // Use UInt32 for fast 4-byte pixel copies
        let dstPtr32 = baseAddress.assumingMemoryBound(to: UInt32.self)
        let pixelsPerRow = bytesPerRow / bytesPerPixel

        // Copy each column into the output frame horizontally
        // columnsForX contains all frames' columns for this x-position
        for (frameIndex, columnData) in columnsForX.enumerated() {
            guard frameIndex < width else { break }

            columnData.withUnsafeBytes { columnPtr in
                guard let srcPtr32 = columnPtr.baseAddress?.assumingMemoryBound(to: UInt32.self) else {
                    return
                }

                // Copy entire column using single 32-bit writes (4x faster than byte-by-byte)
                for y in 0..<height {
                    let dstIndex = y * pixelsPerRow + frameIndex
                    dstPtr32[dstIndex] = srcPtr32[y]
                }
            }
        }

        return buffer
    }
}
