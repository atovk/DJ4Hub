import Foundation
import XCTest
@testable import DJ4Hub

private final class ClientFailureProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class NativeClientStateTests: XCTestCase {
    override func tearDown() {
        ClientFailureProtocol.handler = nil
        super.tearDown()
    }

    @MainActor func testTransportFailureMakesStoreRetryable() async {
        ClientFailureProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let service = serviceUsingClientFailureProtocol()
        defer { service.session.invalidateAndCancel() }
        service.connected = true
        let store = HubStore(service: service)
        store.ready = true

        await store.refresh()

        XCTAssertFalse(store.ready)
        XCTAssertFalse(service.connected)
        XCTAssertTrue(service.connectionText.contains("请重试连接"))

        ClientFailureProtocol.handler = { _ in
            (200, Data("{\"ok\":true,\"demo\":false,\"esim_available\":false}".utf8))
        }
        await service.start()

        XCTAssertTrue(service.connected)
        XCTAssertEqual(service.base.port, 7576)
    }

    @MainActor func testBackendHttpFailureKeepsConnectionStateForDeviceErrors() async {
        ClientFailureProtocol.handler = { _ in
            (503, Data("{\"error\":\"device busy\"}".utf8))
        }
        let service = serviceUsingClientFailureProtocol()
        defer { service.session.invalidateAndCancel() }
        service.connected = true
        let store = HubStore(service: service)
        store.ready = true

        await store.refresh()

        XCTAssertTrue(store.ready)
        XCTAssertTrue(service.connected)
        XCTAssertFalse(store.healthKnown)
    }

    func testBackupRefreshClearsStaleErrorButKeepsOperationMessage() {
        var display = HistoryBackupDisplayState()
        display.applyRefresh(HubValue(["directory": "/tmp/dj4hub", "enabled": true, "last_time": "—", "error": "disk full"]))
        XCTAssertEqual(display.message, "备份失败：disk full")

        display.operationMessage = "备份已完成"
        display.applyRefresh(HubValue(["directory": "/tmp/dj4hub", "enabled": true, "last_time": "—", "error": ""]))

        XCTAssertEqual(display.message, "备份已完成")
        XCTAssertEqual(display.directory, "/tmp/dj4hub")
        XCTAssertTrue(display.enabled)
    }

    func testBackupOperationFailureSurvivesNormalStatusRefresh() {
        var display = HistoryBackupDisplayState()
        display.operationMessage = "备份已完成"

        display.beginOperation()
        display.operationFailed(URLError(.cannotWriteToFile))
        display.applyRefresh(HubValue(["directory": "/tmp/dj4hub", "enabled": true, "last_time": "—", "error": ""]))

        XCTAssertTrue(display.message.contains("操作失败"))
        XCTAssertFalse(display.message.contains("备份已完成"))
    }

    @MainActor private func serviceUsingClientFailureProtocol() -> HubService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClientFailureProtocol.self]
        let session = URLSession(configuration: config)
        return HubService(session: session)
    }
}
