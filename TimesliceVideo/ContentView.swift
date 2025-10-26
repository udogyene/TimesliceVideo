//
//  ContentView.swift
//  TimesliceVideo
//
//  Created on 2025-10-24.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var viewModel = VideoProcessorViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text("TimesliceVideo")
                        .font(.system(size: 28, weight: .bold))
                    Text("Transform your videos with unique timeslice effects")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)

                Divider()

                // File Import Section
                fileImportSection

                // Error Message
                if let errorMessage = viewModel.errorMessage {
                    errorMessageView(message: errorMessage)
                }

                // Preprocessing Status
                if case .preprocessing(let progress) = viewModel.processingState {
                    preprocessingStatusView(progress: progress)
                }

                // Video Info Section (visible only when video is loaded)
                if let metadata = viewModel.videoMetadata {
                    Divider()
                    videoInfoSection(metadata: metadata)
                }

                // Video Playback Preview Section
                if let player = viewModel.videoPlayer {
                    Divider()
                    videoPlaybackSection(player: player)
                }

                // Preview Section
                if viewModel.hasVideoLoaded {
                    Divider()
                    previewSection
                }

                // Generate Button
                generateButtonSection
            }
            .padding(30)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 700, height: 800)
    }

    // MARK: - File Import Section

    private var fileImportSection: some View {
        VStack(spacing: 16) {
            Text("Video File")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: {
                viewModel.selectAndLoadVideo()
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.videoURL?.lastPathComponent ?? "Select Video File")
                            .font(.system(size: 13, weight: .medium))
                        if viewModel.videoURL == nil {
                            Text("Click to choose a video file")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()

                    if viewModel.processingState == .loading || viewModel.processingState.isProcessing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.processingState == .loading || viewModel.processingState.isProcessing)
        }
    }

    // MARK: - Error Message View

    private func errorMessageView(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
            Button(action: {
                viewModel.errorMessage = nil
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
    }

    // MARK: - Preprocessing Status View

    private func preprocessingStatusView(progress: Double) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.blue)
                Text("Preprocessing long video...")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)

            Text("Speeding up video to 5 minutes for optimal processing")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.1))
        )
    }

    // MARK: - Video Info Section

    private func videoInfoSection(metadata: VideoMetadata) -> some View {
        VStack(spacing: 16) {
            Text("Video Information")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                infoRow(label: "Dimensions", value: metadata.dimensionsString)
                infoRow(label: "Duration", value: metadata.durationString)
                infoRow(label: "Frame Rate", value: metadata.frameRateString)
                infoRow(label: "Total Frames", value: "\(metadata.totalFrames)")
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
        }
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Timeslice Preview")
                    .font(.headline)

                Spacer()

                if let preview = viewModel.timeslicePreview {
                    Text("\(Int(preview.size.width)) × \(Int(preview.size.height)) px")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(height: 300)

                if viewModel.isGeneratingPreview {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Generating preview...")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Text("This shows what your output will look like")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                } else if let image = viewModel.timeslicePreview {
                    VStack {
                        Spacer()
                        GeometryReader { geometry in
                            ScrollView(.horizontal, showsIndicators: true) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 280)
                                    .frame(minWidth: geometry.size.width)
                                    .cornerRadius(6)
                            }
                        }
                        .frame(height: 280)
                        Spacer()
                    }
                    .frame(height: 300)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Timeslice preview will appear here")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if !viewModel.isGeneratingPreview && viewModel.timeslicePreview != nil {
                Text("Tip: Adjust sliders to see how the output will change")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Generate Button Section

    private var generateButtonSection: some View {
        VStack(spacing: 12) {
            if viewModel.isProcessingFullVideo {
                // Processing UI
                VStack(spacing: 12) {
                    HStack {
                        Text("Processing Video")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("\(Int(viewModel.processingProgress * 100))%")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    ProgressView(value: viewModel.processingProgress, total: 1.0)
                        .progressViewStyle(.linear)

                    Button(action: {
                        viewModel.cancelProcessing()
                    }) {
                        Text("Cancel")
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
            } else {
                // Generate button
                Button(action: {
                    viewModel.generateOutput()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 14))
                        Text("Generate Output Video")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canGenerateOutput)
                .controlSize(.large)

                if !viewModel.hasVideoLoaded {
                    Text("Please select a video file to continue")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else if !viewModel.processingParameters.isValid {
                    Text("Please adjust parameters to valid values")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }

                // Success message
                if case .completed(let outputURL) = viewModel.processingState {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Video saved successfully!")
                                .font(.system(size: 13, weight: .medium))
                            Text(outputURL.lastPathComponent)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                        }) {
                            Text("Show in Finder")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.link)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green.opacity(0.1))
                    )
                }

                // Error message
                if case .failed(let error) = viewModel.processingState {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: {
                            viewModel.processingState = .ready
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.1))
                    )
                }
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: - Video Playback Section

    private func videoPlaybackSection(player: AVPlayer) -> some View {
        VStack(spacing: 12) {
            Text("Video Preview")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                VideoPlayerView(player: player)
                    .frame(height: 300)

                VideoPlayerControls(
                    player: player,
                    startTime: $viewModel.processingParameters.startTime,
                    endTime: $viewModel.processingParameters.endTime,
                    onStartTimeChanged: { _ in viewModel.schedulePreviewGeneration() },
                    onEndTimeChanged: { _ in viewModel.schedulePreviewGeneration() }
                )

                // Speed Factor Slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Speed Factor")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(String(format: "%.1f", viewModel.processingParameters.speedFactor) + " ×")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    Slider(
                        value: Binding(
                            get: { viewModel.processingParameters.speedFactor },
                            set: { viewModel.updateSpeedFactor($0) }
                        ),
                        in: 1.0...10.0
                    )
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
