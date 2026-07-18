# Crates iOS

An independent native iPhone proof of concept for [Crates](https://crates.co). It is not the official app: the goal here is narrower—make an existing Crates library comfortable to browse, search, and play from a phone while the desktop app remains the place to manage it.

Early POC; expect rough edges and breaking changes.

## Features

- Pair with a Crates server over a local network or Tailscale, including MagicDNS names.
- Browse and search a cache-first library, including while offline.
- Stream or download audio with background and system Now Playing support.
- Build an on-device queue with Play Next and Add to Queue swipe actions.

## Demo

[Watch the simulator walkthrough (MP4)](Media/crates-ios-demo.mp4)

<table>
  <tr>
    <td><img src="Media/Screenshots/01-home.png" alt="Home" width="220"></td>
    <td><img src="Media/Screenshots/02-crate-detail.png" alt="Crate detail" width="220"></td>
    <td><img src="Media/Screenshots/06-now-playing.png" alt="Now Playing" width="220"></td>
  </tr>
  <tr>
    <td><img src="Media/Screenshots/04-play-next-swipe.png" alt="Play Next swipe action" width="220"></td>
    <td><img src="Media/Screenshots/05-add-to-queue-swipe.png" alt="Add to Queue swipe action" width="220"></td>
    <td><img src="Media/Screenshots/07-queue.png" alt="Expanded play queue" width="220"></td>
  </tr>
</table>

## Build

Requires iOS 26+, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open CratesIOS.xcodeproj
```
