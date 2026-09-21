import Foundation
import Security

struct KeychainCredentialsStore: Sendable {
  private let service = "cc.ammann.apps.blinklive"
  private let account = "blink-credentials"

  func load() throws -> BlinkCredentials? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = result as? Data else {
      throw KeychainError(status: status)
    }
    return try JSONDecoder().decode(BlinkCredentials.self, from: data)
  }

  func save(_ credentials: BlinkCredentials) throws {
    let data = try JSONEncoder().encode(credentials)
    let lookup: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)

    if updateStatus == errSecItemNotFound {
      var item = lookup
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw KeychainError(status: addStatus)
      }
    } else if updateStatus != errSecSuccess {
      throw KeychainError(status: updateStatus)
    }
  }

  func delete() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }
}

private struct KeychainError: LocalizedError {
  let status: OSStatus

  var errorDescription: String? {
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Status \(status)"
    return "Der iOS-Schlüsselbund konnte nicht verwendet werden: \(detail)"
  }
}
