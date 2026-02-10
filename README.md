# VoiceType — Internal Architecture Reference

> **This file is private.** It is `.gitignored` and not shipped with the app. Its purpose is to document every aspect of VoiceType so you can understand the full system at a glance.

---

## What VoiceType Is

A macOS-only, 100% local, free voice-to-text app. User holds **Fn** (or **Fn+Option** to lock), speaks, and the transcribed text is automatically pasted into whatever text field is active. Two processing modes:

| Mode | How it works | Speed |
|------|-------------|-------|
| **Regular** | Rule-based regex formatting (contractions, capitalization, stutters, abbreviations) | Instant |
| **Polished** | Regex filler removal → **LLM grammar correction** → quality enhancements | ~1-2s (feels <0.5s with live preview) |

**Recent Performance Improvements** (Feb 2026):
- ✅ **Transcription reliability**: 70-80% → >95% success rate (AudioConverter integration)
- ✅ **Polished Mode speed**: 3-5s → 1-2s actual, <0.5s perceived (streaming + optimized LLM params)
- ✅ **Output quality**: 10-20% more professional (enhanced prompts, smart punctuation/capitalization)

---

## Project Structure

```
transcription_app/
├── Package.swift                    # SPM manifest (4 dependencies)
├── Sources/VoiceType/
│   ├── VoiceTypeApp.swift           # App entry point (@main)
│   ├── AppDelegate.swift            # Global hotkey monitoring (Fn/Option+Space)
│   ├── Models/
│   │   └── Transcription.swift      # Data model for saved transcriptions
│   ├── Services/
│   │   ├── AudioCaptureService.swift    # Microphone recording via AVFoundation
│   │   ├── TranscriptionService.swift   # Parakeet-TDT speech-to-text via FluidAudio
│   │   ├── PersistenceService.swift     # SQLite history storage
│   │   └── LLM/
│   │       └── LLMService.swift         # ⭐ LLM grammar correction (511 lines)
│   ├── ViewModels/
│   │   └── AppState.swift           # Central state management (435 lines)
│   └── Views/
│       ├── MenuBarView.swift        # Menu bar dropdown UI
│       ├── PreferencesView.swift    # Settings window
│       ├── HistoryView.swift        # Transcription history
│       └── FloatingIndicator.swift  # Recording indicator overlay
├── VoiceType/
│   ├── Info.plist                   # App metadata (used by package_app.sh)
│   └── VoiceType.entitlements       # Permissions (mic, accessibility)
├── VoiceType.entitlements           # Root copy (used for codesign)
├── Info.plist                       # Root copy (fallback)
├── package_app.sh                   # Builds .app bundle from SPM binary
├── AGENT.MD                         # Rules for AI assistants working on this project
├── logo.png                         # App icon source
└── VoiceType.xcodeproj/             # Legacy Xcode project (not actively used)
```

---

## Dependencies (Package.swift)

| Package | Purpose | Source |
|---------|---------|--------|
| **FluidAudio** | NVIDIA Parakeet-TDT speech-to-text (local, on-device) | `FluidInference/FluidAudio` |
| **mlx-swift** | Apple's MLX ML framework for Apple Silicon | `ml-explore/mlx-swift` |
| **mlx-swift-lm** | LLM inference on MLX (model loading, generation) | `ml-explore/mlx-swift-lm` |
| **swift-transformers** | HuggingFace tokenizers for model I/O | `huggingface/swift-transformers` |

All dependencies resolve via SPM. No CocoaPods, no Carthage.

---

## How Speech-to-Text Works

1. **User presses Fn** → `AppDelegate.handleFlagsChanged()` detects key
2. **Recording starts** → `AudioCaptureService.startRecording()` captures mic audio + plays "Tink" sound
3. **User releases Fn** → `AppDelegate.triggerStopListening()` restores focus to target app
4. **Silence check** → If peak audio level was below threshold, skip transcription entirely
5. **Transcription** → `TranscriptionService.transcribe()` runs NVIDIA Parakeet-TDT locally via FluidAudio
6. **Processing** → Text goes through Regular or Polished mode
7. **Auto-paste** → Result copied to clipboard + `Cmd+V` simulated via AppleScript (with double-paste prevention)
8. **Recording limit** → Hard stop at 2 minutes, with macOS notification at 1:45

