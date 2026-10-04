# Sprout README animation

A 12-second silent loop composed and rendered with [HeyGen Hyperframes](https://hyperframes.heygen.com/). The screenshots come from Sprout's actual Flutter UI with synthetic activities and sessions. Personal Toggl exports are never used in these assets.

## Reproduce

Requirements: Node.js 22+, FFmpeg, and the Chromium dependencies used by Hyperframes. The CLI is pinned to **0.8.121** in `package.json`.

From this directory:

```sh
npm run check
npx --yes hyperframes@0.8.121 snapshot --at 1,6,11
npm run render -- -o renders/sprout.mp4 --fps 24 --quality high
ffmpeg -y -i renders/sprout.mp4 -filter_complex '[0:v]fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle' -loop 0 ../sprout-demo.gif
```

`index.html` contains the main composition. `compositions/components/browser-device-stage.html` is the Hyperframes registry device-stage component, with its duration extended to 12 seconds and its screen restored at the end for looping. The screenshot transition shows tracking and reports.

To refresh app screenshots from the repository root:

```sh
SPROUT_SCREENSHOTS=1 flutter test test/screenshots_test.dart
```

Copy `docs/screenshots/desktop-track.png`, `desktop-reports.png`, and `phone-track.png` into `assets/` before rendering. Fonts, GSAP and images are local assets so the composition does not rely on CDN loading.

See [NOTICE.md](NOTICE.md) for third-party licensing. Build outputs, snapshots, browser caches and `node_modules` are ignored by Git.
