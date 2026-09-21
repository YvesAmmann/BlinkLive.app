import SwiftUI

struct ContentView: View {
  @StateObject private var model = AppViewModel()

  var body: some View {
    ZStack(alignment: .top) {
      BlinkTheme.background
        .ignoresSafeArea()

      LinearGradient(
        colors: [BlinkTheme.fuchsia, BlinkTheme.cyan, BlinkTheme.blue],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(height: 5)
      .ignoresSafeArea(edges: .top)

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          header
          phaseContent
          disclaimer
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity)
      }
      .scrollDismissesKeyboard(.interactively)
    }
    .fontDesign(.rounded)
    .task {
      await model.start()
    }
    .animation(.snappy(duration: 0.3), value: model.phase.transitionKey)
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "video.fill")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 46, height: 46)
        .background(BlinkTheme.blue, in: RoundedRectangle(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 2) {
        Text("BlinkLive")
          .font(.title2.bold())
        Text("Aufnahme beim App-Start")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if model.isConfigured {
        Image(systemName: "checkmark.shield.fill")
          .foregroundStyle(BlinkTheme.cyan)
          .accessibilityLabel("Eingerichtet")
      }
    }
  }

  @ViewBuilder
  private var phaseContent: some View {
    switch model.phase {
    case .launching:
      ProgressPanel(
        title: "Konfiguration wird geladen",
        detail: "Einen Moment bitte."
      )

    case .credentials:
      credentialsForm

    case .authenticating:
      ProgressPanel(
        title: "Verbindung wird hergestellt",
        detail: "Blink-Konto wird sicher angemeldet."
      )

    case .pin(let channel):
      pinForm(channel: channel)

    case .loadingCameras:
      ProgressPanel(
        title: "Kameras werden geladen",
        detail: "Verfügbare Geräte werden abgerufen."
      )

    case .cameras(let cameras):
      cameraSelection(cameras)

    case .recording(let target):
      ProgressPanel(
        title: "Aufnahme wird gestartet",
        detail: target.name,
        symbol: "record.circle"
      )

    case .success(let target, let commandID, let date):
      successPanel(target: target, commandID: commandID, date: date)

    case .failure(let message):
      failurePanel(message: message)
    }
  }

  private var credentialsForm: some View {
    VStack(alignment: .leading, spacing: 18) {
      SectionHeading(
        symbol: "person.badge.key.fill",
        title: "Blink-Konto verbinden",
        detail: "Die Zugangsdaten bleiben verschlüsselt im iOS-Schlüsselbund."
      )

      VStack(spacing: 12) {
        TextField("E-Mail-Adresse", text: $model.email)
          .textContentType(.username)
          .keyboardType(.emailAddress)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .fieldStyle()

        SecureField("Passwort", text: $model.password)
          .textContentType(.password)
          .fieldStyle()
      }

      if let formError = model.formError {
        Label(formError, systemImage: "exclamationmark.circle.fill")
          .font(.footnote.weight(.medium))
          .foregroundStyle(BlinkTheme.fuchsia)
      }

      PrimaryButton(title: "Anmelden", symbol: "arrow.right") {
        Task { await model.submitCredentials() }
      }
    }
    .panelStyle()
  }

  private func pinForm(channel: String?) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      SectionHeading(
        symbol: "lock.open.fill",
        title: "Gerät bestätigen",
        detail: verificationMessage(channel: channel)
      )

      TextField("Bestätigungscode", text: $model.pin)
        .keyboardType(.numberPad)
        .textContentType(.oneTimeCode)
        .fieldStyle()

      if let formError = model.formError {
        Label(formError, systemImage: "exclamationmark.circle.fill")
          .font(.footnote.weight(.medium))
          .foregroundStyle(BlinkTheme.fuchsia)
      }

      PrimaryButton(title: "Code bestätigen", symbol: "checkmark") {
        Task { await model.submitPIN() }
      }
    }
    .panelStyle()
  }

  private func cameraSelection(_ cameras: [BlinkCamera]) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      SectionHeading(
        symbol: "video.badge.ellipsis",
        title: "Aufnahmekamera wählen",
        detail: "Diese Kamera wird künftig bei jedem App-Start ausgelöst."
      )

      if cameras.isEmpty {
        Label(
          "In diesem Blink-Konto wurden keine Kameras gefunden.", systemImage: "video.slash.fill"
        )
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
      } else {
        ForEach(cameras) { camera in
          Button {
            Task { await model.select(camera) }
          } label: {
            HStack(spacing: 14) {
              Image(systemName: camera.status == "offline" ? "video.slash.fill" : "video.fill")
                .foregroundStyle(camera.status == "offline" ? BlinkTheme.fuchsia : BlinkTheme.cyan)
                .frame(width: 24)

              VStack(alignment: .leading, spacing: 3) {
                Text(camera.name)
                  .font(.headline)
                  .foregroundStyle(BlinkTheme.primaryText)
                Text(camera.statusText)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              Spacer()
              Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(BlinkTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
          }
          .buttonStyle(.plain)
        }
      }

      Button("Abmelden", role: .destructive) {
        model.signOut()
      }
      .font(.subheadline.weight(.semibold))
    }
    .panelStyle()
  }

  private func successPanel(target: CameraTarget, commandID: Int64, date: Date) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .top, spacing: 16) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 34))
          .foregroundStyle(BlinkTheme.cyan)

        VStack(alignment: .leading, spacing: 5) {
          Text("Aufnahme angefordert")
            .font(.title3.bold())
          Text(target.name)
            .foregroundStyle(.secondary)
        }
      }

      Divider()

      LabeledContent("Zeitpunkt", value: date.formatted(date: .abbreviated, time: .standard))
      LabeledContent("Befehl", value: "#\(commandID)")

      PrimaryButton(title: "Erneut aufnehmen", symbol: "record.circle") {
        Task { await model.recordAgain() }
      }

      Button {
        Task { await model.chooseDifferentCamera() }
      } label: {
        Label("Andere Kamera wählen", systemImage: "video.badge.ellipsis")
      }
      .buttonStyle(.borderless)
      .font(.subheadline.weight(.semibold))
    }
    .panelStyle(highlight: BlinkTheme.cyan)
  }

  private func failurePanel(message: String) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      SectionHeading(
        symbol: "exclamationmark.triangle.fill",
        title: "Aufnahme nicht gestartet",
        detail: message,
        color: BlinkTheme.fuchsia
      )

      PrimaryButton(title: "Erneut versuchen", symbol: "arrow.clockwise") {
        Task { await model.retry() }
      }

      Button("Zugangsdaten ändern", role: .destructive) {
        model.signOut()
      }
      .font(.subheadline.weight(.semibold))
    }
    .panelStyle(highlight: BlinkTheme.fuchsia)
  }

  private var disclaimer: some View {
    Label(
      "BlinkLive verwendet eine inoffizielle Blink-Schnittstelle. Änderungen am Dienst können die Funktion beeinträchtigen.",
      systemImage: "info.circle"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 4)
  }

  private func verificationMessage(channel: String?) -> String {
    switch channel?.lowercased() {
    case "sms", "phone":
      "Den von Blink per SMS gesendeten Code eingeben."
    case "email":
      "Den von Blink per E-Mail gesendeten Code eingeben."
    default:
      "Den von Blink gesendeten Bestätigungscode eingeben."
    }
  }
}