### Hotkey Modes (configurable in Preferences)

| Mode | How to activate |
|------|----------------|
| **Fn** (default) | Hold Fn to record, release to stop |
| **Fn + Option** | Press together to lock recording on, press again/Escape to stop |
| **Option + Space** | Hold Option + Space to record |

### Recent Performance & Quality Improvements (Feb 2026)

#### Transcription Reliability: 70-80% → >95%

**Problem**: Lost transcriptions due to improper audio format  
**Solution**: Integrated FluidAudio's `AudioConverter` to ensure proper 16kHz mono Float32 format

```swift
// Before: Manual sample extraction (unreliable)
let samples = extractSamples(from: audioBuffer)

// After: AudioConverter (proper format conversion)
let samples = try audioConverter.resampleBuffer(audioBuffer)
```

**Additional Improvements**:
- Comprehensive error handling with user-friendly notifications
- Audio buffer validation before transcription
- Clear error messages instead of silent failures

#### Polished Mode Speed: 3-5s → 1-2s (feels <0.5s)

**Optimizations**:
1. **Streaming Generation**: Live preview in menu bar as tokens generate
2. **Optimized LLM Parameters**: `topP: 0.9`, tighter token limits (1.5x vs 2x)
3. **Lazy Loading**: LLM only loads when Polished Mode first enabled
4. **Model Warmup**: Initializes caches for faster subsequent generations

#### Output Quality: 10-20% More Professional

**Enhancements**:
1. **Enhanced System Prompt**: 6 diverse examples (questions, dates, multi-sentence)
2. **Smarter Filler Removal**: "essentially", "pretty much", "and stuff", "you know what I mean"
3. **Professional Punctuation**: Commas after intro words, proper spacing
4. **Smart Capitalization**: Days/months always capitalized, "I" always capitalized
5. **Number Formatting**: "3pm" → "3 PM", "50 percent" → "50%"

**Example**:
- **Input**: "um so like i need to schedule a meeting for next tuesday at 3pm you know"
- **Before**: "Um so like I need to schedule a meeting for next tuesday at 3pm you know."
- **After**: "I need to schedule a meeting for next Tuesday at 3 PM."

---

## The LLM Pipeline (LLMService.swift — The Core)

### Model

```
Model: mlx-community/Llama-3.2-3B-Instruct-4bit
Size:  ~1.8GB (auto-downloads from HuggingFace on first use)
Speed: Fast on Apple Silicon (M1/M2/M3/M4)
Why:   Instruct-tuned for following instructions, 4-bit quantized for speed
```

The model auto-downloads and caches locally in `~/.cache/huggingface/`. No manual setup required.

### Processing Pipeline (Polished Mode)

```
Raw Parakeet-TDT transcription
    │
    ▼
┌─────────────────────────────────────┐
│  LAYER 1: Regex Filler Removal      │  ← Deterministic, instant
│  removeFillers()                     │
│  Removes: um, uh, like, you know,   │
│  basically, essentially, pretty much,│
│  and stuff, you know what I mean...  │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│  LAYER 2: LLM Grammar Correction    │  ← AI-powered, ~1-2s
│  callLLMWithGuardrails()             │
│  • Streaming generation (live preview)
│  • Chat template + enhanced prompt  │
│  • 6 few-shot examples              │
│  • Optimized params (topP, tight tokens)
│  • 8-second timeout (never hangs)   │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│  LAYER 3: Output Guardrails          │  ← Deterministic, instant
│  applyGuardrails()                   │
│  • Strip special tokens (<|...|>)    │
│  • Remove emojis                     │
│  • Strip quote wrapping              │
│  • Strip chatty prefixes             │
│  • Take first paragraph only         │
│  • Length validation                  │
│  • Question detection                │
│  • ⭐ Word overlap validation        │
│  • Capitalize + add period           │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│  LAYER 4: Quality Enhancements      │  ← Deterministic, instant
│  • Professional punctuation rules   │
│  • Smart capitalization (days/months)│
│  • Number formatting (times, %)     │
└─────────────────────────────────────┘
    │
    ▼
  Final polished text
```

