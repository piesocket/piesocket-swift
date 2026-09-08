import XCTest
@testable import Channels

final class ConnectionTests: XCTestCase {

    private func v4Options() -> PieSocketOptions {
        let o = PieSocketOptions()
        o.setVersion(version: "4")
        o.setEnableLogs(enableLogs: false)
        return o
    }

    private func testConn(_ sent: Sent) -> Connection {
        let conn = Connection(testingPrimary: "room-1", options: v4Options(), logger: Logger(enabled: false))
        conn.sendOverride = { sent.append($0) }
        return conn
    }

    private final class Sent {
        private(set) var frames: [String] = []
        private let lock = NSLock()
        func append(_ s: String) { lock.lock(); frames.append(s); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
        subscript(_ i: Int) -> String { lock.lock(); defer { lock.unlock() }; return frames[i] }
    }

    private func json(_ s: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as! [String: Any]
    }

    // MARK: - Outbound tagging

    func testSendTagsSystemChannelForSecondaryNotPrimary() {
        let sent = Sent()
        let conn = testConn(sent)

        let e = PieSocketEvent(event: "chat"); e.setData(data: "hi")
        conn.send("room-1", e)
        conn.send("room-2", e)

        XCTAssertNil(json(sent[0])["system::channel"])
        XCTAssertEqual(json(sent[1])["system::channel"] as? String, "room-2")
    }

    func testSendRawTagsJsonStringTheSameWay() {
        let sent = Sent()
        let conn = testConn(sent)
        conn.sendRaw("room-2", "{\"event\":\"ping\"}")
        XCTAssertEqual(json(sent[0])["system::channel"] as? String, "room-2")
    }

    func testSendRawSendsNonJsonVerbatim() {
        let sent = Sent()
        let conn = testConn(sent)
        conn.sendRaw("room-2", "plain text")
        XCTAssertEqual(sent[0], "plain text")
    }

    func testSendBinaryEmitsRawBytesForPrimary() {
        let conn = Connection(testingPrimary: "room-1", options: v4Options(), logger: Logger(enabled: false))
        var got: Data?
        conn.sendBinaryOverride = { got = $0 }
        XCTAssertNoThrow(try conn.sendBinary("room-1", Data([1, 2, 3, 4])))
        XCTAssertEqual(got, Data([1, 2, 3, 4]))
    }

    func testSendBinaryThrowsForSecondary() {
        let conn = Connection(testingPrimary: "room-1", options: v4Options(), logger: Logger(enabled: false))
        conn.sendBinaryOverride = { _ in }
        XCTAssertThrowsError(try conn.sendBinary("room-2", Data([1, 2, 3])))
    }

    // MARK: - Subscribe control frames

    func testSubscribeChannelSendsSubscribeOnceConnected() {
        let sent = Sent()
        let conn = testConn(sent)
        conn.onOpen()
        conn.subscribeChannel("room-2", ["channel": "room-2", "uuid": "u1"]) { _ in }

        XCTAssertEqual(sent.count, 1)
        let frame = json(sent[0])
        XCTAssertEqual(frame["event"] as? String, "system::subscribe")
        XCTAssertEqual((frame["data"] as? [String: Any])?["channel"] as? String, "room-2")
    }

    func testSubscribeChannelDefersUntilConnectedThenReplays() {
        let sent = Sent()
        let conn = testConn(sent)
        conn.subscribeChannel("room-2", ["channel": "room-2"]) { _ in }
        XCTAssertEqual(sent.count, 0)
        conn.onOpen()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(json(sent[0])["event"] as? String, "system::subscribe")
    }

    func testSubscribeChannelResolvesOnSubscribeSuccess() {
        let sent = Sent()
        let conn = testConn(sent)
        conn.onOpen()
        let exp = expectation(description: "resolved")
        conn.subscribeChannel("room-2", ["channel": "room-2"]) { error in
            XCTAssertNil(error)
            exp.fulfill()
        }
        conn.onMessage("{\"event\":\"system::subscribe_success\",\"data\":{\"channel\":\"room-2\"}}")
        wait(for: [exp], timeout: 1)
    }

