//
//  PieRTC.swift
//
//  Method-for-method port of piesocket-js's `PieRTC.js` / piesocket-flutter's
//  `pie_rtc.dart` / piesocket-android's `PieRTC.java`, on the `stasel/WebRTC`
//  framework. Signalling rides the channel via `Channel.publishEvent` on the
//  same `rtc::` namespace those SDKs use — a plain PieSocket relay, no
//  server-side special-casing — so an Apple, an Android and a JS client can be
//  mixed in one room.
//
//  Mutating operations are serialised on `queue`; WebRTC delegate callbacks
//  (a different thread) re-dispatch onto it.
//
import Foundation
import CoreMedia
import WebRTC
#if canImport(ReplayKit)
import ReplayKit
#endif

public class PieRTC {

    let channel: Channel
    let identity: PieRTCOptions
    private let logger: Logger

    private static var sslInitialized = false
    private static let sslLock = NSLock()

    private let factory: RTCPeerConnectionFactory
    private let queue = DispatchQueue(label: "com.piesocket.piertc")

    public private(set) var localStream: RTCMediaStream?
    public private(set) var displayStream: RTCMediaStream?

    private var videoCapturer: RTCCameraVideoCapturer?
    private var screenCapturer: RTCVideoCapturer?
    private var screenSource: RTCVideoSource?
    private var screenTrack: RTCVideoTrack?

    private var participants: [String: Participant] = [:]
    private var isNegotiating: [String: Bool] = [:]

    private let iceServers = [
        RTCIceServer(urlStrings: ["stun:stun.stunprotocol.org:3478"]),
        RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
    ]

    private final class Participant {
        var rtc: RTCPeerConnection?
        var delegate: PeerConnectionDelegate?
    }

    public init(channel: Channel, options: PieRTCOptions, logger: Logger) {
        self.channel = channel
        self.identity = options
        self.logger = logger

        PieRTC.sslLock.lock()
        if !PieRTC.sslInitialized {
            RTCInitializeSSL()
            PieRTC.sslInitialized = true
        }
        PieRTC.sslLock.unlock()

        self.factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())

