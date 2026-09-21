import Foundation

@MainActor
final class AppPreferences {
  private enum Key {
    static let uniqueID = "blink.uniqueID"
    static let cameraTarget = "blink.cameraTarget"
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var uniqueID: String {
    if let existing = defaults.string(forKey: Key.uniqueID),
      let uuid = UUID(uuidString: existing)
    {
      return uuid.uuidString.uppercased()
    }

    let newValue = UUID().uuidString.uppercased()
    defaults.set(newValue, forKey: Key.uniqueID)
    return newValue
  }

  var cameraTarget: CameraTarget? {
    get {
      guard let data = defaults.data(forKey: Key.cameraTarget) else {
        return nil
      }
      return try? JSONDecoder().decode(CameraTarget.self, from: data)
    }
    set {
      let data = try? newValue.map { try JSONEncoder().encode($0) }
      defaults.set(data, forKey: Key.cameraTarget)
    }
  }
}
