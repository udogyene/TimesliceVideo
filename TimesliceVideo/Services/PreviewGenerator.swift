//
//  PreviewGenerator.swift
//  TimesliceVideo
//
//  Created on 2025-10-24.
//

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import AppKit

/// Errors that can occur during preview generation
enum PreviewGeneratorError: LocalizedError {
    case invalidAsset
    case noVideoTrack
    case imageGenerationFailed(String)
    case invalidParameters
    case readerSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAsset:
            return "The video asset is invalid."
        case .noVideoTrack:
            return "No video track found in the video."
        case .imageGenerationFailed(let message):
            return "Failed to generate preview: \(message)"
        case .invalidParameters:
            return "Invalid preview parameters."
        case .readerSetupFailed(let message):
            return "Failed to setup asset reader: \(message)"
        }
    }
}

/// Service responsible for generating timeslice preview images
class PreviewGenerator {

    /// Generates a preview image showing the timeslice effect using optimized AVAssetReader
    /// - Parameters:
    ///   - asset: The video asset to process
    ///   - startTime: Start time in seconds
    ///   - endTime: End time in seconds
    ///   - speedFactor: Speed multiplier (e.g., 2.0 = 2x speed)
    ///   - xPosition: X-coordinate to sample (nil = middle of frame)
    ///   - maxFrames: Maximum number of frames to process (for performance)
    /// - Returns: The generated preview image
    static func generatePreview(
        from asset: AVAsset,
        startTime: Double,
        endTime: Double,
        speedFactor: Double,
        xPosition: Int? = nil,
        maxFrames: Int = 2000
    ) async throws -> NSImage {
        let overallStart = CFAbsoluteTimeGetCurrent()

        // Validate parameters
        guard startTime < endTime, speedFactor >= 1.0 else {
            throw PreviewGeneratorError.invalidParameters
        }

        // Get video track
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw PreviewGeneratorError.noVideoTrack
        }

