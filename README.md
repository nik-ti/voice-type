# VoiceType

VoiceType is a macOS menu-bar dictation app. Hold a hotkey, speak, and release to copy and paste the result into the app where you started recording. Speech recognition and polishing run locally; model downloads need internet on first use.

## Using the app

- **Hold Fn:** record while held, release to finish.
- **Fn + Option:** lock recording; press Option alone, Escape, or the indicator's stop button to finish. Fn + Space is also a lock toggle.
- **Option + Space:** alternative hold-to-record shortcut; releasing either key stops recording.
- **Toggle mode:** press Option + Space to start or stop.
- The floating waveform appears as soon as startup begins. Start speaking after the audible cue, which means the microphone is ready.
- **Regular mode** uses deterministic text cleanup after recognition.
- **Polished mode** gives the raw recognized speech to Qwen3 8B, running locally. The model decides punctuation, grammar, numbers (“the first part” stays a word, “fourteen hundred dollars” becomes $1,400), self-corrections, numbered lists and paragraphs. It is taught by the instructions and worked examples in `CleanupInstructions.swift`, not by regex rules. If the model is not ready, busy or too slow, you get the Regular-mode text instead. The model is a 4.6 GB download on first use.
- Completed prose is copied with one trailing space so the next dictation does not run into it. History stays clean. Literal filenames are copied without a forced sentence period.
- Spoken filenames and commands (`package dot json`, `Cloud. Md.` → `CLAUDE.md`), `quote … end quote`, “new line” and “new paragraph” are handled by the model in Polished mode.
- Clear spoken enumerations (“number one… number two…”, “first… second… third…”, in English or Russian) become numbered lists in Polished mode. Ordinary sentences such as “my number one priority” stay prose.
- English and Russian are supported; Parakeet v3 supports additional European languages. Quality varies by language and microphone.

Grant Microphone and Accessibility permission when requested. If automatic paste is unavailable, the text stays on the clipboard for Command+V. Switching to another app during processing intentionally leaves the text copied instead of typing into the wrong app.

Input selection is in Preferences. Auto follows the input selected in macOS System Settings. Choosing a microphone in VoiceType changes the Mac's default input once; the app does not switch it back and forth for every take. If the input changes during a take, VoiceType finishes that take using audio already captured; start a new recording for the new device.

Preferences also has a **Recognition language** selector: Auto (the default), English, or Russian. Choose English to reduce Cyrillic guesses on short technical phrases such as `spec.py`; use Auto for mixed-language speech. The fixed choices prefer Latin or Cyrillic letters, so foreign names and filenames can be affected. This is a recognition hint, not a guarantee of correct spelling. Each recording keeps the language selected when it starts.

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
- Optional polishing has a **waiting limit** of 3 seconds plus 50 ms per dictated word (at most 12 seconds), separate from the lifetime of model work. A timed-out worker stays unavailable until its GPU work finishes; requests never pile up behind it.
- The fixed instructions and examples are read by the model once and cached (`InstructionPromptCache.swift`); each take only processes its own words. This cut the average polish time from 1.9 s to about 0.9 s.
- The polish model's GPU buffer cache is capped at 128 MB and emptied after every take. Without this, MLX hoards freed buffers until it fills most of RAM (17 GB after a week), and the Mac's swapping slows everything. The app should stay near 2–3 GB; check with `footprint $(pgrep -f VoiceType.app/Contents/MacOS)`.
- The polish model warms after loading and when recording begins following at least a minute of model inactivity. There is no permanent keepalive timer. Active dictation uses a scoped macOS user-initiated activity.
- Recording retains all samples after readiness, with session IDs rejecting stale callbacks. Audio from different hardware rates is never joined.
- The redundant whole-recording VAD pass was removed to avoid a second serial model pass after release.
- Clipboard delivery precedes SQLite writes. History updates insert the new entry in memory instead of rereading the database each time.
- Paste requires event permission, the original target app in front, and unchanged clipboard ownership. Events are posted once; macOS provides no universal confirmation that another application inserted the text.

The waiting limit is for polishing, **not a promise for total transcription time**. Recognition depends on take length, hardware and system load. Real microphone, idle and sleep/wake latency must be tested on the user's desktop.

The speech model remains Parakeet v3, using the rebuilt linear INT8 encoder (`int8V2`) that fixes a documented upstream token-corruption case. Model downloads are automatic; the new grammar weights are approximately 2.3 GB and the rebuilt speech encoder approximately 0.6 GB. [Quality checks and model research](docs/DICTATION_QUALITY.md) explain what was measured and what remains unverified.

In Regular mode, duration phrases are protected before native number normalization: `ten second video` becomes `10-second video`, rather than the incorrect `12th video`. Polished mode skips the native normalizer and lets the model write numbers.

## Diagnostics

```sh
log stream --style compact --predicate 'subsystem == "com.nikti.VoiceType"'
```

Application timing logs contain build identity, session IDs, stage times and fallback events, without dictated text. Compare `audio_conversion`, `speech_recognition`, `basic_cleanup`, `polishing`, `delivery`, and `history` when a delay returns. A `paste_event_posted` message means a keyboard event was sent, not that insertion was verified.

`polish_fallback_reason=…` distinguishes a model that is not ready, a busy worker, a deadline/generation failure, an empty reply, and a reply far longer than the dictation (`answered_instead`). `polish_gpu_memory` reports active and cached GPU memory after each take.

History remains in `~/Library/Application Support/VoiceType/history.sqlite`; it is not deleted or migrated by this repair. History export and search remain available from the menu.

## Code map

| Location | Responsibility |
| --- | --- |
| `Sources/VoiceType/AppDelegate.swift` | Hotkeys and recording indicator |
| `Sources/VoiceType/ViewModels/AppState.swift` | Session coordination, delivery, history |
| `Sources/VoiceType/Services/AudioCaptureService.swift` | Microphone startup and routing |
| `Sources/VoiceType/Services/TranscriptionService.swift` | FluidAudio Parakeet v3 recognition |
| `Sources/VoiceType/Services/LLM/LLMService.swift` | Qwen loading, warmup, bounded polishing |
| `Sources/VoiceType/Services/LLM/CleanupInstructions.swift` | What the model is told to do, with worked examples |
| `Sources/VoiceTypeCore/` | Testable session, deadline, audio and cleanup behavior |
| `Tests/` | Regression checks, the cleanup comparison, and packaging failure tests |
| `SPEC.md` | Repair contract and current verification status |
| `HOW_IT_WORKS.md` | Plain-language architecture reference |

The automated suite checks cleanup, cancellation, overlapping work, audio accumulation, paste preconditions and packaging failure. Live microphone routing and insertion into third-party apps still need desktop checks.
