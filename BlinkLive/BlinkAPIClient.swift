import CryptoKit
import Foundation
import Security

actor BlinkAPIClient {
  private let loginBaseURL = URL(string: "https://rest-prod.immedia-semi.com")!
  private let oauthBaseURL = URL(string: "https://api.oauth.blink.com")!
  private let urlSession: URLSession
  private let decoder = JSONDecoder()
  private var pendingOAuth: PendingOAuth?

  private let appVersion = "50.1"
  private let browserUserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1"
  private let tokenUserAgent = "Blink/2511191620 CFNetwork/3860.200.71 Darwin/25.1.0"

  init(configuration: URLSessionConfiguration = .default) {
    configuration.timeoutIntervalForRequest = 30
    urlSession = URLSession(configuration: configuration)
  }

  func login(credentials: BlinkCredentials, uniqueID: String) async throws -> BlinkSession {
    pendingOAuth = nil
    let hardwareID =
      UUID(uuidString: uniqueID)?.uuidString.uppercased() ?? UUID().uuidString.uppercased()

    if let refreshToken = credentials.refreshToken,
      let session = try await refreshSession(refreshToken: refreshToken, hardwareID: hardwareID)
    {
      return session
    }

    let pkce = try makePKCEPair()
    try await authorize(hardwareID: hardwareID, codeChallenge: pkce.challenge)
    let csrfToken = try await fetchCSRFToken()
    let outcome = try await signIn(credentials: credentials, csrfToken: csrfToken)

    switch outcome {
    case .authenticated:
      return try await completeOAuth(codeVerifier: pkce.verifier, hardwareID: hardwareID)
    case .verificationRequired(let channel):
      pendingOAuth = PendingOAuth(
        csrfToken: csrfToken,
        codeVerifier: pkce.verifier,
        hardwareID: hardwareID
      )
      throw BlinkAPIError.verificationRequired(channel: channel)
    }
  }

  func verify(pin: String) async throws -> BlinkSession? {
    guard let pendingOAuth else {
      throw BlinkAPIError.verificationExpired
    }

    var request = formRequest(
      url: endpoint(baseURL: oauthBaseURL, path: "/oauth/v2/2fa/verify"),
      fields: [
        "2fa_code": pin,
        "csrf-token": pendingOAuth.csrfToken,
        "remember_me": "false",
      ]
    )
    applyBrowserHeaders(to: &request)

    let (data, response) = try await perform(request)
    guard response.statusCode == 201 else {
      if [400, 401, 403, 412].contains(response.statusCode) {
        return nil
      }
      throw serverError(response: response, data: data)
    }

    let verification = try decoder.decode(OAuthVerificationResponse.self, from: data)
    guard verification.status == "auth-completed" else {
      return nil
    }

    let session = try await completeOAuth(
      codeVerifier: pendingOAuth.codeVerifier,
      hardwareID: pendingOAuth.hardwareID
    )
    self.pendingOAuth = nil
    return session
  }

  private func refreshSession(refreshToken: String, hardwareID: String) async throws
    -> BlinkSession?
  {
    var request = formRequest(
      url: endpoint(baseURL: oauthBaseURL, path: "/oauth/token"),
      fields: [
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "client_id": "ios",
        "scope": "client",
        "hardware_id": hardwareID,
      ]
    )
    applyTokenHeaders(to: &request)

    let (data, response) = try await perform(request)
    guard response.statusCode == 200 else {
      return nil
    }

    let token = try decoder.decode(OAuthTokenResponse.self, from: data)
    return try await makeSession(token: token, fallbackRefreshToken: refreshToken)
  }

  private func authorize(hardwareID: String, codeChallenge: String) async throws {
    var components = URLComponents(
      url: endpoint(baseURL: oauthBaseURL, path: "/oauth/v2/authorize"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "app_brand", value: "blink"),
      URLQueryItem(name: "app_version", value: appVersion),
      URLQueryItem(name: "client_id", value: "ios"),
      URLQueryItem(name: "code_challenge", value: codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "device_brand", value: "Apple"),
      URLQueryItem(name: "device_model", value: "iPhone16,1"),
      URLQueryItem(name: "device_os_version", value: "26.1"),
      URLQueryItem(name: "hardware_id", value: hardwareID),
      URLQueryItem(
        name: "redirect_uri", value: "immedia-blink://applinks.blink.com/signin/callback"),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: "client"),
    ]
    guard let url = components?.url else {
      throw BlinkAPIError.invalidResponse
    }

    var request = URLRequest(url: url)
    applyBrowserHeaders(to: &request, acceptsHTML: true)
    let (data, response) = try await perform(request)
    guard response.statusCode == 200 else {
      throw serverError(response: response, data: data)
    }
  }

  private func fetchCSRFToken() async throws -> String {
    var request = URLRequest(url: endpoint(baseURL: oauthBaseURL, path: "/oauth/v2/signin"))
    applyBrowserHeaders(to: &request, acceptsHTML: true)

    let (data, response) = try await perform(request)
    guard response.statusCode == 200 else {
      throw serverError(response: response, data: data)
    }
    guard let html = String(data: data, encoding: .utf8),
      let csrfToken = csrfToken(from: html)
    else {
      throw BlinkAPIError.invalidResponse
    }
    return csrfToken
  }

  private func signIn(credentials: BlinkCredentials, csrfToken: String) async throws
    -> SignInOutcome
  {
    var request = formRequest(
      url: endpoint(baseURL: oauthBaseURL, path: "/oauth/v2/signin"),
      fields: [
        "username": credentials.email,
        "password": credentials.password,
        "csrf-token": csrfToken,
      ]
    )
    applyBrowserHeaders(to: &request)

    let (data, response) = try await perform(request, followsRedirects: false)
    if 300..<400 ~= response.statusCode {
      return .authenticated
    }
    let verification = verificationDetails(from: data)
    if response.statusCode == 412 {
      return .verificationRequired(channel: verification.channel)
    }
    if response.statusCode == 202, verification.isRequired {
      return .verificationRequired(channel: verification.channel)
    }
    throw serverError(response: response, data: data)
  }

  private func completeOAuth(codeVerifier: String, hardwareID: String) async throws -> BlinkSession
  {
    let code = try await fetchAuthorizationCode()
    var request = formRequest(
      url: endpoint(baseURL: oauthBaseURL, path: "/oauth/token"),
      fields: [
        "app_brand": "blink",
        "client_id": "ios",
        "code": code,
        "code_verifier": codeVerifier,
        "grant_type": "authorization_code",
        "hardware_id": hardwareID,
        "redirect_uri": "immedia-blink://applinks.blink.com/signin/callback",
        "scope": "client",
      ]
    )
    applyTokenHeaders(to: &request)

    let token: OAuthTokenResponse = try await send(request)
    return try await makeSession(token: token, fallbackRefreshToken: nil)
  }

  private func fetchAuthorizationCode() async throws -> String {
    var request = URLRequest(url: endpoint(baseURL: oauthBaseURL, path: "/oauth/v2/authorize"))
    applyBrowserHeaders(to: &request)

    let (data, response) = try await perform(request, followsRedirects: false)
    guard 300..<400 ~= response.statusCode,
      let location = response.value(forHTTPHeaderField: "Location"),
      let components = URLComponents(string: location),
      let code = components.queryItems?.first(where: { $0.name == "code" })?.value
    else {
      throw serverError(response: response, data: data)
    }
    return code
  }

  private func makeSession(
    token: OAuthTokenResponse,
    fallbackRefreshToken: String?
  ) async throws -> BlinkSession {
    var request = URLRequest(url: endpoint(baseURL: loginBaseURL, path: "/api/v1/users/tier_info"))
    request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("27.0ANDROID_28373244", forHTTPHeaderField: "User-Agent")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    let tier: TierResponse = try await send(request)
    return BlinkSession(
      accountID: tier.accountID,
      token: token.accessToken,
      refreshToken: token.refreshToken ?? fallbackRefreshToken,
      baseURL: try regionalBaseURL(tier: tier.tier)
    )
  }

  func cameras(session: BlinkSession) async throws -> [BlinkCamera] {
    let path = "/api/v3/accounts/\(session.accountID)/homescreen"
    let request = authorizedRequest(
      url: endpoint(baseURL: session.baseURL, path: path), token: session.token)
    let response: HomeScreenResponse = try await send(request)
    return response.cameras.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  func record(target: CameraTarget, session: BlinkSession) async throws -> Int64 {
    let path = "/network/\(target.networkID)/camera/\(target.id)/clip"
    var request = authorizedRequest(
      url: endpoint(baseURL: session.baseURL, path: path), token: session.token)
    request.httpMethod = "POST"

    let response: CommandResponse = try await send(request)
    return response.id
  }

  private func authorizedRequest(url: URL, token: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  private func formRequest(url: URL, fields: [String: String]) -> URLRequest {
    var components = URLComponents()
    components.queryItems = fields.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    return request
  }

  private func applyBrowserHeaders(to request: inout URLRequest, acceptsHTML: Bool = false) {
    request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(
      acceptsHTML ? "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" : "*/*",
      forHTTPHeaderField: "Accept")
    request.setValue("de-DE,de;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
    if request.httpMethod == "POST" {
      request.setValue("https://api.oauth.blink.com", forHTTPHeaderField: "Origin")
      request.setValue(
        endpoint(baseURL: oauthBaseURL, path: "/oauth/v2/signin").absoluteString,
        forHTTPHeaderField: "Referer")
    }
  }

  private func applyTokenHeaders(to request: inout URLRequest) {
    request.setValue(tokenUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("*/*", forHTTPHeaderField: "Accept")
  }

  private func csrfToken(from html: String) -> String? {
    let pattern =
      #"<script(?=[^>]*\bid\s*=\s*["']oauth-args["'])(?=[^>]*\btype\s*=\s*["']application/json["'])[^>]*>([\s\S]*?)</script>"#
    guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
      let match = expression.firstMatch(
        in: html,
        range: NSRange(html.startIndex..., in: html)
      ),
      let jsonRange = Range(match.range(at: 1), in: html),
      let data = String(html[jsonRange]).data(using: .utf8),
      let arguments = try? decoder.decode(OAuthArguments.self, from: data)
    else {
      return nil
    }
    return arguments.csrfToken
  }

  private func verificationDetails(from data: Data) -> (isRequired: Bool, channel: String?) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return (false, nil)
    }
    if let methods = object["tsv_methods"] as? [String], let method = methods.first {
      return (true, method)
    }
    if object["tsv_state"] != nil || object["next_time_in_secs"] != nil {
      return (true, nil)
    }
    return (false, nil)
  }

  private func makePKCEPair() throws -> (verifier: String, challenge: String) {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw BlinkAPIError.invalidResponse
    }

    let verifier = Data(bytes).base64URLEncodedString()
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    return (verifier, challenge)
  }

  private func endpoint(baseURL: URL, path: String) -> URL {
    path.split(separator: "/").reduce(baseURL) { url, component in
      url.appendingPathComponent(String(component))
    }
  }

  private func regionalBaseURL(tier: String?) throws -> URL {
    guard let tier, !tier.isEmpty else {
      return loginBaseURL
    }

    let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
    guard tier.unicodeScalars.allSatisfy(allowedCharacters.contains),
      let url = URL(string: "https://rest-\(tier).immedia-semi.com")
    else {
      throw BlinkAPIError.invalidResponse
    }
    return url
  }

  private func send<Response: Decodable & Sendable>(_ request: URLRequest) async throws -> Response
  {
    let (data, response) = try await perform(request)

    guard 200..<300 ~= response.statusCode else {
      throw serverError(response: response, data: data)
    }

    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw BlinkAPIError.decoding(error)
    }
  }

  private func perform(
    _ request: URLRequest,
    followsRedirects: Bool = true
  ) async throws -> (Data, HTTPURLResponse) {
    let data: Data
    let response: URLResponse

    do {
      if followsRedirects {
        (data, response) = try await urlSession.data(for: request)
      } else {
        (data, response) = try await urlSession.data(
          for: request,
          delegate: NoRedirectDelegate.shared
        )
      }
    } catch {
      throw BlinkAPIError.transport(error)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw BlinkAPIError.invalidResponse
    }
    return (data, httpResponse)
  }

  private func serverError(response: HTTPURLResponse, data: Data) -> BlinkAPIError {
    let details = try? decoder.decode(ServerErrorResponse.self, from: data)
    return .server(statusCode: response.statusCode, message: details?.displayMessage)
  }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  static let shared = NoRedirectDelegate()

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

