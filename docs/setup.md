# Setup

## Requirements

- macOS 15 or later.
- To build: a Swift 6 toolchain (Xcode 16 or later).
- A go2rtc server on your home network with an API username and password.
- For pan and tilt: the patched `go2rtc-xiaomi-control` build from [moguennouni/homebridge-xiaomi-go2rtc](https://github.com/moguennouni/homebridge-xiaomi-go2rtc), which adds `POST /api/xiaomi/command`. Video alone works with stock go2rtc 1.9.14.

**If go2rtc runs in Docker, use `network_mode: host`.** The camera answers go2rtc's first UDP packet from a different port, and Docker's bridge network drops that reply. The symptom is `streams: read udp ...: i/o timeout` even though the camera answers ping.

## Build and install

```bash
scripts/build-app.sh --install
```

This builds `Xiaomi Sentry.app`, moves it to `/Applications` and starts it. Use `--open` instead to run it from `build/` without installing.

The app is signed with your Apple Development certificate if you have one, otherwise ad hoc. No paid developer account is needed. To pin one certificate, put its name or SHA-1 from `security find-identity -v -p codesigning` in a `.signing-identity` file at the repo root. With ad hoc signing, macOS may ask for Local Network access again after a rebuild.

A copy built on your own Mac opens without a Gatekeeper warning. A downloaded copy needs System Settings → Privacy & Security → Open Anyway once.

## First run

1. Click the menu bar icon. When macOS asks for Local Network access, allow it, or the app cannot reach go2rtc.
2. Enter the go2rtc address, port, API user and password. Use an IP address, a `.local` name or a one-word host name: macOS blocks plain HTTP to other host names.
3. If go2rtc has no camera streams yet, log in to Xiaomi once in the go2rtc web page. Then pick your Xiaomi region and press **Add from Xiaomi**. This adds one stream per camera to go2rtc's config.

## Controls

- Menu bar icon: show or hide the window. Esc also hides it.
- Opening the app again from Finder or Spotlight shows the window, even when the notch hides the icon.
- Drag the window to move it. Drag its bottom-right corner to resize it. Size and position are remembered.
- Left key: pan. Right key: tilt. Arrow keys work too. Hold to keep moving.
- Round chip, dots or keys 1 to 9: switch camera.
- Right-click the icon: cameras, appearance, open at login, settings, reconnect, quit.

The stream stays open for 60 seconds after you hide the window, so a quick reopen is instant. A new connection takes a few seconds, because go2rtc fetches keys from the Xiaomi cloud and waits for a keyframe.

## Development

```bash
swift test                                          # demuxer, decoding and API tests
swift run XiaomiSentry --snapshot docs/screenshots  # regenerate the README screenshots
```

`Sources/SentryCore` holds the go2rtc client, the fMP4 demuxer and the pan reply parser. `Sources/XiaomiSentry` is the app. Test fixtures are short, silent test patterns.