        logger.log(text: "Initializing video room")
        queue.async { [weak self] in self?.setup() }
    }

    // MARK: - Local media

    private func setup() {
        if !identity.video && !identity.audio {
            requestPeerVideo()
            return
        }
        let stream = factory.mediaStream(withStreamId: "PIE_local")

        if identity.audio {
            let audioSource = factory.audioSource(with: RTCMediaConstraints(
                mandatoryConstraints: nil, optionalConstraints: nil))
            stream.addAudioTrack(factory.audioTrack(with: audioSource, trackId: "PIE_audio"))
        }

        if identity.video {
            let videoSource = factory.videoSource()
            let capturer = RTCCameraVideoCapturer(delegate: videoSource)
            self.videoCapturer = capturer
            if startCamera(capturer) {
                stream.addVideoTrack(factory.videoTrack(with: videoSource, trackId: "PIE_video"))
            } else {
                logger.log(text: "PieRTC: no camera available")
            }
        }

        localStream = stream
        identity.onLocalVideo?(stream, self)
        requestPeerVideo()
    }

    private func startCamera(_ capturer: RTCCameraVideoCapturer) -> Bool {
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == .front }) ?? devices.first else {
            return false
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let target: AVCaptureDevice.Format? = formats.min(by: { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return abs(Int(da.width) - 1280) < abs(Int(db.width) - 1280)
        })
        guard let format = target else { return false }
        let fps = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
        capturer.startCapture(with: device, format: format, fps: Int(min(fps, 30)))
        return true
    }

    // MARK: - Signalling

    func requestPeerVideo() {
        let eventName = identity.shouldBroadcast ? "rtc::broadcaster" : "rtc::watcher"
        channel.publishEvent(eventName, data: [
            "from": channel.uuid,
            "isBroadcasting": identity.shouldBroadcast,
        ])
    }

    func requestOfferFromPeer() {
        channel.publishEvent("rtc::request", data: [
            "from": channel.uuid,
            "isBroadcasting": identity.shouldBroadcast,
        ])
    }

    /// Handle an inbound `rtc::*` signalling frame — `Channel` forwards every
    /// event here; non-`rtc::` events are ignored.
    func handleSignal(eventName: String, data: [String: Any]) {
        guard eventName.hasPrefix("rtc::") else { return }
        let from = data["from"] as? String
        let to = data["to"] as? String
        let fromSelf = (from == channel.uuid)
        let toSelf = (to == channel.uuid)

        switch eventName {
        case "rtc::broadcaster":
            if !fromSelf { queue.async { [weak self] in self?.requestOfferFromPeer() } }
        case "rtc::stopped_screen":
            if !fromSelf {
                identity.onScreenSharingStopped?(from ?? "", data["streamId"] as? String ?? "")
            }
        case "rtc::watcher", "rtc::request":
            if !fromSelf { queue.async { [weak self] in self?.shareVideo(data, isCaller: true) } }
        case "rtc::candidate":
            if toSelf { queue.async { [weak self] in self?.addIce(data) } }
        case "rtc::offer":
            if toSelf { queue.async { [weak self] in self?.createAnswer(data) } }
        case "rtc::answer":
            if toSelf { queue.async { [weak self] in self?.handleAnswer(data) } }
        default:
            break
        }
    }

    private func shareVideo(_ signal: [String: Any], isCaller: Bool) {
        guard let from = signal["from"] as? String else { return }

        if !identity.shouldBroadcast && isCaller && (signal["isBroadcasting"] as? Bool != true) {
            logger.log(text: "Refusing to call, denied broadcast request")
            return
        }

        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        let participant = Participant()
        let delegate = PeerConnectionDelegate()
        participant.delegate = delegate

        delegate.onCandidate = { [weak self] candidate in
            guard let self = self else { return }
            self.channel.publishEvent("rtc::candidate", data: [
                "from": self.channel.uuid,
                "to": from,
                "ice": [
                    "candidate": candidate.sdp,
                    "sdpMid": candidate.sdpMid ?? "",
                    "sdpMLineIndex": candidate.sdpMLineIndex,
                ],
            ])
        }
        delegate.onAddStream = { [weak self] stream in
            guard let self = self, !stream.videoTracks.isEmpty else { return }
            self.identity.onParticipantJoined?(from, stream)
        }
        delegate.onSignalingChange = { [weak self] state in
            self?.queue.async { self?.isNegotiating[from] = (state != .stable) }
        }
        delegate.onRenegotiation = { [weak self] in
            self?.queue.async { self?.sendVideoOffer(from) }
        }

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            logger.log(text: "PieRTC: failed to create peer connection for \(from)")
            return
        }
        participant.rtc = pc

        if let localStream = localStream { addTracks(pc, from: localStream) }
        if let displayStream = displayStream { addTracks(pc, from: displayStream) }

        isNegotiating[from] = false
        participants[from] = participant
    }

    private func addTracks(_ pc: RTCPeerConnection, from stream: RTCMediaStream) {
        let ids = [stream.streamId]
        for track in stream.videoTracks { pc.add(track, streamIds: ids) }
        for track in stream.audioTracks { pc.add(track, streamIds: ids) }
    }

    private func sendVideoOffer(_ from: String) {
        guard let pc = participants[from]?.rtc else { return }
        if isNegotiating[from] == true {
            logger.log(text: "SKIP nested negotiations")
            return
        }
        isNegotiating[from] = true

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] desc, _ in
            guard let self = self, let desc = desc else { return }
            pc.setLocalDescription(desc) { _ in
                self.channel.publishEvent("rtc::offer", data: [
                    "from": self.channel.uuid,
                    "to": from,
                    "sdp": [
                        "type": RTCSessionDescription.string(for: desc.type),
                        "sdp": desc.sdp,
                    ],
                ])
            }
        }
    }

    private func addIce(_ signal: [String: Any]) {
        guard let from = signal["from"] as? String,
              let pc = participants[from]?.rtc,
              let ice = signal["ice"] as? [String: Any],
              let candidate = ice["candidate"] as? String else { return }
        let mid = ice["sdpMid"] as? String
        let mline = (ice["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
        pc.add(RTCIceCandidate(sdp: candidate, sdpMLineIndex: mline, sdpMid: mid)) { _ in }
    }

    private func createAnswer(_ signal: [String: Any]) {
        guard let from = signal["from"] as? String else { return }

        if participants[from]?.rtc == nil {
            logger.log(text: "Starting call in createAnswer")
            shareVideo(signal, isCaller: false)
        }
        guard let pc = participants[from]?.rtc,
              let sdp = signal["sdp"] as? [String: Any],
              let sdpString = sdp["sdp"] as? String else { return }
        let typeString = sdp["type"] as? String ?? "offer"
        let remote = RTCSessionDescription(
            type: RTCSessionDescription.type(for: typeString), sdp: sdpString)

        pc.setRemoteDescription(remote) { [weak self] _ in
            guard let self = self, typeString == "offer" else { return }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            pc.answer(for: constraints) { desc, _ in
                guard let desc = desc else { return }
                pc.setLocalDescription(desc) { _ in
                    self.channel.publishEvent("rtc::answer", data: [
                        "from": self.channel.uuid,
                        "to": from,
                        "sdp": [
                            "type": RTCSessionDescription.string(for: desc.type),
                            "sdp": desc.sdp,
                        ],
                    ])
                }
            }
        }
    }

    private func handleAnswer(_ signal: [String: Any]) {
        guard let from = signal["from"] as? String,
              let pc = participants[from]?.rtc,
              let sdp = signal["sdp"] as? [String: Any],
              let sdpString = sdp["sdp"] as? String else { return }
        let typeString = sdp["type"] as? String ?? "answer"
        pc.setRemoteDescription(
            RTCSessionDescription(type: RTCSessionDescription.type(for: typeString), sdp: sdpString)) { _ in }
    }

    /// A participant left the room — tear down their peer connection.
    public func removeParticipant(uuid: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.participants[uuid]?.rtc?.close()
            self.participants.removeValue(forKey: uuid)
            self.isNegotiating.removeValue(forKey: uuid)
            self.identity.onParticipantLeft?(uuid)
        }
    }

    // MARK: - Screen share

    /// Start sharing this app's screen with everyone in the room — one call, no
    /// Xcode target or App Group required. Uses ReplayKit's in-app capture
    /// (`RPScreenRecorder.startCapture`), so it shares *this app's* content;
    /// the screen track is sent in addition to the camera. Call
    /// `stopScreenShare()` to stop; `onScreenSharingStopped` fires with this
    /// client's own uuid and `rtc::stopped_screen` is published to the room.
    ///
    /// (Whole-device capture needs a Broadcast Upload Extension — a separate
    /// app target — and is out of scope of this one-call API.)
    public func shareScreen() {
        #if os(iOS)
        guard screenTrack == nil else {
            logger.log(text: "PieRTC: screen share already active")
            return
        }
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            logger.log(text: "PieRTC: screen recording is not available on this device")
            return
        }
        recorder.isMicrophoneEnabled = false

        queue.async { [weak self] in
            guard let self = self else { return }

            let source = self.factory.videoSource(forScreenCast: true)
            let capturer = RTCVideoCapturer(delegate: source)
            self.screenSource = source
            self.screenCapturer = capturer

            let track = self.factory.videoTrack(with: source, trackId: "PIE_screen")
            let stream = self.factory.mediaStream(withStreamId: "PIE_screen_stream")
            stream.addVideoTrack(track)
            self.screenTrack = track
            self.displayStream = stream

            let ids = [stream.streamId]
            for participant in self.participants.values {
                guard let pc = participant.rtc else { continue }
                pc.add(track, streamIds: ids) // -> peerConnectionShouldNegotiate
            }

            recorder.startCapture(handler: { [weak self] sampleBuffer, sampleType, error in
                guard let self = self, sampleType == .video, error == nil,
                      let capturer = self.screenCapturer,
                      CMSampleBufferIsValid(sampleBuffer),
                      CMSampleBufferDataIsReady(sampleBuffer),
                      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let ns = Int64(CMTimeGetSeconds(time) * Double(NSEC_PER_SEC))
                let frame = RTCVideoFrame(
                    buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
                    rotation: ._0, timeStampNs: ns)
                capturer.delegate?.capturer(capturer, didCapture: frame)
            }, completionHandler: { [weak self] error in
                if let error = error {
                    self?.logger.log(text: "PieRTC: screen capture failed: \(error.localizedDescription)")
                    self?.queue.async { self?.teardownScreenShare(announce: false) }
                }
            })
        }
        #else
        logger.log(text: "PieRTC.shareScreen is only implemented for iOS")
        #endif
    }

    /// Stop screen sharing started by `shareScreen()`.
    public func stopScreenShare() {
        #if os(iOS)
        RPScreenRecorder.shared().stopCapture { _ in }
        #endif
        queue.async { [weak self] in self?.teardownScreenShare(announce: true) }
    }

    private func teardownScreenShare(announce: Bool) {
        guard screenTrack != nil || displayStream != nil else { return }
        let streamId = displayStream?.streamId ?? ""

        if let screenTrack = screenTrack {
            for participant in participants.values {
                guard let pc = participant.rtc else { continue }
                for sender in pc.senders where sender.track?.trackId == screenTrack.trackId {
                    pc.removeTrack(sender) // -> peerConnectionShouldNegotiate
                }
            }
        }
        screenCapturer = nil
        screenSource = nil
        screenTrack = nil
        displayStream = nil

        if announce {
            channel.publishEvent("rtc::stopped_screen",
                                 data: ["from": channel.uuid, "streamId": streamId])
            identity.onScreenSharingStopped?(channel.uuid, streamId)
        }
    }

    public func dispose() {
        #if os(iOS)
        if screenTrack != nil { RPScreenRecorder.shared().stopCapture { _ in } }
        #endif
        queue.async { [weak self] in
            guard let self = self else { return }
            self.teardownScreenShare(announce: false)
            self.videoCapturer?.stopCapture()
            for participant in self.participants.values { participant.rtc?.close() }
            self.participants.removeAll()
            self.localStream = nil
            self.displayStream = nil
        }
    }
}

// MARK: - Delegate adapter

final class PeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate {
    var onCandidate: ((RTCIceCandidate) -> Void)?
    var onAddStream: ((RTCMediaStream) -> Void)?
    var onSignalingChange: ((RTCSignalingState) -> Void)?
    var onRenegotiation: (() -> Void)?

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onCandidate?(candidate)
    }

    func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if rtpReceiver.track?.kind == "video", let stream = streams.first {
            onAddStream?(stream)
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if !stream.videoTracks.isEmpty { onAddStream?(stream) }
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        onSignalingChange?(stateChanged)
    }

    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {
        onRenegotiation?()
    }

    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
