//
//  Connection.swift
//
//  A single WebSocket shared by many `Channel` handles (PieSocket v4).
//
//  The channel named at connect time is the "primary" — its lifecycle is the
//  socket's lifecycle. Every other channel is subscribed with a
//  `system::subscribe` control frame and rides the same socket; outbound frames
//  for it are tagged with `system::channel`, and inbound frames are routed back
//  to it by the `system::channel` / `data.channel` the server stamps on them.
//
//  All v4 control/system events are `system::x` (double colon) — a separate,
//  untouched convention from v3's single-colon `system:` events that `Channel`
//  still speaks natively when not attached to a hub.
//
//  Port of the piesocket-flutter / piesocket-js `Connection`. All state access
//  is serialised through `queue`; `onQueue` runs inline when already on it
//  (socket callbacks, timeouts) and `queue.sync`s otherwise (external calls).
//
import Foundation
import Starscream

final class Connection {

    private static let controlTimeout: TimeInterval = 10
    private static let queueKey = DispatchSpecificKey<Void>()

    private(set) var primaryChannelId: String
    private let options: PieSocketOptions
    private let logger: Logger

    private var channelsMap: [String: Channel] = [:]
    private var order: [String] = []
    private var pending: [String: PendingControl] = [:]
    private var memberRequests: [String: [MemberRequest]] = [:]

    private var primaryUuid: String
    private var primaryJwt: String?
    private var ws: WebSocket?
    private var connected = false
    private var shouldReconnect = false
    private var migrating = false
    private var openedOnce = false

    private let queue = DispatchQueue(label: "com.piesocket.connection")

    var onPrimaryConnected: (() -> Void)?
    var onPrimaryError: ((Error) -> Void)?

    /// Test seams — bypass the real socket.
    var sendOverride: ((String) -> Void)?
    var sendBinaryOverride: ((Data) -> Void)?

    private struct PendingControl {
        let onSettled: (Error?) -> Void
        let timeout: DispatchWorkItem
        let params: [String: Any]?
    }

    private final class MemberRequest {
        let onResult: (Result<[Any?], Error>) -> Void
        var timeout: DispatchWorkItem?
        init(_ onResult: @escaping (Result<[Any?], Error>) -> Void) { self.onResult = onResult }
    }

    // MARK: - Init

    init(
        primaryChannelId: String,
        options: PieSocketOptions,
        logger: Logger,
        uuid: String,
        primaryChannel: Channel,
        jwt: String?
    ) {
        self.primaryChannelId = primaryChannelId
        self.options = options
        self.logger = logger
        self.primaryUuid = uuid
        self.primaryJwt = jwt
        self.queue.setSpecific(key: Connection.queueKey, value: ())
        self.channelsMap[primaryChannelId] = primaryChannel
        self.order = [primaryChannelId]
        connect(endpoint: Channel.buildUrl(channelId: primaryChannelId, options: options, uuid: uuid, jwt: jwt))
    }

    /// Test seam — no real socket.
    init(testingPrimary primaryChannelId: String, options: PieSocketOptions, logger: Logger) {
        self.primaryChannelId = primaryChannelId
        self.options = options
        self.logger = logger
        self.primaryUuid = ""
        self.primaryJwt = nil
        self.queue.setSpecific(key: Connection.queueKey, value: ())
    }

