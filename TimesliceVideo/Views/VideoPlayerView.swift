//
//  VideoPlayerView.swift
//  TimesliceVideo
//
//  Created on 2025-10-25.
//

import SwiftUI
import AVKit
import AppKit

/// A simple video player view for previewing the source video
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