private struct SectionHeading: View {
  let symbol: String
  let title: String
  let detail: String
  var color = BlinkTheme.blue

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: symbol)
        .font(.title3.weight(.semibold))
        .foregroundStyle(color)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 5) {
        Text(title)
          .font(.title3.bold())
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct ProgressPanel: View {
  let title: String
  let detail: String
  var symbol = "antenna.radiowaves.left.and.right"

  var body: some View {
    HStack(spacing: 16) {
      ZStack {
        Image(systemName: symbol)
          .font(.title2.weight(.semibold))
          .foregroundStyle(BlinkTheme.blue)
        ProgressView()
          .controlSize(.large)
          .tint(BlinkTheme.cyan)
          .scaleEffect(1.45)
      }
      .frame(width: 52, height: 52)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .panelStyle(highlight: BlinkTheme.blue)
  }
}

private struct PrimaryButton: View {
  let title: String
  let symbol: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(.headline)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .foregroundStyle(.white)
        .background(BlinkTheme.blue, in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
  }
}

extension View {
  fileprivate func panelStyle(highlight: Color = BlinkTheme.blue) -> some View {
    self
      .padding(20)
      .background(BlinkTheme.surface, in: RoundedRectangle(cornerRadius: 8))
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(highlight)
          .frame(width: 4)
          .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(BlinkTheme.border, lineWidth: 1)
      }
  }

  fileprivate func fieldStyle() -> some View {
    self
      .padding(.horizontal, 14)
      .frame(height: 50)
      .background(BlinkTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(BlinkTheme.border, lineWidth: 1)
      }
  }
}
