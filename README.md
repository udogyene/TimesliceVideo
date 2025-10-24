# TimesliceVideo

A native macOS application for creating timeslice video effects, where each vertical column in the output represents a different moment in time from the original video.

## Features

- **Timeslice Effect**: Transform videos by sampling vertical columns across time
- **Real-time Preview**: See exactly what your output will look like before processing
- **Adjustable Parameters**:
  - Start/End time selection
  - Speed factor (1x - 10x)
  - Custom time range selection
- **Optimized Performance**: Ultra-fast preview generation using AVAssetReader and direct pixel buffer access
- **Native macOS Design**: Clean SwiftUI interface with native controls

## Requirements

- macOS 12.0+
- Xcode 13.4.1+
- Swift 5.0+

## How It Works

The timeslice effect works by:
1. Extracting a single vertical column (default: middle column) from each frame in the selected time range
2. Applying the speed factor by sampling frames at intervals (e.g., 2x speed = every 2nd frame)
3. Assembling these columns horizontally into a single output image

This creates a unique visual effect where motion in the video appears "stretched" horizontally, with time represented spatially across the width of the image.

## Architecture

The project follows a clean MVVM architecture:

- **Models**: `VideoParameters.swift` - Data models for video metadata and processing parameters
- **ViewModels**: `VideoProcessorViewModel.swift` - Business logic and state management
- **Views**: `ContentView.swift` - SwiftUI user interface
- **Services**:
  - `VideoLoader.swift` - Async video loading and metadata extraction
  - `PreviewGenerator.swift` - Optimized timeslice preview generation

## Performance Optimizations

The preview generation is highly optimized using:
- **AVAssetReader** for sequential frame access
- **Direct pixel buffer manipulation** for column extraction
- **Frame skipping** based on speed factor
- **Pre-allocated buffers** for efficient memory usage
- **BGRA pixel format** with proper color channel handling

Typical performance:
- 2-3 second video: ~100-300ms
- 5 minute video at 1x speed: ~1-2 seconds

## Usage

1. Launch the application
2. Click "Select Video File" and choose a video
3. Adjust the time range and speed factor using the sliders
4. Watch the preview update in real-time (with 500ms debouncing)
5. Click "Generate Output" to process the full video (coming soon)

## License

MIT License - feel free to use and modify as needed.

## Credits

Built with Swift, SwiftUI, and AVFoundation.
