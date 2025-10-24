//
//  VideoLoader.swift
//  TimesliceVideo
//
//  Created on 2025-10-24.
//

import AVFoundation
import Foundation

/// Result type for video loading operations
enum VideoLoaderResult {
    case success(VideoMetadata)
    case failure(VideoLoaderError)
}

/// Errors that can occur during video loading
enum VideoLoaderError: LocalizedError {
    case invalidURL
    case noVideoTrack
    case unsupportedFormat
    case loadingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The video file URL is invalid."
        case .noVideoTrack:
            return "No video track found in the file."
        case .unsupportedFormat:
            return "The video format is not supported."
        case .loadingFailed(let message):
            return "Failed to load video: \(message)"
        }
    }
}

/// Service responsible for loading and extracting video metadata
class VideoLoader {

    /// Loads a video from the specified URL and extracts its metadata
    /// - Parameter url: The URL of the video file to load
    /// - Parameter completion: Completion handler called with the result
    static func loadVideo(from url: URL, completion: @escaping (VideoLoaderResult) -> Void) {
        // Verify URL is valid
        guard url.isFileURL else {
            completion(.failure(.invalidURL))
            return
        }

        // Create AVAsset from URL
        let asset = AVAsset(url: url)

        // Load asset properties asynchronously
        let requiredKeys = ["tracks", "duration", "playable"]

        asset.loadValuesAsynchronously(forKeys: requiredKeys) {
            // Check if asset is playable
            var error: NSError?
            let playableStatus = asset.statusOfValue(forKey: "playable", error: &error)

            if playableStatus == .failed {
                let message = error?.localizedDescription ?? "Unknown error"
                DispatchQueue.main.async {
                    completion(.failure(.loadingFailed(message)))
                }
                return
            }

            guard asset.isPlayable else {
                DispatchQueue.main.async {
                    completion(.failure(.unsupportedFormat))
                }
                return
            }

            // Extract video track
            guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                DispatchQueue.main.async {
                    completion(.failure(.noVideoTrack))
                }
                return
            }

            // Extract metadata
            let duration = CMTimeGetSeconds(asset.duration)
            let size = videoTrack.naturalSize
            let frameRate = videoTrack.nominalFrameRate
            let transform = videoTrack.preferredTransform

            // Check if video is rotated (portrait mode)
            let isPortrait = abs(transform.b) == 1.0 && abs(transform.c) == 1.0

            // Adjust dimensions if portrait
            let width = isPortrait ? size.height : size.width
            let height = isPortrait ? size.width : size.height

            let metadata = VideoMetadata(
                asset: asset,
                width: width,
                height: height,
                duration: duration,
                frameRate: Double(frameRate),
                url: url
            )

            DispatchQueue.main.async {
                completion(.success(metadata))
            }
        }
    }

    /// Synchronously validates if a file is a valid video
    /// - Parameter url: The URL to validate
    /// - Returns: True if the file appears to be a valid video
    static func isValidVideoFile(url: URL) -> Bool {
        guard url.isFileURL else { return false }

        let asset = AVAsset(url: url)
        return !asset.tracks(withMediaType: .video).isEmpty
    }

    /// Generates a thumbnail image from the video at the specified time
    /// - Parameters:
    ///   - asset: The video asset
    ///   - time: The time in seconds to generate the thumbnail
    ///   - completion: Completion handler with the generated CGImage
    static func generateThumbnail(
        from asset: AVAsset,
        at time: Double = 0.0,
        completion: @escaping (Result<CGImage, Error>) -> Void
    ) {
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceAfter = .zero
        imageGenerator.requestedTimeToleranceBefore = .zero

        let cmTime = CMTime(seconds: time, preferredTimescale: 600)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let cgImage = try imageGenerator.copyCGImage(at: cmTime, actualTime: nil)
                DispatchQueue.main.async {
                    completion(.success(cgImage))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}
