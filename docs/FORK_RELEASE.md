# Saber Fork – Releases und Updates

## Versionsschema

Tag: `v<upstream-version>-fork.<N>`, z. B. `v1.38.0-fork.1`

| Tag              | `--build-name`   | `--build-number` (= Android versionCode) |
|------------------|------------------|------------------------------------------|
| `v1.38.0-fork.1` | `1.38.0-fork.1`  | `138000 × 100 + 1 = 13800001`            |
| `v1.38.0-fork.2` | `1.38.0-fork.2`  | `13800002`                               |
| `v1.39.0-fork.1` | `1.39.0-fork.1`  | `13900001`                               |

- `<upstream-version>` muss mit `buildName` in `lib/data/version.dart`
  übereinstimmen, sonst bricht der Workflow ab.
- Die Upstream-Buildnummer wird aus der Version berechnet
  (`major·100000 + minor·1000 + patch·10`), wie in `lib/data/version.dart`.
- `N` läuft von 1 bis 99 und beginnt nach einem Upstream-Update wieder bei 1.
- Die Buildnummer muss **streng steigen**. Der Workflow vergleicht sie mit allen
  bisherigen Fork-Releases und bricht ab, wenn sie nicht größer ist. Android
  würde ein Update mit kleinerer oder gleicher versionCode ohnehin ablehnen.

## Voraussetzungen (einmalig)

- Signatur-Secrets sind eingetragen, siehe [FORK_SIGNING.md](FORK_SIGNING.md).
- GitHub Actions sind im Fork aktiviert (Tab **Actions** → „I understand my
  workflows, go ahead and enable them“).

## Neues Release auslösen

1. Änderungen sind über einen Pull Request in `main` gemergt und die Tests
   („Run tests“) sind grün.
2. Lokal den neuesten Stand holen und ein **annotiertes** Tag setzen. Die
   Tag-Nachricht wird als Release-Text angezeigt, auch im Update-Dialog der App:

   ```powershell
   git checkout main
   git pull
   git tag -a v1.38.0-fork.2 -m "Formerkennung beim Halten des Stifts"
   git push origin v1.38.0-fork.2
   ```

3. Der Workflow **„Saber Fork release (Android)“** startet automatisch:
   1. prüft Tag-Format, Version und dass die Buildnummer steigt,
   2. prüft, dass alle Signatur-Secrets vorhanden sind,
   3. führt die komplette Testsuite (`flutter test`) aus. Bei einem Fehler wird
      **nichts** gebaut.
   4. baut die FOSS-APK (ohne Sentry/Onyx), signiert mit deinem Schlüssel,
   5. prüft Signatur, Paketname (`io.github.solomon7.saberfork`), versionCode
      und versionName der APK,
   6. erstellt das GitHub-Release mit `SaberFork_v1.38.0-fork.2.apk` und
      `SaberFork_v1.38.0-fork.2.apk.sha256`.

Alternativ ohne lokales Tag: **Actions → Saber Fork release (Android) → Run
workflow**, Branch `main` wählen und das Tag (z. B. `v1.38.0-fork.2`) eingeben.
Das Tag wird dann auf dem neuesten Commit des Branches erzeugt.

Schlägt der Workflow fehl, wird kein Release erstellt. Bei einem Tag-Push
löschst du das Tag (`git push --delete origin v1.38.0-fork.2` und
`git tag -d v1.38.0-fork.2`), behebst den Fehler und pushst das Tag erneut.

## Erste Installation auf dem Tablet

1. Auf dem Tablet die Release-Seite öffnen:
   <https://github.com/7Solomon/saber/releases/latest>
2. `SaberFork_v….apk` herunterladen und öffnen. Android fragt einmalig, ob der
   Browser/Dateimanager Apps installieren darf.
3. Die App heißt **„Saber Fork“** (hellblaues Icon) und ist eine eigene App
   neben der Original-Saber (gelbes Icon). Beide haben **getrennte** Notizen.
   Die Original-Saber wird nicht verändert.

## Update auf dem Tablet

1. Saber Fork öffnen → **Einstellungen** → **„Nach Updates suchen“**.
2. Die App fragt `https://api.github.com/repos/7Solomon/saber/releases/latest`
   ab und vergleicht die Buildnummer des Releases mit der installierten.
   - „Du hast die neueste Version.“ → nichts zu tun.
   - Bei Netzwerkfehlern erscheint eine Meldung mit „Erneut versuchen“.
3. Bei einem Update: Version und Release-Text werden angezeigt →
   **„Herunterladen und installieren“**.
4. Die APK und die `.sha256`-Datei werden heruntergeladen und die Prüfsumme wird
   geprüft. Stimmt sie nicht, wird die Datei gelöscht und **nichts** installiert.
5. Beim ersten Update bittet die App, „Unbekannte Apps installieren“ für
   Saber Fork zu erlauben → **„Einstellungen öffnen“** → Schalter aktivieren →
   zurück zur App. Der Installer öffnet sich dann automatisch.
6. Im Android-Installer **„Aktualisieren“** bestätigen. Die Notizen bleiben
   erhalten.

**Niemals deinstallieren, um ein Update zu erzwingen.** Wenn Android meldet,
dass das Paket in Konflikt steht, wurde die APK mit einem anderen Schlüssel
signiert. Dann bitte nicht deinstallieren, sondern die Ursache prüfen.

## Upstream-Updates übernehmen

```powershell
git fetch upstream
git checkout -b fork/merge-upstream-1.39.0 main
git merge v1.39.0          # Upstream-Tag
# Konflikte lösen, PR öffnen, Tests grün → mergen
git tag -a v1.39.0-fork.1 -m "Upstream 1.39.0"
git push origin v1.39.0-fork.1
```

Die Upstream-Workflows (iOS, macOS, Windows, Linux, Snap, Play Store,
Landing-Page, Top-Issues, Submodul-Check, Test-Image) sind im Fork nur noch
manuell startbar. Ihre ursprünglichen Trigger stehen als Kommentar in den
Dateien, damit Merges konfliktarm bleiben.
