# uitbeeld-videogen

Generate a video from audio with CRT-style spectrum.

## Prerequisites
- `ffmpeg`
- `curl`
- `python3`

## Usage
```bash
./generate.sh -i "/path/to/input.mp3" -t "The Handmaiden 2016"
```

Use a manual poster instead of TMDB:
```bash
./generate.sh -i "/path/to/input.mp3" -p "/path/to/poster.jpg"
```
Or pass a direct image URL:
```bash
./generate.sh -i "/path/to/input.mp3" -p "https://example.com/poster.jpg"
```

- `-i` is required
- `-t` is optional (movie title, used for TMDB poster lookup)
- `-p` is optional (poster path or image URL, overrides TMDB lookup)
- `--preset` sets x264 preset for final encode (default: `veryfast`)
- `--benchmark` prints ffmpeg timing stats for each render step
- Rendering/compositing runs in one pass (no intermediate `bars.mov`)
- Output is written next to input as `.mp4`

## TMDB API key
- On first `-t` run, if `./.env` is missing or has no `TMDB_API_KEY`, the script prompts for it and creates `./.env`.
- Later runs load `TMDB_API_KEY` from `./.env` automatically.

## Benchmark

Renders at about 0.5x speed on i9-9900K from 2018.
