# Changelog

## 7.0.0

Version realigned to match the other PieSocket client SDKs (piesocket-js,
piesocket-flutter, piesocket-android). This is the release that follows
`2.1.0` — the jump is version-numbering only, no breaking changes beyond the
ones listed below. SwiftPM resolves versions from git tags, so this ships as
tag `v7.0.0`.

Add **v4 protocol** support and **PieRTC** (WebRTC video/audio rooms) — the
Apple counterparts of the same features in piesocket-js, piesocket-flutter and
piesocket-android. v3 usage is unchanged and still the default.

### v4 — multi-channel over one connection

Set `options.setVersion(version: "4")` to share a **single** WebSocket across
every `join()` call. `join()` still returns a `Channel` synchronously.

- New `Connection` type owns the shared socket; secondary channels ride it
  tagged with `system::channel`, inbound frames route back by the same key.
- **Delta presence.** Full roster once as `system::member_list`, then kept in
  sync from `system::member_joined` / `system::member_left`.
  `channel.refreshMembers { members in ... }` re-syncs on demand.
- **All v4 system events are double-colon** (`system::member_joined`, …).
- **`channel.publishEvent(_:data:meta:)`** sends a structured payload
  (dictionary / array / primitive) without pre-stringifying it.
- **Binary.** Inbound binary arrives as a `system::binary` event whose `data`
  is a base64 string. `try channel.sendBinary(Data)` sends a raw binary frame
  (primary channel only) — the server re-wraps it as `system::binary` for every
  other client, JS / Flutter / Android peers included.
- **Guarded channels** resolve their JWT from `authEndpoint` in the background
  without `join()` blocking (`AuthResolver`).

### PieRTC — WebRTC rooms (v4 only)

Programmable WebRTC over v4, built on
[`stasel/WebRTC`](https://github.com/stasel/WebRTC) (a new SPM dependency).
Signalling rides its own `rtc::` namespace — a plain relay, so Apple, Android
and JS/web clients interoperate in one room.

```swift
let rtc = PieRTCOptions()
rtc.video = true
rtc.audio = true
rtc.onLocalVideo = { stream, pieRTC in /* stream.videoTracks.first?.add(renderer) */ }
rtc.onParticipantJoined = { uuid, stream in /* attach remote stream */ }
rtc.onParticipantLeft = { uuid in /* remove renderer */ }

let room = piesocket.join(roomId: "video-room", pieRTC: rtc)
```

- Add `NSCameraUsageDescription` / `NSMicrophoneUsageDescription` to your app's
  Info.plist.
- `WebRTC` is re-exported from `import Channels` — use `RTCMTLVideoView` /
  `RTCVideoTrack` directly.
- `pieRTC.dispose()` / `piesocket.leave(roomId:)` releases resources.
- **`pieRTC.shareScreen()`** — one call, no Xcode target or App Group. Uses
  ReplayKit's in-app capture (`RPScreenRecorder`), so it shares *this app's*
  screen; the track is sent alongside the camera. `pieRTC.stopScreenShare()`
  stops it; `onScreenSharingStopped` fires with this client's own uuid and
  `rtc::stopped_screen` is published. (Whole-device capture needs a Broadcast
  Upload Extension and is out of scope of this API.) iOS only.

### Other

- `PieSocketException` gained `ControlFrameFailed` / `BinaryOnSecondaryChannel`
  / `ChannelNotReady` / `Generic` cases.
- `Channel.getMemberByUUID` / `getCurrentMember` now return `[String: Any]?`;
  `getAllMembers()` returns `[Any?]`.
- The package now declares `platforms: [.iOS(.v13), .macOS(.v11)]` (WebRTC).

## 2.1.0

Add `clusterDomain` / `ssl` support.
