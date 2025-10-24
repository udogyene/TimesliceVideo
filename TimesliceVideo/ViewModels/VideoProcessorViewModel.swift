//
//  VideoProcessorViewModel.swift
//  TimesliceVideo
//
//  Created on 2025-10-24.
//

import AVFoundation
import AppKit
import Foundation
import SwiftUI

/// ViewModel that manages video loading, processing parameters, and UI state
class VideoProcessorViewModel: ObservableObject {

    // MARK: - Published Properties

    /// The currently loaded video metadata
    @Published var videoMetadata: VideoMetadata?

    /// User-configurable processing parameters
    @Published var processingParameters: ProcessingParameters = ProcessingParameters()

    /// Current processing state
    @Published var processingState: ProcessingState = .idle

    /// Thumbnail preview image (single frame from video)
    @Published var thumbnailImage: NSImage?

    /// Timeslice preview image (shows what the output will look like)
    @Published var timeslicePreview: NSImage?

    /// Whether a timeslice preview is currently being generated
    @Published var isGeneratingPreview: Bool = false

    /// Error message to display to the user
    @Published var errorMessage: String?

    // MARK: - Private Properties

    /// Task for debounced preview generation
    private var previewGenerationTask: Task<Void, Never>?

    /// Debounce delay in seconds
    private let previewDebounceDelay: TimeInterval = 0.5

    // MARK: - Computed Properties

    /// Whether a video is currently loaded
    var hasVideoLoaded: Bool {
        return videoMetadata != nil
    }

    /// Whether the generate button should be enabled
    var canGenerateOutput: Bool {
        return hasVideoLoaded &&
               processingParameters.isValid &&
               !processingState.isProcessing
    }

    /// The selected video URL
    var videoURL: URL? {
        return videoMetadata?.url
    }

    // MARK: - Public Methods

    /// Presents a file selection dialog and loads the selected video
    func selectAndLoadVideo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Select a video file to process"
        panel.prompt = "Select"

        if panel.runModal() == .OK {
            if let url = panel.url {
                loadVideo(from: url)
            }
        }
    }

    /// Loads a video from the specified URL
    /// - Parameter url: The URL of the video file to load
    func loadVideo(from url: URL) {
        // Reset state
        errorMessage = nil
        processingState = .loading

        VideoLoader.loadVideo(from: url) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let metadata):
                self.handleVideoLoaded(metadata)

            case .failure(let error):
                self.handleVideoLoadError(error)
            }
        }
    }

    /// Clears the currently loaded video and resets state
    func clearVideo() {
        videoMetadata = nil
        thumbnailImage = nil
        timeslicePreview = nil
        processingParameters = ProcessingParameters()
        processingState = .idle
        errorMessage = nil
        previewGenerationTask?.cancel()
    }

    /// Updates the start time parameter
    func updateStartTime(_ value: Double) {
        processingParameters.startTime = value

        // Ensure end time is always after start time
        if processingParameters.endTime <= value {
            processingParameters.endTime = min(value + 0.1, videoMetadata?.duration ?? value + 1.0)
        }

        // Trigger debounced preview generation
        schedulePreviewGeneration()
    }

    /// Updates the end time parameter
    func updateEndTime(_ value: Double) {
        processingParameters.endTime = value

        // Ensure start time is always before end time
        if processingParameters.startTime >= value {
            processingParameters.startTime = max(0, value - 0.1)
        }

        // Trigger debounced preview generation
        schedulePreviewGeneration()
    }

    /// Updates the speed factor parameter
    func updateSpeedFactor(_ value: Double) {
        processingParameters.speedFactor = value

        // Trigger debounced preview generation
        schedulePreviewGeneration()
    }

    /// Generates a thumbnail image at the specified time
    /// - Parameter time: The time in seconds to generate the thumbnail
    func updateThumbnail(at time: Double? = nil) {
        guard let metadata = videoMetadata else { return }

        let previewTime = time ?? processingParameters.startTime

        VideoLoader.generateThumbnail(from: metadata.asset, at: previewTime) { [weak self] result in
            switch result {
            case .success(let cgImage):
                let nsImage = NSImage(cgImage: cgImage, size: NSZeroSize)
                self?.thumbnailImage = nsImage

            case .failure(let error):
                print("Failed to generate thumbnail: \(error.localizedDescription)")
            }
        }
    }

    /// Schedules preview generation with debouncing
    private func schedulePreviewGeneration() {
        // Cancel any existing preview generation task
        previewGenerationTask?.cancel()

        // Schedule new preview generation after debounce delay
        previewGenerationTask = Task { @MainActor in
            do {
                // Wait for debounce delay
                try await Task.sleep(nanoseconds: UInt64(previewDebounceDelay * 1_000_000_000))

                // Check if task was cancelled
                guard !Task.isCancelled else { return }

                // Generate preview
                await generateTimeslicePreview()
            } catch {
                // Task was cancelled or sleep was interrupted
            }
        }
    }

    /// Generates the timeslice preview image
    func generateTimeslicePreview() async {
        guard let metadata = videoMetadata else { return }
        guard processingParameters.isValid else { return }

        // Update state
        await MainActor.run {
            isGeneratingPreview = true
        }

        do {
            let preview = try await PreviewGenerator.generateQuickPreview(
                from: metadata.asset,
                startTime: processingParameters.startTime,
                endTime: processingParameters.endTime,
                speedFactor: processingParameters.speedFactor
            )

            // Update preview on main thread
            await MainActor.run {
                self.timeslicePreview = preview
                self.isGeneratingPreview = false
            }

            print("Preview generated successfully")
            print("  Preview size: \(Int(preview.size.width)) × \(Int(preview.size.height))")
        } catch {
            await MainActor.run {
                self.isGeneratingPreview = false
            }
            print("Failed to generate preview: \(error.localizedDescription)")
        }
    }

    /// Forces immediate preview generation without debouncing
    func generatePreviewNow() {
        previewGenerationTask?.cancel()
        Task {
            await generateTimeslicePreview()
        }
    }

    /// Starts the video processing operation
    func generateOutput() {
        guard canGenerateOutput else { return }

        // Placeholder for actual processing logic
        processingState = .processing(progress: 0.0)

        // TODO: Implement actual video processing
        print("Generate output called")
        print("Video: \(videoURL?.path ?? "none")")
        print("Start time: \(processingParameters.startTime)s")
        print("End time: \(processingParameters.endTime)s")
        print("Speed factor: \(processingParameters.speedFactor)x")

        // Simulate processing completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.processingState = .ready
        }
    }

    // MARK: - Private Methods

    private func handleVideoLoaded(_ metadata: VideoMetadata) {
        self.videoMetadata = metadata

        // Initialize processing parameters based on video metadata
        self.processingParameters = ProcessingParameters.from(metadata: metadata)

        // Update state
        self.processingState = .ready

        // Generate initial thumbnail
        self.updateThumbnail(at: 0.0)

        // Generate timeslice preview
        Task {
            await self.generateTimeslicePreview()
        }

        print("Video loaded successfully:")
        print("  Dimensions: \(metadata.dimensionsString)")
        print("  Duration: \(metadata.durationString)")
        print("  Frame Rate: \(metadata.frameRateString)")
        print("  Total Frames: \(metadata.totalFrames)")
    }

    private func handleVideoLoadError(_ error: VideoLoaderError) {
        self.errorMessage = error.errorDescription
        self.processingState = .failed(error: error.errorDescription ?? "Unknown error")

        print("Failed to load video: \(error.errorDescription ?? "Unknown error")")
    }
}
