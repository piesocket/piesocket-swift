//
//  Channel.swift
//  basic-app
//
//  Created by Anand Singh on 18/11/22.
//
import Foundation
import Starscream

public class Channel {

    private static var NORMAL_CLOSURE_STATUS: UInt16 = 1000

    public private(set) var id: String
    private var ws: WebSocket?
    public private(set) var uuid: String

    /// Set when this handle rides a shared v4 `Connection` instead of owning its
    /// own socket. `ws` is unused in that mode.
    var hub: Connection?

    /// True for any multiplexed instance, even before `hub` is attached (a
    /// guarded primary/secondary sits with `hub == nil` while its authEndpoint
    /// fetch is in flight).
    private var isMultiplexed = false

    /// Control-frame params replayed by `Connection` across a reconnect — only
    /// meaningful for a secondary (non-primary) multiplexed channel.
    var subscribeParams: [String: Any]?

    /// Set when this is a PieRTC (WebRTC) room — v4 only.
    public var pieRTC: PieRTC?

    private var listeners: [String: [String: (PieSocketEvent) -> Void]]
    private var logger: Logger
    private var options: PieSocketOptions
    private var members: [Any?]
    private var shouldReconnect: Bool

    public init(roomId: String, options: PieSocketOptions, logger: Logger) {
        self.listeners = [String: [String: (PieSocketEvent) -> Void]]()
        self.id = roomId
        self.logger = logger
        self.options = options
        self.uuid = UUID().uuidString
        self.shouldReconnect = false
        self.members = [Any?]()

        try! self.connect()
    }

    public init(webSocketURL: String, enabledLogs: Bool) {
        self.listeners = [String: [String: (PieSocketEvent) -> Void]]()
        self.id = "standalone"
        self.logger = Logger(enabled: enabledLogs)
        self.options = PieSocketOptions()
        self.options.setWebSocketEndpoint(webSocketEndpoint: webSocketURL)
        self.uuid = UUID().uuidString
        self.shouldReconnect = false
        self.members = [Any?]()

        try! self.connect()
    }

    /// A v4 handle sharing `hub`'s socket instead of opening its own. The
    /// primary channel is live immediately; secondary channels become live once
    /// their `system::subscribe` control frame is acked.
    init(multiplexedRoomId: String, options: PieSocketOptions, logger: Logger, hub: Connection?) {
        self.listeners = [String: [String: (PieSocketEvent) -> Void]]()
        self.id = multiplexedRoomId
        self.logger = logger
        self.options = options
        self.uuid = UUID().uuidString
        self.shouldReconnect = false
        self.members = [Any?]()
        self.isMultiplexed = true
        self.hub = hub
    }

    // MARK: - Endpoint

    static func buildUrl(channelId: String, options: PieSocketOptions, uuid: String, jwt: String?) -> String {
        if !options.getWebSocketEndpoint().isEmpty {
            return options.getWebSocketEndpoint()
        }
        let domain = options.getClusterDomain() ?? (options.getClusterId() + ".piesocket.com")
        let scheme = options.getSsl() ? "wss" : "ws"
        var endpoint = scheme + "://" + domain + "/v" + options.getVersion() + "/" + channelId
            + "?api_key=" + options.getApiKey()
            + "&notify_self=" + String(options.getNotifySelf())
            + "&source=swiftsdk&v=1&presence=" + String(options.getPresence())

        if let jwt = jwt, !jwt.isEmpty { endpoint += "&jwt=" + jwt }
        let userId = options.getUserId()
        if !userId.isEmpty { endpoint += "&user=" + userId }
        endpoint += "&uuid=" + uuid
        return endpoint
    }

    private func isGuarded() -> Bool {
        if options.getForceAuth() { return true }
        return id.starts(with: "private-")
    }

    private func buildEndpoint() throws -> String {
        Channel.buildUrl(channelId: id, options: options, uuid: uuid, jwt: try getAuthToken())
    }

    private func getAuthToken() throws -> String {
        if !options.getJwt().isEmpty { return options.getJwt() }
        if isGuarded() {
            if !options.getAuthEndpoint().isEmpty {
                getAuthTokenFromServer()
                throw PieSocketException.PausedForFetchingJwt
            } else {
                throw PieSocketException.NeitherJwtNorAuthEndpointFound
            }
        }
        return ""
    }

    // MARK: - v3 socket

