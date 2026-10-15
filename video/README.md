# The Keepwatch tour video

An 85-second narrated tour of Keepwatch, built from the app's own screens.
Everything is made on this Mac: no account, no cloud service.

| Part | Tool | Source |
|---|---|---|
| Screens | Keepwatch itself, `--render-snapshots DIR --demo` | `DemoData` in `Sources/KeepwatchCore/DemoData.swift`: made-up sessions, apps and ports, so no one's real data is shown |
| Voice, captions, mix | [AgentSkillDeck audio](https://github.com/AgentSkillDeck/skills) (Supertonic 3, on device, every line checked by transcription) | `audio/tour.audio.md` |
| Music | "Soft Corporate" by MusicLFiles, CC BY 4.0 | `audio/sounds/soft-corporate.ogg.license.json` |
| Animation and render | [HyperFrames](https://github.com/heygen-com/hyperframes) (HTML + GSAP to MP4) | `build.py` writes `tour/index.html` from the voice's timeline |

## Rebuild

```sh
# 1. Screens (demo data only)
scripts/build-app.sh --arm64-only
dist/Keepwatch.app/Contents/MacOS/Keepwatch --render-snapshots /tmp/kw-snap --demo
mkdir -p video/tour/assets && cp /tmp/kw-snap/*-dark.png video/tour/assets/
cp Resources/AppIcon-1024.png video/tour/assets/icon.png

# 2. Music (CC BY 4.0, credit it wherever the video is published)
curl -L -o video/audio/sounds/soft-corporate.ogg \
  "https://upload.wikimedia.org/wikipedia/commons/5/5f/Soft_Corporate_by_MusicLFiles.ogg"

# 3. Voice: from the deck-voice skill folder of the AgentSkillDeck audio plugin
node scripts/produce.mjs "$PWD/video/audio/tour.audio.md" --out "$PWD/video/audio/final"
ffmpeg -i video/audio/final/mix.wav -b:a 160k video/tour/assets/tour.mp3

# 4. Composition and render
python3 video/build.py
cd video/tour && npx hyperframes check && npx hyperframes render --quality delivery --output renders/keepwatch-tour.mp4
```

Edit the words in `audio/tour.audio.md`; scene cuts and captions follow the new timing when you re-run steps 3 and 4.

## Credits

- Music: "Soft Corporate" by MusicLFiles (https://commons.wikimedia.org/wiki/File:Soft_Corporate_by_MusicLFiles.ogg), CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/).
- Voice: Supertonic 3 by Supertone Inc. (code MIT, weights OpenRAIL-M). An AI-generated voice, not a real person.