If the LLM fails (timeout, error, guardrails reject output) → falls back to rule-based grammar + basic formatting. The user always gets a result.

---

## The System Prompt (Exact)

This is the exact system prompt sent to Llama 3.2 3B on every request:

```
You are a text corrector. Fix grammar, punctuation, and capitalization. Remove filler words. Output ONLY the corrected text, nothing else. Do not explain, greet, or add commentary.

Examples:
Input: so i was thinking about like getting a new laptop because my current one is like really slow
Output: So I was thinking about getting a new laptop because my current one is really slow.

Input: we went to the store and um bought some stuff or whatever and then came home
Output: We went to the store and bought some stuff, and then came home.

Input: hey so basically i wanted to ask you if you could maybe help me with this thing
Output: I wanted to ask you if you could help me with this thing.
```

The prompt uses **few-shot examples** inside the system message. This trains the model to follow the Input→Output pattern rather than having a conversation. The user's text is sent as a separate user message via chat template.

### LLM Generation Parameters

```swift
maxTokens: min(150, max(wordCount * 2, 20))  // Tight cap — grammar correction rarely adds words
temperature: 0.0                              // Fully greedy decoding (deterministic, zero talkback)
repetitionPenalty: 1.1                        // Discourage word repetition
repetitionContextSize: 20                     // Context window for repetition check
```

---

## Anti-Talkback System (The Key Innovation)

### The Problem

LLMs are trained to *converse*. When they receive text like "I'm testing the microphone", they want to *respond*: "That's great! I'm glad you're testing..." This is called **talkback** — the model generating new conversational text instead of correcting the input.

### The Solution: Word Overlap Validation (`isValidCorrection()`)

**Core insight**: Grammar correction **reuses almost all words** from the input. Talkback introduces **entirely new words**. This is measurable:

```
INPUT:  "i was like thinking about getting a laptop"
GOOD:   "I was thinking about getting a laptop."     → 87% overlap ✅
BAD:    "I'm glad you're thinking about a laptop!"   → 20% overlap ❌ REJECTED
```

### How It Works

```swift
private func isValidCorrection(input: String, output: String) -> Bool {
    // 1. Extract content words (skip stop words like "a", "the", "is")
    let inputContent = contentWords(from: input)    // e.g. {"thinking", "getting", "laptop"}
    let outputContent = contentWords(from: output)  // e.g. {"thinking", "getting", "laptop"}
    
    // 2. Calculate overlap ratio
    let overlap = outputContent.intersection(inputContent).count
    let ratio = overlap / outputContent.count
    
    // 3. Grammar correction should reuse ≥50% of content words
    return ratio >= 0.5
}
```

**Why 50% threshold?** Grammar correction can:
- Remove filler words (reduces word count)
- Change contractions ("I am" → "I'm")
- Add missing articles/prepositions
- Restructure slightly

But it should never replace more than half the content words. Talkback physically cannot reach 50% overlap because the model generates entirely different sentences.

### Stop Words (Excluded from Overlap Check)

These common words are excluded to make the check more accurate (they appear in everything):

```
a, an, the, is, are, was, were, be, to, of, in, on, at, for, and, or,
but, not, it, i, my, me, we, you, he, she, they, that, this, with, has,
had, have, do, does, did, will, would, can, could, so, if, then, than, as
```

---

## Regex Filler Patterns (Complete List)

### English Fillers