        // Get video properties
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)

        // Check if video is rotated (portrait mode)
        let isPortrait = abs(transform.b) == 1.0 && abs(transform.c) == 1.0
        let width = Int(isPortrait ? naturalSize.height : naturalSize.width)
        let height = Int(isPortrait ? naturalSize.width : naturalSize.height)

        // Calculate sampling position (default to middle)
        let samplingX = xPosition ?? (width / 2)
        guard samplingX >= 0 && samplingX < width else {
            throw PreviewGeneratorError.invalidParameters
        }

        // Calculate frame parameters
        let duration = endTime - startTime
        let fps = Double(nominalFrameRate)
        let totalFrames = Int(duration * fps)

        // Calculate output frames after speed adjustment
        let outputDuration = duration / speedFactor
        let outputFrames = Int(outputDuration * fps)

        // For preview, we want to sample consistently regardless of speed factor
        // Target: ~500-600 frames for good quality/performance balance
        let targetPreviewFrames = min(maxFrames, 600)

        // Calculate optimal sampling interval to get close to target
        // We sample from the output frames (after speed adjustment)
        let optimalInterval = max(1, outputFrames / targetPreviewFrames)
        let framesToSample = min(outputFrames / optimalInterval, maxFrames)

        guard framesToSample > 0 else {
            throw PreviewGeneratorError.invalidParameters
        }

        // Adjust the frame interval for the actual input frames
        // We need to account for the speed factor when sampling from input
        let frameInterval = Int(ceil(Double(optimalInterval) * speedFactor))

        // Downsample height: use half resolution (2x faster)
        let downsampledHeight = height / 2

        print("Preview generation started:")
        print("  Input duration: \(String(format: "%.2f", duration))s")
        print("  Total input frames: \(totalFrames)")
        print("  Speed factor: \(speedFactor)x")
        print("  Output duration: \(String(format: "%.2f", outputDuration))s")
        print("  Output frames: \(outputFrames)")
        print("  Target preview frames: \(targetPreviewFrames)")
        print("  Optimal interval: \(optimalInterval)")
        print("  Frame interval (adjusted for input): \(frameInterval)")
        print("  Frames to sample: \(framesToSample)")
        print("  Sampling column: x=\(samplingX)")
        print("  Output height (downsampled): \(downsampledHeight)")

        // Setup AVAssetReader
        let setupStart = CFAbsoluteTimeGetCurrent()

        let timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            end: CMTime(seconds: endTime, preferredTimescale: 600)
        )

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw PreviewGeneratorError.readerSetupFailed("Could not create asset reader")
        }

        // Configure output settings for fast pixel access
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: false
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)

        reader.timeRange = timeRange
        reader.add(readerOutput)

        guard reader.startReading() else {
            let error = reader.error?.localizedDescription ?? "Unknown error"
            throw PreviewGeneratorError.readerSetupFailed(error)
        }

        let setupTime = CFAbsoluteTimeGetCurrent() - setupStart
        print("  Setup time: \(String(format: "%.3f", setupTime))s")

        // Extract columns
        let extractStart = CFAbsoluteTimeGetCurrent()
        var columns: [UnsafePointer<UInt8>] = []
        var columnBuffers: [Data] = [] // Keep data alive
        var frameIndex = 0
        var sampledCount = 0

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            defer {
                CMSampleBufferInvalidate(sampleBuffer)
            }

            // Check if we should sample this frame based on speed factor
            if frameIndex % frameInterval == 0 && sampledCount < framesToSample {
                if let column = extractColumnFromSampleBuffer(
                    sampleBuffer,
                    x: samplingX,
                    fullHeight: height,
                    downsampledHeight: downsampledHeight
                ) {
                    columnBuffers.append(column)
                    column.withUnsafeBytes { ptr in
                        if let baseAddress = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                            columns.append(baseAddress)
                        }
                    }
                    sampledCount += 1
                }
            }

            frameIndex += 1

            // Stop if we've collected enough frames
            if sampledCount >= framesToSample {
                break
            }
        }

        reader.cancelReading()

        let extractTime = CFAbsoluteTimeGetCurrent() - extractStart
        print("  Extraction time: \(String(format: "%.3f", extractTime))s (\(columns.count) columns)")

        guard !columns.isEmpty else {
            throw PreviewGeneratorError.imageGenerationFailed("No frames could be extracted")
        }

        // Assemble preview image
        let assembleStart = CFAbsoluteTimeGetCurrent()
        let previewImage = try assembleColumnsOptimized(columnBuffers, height: downsampledHeight)
        let assembleTime = CFAbsoluteTimeGetCurrent() - assembleStart
        print("  Assembly time: \(String(format: "%.3f", assembleTime))s")

        let totalTime = CFAbsoluteTimeGetCurrent() - overallStart
        print("  TOTAL TIME: \(String(format: "%.3f", totalTime))s")
        print("  Output size: \(Int(previewImage.size.width)) × \(Int(previewImage.size.height))")

        return previewImage
    }

    /// Extracts a single column from a sample buffer with downsampling
    /// - Parameters:
    ///   - sampleBuffer: The sample buffer containing the frame
    ///   - x: The x-coordinate of the column to extract
    ///   - fullHeight: Full height of the source image
    ///   - downsampledHeight: Target downsampled height (samples every other row)
    /// - Returns: Data containing the downsampled column pixels (4 bytes per pixel)
    private static func extractColumnFromSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        x: Int,
        fullHeight: Int,
        downsampledHeight: Int
    ) -> Data? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let pixelHeight = CVPixelBufferGetHeight(imageBuffer)
        let pixelWidth = CVPixelBufferGetWidth(imageBuffer)

        // Validate dimensions
        guard x < pixelWidth, pixelHeight == fullHeight else {
            return nil
        }

        // Extract column directly from pixel buffer, sampling every other row
        // Each pixel is 4 bytes (BGRA)
        let bytesPerPixel = 4
        var columnData = Data(count: downsampledHeight * bytesPerPixel)

        columnData.withUnsafeMutableBytes { columnPtr in
            guard let columnBase = columnPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }

            let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

            // Copy one pixel from every other row (0, 2, 4, 6...)
            for y in 0..<downsampledHeight {
                let srcY = y * 2 // Sample every other row
                let srcOffset = srcY * bytesPerRow + x * bytesPerPixel
                let dstOffset = y * bytesPerPixel

                // Copy 4 bytes (BGRA)
                columnBase[dstOffset] = srcPtr[srcOffset]
                columnBase[dstOffset + 1] = srcPtr[srcOffset + 1]
                columnBase[dstOffset + 2] = srcPtr[srcOffset + 2]
                columnBase[dstOffset + 3] = srcPtr[srcOffset + 3]
            }
        }

        return columnData
    }

    /// Assembles column data into a single image using optimized buffer operations
    /// - Parameters:
    ///   - columnBuffers: Array of column data buffers
    ///   - height: Height of the output image
    /// - Returns: The assembled image
    private static func assembleColumnsOptimized(_ columnBuffers: [Data], height: Int) throws -> NSImage {
        let width = columnBuffers.count
        guard width > 0 else {
            throw PreviewGeneratorError.imageGenerationFailed("No columns to assemble")
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // BGRA format requires byteOrder32Little flag
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        // Pre-allocate output buffer
        var outputData = Data(count: height * bytesPerRow)

        // Copy columns into output buffer
        outputData.withUnsafeMutableBytes { outputPtr in
            guard let outputBase = outputPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }

            for (columnIndex, columnData) in columnBuffers.enumerated() {
                columnData.withUnsafeBytes { columnPtr in
                    guard let columnBase = columnPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }

                    // Copy column pixels into output buffer
                    for y in 0..<height {
                        let srcOffset = y * bytesPerPixel
                        let dstOffset = y * bytesPerRow + columnIndex * bytesPerPixel

                        // Copy 4 bytes (BGRA)
                        outputBase[dstOffset] = columnBase[srcOffset]
                        outputBase[dstOffset + 1] = columnBase[srcOffset + 1]
                        outputBase[dstOffset + 2] = columnBase[srcOffset + 2]
                        outputBase[dstOffset + 3] = columnBase[srcOffset + 3]
                    }
                }
            }
        }

        // Create CGImage from buffer
        guard let dataProvider = CGDataProvider(data: outputData as CFData) else {
            throw PreviewGeneratorError.imageGenerationFailed("Failed to create data provider")
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw PreviewGeneratorError.imageGenerationFailed("Failed to create CGImage")
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        return nsImage
    }

    /// Generates a quick preview with reduced quality for faster feedback
    /// - Parameters:
    ///   - asset: The video asset to process
    ///   - startTime: Start time in seconds
    ///   - endTime: End time in seconds
    ///   - speedFactor: Speed multiplier
    ///   - xPosition: X-coordinate to sample (nil = middle of frame)
    /// - Returns: The generated preview image
    static func generateQuickPreview(
        from asset: AVAsset,
        startTime: Double,
        endTime: Double,
        speedFactor: Double,
        xPosition: Int? = nil
    ) async throws -> NSImage {
        // Generate with good frame count for preview (1000 frames = ~1000px wide)
        // Balanced between preview quality and generation speed
        return try await generatePreview(
            from: asset,
            startTime: startTime,
            endTime: endTime,
            speedFactor: speedFactor,
            xPosition: xPosition,
            maxFrames: 1000
        )
    }
}
