//
//  VideoPreprocessor.swift
//  TimesliceVideo
//
//  Created on 2025-10-25.
//

import AVFoundation
import AppKit
import CoreMedia

/// Service for preprocessing videos that are too long
class VideoPreprocessor {

    /// Maximum video duration in seconds before preprocessing is required
    static let maxDuration: Double = 300.0 // 5 minutes

    /// Speeds up a video to fit within the maximum duration
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
        print("  Target frame rate: 30 fps")

        // Create temporary output URL
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("preprocessed_\(UUID().uuidString).mp4")

        // Remove existing file if it exists
        try? FileManager.default.removeItem(at: outputURL)

        // Create composition
        let composition = AVMutableComposition()

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoPreprocessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "VideoPreprocessor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create composition track"])
        }

        // Insert the video track
        let timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)

        // Apply time scaling to speed up the video
        let scaledDuration = CMTime(seconds: maxDuration, preferredTimescale: 600)
        compositionVideoTrack.scaleTimeRange(timeRange, toDuration: scaledDuration)

        // Handle audio track if present
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
            compositionAudioTrack.scaleTimeRange(timeRange, toDuration: scaledDuration)
        }

        // Create video composition to control frame rate (30fps)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30) // 30 fps

        let naturalSize = try await videoTrack.load(.naturalSize)
        videoComposition.renderSize = naturalSize

        // Create instruction for the composition
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: scaledDuration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        instruction.layerInstructions = [layerInstruction]

        videoComposition.instructions = [instruction]

        // Export the composition
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw NSError(domain: "VideoPreprocessor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition

        // Monitor progress while exporting
        print("Starting export...")

        await withTaskGroup(of: Void.self) { group in
            // Start the export task
            group.addTask {
                await withCheckedContinuation { continuation in
                    exportSession.exportAsynchronously {
                        continuation.resume()
                    }
                }
            }

            // Start the progress monitoring task
            group.addTask {
                while exportSession.status != .completed &&
                      exportSession.status != .failed &&
                      exportSession.status != .cancelled {
                    let progress = Double(exportSession.progress)
                    print("Export progress: \(Int(progress * 100))%")
                    await MainActor.run {
                        progressCallback(progress)
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                }

                // Final progress update
                let finalProgress = Double(exportSession.progress)
                print("Export final progress: \(Int(finalProgress * 100))%")
                await MainActor.run {
                    progressCallback(finalProgress)
                }
            }

            await group.waitForAll()
        }

        print("Export completed with status: \(exportSession.status.rawValue)")

        if let error = exportSession.error {
            print("Export error: \(error.localizedDescription)")
            throw error
        }

        guard exportSession.status == .completed else {
            let errorMsg = "Export failed with status: \(exportSession.status.rawValue)"
            print(errorMsg)
            throw NSError(domain: "VideoPreprocessor", code: 4, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        print("Preprocessing completed successfully")
        print("  Output URL: \(outputURL.path)")

        return outputURL
    }

    /// Checks if a video needs preprocessing
    /// - Parameter duration: Video duration in seconds
    /// - Returns: True if video needs preprocessing
    static func needsPreprocessing(duration: Double) -> Bool {
        return duration > maxDuration
    }
}
