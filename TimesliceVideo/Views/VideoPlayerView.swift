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

/// Draggable range marker for start/end time
struct RangeMarker: View {
    let color: Color
    @Binding var position: Double
    let otherPosition: Double
    let isStart: Bool
    let duration: Double
    let sliderWidth: CGFloat
    let onChanged: (Double) -> Void

    @State private var isDragging = false

    var body: some View {
        let xPosition = CGFloat(position / duration) * sliderWidth

        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 6, height: 20)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white, lineWidth: 1)
            )
            .shadow(radius: 2)
            .offset(x: xPosition - 3)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let newPosition = Double(value.location.x / sliderWidth) * duration
                        let clampedPosition = max(0, min(duration, newPosition))
                        onChanged(clampedPosition)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
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

                // Progress slider with range markers
                GeometryReader { geometry in
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
                        .padding(.horizontal, 4)

                        // Range indicator overlay
                        // Add 4px padding on each side to prevent marker clipping
                        let sliderWidth = geometry.size.width - 8
                        let startX = CGFloat(startTime / duration) * sliderWidth + 4
                        let endX = CGFloat(endTime / duration) * sliderWidth + 4

                        // Range highlight
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: max(0, endX - startX), height: 4)
                            .offset(x: startX)
                            .allowsHitTesting(false)

                        // Start marker (green)
                        RangeMarker(
                            color: .green,
                            position: $startTime,
                            otherPosition: endTime,
                            isStart: true,
                            duration: duration,
                            sliderWidth: sliderWidth,
                            onChanged: { newValue in
                                if newValue < endTime - 0.1 {
                                    startTime = newValue
                                    onStartTimeChanged(newValue)
                                }
                            }
                        )
                        .offset(x: 4)

                        // End marker (red)
                        RangeMarker(
                            color: .red,
                            position: $endTime,
                            otherPosition: startTime,
                            isStart: false,
                            duration: duration,
                            sliderWidth: sliderWidth,
                            onChanged: { newValue in
                                if newValue > startTime + 0.1 {
                                    endTime = newValue
                                    onEndTimeChanged(newValue)
                                }
                            }
                        )
                        .offset(x: 4)
                    }
                }
                .frame(height: 20)

                // Duration
                Text(formatTime(duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Time labels
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.green)
                    Text("Start:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(formatTime(startTime))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.green)
                }

                Spacer()

                HStack(spacing: 6) {
                    Text("End:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(formatTime(endTime))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.red)
                    Image(systemName: "arrowtriangle.left.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.red)
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
            // If we're outside the range or at the end, start from beginning
            if currentTime < startTime || currentTime >= endTime {
                seek(to: startTime)
                currentTime = startTime
            }
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

            // Loop back to start time when reaching end time
            if currentTime >= endTime && isPlaying {
                seek(to: startTime)
                currentTime = startTime
            }
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
        // Loop video when it reaches the actual end
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [player, startTime] _ in
            // Seek back to start time and continue playing
            let cmTime = CMTime(seconds: startTime, preferredTimescale: 600)
            player.seek(to: cmTime)
            player.play()
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
