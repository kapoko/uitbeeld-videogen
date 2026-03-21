# uitbeeld-videogen

Generate a video from audio with CRT-style spectrum.

## Prerequisites
- `ffmpeg`
- `magick` (ImageMagick, only needed when using `-t`)

## Usage
```bash
./generate.sh -i "/path/to/input.mp3" -t "#1: THRASHIN' 1986"
```

- `-i` is required
- `-t` is optional (title text)
- `--bars-only` renders only `bars.mov` (skip compositing)
- `--compose-only` skips rendering and composes using existing `bars.mov`
- Output is written next to input as `.mp4`

If you use `-t`, keep `Kanit-Bold.ttf` in the same folder as `generate.sh`.

## Benchmark

Renders at about 0.5x speed on i9-9900K from 2018.