    private func onQueue<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Connection.queueKey) != nil { return block() }
        return queue.sync(execute: block)
    }

    // MARK: - Accessors

    var channels: [String: Channel] { onQueue { channelsMap } }
    var channelOrder: [String] { onQueue { order } }
    var isConnected: Bool { onQueue { connected } }
    func isPrimary(_ channelId: String) -> Bool { channelId == primaryChannelId }

    func attachChannel(_ channelId: String, _ channel: Channel) {
        onQueue {
            if channelsMap[channelId] == nil { order.append(channelId) }
            channelsMap[channelId] = channel
        }
    }

    func detachChannel(_ channelId: String) {
        onQueue {
            channelsMap.removeValue(forKey: channelId)
            order.removeAll { $0 == channelId }
            settleMemberRequestsLocked(channelId, .failure(PieSocketException.Generic("Channel detached")))
        }
    }

    // MARK: - Outbound

    private func rawSend(_ text: String) {
        if let sendOverride = sendOverride { sendOverride(text); return }
        ws?.write(string: text)
    }

    private func rawSendBinary(_ data: Data) {
        if let sendBinaryOverride = sendBinaryOverride { sendBinaryOverride(data); return }
        ws?.write(data: data)
    }

    func sendControl(_ eventName: String, _ data: [String: Any]) {
        guard let encoded = Connection.encode(["event": eventName, "data": data]) else {
            logger.log(text: "PieSocket: control frame encode failed")
            return
        }
        rawSend(encoded)
    }

    func send(_ channelId: String, _ event: PieSocketEvent) {
        var payload: [String: Any] = ["event": event.getEvent()]
        if !event.getData().isEmpty { payload["data"] = event.getData() }
        if !event.getMeta().isEmpty { payload["meta"] = event.getMeta() }
        if !isPrimary(channelId) { payload["system::channel"] = channelId }
        if let encoded = Connection.encode(payload) { rawSend(encoded) }
    }

    func sendRaw(_ channelId: String, _ text: String) {
        if !isPrimary(channelId),
           let data = text.data(using: .utf8),
           var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            obj["system::channel"] = channelId
            if let encoded = Connection.encode(obj) { rawSend(encoded); return }
        }
        rawSend(text)
    }

    func sendBinary(_ channelId: String, _ data: Data) throws {
        guard isPrimary(channelId) else {
            throw PieSocketException.BinaryOnSecondaryChannel(
                "Binary frames are only supported on the primary channel, not \"\(channelId)\".")
        }
        rawSendBinary(data)
    }

    // MARK: - Subscription control

    func subscribeChannel(_ channelId: String, _ params: [String: Any], completion: @escaping (Error?) -> Void) {
        onQueue {
            let timeout = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.onQueue({ self.pending.removeValue(forKey: channelId) }) != nil {
                    completion(PieSocketException.ControlFrameFailed(
                        "system::subscribe timed out for \"\(channelId)\""))
                }
            }
            pending[channelId] = PendingControl(onSettled: completion, timeout: timeout, params: params)
            queue.asyncAfter(deadline: .now() + Connection.controlTimeout, execute: timeout)
            if connected { sendControl("system::subscribe", params) }
        }
    }

    func unsubscribeChannel(_ channelId: String, completion: @escaping (Error?) -> Void) {
        onQueue {
            if isPrimary(channelId) {
                completion(PieSocketException.Generic("Cannot unsubscribe the primary channel directly"))
                return
            }
            let timeout = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.onQueue({ self.pending.removeValue(forKey: channelId) }) != nil { completion(nil) }
            }
            pending[channelId] = PendingControl(onSettled: completion, timeout: timeout, params: nil)
            queue.asyncAfter(deadline: .now() + Connection.controlTimeout, execute: timeout)
            sendControl("system::unsubscribe", ["channel": channelId])
        }
    }

    func requestMembers(_ channelId: String, completion: @escaping (Result<[Any?], Error>) -> Void) {
        onQueue {
            let request = MemberRequest(completion)
            let timeout = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.onQueue { self.memberRequests[channelId]?.removeAll { $0 === request } }
                completion(.failure(PieSocketException.ControlFrameFailed(
                    "system::get_members timed out for \"\(channelId)\"")))
            }
            request.timeout = timeout
            memberRequests[channelId, default: []].append(request)
            queue.asyncAfter(deadline: .now() + Connection.controlTimeout, execute: timeout)
            sendControl("system::get_members", ["channel": channelId])
        }
    }

    func migratePrimary(_ newPrimaryId: String, endpoint: String, newUuid: String?, newJwt: String?) {
        onQueue {
            migrating = true
            let old = ws
            old?.onEvent = { _ in }
            old?.disconnect()

            primaryChannelId = newPrimaryId
            channelsMap[newPrimaryId]?.subscribeParams = nil
            if let newUuid = newUuid { primaryUuid = newUuid }
            primaryJwt = newJwt

            connected = false
            connect(endpoint: endpoint)
            migrating = false
        }
    }

    func close() {
        onQueue {
            shouldReconnect = false
            ws?.disconnect()
        }
    }

    // MARK: - Socket lifecycle

    private func connect(endpoint: String) {
        logger.log(text: "PieSocket: opening shared v4 connection: \(endpoint)")
        guard let url = URL(string: endpoint) else {
            logger.log(text: "PieSocket: invalid endpoint")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let socket = WebSocket(request: request)
        socket.callbackQueue = queue
        socket.onEvent = { [weak self] event in self?.handle(event) }
        socket.connect()
        self.ws = socket
    }

    private func handle(_ event: WebSocketEvent) {
        switch event {
        case .connected: onOpen()
        case .text(let text): onMessage(text)
        case .binary: break
        case .disconnected, .cancelled: onClose()
        case .error(let error): onFailure(error)
        default: break
        }
    }

    func onOpen() {
        connected = true
        shouldReconnect = true

        for channelId in order where !isPrimary(channelId) {
            if let params = channelsMap[channelId]?.subscribeParams {
                sendControl("system::subscribe", params)
            }
        }
        for entry in pending.values where entry.params != nil {
            sendControl("system::subscribe", entry.params!)
        }

        if !openedOnce {
            openedOnce = true
            onPrimaryConnected?()
        }
        channelsMap[primaryChannelId]?.handleOpenFromHub()
    }

    func onMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            channelsMap[primaryChannelId]?.handleFromHub(text: text)
            return
        }

        let event = obj["event"] as? String

        if event == "system::subscribe_success" || event == "system::subscribe_error"
            || event == "system::unsubscribe_success" || event == "system::unsubscribe_error" {
            settleControlLocked(event: event!, message: obj)
            return
        }

        if event == "system::member_list_error" {
            let dict = obj["data"] as? [String: Any]
            let channelId = (dict?["channel"] as? String) ?? primaryChannelId
            let err = (dict?["error"] as? String) ?? "Could not fetch members"
            settleMemberRequestsLocked(channelId, .failure(PieSocketException.ControlFrameFailed(err)))
            return
        }

        var channelId = obj["system::channel"] as? String
        if channelId == nil, let dataObj = obj["data"] as? [String: Any] {
            channelId = dataObj["channel"] as? String
        }
        let resolvedId = channelId ?? primaryChannelId

        guard let channel = channelsMap[resolvedId] ?? channelsMap[primaryChannelId] else { return }
        channel.handleFromHub(text: text)

        if event == "system::member_list", channelsMap[resolvedId] === channel {
            settleMemberRequestsLocked(resolvedId, .success(channel.getAllMembers()))
        }
    }

    private func onFailure(_ error: Error?) {
        logger.log(text: "PieSocket: connection error: \(error?.localizedDescription ?? "unknown")")
        if !connected { onPrimaryError?(error ?? PieSocketException.Generic("connection error")) }
        for channel in channelsMap.values {
            let ev = PieSocketEvent(event: "system:error")
            ev.setData(data: error?.localizedDescription ?? "connection error")
            channel.fireEvent(event: ev)
        }
        onClose()
    }

    private func onClose() {
        connected = false
        for channel in channelsMap.values {
            channel.fireEvent(event: PieSocketEvent(event: "system:closed"))
        }
        if shouldReconnect && !migrating {
            logger.log(text: "PieSocket: reconnecting multiplexed connection")
            connect(endpoint: Channel.buildUrl(
                channelId: primaryChannelId, options: options, uuid: primaryUuid, jwt: primaryJwt))
        }
    }

    // MARK: - Internals (assume on queue)

    private func settleControlLocked(event: String, message: [String: Any]) {
        guard let dict = message["data"] as? [String: Any],
              let channelId = dict["channel"] as? String,
              let entry = pending.removeValue(forKey: channelId) else { return }
        entry.timeout.cancel()
        if event.hasSuffix("_success") {
            entry.onSettled(nil)
        } else {
            entry.onSettled(PieSocketException.ControlFrameFailed((dict["error"] as? String) ?? event))
        }
    }

    private func settleMemberRequestsLocked(_ channelId: String, _ result: Result<[Any?], Error>) {
        guard let list = memberRequests.removeValue(forKey: channelId) else { return }
        for request in list {
            request.timeout?.cancel()
            request.onResult(result)
        }
    }

    static func encode(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
