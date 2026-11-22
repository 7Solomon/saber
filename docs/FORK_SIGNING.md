# Saber Fork – Signaturschlüssel einrichten

Android installiert ein Update nur, wenn die neue APK mit **genau demselben
Schlüssel** signiert ist wie die installierte App. Ist der Schlüssel ein anderer,
musst du die App deinstallieren – und **dabei gehen alle Notizen verloren**.
Deshalb gilt:

- Es gibt genau **einen** Release-Schlüssel für Saber Fork, und den hast nur du.
- Der Release-Workflow (`.github/workflows/fork-release.yml`) bricht ab, wenn
  die Secrets fehlen. Er greift nie auf `android/fallback-key.jks` oder einen
  Debug-Schlüssel zurück und löscht den Fallback-Schlüssel vor dem Build sogar.
- Nach dem Build prüft der Workflow mit `apksigner`, dass die APK wirklich mit
  deinem Schlüssel signiert ist.
- Der Schlüssel wird **nie** ins Repository committet.

## 1. Keystore erzeugen (einmalig, auf deinem PC)

`keytool` gehört zum JDK, z. B. `C:\Program Files\Java\jdk-*\bin\keytool.exe`
oder das JDK aus Android Studio (`<Android Studio>\jbr\bin\keytool.exe`).

Den Keystore **außerhalb** des Repository-Ordners anlegen:

```powershell
cd $HOME\Documents
keytool -genkeypair -v `
  -keystore saberfork-release.jks `
  -storetype PKCS12 `
  -alias saberfork `
  -keyalg RSA -keysize 4096 `
  -validity 36500
```

- Du wirst nach einem **Keystore-Passwort** gefragt. Nimm ein langes, zufälliges
  Passwort (z. B. aus deinem Passwortmanager).
- Bei PKCS12 ist das Schlüssel-Passwort gleich dem Keystore-Passwort.
  `KEY_STORE_PASSWORD` und `KEY_PASSWORD` sind dann identisch.
- Name/Organisation usw. sind beliebig (z. B. nur den Namen ausfüllen).
- `-validity 36500` ≈ 100 Jahre. Ein abgelaufener Schlüssel kann keine Updates
  mehr signieren.

Fingerabdruck anzeigen (brauchst du in Schritt 3):

```powershell
keytool -list -v -keystore saberfork-release.jks -alias saberfork
```

Notiere die Zeile `SHA256: AB:CD:…`.

## 2. Keystore base64-kodieren

PowerShell:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\Documents\saberfork-release.jks")) |
  Set-Content -NoNewline saberfork-release.jks.b64
```

Git Bash / Linux:

```bash
base64 -w0 saberfork-release.jks > saberfork-release.jks.b64
```

## 3. Secrets im Fork eintragen

GitHub → `7Solomon/saber` → **Settings → Secrets and variables → Actions**

Unter **Secrets** („New repository secret“):

| Name                 | Wert                                               |
|----------------------|----------------------------------------------------|
| `SIGNING_KEY`        | kompletter Inhalt von `saberfork-release.jks.b64`  |
| `KEY_STORE_PASSWORD` | Keystore-Passwort                                  |
| `KEY_PASSWORD`       | Schlüssel-Passwort (bei PKCS12 = Keystore-Passwort) |
| `ALIAS`              | `saberfork` (bzw. der gewählte Alias)              |

Optional, aber empfohlen, unter **Variables** („New repository variable“):

| Name                 | Wert                                                 |
|----------------------|------------------------------------------------------|
| `SIGNING_CERT_SHA256` | der SHA256-Fingerabdruck aus Schritt 1 (mit oder ohne `:`) |

Ist die Variable gesetzt, bricht der Workflow ab, wenn das Zertifikat der
gebauten APK nicht genau diesem Fingerabdruck entspricht. Das schützt dich, falls
das Secret `SIGNING_KEY` jemals versehentlich durch einen anderen Schlüssel
ersetzt wird.

Danach die Datei `saberfork-release.jks.b64` löschen.

Alternativ per GitHub CLI:

```powershell
gh secret set SIGNING_KEY --repo 7Solomon/saber < saberfork-release.jks.b64
gh secret set KEY_STORE_PASSWORD --repo 7Solomon/saber
gh secret set KEY_PASSWORD --repo 7Solomon/saber
gh secret set ALIAS --repo 7Solomon/saber --body saberfork
gh variable set SIGNING_CERT_SHA256 --repo 7Solomon/saber --body "AB:CD:..."
```

## 4. Keystore sicher aufbewahren

**Verlierst du den Keystore oder das Passwort, kannst du nie wieder ein Update
für die installierte App bauen.** (Dann bleibt nur: Notizen exportieren bzw. per
Sync sichern, deinstallieren, neu installieren.)

- Bewahre `saberfork-release.jks` **und** das Passwort an mindestens zwei
  getrennten Orten auf, z. B.:
  - im Passwortmanager (Keystore-Datei als Anhang und Passwort),
  - auf einem USB-Stick oder einer externen Festplatte (offline).
- Lege den Keystore **nie** in den Repository-Ordner. `.gitignore` ignoriert
  zwar `*.jks`/`*.keystore`, aber verlass dich nicht darauf.
- Gib den Keystore niemandem weiter. Wer ihn hat, kann Updates bauen, die dein
  Tablet als echt akzeptiert.

## Lokale Builds

Lokale Builds (`flutter run`, `flutter build apk` ohne `android/key.properties`)
werden mit dem öffentlichen Upstream-Schlüssel `android/fallback-key.jks`
signiert. **Installiere so einen Build nie auf dem Tablet über den Fork.**
Android lehnt ihn ab („Paket steht in Konflikt“). Deinstalliere die App in dem
Fall **nicht**, sonst sind die Notizen weg. Installiere nur APKs aus den
GitHub-Releases bzw. über „Nach Updates suchen“.
