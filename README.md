# PieSocket Realtime Swift SDK

PieSocket Realtime SDK for WebSockets written in Swift.
Supports cross-platform Xcode projects for:  iOS, iPad, Mac, etc.


## Add to project
Simply import this github repository into your Xcode project.

 - In your Xcode project, go to File > Add packages
 - Enter `https://github.com/piesocket/piesocket-swift` in the search box
 - Click "Add package"


## Usage

### Managed PieSocket Server
Use following code to create a Channel with Managed PieSocket Server.

Get your API key and Cluster ID here: [Get API Key](https://www.piehost.com/app/v4/register)

```dart
let options: PieSocketOptions = PieSocketOptions();
options.setClusterId(clusterId: "demo");
options.setApiKey(apiKey: "VCXCEuvhGcBDP7XhiJJUDvR1e1D3eiVjgZ9VRiaV");

let piesocket: PieSocket = PieSocket(pieSocketOptions: options);
let channel: Channel = piesocket.join(roomId: "chat-room");
```

### Self-hosted PieSocket Server
Use the following code to create a Channel with a self-hosted PieSocket Server.


```dart
let options: PieSocketOptions = PieSocketOptions();
options.setClusterDomain(clusterDomain: "localhost:4001");
options.setSsl(ssl: false);

let piesocket: PieSocket = PieSocket(pieSocketOptions: options);
let channel: Channel = piesocket.join(roomId: "chat-room");
```


[PieSocket Realtime](https://piesocket.com/channels) is scalable WebSocket API service with following features:
  - Authentication
  - Private Channels
  - Presence Channels
  - Publish messages with REST API
  - Auto-scalability
  - Webhooks
  - Analytics
  - Authentication
  - Upto 60% cost savings


## v4 — multi-channel over one connection

Set `options.setVersion(version: "4")` to share a **single** WebSocket across
every `join()` call. `join()` still returns a `Channel` synchronously.

```swift
let options = PieSocketOptions()
options.setClusterId(clusterId: "demo")
options.setApiKey(apiKey: "VCXCEuvhGcBDP7XhiJJUDvR1e1D3eiVjgZ9VRiaV")
options.setVersion(version: "4")

let piesocket = PieSocket(pieSocketOptions: options)
let chat = piesocket.join(roomId: "chat-room")     // opens the socket
let alerts = piesocket.join(roomId: "alerts")      // rides the same socket

chat.listen(eventName: "message") { event in /* ... */ }
alerts.publishEvent("ping", data: ["at": Date().timeIntervalSince1970])
```

- **`join()` stays synchronous.** Listen for `system:connected` on the primary
  channel (the first `join()`); secondary channels' subscribe acks are handled
  internally.
- **Delta presence.** `channel.refreshMembers { members in ... }` re-syncs.
- **All v4 system events are double-colon** (`system::member_joined`, …).
- **`publishEvent(_:data:meta:)`** sends a structured payload directly.
- **Binary.** Inbound binary arrives as a `system::binary` event whose `data`
  is a base64 string. `try channel.sendBinary(Data)` sends a raw binary frame
  (primary channel only) that the server re-wraps as `system::binary` for every
  other client — JS / Flutter / Android peers included.

## PieRTC — WebRTC video/audio rooms (v4 only)

Built on [`stasel/WebRTC`](https://github.com/stasel/WebRTC). Signalling rides
its own `rtc::` namespace — a plain relay, so Apple, Android and JS/web clients
interoperate in one room.

```swift
let rtc = PieRTCOptions()
rtc.video = true
rtc.audio = true
rtc.onLocalVideo = { stream, pieRTC in /* stream.videoTracks.first?.add(renderer) */ }
rtc.onParticipantJoined = { uuid, stream in /* attach remote stream */ }
rtc.onParticipantLeft = { uuid in /* remove renderer */ }

let room = piesocket.join(roomId: "video-room", pieRTC: rtc)
```

- Add `NSCameraUsageDescription` / `NSMicrophoneUsageDescription` to Info.plist.
- `WebRTC` is re-exported from `import Channels` — use `RTCMTLVideoView` etc.
- **`pieRTC.shareScreen()`** (iOS) — one call, no extension target. In-app
  ReplayKit capture; `pieRTC.stopScreenShare()` stops.
- `pieRTC.dispose()` / `piesocket.leave(roomId:)` releases resources.

## Events
`system:connected` is the event fired when WebSocket connection is ready, get a full list system messages here: [PieSocket System Messages](https://piehost.com/docs/3.0/events#system-events)


## Documentation
For usage examples and more information, refer to: [Official SDK docs](https://piehost.com/docs/3.0/ios-websockets)
