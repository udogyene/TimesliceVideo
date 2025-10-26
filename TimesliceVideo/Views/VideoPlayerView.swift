//
//  VideoPlayerView.swift
//  TimesliceVideo
//
//  Created on 2025-10-25.
//

import SwiftUI
import AVKit
import AppKit

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

/// A simple video player view for previewing the source video
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        // Create container
        let containerView = ScrollPassthroughContainer()

        // Create the custom player view
        let playerView = NonScrubbableAVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
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
