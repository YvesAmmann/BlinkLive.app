import XCTest

@testable import BlinkLive

final class BlinkAPIClientTests: XCTestCase {
  override func tearDown() {
    URLProtocolStub.handler = nil
    super.tearDown()
  }

  func testLoginUsesDocumentedPayloadAndRegionalTier() async throws {
    URLProtocolStub.handler = { request in
      XCTAssertEqual(
        request.url?.absoluteString, "https://rest-prod.immedia-semi.com/api/v5/account/login")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

      let body = try Self.bodyData(from: request)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
      XCTAssertEqual(json["email"], "test@example.com")
      XCTAssertEqual(json["password"], "secret")
      XCTAssertEqual(json["unique_id"], "BLINKLIVE_TEST-ID")
      XCTAssertEqual(json["client_name"], "BlinkLive")
      XCTAssertEqual(json["reauth"], "true")

      return Self.response(
        for: request,
        json: """
          {
            "account": {
              "account_id": 12,
              "client_id": 34,
              "tier": "e002",
              "client_verification_required": false,
              "verification_channel": "email"
            },
            "auth": { "token": "token-123" }
          }
          """
      )
    }

    let client = BlinkAPIClient(configuration: stubConfiguration())
    let result = try await client.login(
      credentials: BlinkCredentials(email: "test@example.com", password: "secret"),
      uniqueID: "BLINKLIVE_TEST-ID"
    )

    XCTAssertEqual(result.accountID, 12)
    XCTAssertEqual(result.clientID, 34)
    XCTAssertEqual(result.baseURL.absoluteString, "https://rest-e002.immedia-semi.com")
    XCTAssertEqual(result.token, "token-123")
    XCTAssertFalse(result.verificationRequired)
  }

  func testHomeScreenUsesTokenAndDecodesCameras() async throws {
    URLProtocolStub.handler = { request in
      XCTAssertEqual(request.url?.path, "/api/v3/accounts/12/homescreen")
      XCTAssertEqual(request.value(forHTTPHeaderField: "TOKEN-AUTH"), "token-123")

      return Self.response(
        for: request,
        json: """
          {
            "cameras": [
              { "id": 99, "name": "Garten", "network_id": 45, "status": "done", "battery": "ok" }
            ]
          }
          """
      )
    }

    let client = BlinkAPIClient(configuration: stubConfiguration())
    let cameras = try await client.cameras(session: session())

    XCTAssertEqual(
      cameras, [BlinkCamera(id: 99, name: "Garten", networkID: 45, status: "done", battery: "ok")])
  }

  func testPINVerificationUsesAccountAndClient() async throws {
    URLProtocolStub.handler = { request in
      XCTAssertEqual(request.url?.path, "/api/v4/account/12/client/34/pin/verify")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "TOKEN-AUTH"), "token-123")

      let body = try Self.bodyData(from: request)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
      XCTAssertEqual(json["pin"], "123456")
      return Self.response(for: request, json: #"{ "valid": true }"#)
    }

    let client = BlinkAPIClient(configuration: stubConfiguration())
    let valid = try await client.verify(pin: "123456", session: session())

    XCTAssertTrue(valid)
  }

  func testRecordUsesSelectedNetworkAndCamera() async throws {
    URLProtocolStub.handler = { request in
      XCTAssertEqual(request.url?.path, "/network/45/camera/99/clip")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "TOKEN-AUTH"), "token-123")
      return Self.response(for: request, json: #"{ "id": 87654321 }"#)
    }

    let client = BlinkAPIClient(configuration: stubConfiguration())
    let target = CameraTarget(
      camera: BlinkCamera(id: 99, name: "Garten", networkID: 45, status: nil, battery: nil))
    let commandID = try await client.record(target: target, session: session())

    XCTAssertEqual(commandID, 87_654_321)
  }

  private func stubConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolStub.self]
    return configuration
  }

  private func session() -> BlinkSession {
    BlinkSession(
      accountID: 12,
      clientID: 34,
      token: "token-123",
      baseURL: URL(string: "https://rest-e002.immedia-semi.com")!,
      verificationRequired: false,
      verificationChannel: nil
    )
  }

  private static func response(for request: URLRequest, json: String) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(json.utf8))
  }

  private static func bodyData(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
      return body
    }

    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
      let bytesRead = stream.read(buffer, maxLength: bufferSize)
      guard bytesRead >= 0 else {
        throw stream.streamError ?? URLError(.cannotDecodeContentData)
      }
      if bytesRead == 0 {
        break
      }
      data.append(buffer, count: bytesRead)
    }
    return data
  }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
