# VoiceType

VoiceType is a macOS menu-bar dictation app. Hold a hotkey, speak, and release to copy and paste the result into the app where you started recording. Speech recognition and polishing run locally; model downloads need internet on first use.

## Using the app

- **Hold Fn:** record while held, release to finish.
- **Fn + Option:** lock recording; press Option alone, Escape, or the indicator's stop button to finish. Fn + Space is also a lock toggle.
- **Option + Space:** alternative hold-to-record shortcut; releasing either key stops recording.
- **Toggle mode:** press Option + Space to start or stop.
- The floating waveform appears as soon as startup begins. Start speaking after the audible cue, which means the microphone is ready.
- **Regular mode** uses deterministic text cleanup after recognition.
- **Polished mode** additionally uses Qwen3 0.6B to clean longer takes. Short takes use rules; unavailable, busy, slow, or rejected model output falls back to rules.
- English and Russian are supported; Parakeet v3 supports additional European languages. Quality varies by language and microphone.

Grant Microphone and Accessibility permission when requested. If automatic paste is unavailable, the text stays on the clipboard for Command+V. Switching to another app during processing intentionally leaves the text copied instead of typing into the wrong app.

Input selection is in Preferences. Auto follows the input selected in macOS System Settings. Choosing a microphone in VoiceType changes the Mac's default input once; the app does not switch it back and forth for every take. If the input changes during a take, VoiceType finishes that take using audio already captured; start a new recording for the new device.

## Build and run

Requires Apple Silicon, macOS 14+, a compatible Xcode/Swift toolchain, and Apple's Metal compiler tools.

```sh
swift test --disable-automatic-resolution
python3 -m unittest discover -s Tests/PackagingTests
./package_app.sh
open /Applications/VoiceType.app
```

An opt-in installed-model smoke test is documented in [SPEC.md](SPEC.md). It uses a caller-supplied audio file and the packaged Metal library; it never opens the microphone or types into another app.

The packaging script builds release code first, uses the checked-in dependency resolution, compiles matching Metal shaders, validates resources and the signature, quits any running copy, and then installs the app to `/Applications/VoiceType.app` (open it from Launchpad, Spotlight, or the Applications folder). The previous app is retained under `.build/VoiceType.previous.<build-id>.app`. A failed build keeps the installed app intact.

Local builds are ad-hoc signed. macOS may require you to re-enable Accessibility access after replacing the app. The bundle's `VoiceTypeBuildID` identifies its source revision and build time.

## Latency and reliability

The pipeline is: stop capture → resample → speech recognition → basic cleanup → optional polish → copy/paste → save history.

- One session owns startup, recording and processing. Releasing the hotkey during startup cancels it; a second start cannot overlap a pending result.
- Start and stop cues play on the active output device. The recording waveform is a non-activating panel that follows the active screen and can appear above other apps and full-screen spaces.
- Audio capture follows one stable system input for the whole take. VoiceType no longer changes the default input at recording start and restores it during Core Audio teardown.
- Optional polishing has a two-second **waiting budget**, separate from the lifetime of model work. A timed-out worker stays unavailable until its GPU work finishes; requests never pile up behind it.
- The polish model warms after loading and when recording begins following at least a minute of model inactivity. There is no permanent keepalive timer. Active dictation uses a scoped macOS user-initiated activity.
- Recording retains all samples after readiness, with session IDs rejecting stale callbacks. Audio from different hardware rates is never joined.
- The redundant whole-recording VAD pass was removed to avoid a second serial model pass after release.
- Clipboard delivery precedes SQLite writes. History updates insert the new entry in memory instead of rereading the database each time.
- Paste requires event permission, the original target app in front, and unchanged clipboard ownership. Events are posted once; macOS provides no universal confirmation that another application inserted the text.

Two seconds is the polish budget, **not a promise for total transcription time**. Recognition depends on take length, hardware and system load. Real microphone, idle and sleep/wake latency must be tested on the user's desktop.

## Diagnostics

```sh
log stream --style compact --predicate 'subsystem == "com.nikti.VoiceType"'
```

Application timing logs contain build identity, session IDs, stage times and fallback events, without dictated text. Compare `audio_conversion`, `speech_recognition`, `basic_cleanup`, `polishing`, `delivery`, and `history` when a delay returns. A `paste_event_posted` message means a keyboard event was sent, not that insertion was verified.

History remains in `~/Library/Application Support/VoiceType/history.sqlite`; it is not deleted or migrated by this repair. History export and search remain available from the menu.

## Code map

| Location | Responsibility |
| --- | --- |
| `Sources/VoiceType/AppDelegate.swift` | Hotkeys and recording indicator |
| `Sources/VoiceType/ViewModels/AppState.swift` | Session coordination, delivery, history |
| `Sources/VoiceType/Services/AudioCaptureService.swift` | Microphone startup and routing |
| `Sources/VoiceType/Services/TranscriptionService.swift` | FluidAudio Parakeet v3 recognition |
| `Sources/VoiceType/Services/LLM/LLMService.swift` | Qwen loading, warmup, bounded polishing |
| `Sources/VoiceTypeCore/` | Testable session, deadline, audio and cleanup behavior |
| `Tests/` | Regression checks and packaging failure tests |
| `SPEC.md` | Repair contract and current verification status |
| `HOW_IT_WORKS.md` | Plain-language architecture reference |

The automated suite checks cleanup, cancellation, overlapping work, audio accumulation, paste preconditions and packaging failure. Live microphone routing and insertion into third-party apps still need desktop checks.
