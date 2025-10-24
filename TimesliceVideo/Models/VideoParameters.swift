//
//  VideoParameters.swift
//  TimesliceVideo
//
//  Created on 2025-10-24.
//

import AVFoundation
import Foundation

/// Represents metadata extracted from a video file
struct VideoMetadata: Equatable {
    let asset: AVAsset
    let width: CGFloat
    let height: CGFloat
    let duration: Double
    let frameRate: Double
    let url: URL

    // Custom equality to handle AVAsset comparison
    static func == (lhs: VideoMetadata, rhs: VideoMetadata) -> Bool {
        return lhs.url == rhs.url &&
               lhs.width == rhs.width &&
               lhs.height == rhs.height &&
               lhs.duration == rhs.duration &&
               lhs.frameRate == rhs.frameRate
    }

    /// Returns a formatted string for the video dimensions
    var dimensionsString: String {
        return "\(Int(width)) × \(Int(height)) px"
    }

    /// Returns a formatted string for the video duration
    var durationString: String {
        return String(format: "%.2f seconds", duration)
    }

    /// Returns a formatted string for the frame rate
    var frameRateString: String {
        return String(format: "%.2f fps", frameRate)
    }

    /// Returns the total number of frames in the video
    var totalFrames: Int {
        return Int(duration * frameRate)
    }
}

/// Represents user-configurable processing parameters
struct ProcessingParameters {
    var startTime: Double
    var endTime: Double
    var speedFactor: Double

    /// Default initializer with sensible defaults
    init(startTime: Double = 0.0, endTime: Double = 1.0, speedFactor: Double = 1.0) {
        self.startTime = startTime
        self.endTime = endTime
        self.speedFactor = speedFactor
    }

    /// Creates processing parameters initialized from video metadata
    static func from(metadata: VideoMetadata) -> ProcessingParameters {
        return ProcessingParameters(
            startTime: 0.0,
            endTime: metadata.duration,
            speedFactor: 1.0
        )
    }

    /// Validates that the parameters are logically correct
    var isValid: Bool {
        return startTime >= 0 &&
               endTime > startTime &&
               speedFactor >= 1.0 &&
               speedFactor <= 10.0
    }

    /// Returns the duration of the selected segment
    var segmentDuration: Double {
        return endTime - startTime
    }

    /// Returns the expected output duration based on speed factor
    var outputDuration: Double {
        return segmentDuration / speedFactor
    }

    /// Returns the number of frames to process
    func frameCount(for metadata: VideoMetadata) -> Int {
        return Int(segmentDuration * metadata.frameRate)
    }
}

/// Represents the current state of video processing
enum ProcessingState: Equatable {
    case idle
    case loading
    case ready
    case processing(progress: Double)
    case completed(outputURL: URL)
    case failed(error: String)

    var isProcessing: Bool {
        if case .processing = self {
            return true
        }
        return false
    }

    var isIdle: Bool {
        if case .idle = self {
            return true
        }
        return false
    }

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}