    func testSubscribeChannelRejectsOnSubscribeError() {
        let sent = Sent()
        let conn = testConn(sent)
        conn.onOpen()
        let exp = expectation(description: "rejected")
        conn.subscribeChannel("room-2", ["channel": "room-2"]) { error in
            XCTAssertNotNil(error)
            exp.fulfill()
        }
        conn.onMessage("{\"event\":\"system::subscribe_error\",\"data\":{\"channel\":\"room-2\",\"error\":\"nope\"}}")
        wait(for: [exp], timeout: 1)
    }

    func testUnsubscribeChannelRejectsForPrimary() {
        let conn = testConn(Sent())
        let exp = expectation(description: "rejected")
        conn.unsubscribeChannel("room-1") { error in
            XCTAssertNotNil(error)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // MARK: - Inbound routing

    func testRoutesAppFrameToChannelNamedBySystemChannel() {
        let conn = testConn(Sent())
        let opts = v4Options()
        let primary = Channel(multiplexedRoomId: "room-1", options: opts, logger: Logger(enabled: false), hub: conn)
        let secondary = Channel(multiplexedRoomId: "room-2", options: opts, logger: Logger(enabled: false), hub: conn)
        conn.attachChannel("room-1", primary)
        conn.attachChannel("room-2", secondary)

        var onPrimary: String?
        var onSecondary: String?
        primary.listen(eventName: "chat") { onPrimary = $0.getData() }
        secondary.listen(eventName: "chat") { onSecondary = $0.getData() }

        conn.onMessage("{\"event\":\"chat\",\"data\":\"hello\",\"system::channel\":\"room-2\"}")

        XCTAssertEqual(onSecondary, "hello")
        XCTAssertNil(onPrimary)
    }

    func testFallsBackToPrimaryWhenNoSystemChannel() {
        let conn = testConn(Sent())
        let primary = Channel(multiplexedRoomId: "room-1", options: v4Options(), logger: Logger(enabled: false), hub: conn)
        conn.attachChannel("room-1", primary)

        var got: String?
        primary.listen(eventName: "chat") { got = $0.getData() }
        conn.onMessage("{\"event\":\"chat\",\"data\":\"hi\"}")
        XCTAssertEqual(got, "hi")
    }

    func testSystemBinaryCarriesBase64DataThrough() {
        let conn = testConn(Sent())
        let primary = Channel(multiplexedRoomId: "room-1", options: v4Options(), logger: Logger(enabled: false), hub: conn)
        conn.attachChannel("room-1", primary)

        var got: String?
        primary.listen(eventName: "system::binary") { got = $0.getData() }
        conn.onMessage("{\"event\":\"system::binary\",\"data\":\"aGVsbG8=\"}")
        XCTAssertEqual(got, "aGVsbG8=")
    }

    func testRequestMembersSendsGetMembersAndResolvesOnMemberList() {
        let sent = Sent()
        let conn = testConn(sent)
        let primary = Channel(multiplexedRoomId: "room-1", options: v4Options(), logger: Logger(enabled: false), hub: conn)
        conn.attachChannel("room-1", primary)

        let exp = expectation(description: "members")
        conn.requestMembers("room-1") { result in
            if case .success(let members) = result {
                XCTAssertEqual(members.count, 1)
                XCTAssertEqual((members[0] as? [String: Any])?["uuid"] as? String, "a")
                exp.fulfill()
            } else {
                XCTFail("expected success")
            }
        }

        XCTAssertEqual(json(sent[0])["event"] as? String, "system::get_members")
        conn.onMessage("{\"event\":\"system::member_list\",\"data\":{\"channel\":\"room-1\",\"members\":[{\"uuid\":\"a\"}]}}")
        wait(for: [exp], timeout: 1)
    }
}
