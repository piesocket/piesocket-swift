//
//  PieSocket.swift
//  basic-app
//
//  Created by Anand Singh on 17/11/22.
//
import Foundation

public class PieSocket {

    var rooms: [String: Channel]
    var options: PieSocketOptions
    var logger: Logger

    /// The shared v4 socket every multiplexed `join()` rides — nil under v3, or
    /// before the first v4 `join()` has opened it.
    private var connection: Connection?

    /// True while the primary connection is resolving auth — a `join()` racing
    /// in during that window queues in `pendingJoins` instead of opening a
    /// second primary.
    private var multiplexOpening = false
    private var pendingJoins: [() -> Void] = []

    public init(pieSocketOptions: PieSocketOptions) {
        self.rooms = [String: Channel]()
        self.options = pieSocketOptions
        self.logger = Logger(enabled: options.getEnableLogs())
        try! validateOptions()
    }

    private func validateOptions() throws {
        if options.getClusterId().isEmpty { throw PieSocketException.ClusterIdNotSet }
        if options.getApiKey().isEmpty { throw PieSocketException.ApiKeyNotSet }
    }

    // MARK: - Join

    public func join(roomId: String) -> Channel {
        join(roomId: roomId, pieRTC: nil)
    }

    /// Subscribe to a room, optionally as a PieRTC (WebRTC) room. Always returns
    /// synchronously — under `version: "4"` the first call opens a shared socket
    /// and later calls ride it via a background `system::subscribe`.
    public func join(roomId: String, pieRTC rtcOptions: PieRTCOptions?) -> Channel {
        if let existing = rooms[roomId] {
            logger.log(text: "Returning existing room instance: " + roomId)
            return existing
        }

        let room: Channel = options.getVersion() == "4"
            ? joinMultiplexed(roomId, rtcOptions)
            : Channel(roomId: roomId, options: options, logger: logger)

        rooms[roomId] = room
        return room
    }

    private func joinMultiplexed(_ roomId: String, _ rtc: PieRTCOptions?) -> Channel {
        if let conn = connection {
            return attachSecondary(roomId, conn, rtc)
        }
        if multiplexOpening {
            let channel = Channel(multiplexedRoomId: roomId, options: options, logger: logger, hub: nil)
            pendingJoins.append { [weak self] in self?.attachOrRetry(roomId, channel, rtc) }
            return channel
        }
        return openPrimary(roomId, rtc, existing: nil)
    }

    private func attachOrRetry(_ roomId: String, _ channel: Channel, _ rtc: PieRTCOptions?) {
        if let conn = connection {
            resolveAndAttach(roomId, channel, conn, rtc)
            return
        }
        if multiplexOpening {
            pendingJoins.append { [weak self] in self?.attachOrRetry(roomId, channel, rtc) }
            return
        }
        _ = openPrimary(roomId, rtc, existing: channel)
    }

    private func openPrimary(_ roomId: String, _ rtc: PieRTCOptions?, existing: Channel?) -> Channel {
        let resolved = existing ?? Channel(multiplexedRoomId: roomId, options: options, logger: logger, hub: nil)
        multiplexOpening = true

        AuthResolver.resolve(
            channelId: roomId, connectionUuid: resolved.uuid, options: options, logger: logger,
            onReady: { [weak self] jwt in
                guard let self = self else { return }
                let conn = Connection(
                    primaryChannelId: roomId, options: self.options, logger: self.logger,
                    uuid: resolved.uuid, primaryChannel: resolved, jwt: jwt)
                resolved.hub = conn
                self.connection = conn
                if let rtc = rtc {
                    resolved.pieRTC = PieRTC(channel: resolved, options: rtc, logger: self.logger)
                }
                self.multiplexOpening = false
                self.drainPendingJoins()
            },
            onError: { [weak self] error in
                guard let self = self else { return }
                self.logger.log(text: "PieSocket: auth resolution failed for \"\(roomId)\": \(error)")
                self.fireErrorNextTick(resolved, error)
                self.multiplexOpening = false
                self.drainPendingJoins()
            })

        return resolved
    }