    public func connect() throws {
        logger.log(text: "Connecting to: " + id)
        do {
            let endpoint = try buildEndpoint()
            logger.log(text: "WebSocket Endpoint: " + endpoint)
            var request = URLRequest(url: URL(string: endpoint)!)
            request.timeoutInterval = 5
            ws = WebSocket(request: request)
            ws?.connect()
            ws?.onEvent = { event in
                switch event {
                case .connected: self.onOpen()
                case .disconnected: self.onClosing()
                case .text(let text): self.onMessage(text: text)
                case .cancelled: self.onClosing()
                case .error(let error): self.onError(error: error)
                default: break
                }
            }
        } catch PieSocketException.PausedForFetchingJwt {
            logger.log(text: "JWT not provided, will fetch from authEndpoint.")
        } catch PieSocketException.NeitherJwtNorAuthEndpointFound {
            throw PieSocketException.NeitherJwtNorAuthEndpointFound
        }
    }

    private func getAuthTokenFromServer() {
        guard let url = URL(string: options.getAuthEndpoint()) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        options.getAuthHeaders().forEach { key, val in request.addValue(val, forHTTPHeaderField: key) }
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["channel_name": id, "connection_uuid": uuid])

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let jwt = json["auth"] as? String, !jwt.isEmpty else {
                self.logger.log(text: "No \"auth\" key found in authEndpoint response.")
                return
            }
            self.options.setJwt(jwt: jwt)
            try? self.connect()
        }.resume()
    }

    public func reconnect() {
        if shouldReconnect { try? connect() }
    }

    public func disconnect() {
        shouldReconnect = false

        if let hub = hub {
            // A multiplexed secondary channel has no socket of its own.
            hub.unsubscribeChannel(id) { _ in }
            hub.detachChannel(id)
            self.hub = nil
            return
        }
        if isMultiplexed { return }
        ws?.disconnect(closeCode: Channel.NORMAL_CLOSURE_STATUS)
    }

    // MARK: - Listeners

    @discardableResult
    public func listen(eventName: String, callback: @escaping (PieSocketEvent) -> Void) -> String {
        var callbacks = listeners[eventName] ?? [:]
        let callbackId = UUID().uuidString
        callbacks[callbackId] = callback
        listeners[eventName] = callbacks
        return callbackId
    }

    public func removeListener(eventName: String, callbackId: String) {
        listeners[eventName]?.removeValue(forKey: callbackId)
    }

    public func removeAllListeners(eventName: String) {
        listeners.removeValue(forKey: eventName)
    }

    // MARK: - Outbound

    public func publish(event: PieSocketEvent) {
        if let hub = hub { hub.send(id, event); return }
        if isMultiplexed {
            logger.log(text: "Channel \"\(id)\" is not connected yet — authEndpoint fetch in flight.")
            return
        }
        ws?.write(string: event.toString())
    }

    public func send(text: String) {
        if let hub = hub { hub.sendRaw(id, text); return }
        if isMultiplexed {
            logger.log(text: "Channel \"\(id)\" is not connected yet — authEndpoint fetch in flight.")
            return
        }
        ws?.write(string: text)
    }

    /// Publish a structured payload directly, without pre-stringifying it into a
    /// `PieSocketEvent`. `data`/`meta` may be a dictionary, array, or primitive.
    public func publishEvent(_ eventName: String, data: Any? = nil, meta: Any? = nil) {
        var frame: [String: Any] = ["event": eventName]
        if let data = data { frame["data"] = data }
        if let meta = meta { frame["meta"] = meta }
        guard let encoded = Connection.encode(frame) else {
            logger.log(text: "PieSocket: publishEvent encode failed")
            return
        }
        send(text: encoded)
    }

    /// Send a raw binary WebSocket frame (v4). The server wraps any inbound
    /// binary frame as a `system::binary` event (base64 `data`) before relaying
    /// it, so a browser/Flutter/Android peer receives this exactly as it would a
    /// binary frame from another client. Primary channel only.
    public func sendBinary(_ data: Data) throws {
        if let hub = hub { try hub.sendBinary(id, data); return }
        if isMultiplexed {
            throw PieSocketException.ChannelNotReady(
                "Channel \"\(id)\" is not connected yet — its authEndpoint fetch is still in flight.")
        }
        ws?.write(data: data)
    }

    /// Re-sync this channel's presence roster from the server (v4 only) via
    /// `system::get_members`. On v3 returns the roster already held.
    public func refreshMembers(completion: @escaping ([Any?]) -> Void) {
        if let hub = hub {
            hub.requestMembers(id) { result in
                switch result {
                case .success(let members): completion(members)
                case .failure: completion(self.members)
                }
            }
            return
        }
        completion(members)
    }

    // MARK: - Event dispatch

    func fireEvent(event: PieSocketEvent) {
        logger.log(text: "Firing Event: " + event.getEvent())
        if listeners.keys.contains(event.getEvent()) {
            doFireEvents(listnerKey: event.getEvent(), event: event)
        }
        if listeners.keys.contains("*") {
            doFireEvents(listnerKey: "*", event: event)
        }
    }

    private func doFireEvents(listnerKey: String, event: PieSocketEvent) {
        guard let callbacks = listeners[listnerKey] else { return }
        for (_, callback) in callbacks { callback(event) }
    }

    // MARK: - Inbound

    /// Called by `Connection` for a frame routed to this channel.
    func handleFromHub(text: String) { onMessage(text: text) }

    /// Called by `Connection` when the shared socket opens (primary only).
    func handleOpenFromHub() { onOpen() }

    private func onOpen() {
        fireEvent(event: PieSocketEvent(event: "system:connected"))
        shouldReconnect = true
    }

    private func onClosing() {
        fireEvent(event: PieSocketEvent(event: "system:closed"))
        reconnect()
    }

    private func onError(error: Error?) {
        let event = PieSocketEvent(event: "system:error")
        event.setData(data: error?.localizedDescription ?? "error")
        fireEvent(event: event)
    }

    private func convertStringToDictionary(text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func dictToString(_ value: Any?) -> String {
        guard let value = value else { return "" }
        if let s = value as? String { return s }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func onMessage(text: String) {
        if listeners.keys.contains("system:message") {
            let payload = PieSocketEvent(event: "system:message")
            payload.setData(data: text)
            doFireEvents(listnerKey: "system:message", event: payload)
        }

        guard let jsonObject = convertStringToDictionary(text: text) else { return }

        if let eventName = jsonObject["event"] as? String {
            if eventName == "system:boot" {
                onOpen()
                return
            }
            let payload = PieSocketEvent(event: eventName)
            if let data = jsonObject["data"], !(data is NSNull) {
                payload.setData(data: dictToString(data))
            }
            if let meta = jsonObject["meta"], !(meta is NSNull) {
                payload.setMeta(meta: dictToString(meta))
            }

            handleSystemEvents(event: payload)
            handlePieRTCEvent(eventName: eventName, data: jsonObject["data"])
            fireEvent(event: payload)
        }

        if let error = jsonObject["error"] {
            shouldReconnect = false
            let payload = PieSocketEvent(event: "system:error")
            payload.setData(data: dictToString(error))
            fireEvent(event: payload)
        }
    }

    // MARK: - Presence

    private func handleSystemEvents(event: PieSocketEvent) {
        let deltaPresence = options.getVersion() == "4"
        let memberListEvent = deltaPresence ? "system::member_list" : "system:member_list"
        let memberJoinedEvent = deltaPresence ? "system::member_joined" : "system:member_joined"
        let memberLeftEvent = deltaPresence ? "system::member_left" : "system:member_left"

        let name = event.getEvent()
        guard name == memberListEvent || name == memberJoinedEvent || name == memberLeftEvent else { return }
        guard let data = convertStringToDictionary(text: event.getData()) else { return }

        if name == memberListEvent {
            members = (data["members"] as? [Any?]) ?? []
        } else if name == memberJoinedEvent {
            if deltaPresence { addMember(data["member"]) }
            else { members = (data["members"] as? [Any?]) ?? [] }
        } else if name == memberLeftEvent {
            if deltaPresence { removeMember(data["member"]) }
            else { members = (data["members"] as? [Any?]) ?? [] }
            if let member = data["member"] as? [String: Any], let uuid = member["uuid"] as? String {
                pieRTC?.removeParticipant(uuid: uuid)
            }
        }
    }

    private func memberKey(_ member: Any?) -> String {
        if let dict = member as? [String: Any] {
            if let uuid = dict["uuid"] { return "uuid:\(uuid)" }
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let s = String(data: data, encoding: .utf8) {
                return "obj:\(s)"
            }
            return "obj:\(dict)"
        }
        return "val:\(String(describing: member))"
    }

    private func addMember(_ member: Any?) {
        guard let member = member else { return }
        let key = memberKey(member)
        if members.contains(where: { memberKey($0) == key }) { return }
        members.append(member)
    }

    private func removeMember(_ member: Any?) {
        guard let member = member else { return }
        let key = memberKey(member)
        members.removeAll { memberKey($0) == key }
    }

    // MARK: - PieRTC routing

    private func handlePieRTCEvent(eventName: String, data: Any?) {
        guard let pieRTC = pieRTC, let dict = data as? [String: Any] else { return }
        pieRTC.handleSignal(eventName: eventName, data: dict)
    }

    // MARK: - Members accessors

    public func getMemberByUUID(uuid: String) -> [String: Any]? {
        for member in members {
            if let dict = member as? [String: Any], dict["uuid"] as? String == uuid {
                return dict
            }
        }
        return nil
    }

    public func getCurrentMember() -> [String: Any]? {
        getMemberByUUID(uuid: uuid)
    }

    public func getAllMembers() -> [Any?] {
        members
    }
}
