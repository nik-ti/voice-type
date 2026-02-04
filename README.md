# VoiceType

A fast, local speech-to-text macOS menu bar app using the Parakeet-TDT 0.6B Core ML model. Runs fully locally on Apple Silicon with no network calls for transcription.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1+-green)
![License](https://img.shields.io/badge/License-MIT-yellow)

## Features

- 🎤 **Global hotkey transcription** - Press and hold `fn` to record, release to transcribe
- 🚀 **Fast, local transcription** - Uses Parakeet-TDT 0.6B via FluidAudio (no internet required)
- 🌍 **Multilingual** - Supports English and Russian
- 📋 **Auto clipboard** - Transcriptions automatically copied to clipboard
- 📝 **History** - All transcriptions saved locally with search and export
- 🎨 **Beautiful UI** - Clean floating indicator with audio level visualization

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (M1, M2, M3, M4)
- ~600MB disk space for the AI model (downloaded on first launch)

## Installation

### From Source

1. **Clone or download** this project

2. **Open in Xcode**
   ```bash
   open /Users/nikti/Documents/Projects/transcription_app/VoiceType.xcodeproj
   ```

3. **Wait for packages** - Xcode will automatically download the FluidAudio package

4. **Build and run** - Press `⌘R` or click the Play button

5. **Grant permissions** when prompted:
   - **Microphone**: Required for recording
   - **Accessibility**: Required for global hotkeys (will prompt on first hotkey use)

### Installing to /Applications

1. In Xcode, select **Product → Archive**
2. Click **Distribute App → Copy App**
3. Drag `VoiceType.app` to `/Applications`

## Usage

### Basic Workflow

1. **Launch VoiceType** - A microphone icon appears in your menu bar
2. **Hold `fn`** (or your configured hotkey) anywhere on your Mac
3. **Speak** - A floating indicator shows you're recording
4. **Release** - Your speech is transcribed and copied to clipboard
5. **Paste** - Use `⌘V` to paste (or enable auto-paste in preferences)

### Menu Bar

Click the menu bar icon to access:
- **Language selector** - Switch between English (🇺🇸) and Russian (🇷🇺)
- **Start/Stop Listening** - Manual control
- **History** - View past transcriptions
- **Preferences** - Configure hotkey, auto-paste, and more
- **Quit** - Exit the app

### Hotkey Options

Configure in Preferences:
- **Hold fn** (default) - Press and hold fn key
- **Hold ⌥ Space** - Press and hold Option+Space
- **Toggle mode** - Press once to start, press again to stop

## Preferences

| Setting | Description |
|---------|-------------|
| Language | Choose English or Russian |
| Auto-paste | Automatically paste after copying |
| Launch at login | Start VoiceType when you log in |
| Clear history | Delete all saved transcriptions |

## Data Storage

Transcriptions are stored locally at:
```
~/Library/Application Support/VoiceType/history.sqlite
```

The AI model is cached by FluidAudio at:
```
~/Library/Caches/FluidAudio/
```

## Troubleshooting

### "Accessibility access required"

1. Go to **System Settings → Privacy & Security → Accessibility**
2. Click the lock to make changes
3. Enable **VoiceType**

### "Microphone permission denied"

1. Go to **System Settings → Privacy & Security → Microphone**
2. Enable **VoiceType**

### Model loading takes a long time

The first launch downloads the Parakeet-TDT model (~600MB). Subsequent launches will be much faster.

### Hotkey doesn't work

1. Ensure Accessibility permission is granted
2. Check if another app is using the same hotkey
3. Try a different hotkey mode in Preferences

## Architecture

```
VoiceType/
├── VoiceTypeApp.swift      # Main entry point
├── AppDelegate.swift        # Global hotkey & floating window
├── Info.plist               # App configuration
├── VoiceType.entitlements   # Permissions
│
├── Models/
│   └── Transcription.swift  # Data model
│
├── Services/
│   ├── AudioCaptureService.swift    # Microphone recording
│   ├── TranscriptionService.swift   # FluidAudio/Parakeet
│   └── PersistenceService.swift     # SQLite storage
│
├── Views/
│   ├── MenuBarView.swift      # Menu dropdown
│   ├── FloatingIndicator.swift # Recording bubble
│   ├── HistoryView.swift       # History window
│   └── PreferencesView.swift   # Settings
│
└── ViewModels/
    └── AppState.swift         # Shared state
```

## Technologies

- **Swift 5** + **SwiftUI**
- **AVAudioEngine** - Audio capture
- **FluidAudio** - Core ML model wrapper
- **Parakeet-TDT 0.6B v3** - NVIDIA's multilingual ASR model
- **SQLite** - Local history storage

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference
- [Parakeet-TDT](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA
