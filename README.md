# BlinkLive

BlinkLive ist eine kleine SwiftUI-App, die nach einmaliger Einrichtung bei jedem
Kaltstart automatisch einen neuen Videoclip auf einer gewählten Blink-Kamera
anfordert.

## Start

1. `xcodegen generate` im Projektordner ausführen.
2. `BlinkLive.xcodeproj` in Xcode öffnen.
3. Ein Development Team und bei Bedarf eine eigene Bundle-ID wählen.
4. Die App auf einem iPhone starten und das Blink-Konto verbinden.
5. Falls Blink einen PIN sendet, diesen in der App bestätigen.
6. Die gewünschte Kamera auswählen. Die erste Aufnahme startet sofort.

E-Mail-Adresse und Passwort liegen im iOS-Schlüsselbund mit
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Kamera-ID, Netzwerk-ID und die
stabile Client-ID werden in `UserDefaults` gespeichert.

## API

Die Implementierung folgt der inoffiziellen Dokumentation unter
<https://github.com/MattTW/BlinkMonitorProtocol>:

- Anmeldung: `POST /api/v5/account/login`
- PIN-Prüfung: `POST /api/v4/account/{account}/client/{client}/pin/verify`
- Kameraliste: `GET /api/v3/accounts/{account}/homescreen`
- Aufnahme: `POST /network/{network}/camera/{camera}/clip`

Die Aufnahme-API arbeitet asynchron. Eine erfolgreiche Anzeige bedeutet, dass
Blink den Befehl angenommen hat; sie bestätigt nicht, dass der Clip bereits
vollständig gespeichert wurde.

BlinkLive nutzt keine offizielle öffentliche Blink-API. Der Anbieter kann
Endpoints, Authentifizierung oder Nutzungsbedingungen jederzeit ändern.