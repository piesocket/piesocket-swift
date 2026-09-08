//
//  PieRTCOptions.swift
//
//  Options for a `PieRTC` room, passed to `PieSocket.join(roomId:pieRTC:)`.
//
import Foundation
import WebRTC

public class PieRTCOptions {
    public var shouldBroadcast = true
    public var video = false
    public var audio = true

    /// `(stream, pieRTC)` — attach `stream.videoTracks.first` to a renderer.
    public var onLocalVideo: ((RTCMediaStream, PieRTC) -> Void)?
    /// `(uuid, stream)` — a peer's remote stream arrived.
    public var onParticipantJoined: ((String, RTCMediaStream) -> Void)?
    /// `(uuid)` — a peer left; drop their renderer.
    public var onParticipantLeft: ((String) -> Void)?
    /// `(uuid, streamId)` — a peer stopped screen sharing.
    public var onScreenSharingStopped: ((String, String) -> Void)?

    public init() {}
}
