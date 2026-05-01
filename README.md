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
Use following code to create a Channel with Managed PieSocket Server.

Get your API key and Cluster ID here: [Get API Key](https://www.piehost.com/app/v4/register)

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

We highly recommend using PieSocket Channels over self hosted WebSocket servers for production applications.

## Events
`system:connected` is the event fired when WebSocket connection is ready, get a full list system messages here: [PieSocket System Messages](https://piehost.com/docs/3.0/events#system-events)


## Documentation
For usage examples and more information, refer to: [Official SDK docs](https://piehost.com/docs/3.0/ios-websockets)
