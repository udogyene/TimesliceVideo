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

/// Custom video player controls
struct VideoPlayerControls: View {
    let player: AVPlayer
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var isDragging = false

    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
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

            // Progress slider
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

            // Duration
            Text(formatTime(duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
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