private struct PendingOAuth: Sendable {
  let csrfToken: String
  let codeVerifier: String
  let hardwareID: String
}

private enum SignInOutcome {
  case authenticated
  case verificationRequired(channel: String?)
}

private struct OAuthArguments: Decodable {
  let csrfToken: String

  private enum CodingKeys: String, CodingKey {
    case csrfToken = "csrf-token"
  }
}

private struct OAuthVerificationResponse: Decodable {
  let status: String
}

private struct OAuthTokenResponse: Decodable, Sendable {
  let accessToken: String
  let refreshToken: String?

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
  }
}

private struct TierResponse: Decodable, Sendable {
  let accountID: Int64
  let tier: String

  private enum CodingKeys: String, CodingKey {
    case accountID = "account_id"
    case tier
  }
}

private struct ServerErrorResponse: Decodable {
  let message: String?
  let error: String?
  let errorDescription: String?

  var displayMessage: String? {
    message ?? errorDescription ?? error
  }

  private enum CodingKeys: String, CodingKey {
    case message
    case error
    case errorDescription = "error_description"
  }
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

enum BlinkAPIError: LocalizedError {
  case transport(Error)
  case invalidResponse
  case verificationRequired(channel: String?)
  case verificationExpired
  case server(statusCode: Int, message: String?)
  case decoding(Error)

  var errorDescription: String? {
    switch self {
    case .transport:
      "Blink ist derzeit nicht erreichbar. Bitte die Internetverbindung prüfen."
    case .invalidResponse:
      "Blink hat eine ungültige Antwort gesendet."
    case .verificationRequired:
      "Blink verlangt einen Bestätigungscode."
    case .verificationExpired:
      "Die Anmeldung ist abgelaufen. Bitte erneut anmelden."
    case .server(let statusCode, let message):
      if statusCode == 401 || statusCode == 403 {
        "Die Anmeldung wurde abgelehnt. Bitte Zugangsdaten und Bestätigung prüfen."
      } else if let message, !message.isEmpty {
        "Blink meldet: \(message)"
      } else {
        "Der Blink-Dienst hat mit Status \(statusCode) geantwortet."
      }
    case .decoding:
      "Die Blink-Antwort hat ein unbekanntes Format. Die inoffizielle API könnte geändert worden sein."
    }
  }
}
