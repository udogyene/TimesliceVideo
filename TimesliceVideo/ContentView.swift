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

                // Video Info Section (visible only when video is loaded)
                if let metadata = viewModel.videoMetadata {
                    Divider()
                    videoInfoSection(metadata: metadata)
                }

                // Preview Section
                if viewModel.hasVideoLoaded {
                    Divider()
                    previewSection
                }

                // Controls Section (visible only when video is loaded)
                if viewModel.hasVideoLoaded {
                    Divider()
                    controlsSection
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

                    if viewModel.processingState == .loading {
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
            .disabled(viewModel.processingState == .loading)
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
                    ScrollView(.horizontal) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 280)
                            .cornerRadius(6)
                    }
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

    // MARK: - Controls Section

    private var controlsSection: some View {
        VStack(spacing: 20) {
            Text("Processing Parameters")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 20) {
                // Start Time Slider
                sliderControl(
                    title: "Start Time",
                    value: Binding(
                        get: { viewModel.processingParameters.startTime },
                        set: { viewModel.updateStartTime($0) }
                    ),
                    range: 0...(viewModel.videoMetadata?.duration ?? 1.0),
                    unit: "s",
                    format: "%.2f"
                )

                // End Time Slider
                sliderControl(
                    title: "End Time",
                    value: Binding(
                        get: { viewModel.processingParameters.endTime },
                        set: { viewModel.updateEndTime($0) }
                    ),
                    range: 0...(viewModel.videoMetadata?.duration ?? 1.0),
                    unit: "s",
                    format: "%.2f"
                )

                // Speed Factor Slider
                sliderControl(
                    title: "Speed Factor",
                    value: Binding(
                        get: { viewModel.processingParameters.speedFactor },
                        set: { viewModel.updateSpeedFactor($0) }
                    ),
                    range: 1.0...10.0,
                    unit: "×",
                    format: "%.1f"
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
    }

    private func sliderControl(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        unit: String,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(String(format: format, value.wrappedValue) + " " + unit)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    // MARK: - Generate Button Section

    private var generateButtonSection: some View {
        VStack(spacing: 12) {
            Button(action: {
                viewModel.generateOutput()
            }) {
                HStack(spacing: 8) {
                    if viewModel.processingState.isProcessing {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 14))
                    }
                    Text(viewModel.processingState.isProcessing ? "Processing..." : "Generate Output")
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
        }
        .padding(.bottom, 10)
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