    private func drainPendingJoins() {
        let jobs = pendingJoins
        pendingJoins = []
        jobs.forEach { $0() }
    }

    private func attachSecondary(_ roomId: String, _ conn: Connection, _ rtc: PieRTCOptions?) -> Channel {
        let channel = Channel(multiplexedRoomId: roomId, options: options, logger: logger, hub: conn)
        resolveAndAttach(roomId, channel, conn, rtc)
        return channel
    }

    private func resolveAndAttach(_ roomId: String, _ channel: Channel, _ conn: Connection, _ rtc: PieRTCOptions?) {
        AuthResolver.resolve(
            channelId: roomId, connectionUuid: channel.uuid, options: options, logger: logger,
            onReady: { [weak self] jwt in
                guard let self = self else { return }
                let presence = self.options.getPresence() == 1 || roomId.hasPrefix("presence-")
                var params: [String: Any] = ["channel": roomId, "presence": presence, "uuid": channel.uuid]
                if let jwt = jwt { params["jwt"] = jwt }
                if !self.options.getUserId().isEmpty { params["user"] = self.options.getUserId() }

                channel.subscribeParams = params
                channel.hub = conn
                conn.attachChannel(roomId, channel)
                if let rtc = rtc {
                    channel.pieRTC = PieRTC(channel: channel, options: rtc, logger: self.logger)
                }
                conn.subscribeChannel(roomId, params) { error in
                    if let error = error {
                        self.logger.log(text: "PieSocket: subscribe failed for \"\(roomId)\": \(error)")
                    }
                }
            },
            onError: { [weak self] error in
                guard let self = self else { return }
                self.logger.log(text: "PieSocket: auth resolution failed for \"\(roomId)\": \(error)")
                self.fireErrorNextTick(channel, error)
            })
    }

    private func fireErrorNextTick(_ channel: Channel, _ error: Error) {
        DispatchQueue.global().async {
            let event = PieSocketEvent(event: "system:error")
            event.setData(data: "\(error)")
            channel.fireEvent(event: event)
        }
    }

    // MARK: - Leave

    public func leave(roomId: String) {
        guard let channel = rooms[roomId] else {
            logger.log(text: "DISCONNECT: Room does not exist: " + roomId)
            return
        }

        if let conn = connection, channel.hub != nil {
            if roomId == conn.primaryChannelId {
                let others = conn.channelOrder.filter { $0 != roomId }
                if others.isEmpty {
                    conn.close()
                    connection = nil
                } else if let newPrimary = conn.channels[others[0]] {
                    let newPrimaryId = others[0]
                    conn.detachChannel(roomId)
                    AuthResolver.resolve(
                        channelId: newPrimaryId, connectionUuid: newPrimary.uuid,
                        options: options, logger: logger,
                        onReady: { [weak self] jwt in
                            guard let self = self else { return }
                            let endpoint = Channel.buildUrl(
                                channelId: newPrimaryId, options: self.options,
                                uuid: newPrimary.uuid, jwt: jwt)
                            conn.migratePrimary(newPrimaryId, endpoint: endpoint,
                                                newUuid: newPrimary.uuid, newJwt: jwt)
                        },
                        onError: { [weak self] error in
                            guard let self = self else { return }
                            self.logger.log(text: "PieSocket: promotion auth failed, closing shared connection: \(error)")
                            let remaining = Array(conn.channels.keys)
                            conn.close()
                            self.connection = nil
                            for id in remaining {
                                if let ch = self.rooms.removeValue(forKey: id) {
                                    self.fireErrorNextTick(ch, error)
                                }
                            }
                        })
                } else {
                    conn.close()
                    connection = nil
                }
            } else {
                channel.disconnect()
            }
            rooms.removeValue(forKey: roomId)
            return
        }

        logger.log(text: "DISCONNECT: Closing room connection: " + roomId)
        channel.disconnect()
        rooms.removeValue(forKey: roomId)
    }

    public func getAllRooms() -> [String: Channel] {
        rooms
    }
}
