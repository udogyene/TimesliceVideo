//
//  VideoPlayerView.swift
//  TimesliceVideo
//
//  Created on 2025-10-25.
//

import SwiftUI
import AVKit
import AppKit
import CoreMedia

/// Custom AVPlayerView that blocks scroll-to-scrub
class NonScrubbableAVPlayerView: AVPlayerView {
    weak var containerView: NSView?

    override func scrollWheel(with event: NSEvent) {
        // Don't call super - this prevents AVPlayerView from handling scroll
        // Pass to container which will forward to parent ScrollView
        containerView?.scrollWheel(with: event)
    }

    // Recursively disable scroll in all subviews
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        disableScrollInView(subview)
    }

    private func disableScrollInView(_ view: NSView) {
        // Swizzle scrollWheel for each subview
        if let viewClass = object_getClass(view) {
            let originalSelector = #selector(NSView.scrollWheel(with:))
            let swizzledBlock: @convention(block) (AnyObject, NSEvent) -> Void = { [weak self] (obj, event) in
                // Forward to our player view's scrollWheel instead
                self?.scrollWheel(with: event)
            }

            let implementation = imp_implementationWithBlock(swizzledBlock as Any)

            if let method = class_getInstanceMethod(viewClass, originalSelector) {
                method_setImplementation(method, implementation)
            }
        }

        // Recursively apply to subviews
        for subview in view.subviews {
            disableScrollInView(subview)
        }
    }
}

/// Container view that passes scroll events to parent
class ScrollPassthroughContainer: NSView {
    override func scrollWheel(with event: NSEvent) {
        // Pass scroll event to the next responder (SwiftUI's ScrollView)
        self.nextResponder?.scrollWheel(with: event)
    }
}

/// Custom video player controls with start/end time markers
struct VideoPlayerControls: View {
    let player: AVPlayer
    @Binding var startTime: Double
    @Binding var endTime: Double
    let onStartTimeChanged: (Double) -> Void
    let onEndTimeChanged: (Double) -> Void

    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var isDragging = false

    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            // Main playback controls
            HStack(spacing: 12) {
                // Play/Pause button
                Button(action: togglePlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)

                // Current time
                Text(formatTime(currentTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)

                // Progress slider with range overlay
                ZStack(alignment: .leading) {
                    // Background slider
                    Slider(
                        value: Binding(
                            get: { currentTime },
                            set: { newValue in
                                currentTime = newValue
                                if !isDragging {
                                    seek(to: newValue)
                                }
                            }
                        ),
                        in: 0...duration,
                        onEditingChanged: { editing in
                            isDragging = editing
                            if !editing {
                                seek(to: currentTime)
                            }
                        }
                    )
                    .controlSize(.small)
                }

                // Duration
                Text(formatTime(duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Start/End time controls
            HStack(spacing: 12) {
                // Start time marker and slider
                HStack(spacing: 6) {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.green)
                    Text("Start")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(formatTime(startTime))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.green)
                        .frame(width: 40, alignment: .trailing)
                }

                Slider(value: $startTime, in: 0...duration)
                    .controlSize(.mini)
                    .tint(.green)
                    .onChange(of: startTime) { newValue in
                        // Ensure start time doesn't exceed end time
                        if newValue >= endTime {
                            startTime = max(0, endTime - 0.1)
                        }
                        // Trigger preview regeneration
                        onStartTimeChanged(startTime)
                    }

                Spacer().frame(width: 20)

                // End time marker and slider
                HStack(spacing: 6) {
                    Image(systemName: "arrowtriangle.left.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.red)
                    Text("End")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(formatTime(endTime))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.red)
                        .frame(width: 40, alignment: .trailing)
                }

                Slider(value: $endTime, in: 0...duration)
                    .controlSize(.mini)
                    .tint(.red)
                    .onChange(of: endTime) { newValue in
                        // Ensure end time doesn't go below start time
                        if newValue <= startTime {
                            endTime = min(duration, startTime + 0.1)
                        }
                        // Trigger preview regeneration
                        onEndTimeChanged(endTime)
                    }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .onReceive(timer) { _ in
            updateTime()
        }
        .onAppear {
            updateDuration()
            observePlayerState()
        }
    }

    private func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime)
    }

    private func updateTime() {
        if !isDragging {
            currentTime = player.currentTime().seconds
        }
    }

    private func updateDuration() {
        if let currentItem = player.currentItem {
            duration = currentItem.duration.seconds
            if duration.isNaN || duration.isInfinite {
                duration = 1
            }
        }
    }

    private func observePlayerState() {
        // Loop video when it ends
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            // Seek back to beginning and continue playing
            player?.seek(to: .zero)
            player?.play()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "0:00" }
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// A simple video player view for previewing the source video
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        // Create container
        let containerView = ScrollPassthroughContainer()

        // Create the custom player view
        let playerView = NonScrubbableAVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .none  // Disable built-in controls
        playerView.showsFullScreenToggleButton = false
        playerView.containerView = containerView

        // Add player to container
        containerView.addSubview(playerView)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: containerView.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])

        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let containerView = nsView as? ScrollPassthroughContainer,
           let playerView = containerView.subviews.first as? NonScrubbableAVPlayerView {
            playerView.player = player
        }
    }
}
