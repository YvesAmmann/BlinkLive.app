import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
  @Published private(set) var phase: AppPhase = .launching
  @Published var email = ""
  @Published var password = ""
  @Published var pin = ""
  @Published private(set) var formError: String?

  private let api: BlinkAPIClient
  private let credentialsStore: KeychainCredentialsStore
  private let preferences: AppPreferences
  private var activeSession: BlinkSession?
  private var currentCredentials: BlinkCredentials?
  private var didStart = false

  init(
    api: BlinkAPIClient = BlinkAPIClient(),
    credentialsStore: KeychainCredentialsStore = KeychainCredentialsStore(),
    preferences: AppPreferences? = nil
  ) {
    self.api = api
    self.credentialsStore = credentialsStore
    self.preferences = preferences ?? AppPreferences()
  }

  var isConfigured: Bool {
    preferences.cameraTarget != nil
  }

  func start() async {
    guard !didStart else { return }
    didStart = true
    await bootstrap()
  }

  func submitCredentials() async {
    let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedEmail.isEmpty, !password.isEmpty else {
      formError = "E-Mail-Adresse und Passwort sind erforderlich."
      return
    }

    formError = nil
    let credentials = BlinkCredentials(email: trimmedEmail, password: password)
    await authenticate(credentials: credentials, target: preferences.cameraTarget)
  }

  func submitPIN() async {
    let trimmedPIN = pin.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPIN.isEmpty else {
      formError = "Bitte den Bestätigungscode eingeben."
      return
    }

    formError = nil
    phase = .authenticating
    do {
      guard let session = try await api.verify(pin: trimmedPIN) else {
        phase = .pin(channel: nil)
        formError = "Der Bestätigungscode wurde nicht akzeptiert."
        return
      }
      if let credentials = currentCredentials {
        let updatedCredentials = BlinkCredentials(
          email: credentials.email,
          password: credentials.password,
          refreshToken: session.refreshToken
        )
        try credentialsStore.save(updatedCredentials)
        currentCredentials = updatedCredentials
      }
      activeSession = session
      pin = ""
      await continueAfterAuthentication(session: session, target: preferences.cameraTarget)
    } catch {
      phase = .failure(message(for: error))
    }
  }

  func select(_ camera: BlinkCamera) async {
    guard let session = activeSession else {
      phase = .failure("Die Anmeldung ist abgelaufen. Bitte erneut versuchen.")
      return
    }

    let target = CameraTarget(camera: camera)
    preferences.cameraTarget = target
    await record(target: target, session: session)
  }

  func recordAgain() async {
    guard let target = preferences.cameraTarget else {
      await chooseDifferentCamera()
      return
    }

    if let activeSession {
      await record(target: target, session: activeSession)
    } else {
      await retry()
    }
  }

  func chooseDifferentCamera() async {
    preferences.cameraTarget = nil

    if let activeSession {
      await loadCameras(session: activeSession)
    } else if let currentCredentials {
      await authenticate(credentials: currentCredentials, target: nil)
    } else {
      await bootstrap()
    }
  }

  func retry() async {
    await bootstrap()
  }

  func signOut() {
    do {
      try credentialsStore.delete()
    } catch {
      phase = .failure(message(for: error))
      return
    }

    preferences.cameraTarget = nil
    activeSession = nil
    currentCredentials = nil
    email = ""
    password = ""
    pin = ""
    formError = nil
    phase = .credentials
  }

  private func bootstrap() async {
    phase = .launching
    formError = nil

    do {
      guard let credentials = try credentialsStore.load() else {
        phase = .credentials
        return
      }
      email = credentials.email
      password = credentials.password
      await authenticate(credentials: credentials, target: preferences.cameraTarget)
    } catch {
      phase = .failure(message(for: error))
    }
  }

  private func authenticate(credentials: BlinkCredentials, target: CameraTarget?) async {
    phase = .authenticating

    do {
      let session = try await api.login(credentials: credentials, uniqueID: preferences.uniqueID)
      let updatedCredentials = BlinkCredentials(
        email: credentials.email,
        password: credentials.password,
        refreshToken: session.refreshToken
      )
      try credentialsStore.save(updatedCredentials)
      currentCredentials = updatedCredentials
      activeSession = session
      await continueAfterAuthentication(session: session, target: target)
    } catch let BlinkAPIError.verificationRequired(channel) {
      try? credentialsStore.save(credentials)
      currentCredentials = credentials
      activeSession = nil
      phase = .pin(channel: channel)
    } catch {
      phase = .failure(message(for: error))
    }
  }

  private func continueAfterAuthentication(session: BlinkSession, target: CameraTarget?) async {
    if let target {
      await record(target: target, session: session)
    } else {
      await loadCameras(session: session)
    }
  }

  private func loadCameras(session: BlinkSession) async {
    phase = .loadingCameras
    do {
      phase = .cameras(try await api.cameras(session: session))
    } catch {
      phase = .failure(message(for: error))
    }
  }

  private func record(target: CameraTarget, session: BlinkSession) async {
    phase = .recording(target)
    do {
      let commandID = try await api.record(target: target, session: session)
      phase = .success(target, commandID: commandID, date: Date())
    } catch {
      phase = .failure(message(for: error))
    }
  }

  private func message(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}
