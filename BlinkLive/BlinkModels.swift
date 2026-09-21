import Foundation

struct BlinkCredentials: Codable, Equatable, Sendable {
  let email: String
  let password: String
  let refreshToken: String?

  init(email: String, password: String, refreshToken: String? = nil) {
    self.email = email
    self.password = password
    self.refreshToken = refreshToken
  }
}

struct BlinkSession: Equatable, Sendable {
  let accountID: Int64
  let token: String
  let refreshToken: String?
  let baseURL: URL
}

struct BlinkCamera: Decodable, Identifiable, Equatable, Sendable {
  let id: Int64
  let name: String
  let networkID: Int64
  let status: String?
  let battery: String?

  var statusText: String {
    var parts: [String] = []

    if let status {
      parts.append(status == "offline" ? "Offline" : "Status: \(status)")
    }
    if let battery {
      parts.append(battery == "low" ? "Batterie schwach" : "Batterie: \(battery)")
    }

    return parts.isEmpty ? "Bereit" : parts.joined(separator: " · ")
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case networkID = "network_id"
    case status
    case battery
  }
}

struct CameraTarget: Codable, Equatable, Sendable {
  let id: Int64
  let networkID: Int64
  let name: String

  init(camera: BlinkCamera) {
    id = camera.id
    networkID = camera.networkID
    name = camera.name
  }
}

struct HomeScreenResponse: Decodable, Sendable {
  let cameras: [BlinkCamera]
}

struct CommandResponse: Decodable, Sendable {
  let id: Int64
}

enum AppPhase: Equatable {
  case launching
  case credentials
  case authenticating
  case pin(channel: String?)
  case loadingCameras
  case cameras([BlinkCamera])
  case recording(CameraTarget)
  case success(CameraTarget, commandID: Int64, date: Date)
  case failure(String)

  var transitionKey: String {
    switch self {
    case .launching: "launching"
    case .credentials: "credentials"
    case .authenticating: "authenticating"
    case .pin: "pin"
    case .loadingCameras: "loadingCameras"
    case .cameras: "cameras"
    case .recording: "recording"
    case .success: "success"
    case .failure: "failure"
    }
  }
}
