import XCTest

@testable import BlinkLive

final class BlinkAPIClientTests: XCTestCase {
  override func tearDown() {
    URLProtocolStub.handler = nil
    super.tearDown()
  }

  func testLoginFollowsSignInRedirectAndRegionalTier() async throws {
    var authorizationRequests = 0
    URLProtocolStub.handler = { request in
      switch (request.url?.path, request.httpMethod) {
      case ("/oauth/v2/authorize", "GET"):
        authorizationRequests += 1
        XCTAssertEqual(authorizationRequests, 1)
        let items = try XCTUnwrap(
          URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["client_id"], "ios")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertFalse(try XCTUnwrap(query["code_challenge"]).isEmpty)
        XCTAssertEqual(query["hardware_id"], "00000000-0000-0000-0000-000000000001")
        return Self.response(for: request, json: "{}")
      case ("/oauth/v2/signin", "GET"):
        return Self.response(
          for: request,
          body:
            #"<script id="oauth-args" type="application/json">{"csrf-token":"csrf-123"}</script>"#)
      case ("/oauth/v2/signin", "POST"):
        let body = try XCTUnwrap(String(data: Self.bodyData(from: request), encoding: .utf8))
        XCTAssertTrue(body.contains("username=test%2Btag@example.com"))
        XCTAssertTrue(body.contains("password=sec%2Bret%2642"))
        let fields = try Self.formFields(from: request)
        XCTAssertEqual(fields["username"], "test+tag@example.com")
        XCTAssertEqual(fields["password"], "sec+ret&42")
        XCTAssertEqual(fields["csrf-token"], "csrf-123")
        let publicKey = try XCTUnwrap(fields["public_key"])
        XCTAssertEqual(fields["public_signing_key"], publicKey)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(fields["browser_salt"]))?.count, 16)
        return Self.response(
          for: request, statusCode: 201,
          body:
            #"{"status":"auth-completed","redirect_url":"immedia-blink://applinks.blink.com/signin/callback?code=auth-code"}"#
        )
      case ("/oauth/token", "POST"):
        let fields = try Self.formFields(from: request)
        XCTAssertEqual(fields["code"], "auth-code")
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertFalse(try XCTUnwrap(fields["code_verifier"]).isEmpty)
        return Self.response(
          for: request, json: #"{"access_token":"token-123","refresh_token":"refresh-123"}"#)
      case ("/api/v1/users/tier_info", "GET"):
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        return Self.response(for: request, json: #"{"account_id":12,"tier":"e002"}"#)
      default:
        XCTFail("Unexpected request: \(request)")
        throw URLError(.badURL)
      }
    }

    let client = BlinkAPIClient(configuration: stubConfiguration())
    let result = try await client.login(
      credentials: BlinkCredentials(email: "test+tag@example.com", password: "sec+ret&42"),
      uniqueID: "00000000-0000-0000-0000-000000000001"
    )

    XCTAssertEqual(authorizationRequests, 1)
    XCTAssertEqual(result.accountID, 12)
    XCTAssertEqual(result.baseURL.absoluteString, "https://rest-e002.immedia-semi.com")
    XCTAssertEqual(result.token, "token-123")
    XCTAssertEqual(result.refreshToken, "refresh-123")
  }

  func testServerErrorIdentifiesFailingEndpoint() async throws {
    URLProtocolStub.handler = { request in
      XCTAssertEqual(request.url?.path, "/oauth/v2/authorize")
      return Self.response(
        for: request, statusCode: 400, body: #"{"message":"malformed request"}"#)
    }

    let client = BlinkAPIClient(configuration: stubConfiguration())
    do {
      _ = try await client.login(
        credentials: BlinkCredentials(email: "test@example.com", password: "secret"),
        uniqueID: "00000000-0000-0000-0000-000000000001")
      XCTFail("Expected server error")
    } catch let error as BlinkAPIError {
      XCTAssertEqual(
        error.errorDescription,
        "Blink meldet (HTTP 400, /oauth/v2/authorize): malformed request")
    }
  }

  func testHomeScreenUsesTokenAndDecodesCameras() async throws {
    URLProtocolStub.handler = { request in
      XCTAssertEqual(request.url?.path, "/api/v3/accounts/12/homescreen")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")

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

  func testPINVerificationCompletesOAuth() async throws {
    var authorizationRequests = 0
    URLProtocolStub.handler = { request in
      switch (request.url?.path, request.httpMethod) {
      case ("/oauth/v2/authorize", "GET"):
        authorizationRequests += 1
        XCTAssertEqual(authorizationRequests, 1)
        return Self.response(for: request, json: "{}")
      case ("/oauth/v2/signin", "GET"):
        return Self.response(
          for: request,
          body:
            #"<script id="oauth-args" type="application/json">{"csrf-token":"csrf-123"}</script>"#)
      case ("/oauth/v2/signin", "POST"):
        return Self.response(
          for: request, statusCode: 412,
          body: #"{"tsv_methods":["email"],"tsv_state":"email"}"#)
      case ("/oauth/v2/2fa/verify", "POST"):
        let fields = try Self.formFields(from: request)
        XCTAssertEqual(fields["2fa_code"], "123456")
        XCTAssertEqual(fields["csrf-token"], "csrf-123")
        XCTAssertEqual(fields["tsv_state"], "email")
        return Self.response(
          for: request, statusCode: 201,
          body:
            #"{"status":"auth-completed","redirect_url":"immedia-blink://applinks.blink.com/signin/callback?code=pin-code"}"#
        )
      case ("/oauth/token", "POST"):
        XCTAssertEqual(try Self.formFields(from: request)["code"], "pin-code")
        return Self.response(for: request, json: #"{"access_token":"token-123"}"#)
      case ("/api/v1/users/tier_info", "GET"):
        return Self.response(for: request, json: #"{"account_id":12,"tier":"e002"}"#)
      default:
        XCTFail("Unexpected request: \(request)")
        throw URLError(.badURL)
      }
    }

    let client = BlinkAPIClient(configuration: stubConfiguration())
    do {
      _ = try await client.login(
        credentials: BlinkCredentials(email: "test@example.com", password: "secret"),
        uniqueID: "00000000-0000-0000-0000-000000000001")
      XCTFail("Expected PIN verification")
    } catch BlinkAPIError.verificationRequired(let channel) {
      XCTAssertEqual(channel, "email")
    }
    let result = try await client.verify(pin: "123456")

    XCTAssertEqual(authorizationRequests, 1)
    XCTAssertEqual(result?.token, "token-123")
  }

  func testRecordUsesSelectedNetworkAndCamera() async throws {
    URLProtocolStub.handler = { request in
      XCTAssertEqual(request.url?.path, "/network/45/camera/99/clip")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
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
      token: "token-123",
      refreshToken: nil,
      baseURL: URL(string: "https://rest-e002.immedia-semi.com")!
    )
  }

  private static func response(for request: URLRequest, json: String) -> (HTTPURLResponse, Data) {
    response(for: request, body: json)
  }

  private static func response(
    for request: URLRequest, statusCode: Int = 200, body: String = "",
    headers: [String: String] = [:]
  ) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: headers
    )!
    return (response, Data(body.utf8))
  }

  private static func formFields(from request: URLRequest) throws -> [String: String] {
    let body = try bodyData(from: request)
    var components = URLComponents()
    components.percentEncodedQuery = String(data: body, encoding: .utf8)
    return Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map {
        ($0.name, $0.value ?? "")
      })
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