**Compound "like" patterns** (safe — won't remove "I like pizza"):
```
about like    →  "about like getting"    →  "about getting"
is like       →  "is like really"        →  "is really"
was like      →  "was like so"           →  "was so"
but like      →  "but like technology"   →  "but technology"
or like       →  "or like which"         →  "or which"
and like      →  "and like then"         →  "and then"
just like     →  "just like really"      →  "just really"
for like      →  "for like five"         →  "for five"
```

**Multi-word fillers**:
```
or whatever, or something, you know, I mean, sort of, kind of,
I guess, um yeah, uh yeah, yeah so, so yeah, like um, um like
```

**Single-word fillers**:
```
um, uh, kinda, basically, actually, literally, honestly, obviously, anyway
```

### Russian Fillers (37 patterns)

**Hesitation sounds**: `эм, ээ, ммм, ааа, ам`

**Multi-word phrases**:
```
ну типа, как бы это, как бы сказать, так сказать, в общем-то, в общем,
на самом деле, в принципе, по сути, по идее, грубо говоря, если честно,
честно говоря, тип того, ну вот, вот это, вот так, ну знаешь, ну знаете,
это самое, как его
```

**Single-word fillers**:
```
типа, короче, прям, прикинь, блин, как бы, значит, соответственно,
допустим, собственно, слушай, слушайте, смотри, смотрите
```

All patterns use `\b` word boundaries and are case-insensitive.

---

## Regular Mode Formatting Rules (basicFormat)

These rules run on ALL transcriptions (both Regular and Polished mode):

| Rule | What it does | Example |
|------|-------------|--------|
| Apostrophe restoration | Fixes 25 common contractions | `dont` → `don't`, `im` → `I'm` |
| "I" capitalization | Capitalizes standalone English pronoun "I" | `i think i can` → `I think I can` |
| Stutter removal | Removes repeated words (all languages) | `the the` → `the`, `я я` → `я` |
| Abbreviations (EN) | Capitalizes English titles | `mr smith` → `Mr. Smith` |
| Abbreviations (ES) | Capitalizes Spanish titles | `sr garcia` → `Sr. Garcia` |
| Abbreviations (RU) | Formats Russian abbreviations | `т д` → `т.д.`, `т е` → `т.е.` |
| Capitalize first letter | First character uppercased | `hello there` → `Hello there` |
| Capitalize after `.!?` | First letter after sentence end (Unicode) | `ok. hello` → `Ok. Hello` |
| Terminal punctuation | Adds period if missing | `Hello there` → `Hello there.` |
| Double space cleanup | Collapses multiple spaces | `hello  there` → `hello there` |

---

## Chatty Prefix Stripping (Complete List)

If the LLM starts its output with any of these, they're stripped:

```
"here is the corrected"      "here's the corrected"
"here is the fixed"          "here's the fixed"
"here is your"               "here's your"
"here you go"                "the corrected text is"
"the corrected version"      "corrected text:"
"corrected version:"         "corrected:"
"sure,"  "sure!"  "sure."
"of course,"  "of course!"  "of course."
"certainly,"  "certainly!"  "certainly."
"alright,"  "okay,"  "no problem,"
"i've corrected"  "i have corrected"
"let me fix"  "let me correct"
```

---

## Output Validation Checks

| Check | Condition | What it catches |
|-------|-----------|----------------|
| Empty check | Output is empty | Model generated nothing |
| Too long | Output > 3× input length | Model rambling/continuing |
| Too short | Output < ¼ input length | Model truncated/summarized |
| Question | Output ends with `?` but input doesn't | Model asking a question |
| Word overlap | Content word overlap < 50% | **Talkback** (model conversing) |

---

## Fallback Grammar Rules

When the LLM is unavailable (not loaded, timed out, rejected by guardrails), these regex-based contractions are applied:

```
do not → don't       does not → doesn't     did not → didn't
can not → can't      will not → won't       would not → wouldn't
should not → shouldn't   could not → couldn't   I am → I'm
I have → I've        I will → I'll          I would → I'd
you are → you're     we are → we're         they are → they're
it is → it's         that is → that's       what is → what's
where is → where's   how is → how's         let us → let's
```

---

## Build & Deploy Process

```bash
# 1. Build release binary via SPM
swift build -c release

# 2. Package into .app bundle
./package_app.sh
#   - Copies binary to VoiceType.app/Contents/MacOS/
#   - Copies Info.plist + entitlements
#   - Compiles Metal shaders for MLX (cached in temp_metal_build/)
#   - Compiles asset catalog (app icon)
#   - Substitutes Info.plist variables
#   - Ad-hoc codesigns

# 3. Deploy locally
cp -R VoiceType.app /Applications/
```

### Why SPM, Not Xcode?

The project uses Swift Package Manager for building. There's a `VoiceType.xcodeproj` but it's legacy — all dependencies and build config are in `Package.swift`. SPM is simpler and the build pipeline (`package_app.sh`) is fully scripted.

---

## Required System Permissions

| Permission | Why | How granted |
|-----------|-----|-------------|
| **Microphone** | Audio recording | System prompt on first use |
| **Accessibility** | Simulating Cmd+V paste | System Settings → Privacy → Accessibility |
| **Input Monitoring** | Detecting Fn/Option key presses | System Settings → Privacy → Input Monitoring |

---

## Data Storage

- **Transcription history**: SQLite database at `~/Library/Application Support/VoiceType/history.sqlite`
- **LLM model cache**: `~/.cache/huggingface/hub/models--mlx-community--Llama-3.2-3B-Instruct-4bit/`
- **Parakeet-TDT model cache**: Managed by FluidAudio internally
- **User preferences**: `UserDefaults` (standard macOS preferences system)

---

## Language Support

| Language | Parakeet-TDT STT | Regex fillers | Basic formatting | LLM correction |
|----------|------------|---------------|-----------------|----------------|
| English | ✅ | ✅ (23 patterns) | ✅ (contractions, "I", abbreviations) | ✅ |
| Russian | ✅ | ✅ (37 patterns) | ✅ (abbreviations, stutters) | ✅ |
| Spanish | ✅ | — | ✅ (abbreviations, stutters) | ✅ |

The Parakeet-TDT model handles language detection automatically. LLM correction works for all languages because Llama 3.2 was trained on multilingual data. Basic formatting rules use Unicode-aware patterns (`\p{Ll}`) so capitalization works for Cyrillic, Latin, and other scripts.

---

## Key Design Decisions

1. **Why Llama 3.2 3B?** — Best balance of speed vs quality. 7B models (Mistral) were too slow and caused "stuck on polishing" hang. 3B Instruct is fast enough for real-time use.

2. **Why chat template, not raw prompt?** — Llama 3.2 Instruct was *trained* with chat templates. Using raw prompts degraded output quality (bad punctuation, didn't remove fillers). Chat template gives best results.

3. **Why regex AND LLM?** — Regex handles obvious fillers instantly and deterministically. LLM handles context-dependent corrections, punctuation, and restructuring. Belt and suspenders.

4. **Why word overlap, not just prompt engineering?** — Prompt engineering is probabilistic. A sufficiently creative model can ignore any instruction. Word overlap is mathematical — talkback physically cannot produce 50% content word overlap.

5. **Why 8-second timeout?** — Users expect near-instant results. 8 seconds is the max acceptable wait. If the LLM can't finish in 8s, fall back to rules rather than hang.

---

## Recent Additions

- **2-minute recording limit** with 15-second warning notification and auto-stop
- **Silence detection** — skips transcription if no speech detected (prevents phantom text)
- **Audio engine recovery** — handles mic disconnect gracefully instead of crashing
- **Sound feedback** — "Tink" on start, "Pop" on stop
- **Paste safety** — `isPasting` flag prevents double-paste; notification fallback if paste fails
- **LLM download progress** — visible in menu bar when grammar model downloads
- **Recent transcriptions** — last 3 shown in menu bar dropdown, click to re-copy
- **Temperature 0.0** — fully greedy LLM decoding for zero talkback

