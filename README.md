# NaughtScribe

A native macOS app that transcribes audio files on your Mac, using Apple's on-device speech engines. Requires macOS 26.

- **Apple Speech** (`SpeechAnalyzer`) needs a Mac with Apple silicon. It is used first.
- **Apple Speech (Legacy)** (`SFSpeechRecognizer`) is used automatically on Intel Macs. It runs on-device only and is less accurate. The app asks for Speech Recognition permission on the first transcription. Each language must have on-device Dictation installed (System Settings > Keyboard > Dictation).


<img width="2024" height="1424" alt="naughtscribe-20261024" src="https://github.com/user-attachments/assets/9d88be04-5dbd-4b80-842a-5d2cb5ecc012" />



## Usage

- Drop an audio file on the NaughtScribe window, or on its icon in the Dock or in the Applications folder.
- Each file becomes a transcript in the sidebar, with the date and time it was added. The text appears when transcription finishes.
- Search the sidebar to find transcripts by their text.
- Right-click a transcript to delete it.
- Choose the engine and the transcription language in Settings (⌘,). The defaults are Automatic and the system language.
- If the app quits during a transcription, that transcript is marked as failed.

Transcripts are stored as one JSON file each in `~/Library/Containers/com.naughtscribe.app/Data/Library/Application Support/NaughtScribe/Transcripts/`.

## Building

Requires Xcode 26 (Swift 6.2 or later) on macOS 26.

```bash
make            # build build/NaughtScribe.app (release, ad-hoc signed)
make run        # build and open the app
make install    # copy the app to /Applications
make clean      # remove build outputs
```

The app is ad-hoc signed, so it runs on the machine that built it.
