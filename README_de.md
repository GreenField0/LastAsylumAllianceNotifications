# LastAsylum (Deutsche Anleitung)

*🇺🇸 [Click here for the English Version](README.md)*  
> 📌 **Allianz-Guides:** [📅 Zeitplan](ALLIANZ-ZEITPLAN.md) | [📜 Regeln & SvS](ALLIANZ_REGELN.md) | [🦸 Helden](HELDEN_GUIDE.md) | [🦅 Raben](RABEN_GUIDE.md) | [💎 Tipps](ANFAENGER_TIPPS.md)

Automatisierte Benachrichtigungen für die LastAsylum-Allianz – tägliche Zeitpläne und individuelle R4/R5-Ankündigungen, übermittelt an Discord und Telegram via GitHub Actions.

---

## Tägliches Briefing (Daily Briefing)

Postet jeden Morgen den aktuellen Tagesplan für das Allianz-Duell und den Überlebenskampf in Discord (und optional Telegram). Der Zeitplan ist in der Datei [`schedule.json`](schedule.json) definiert.

**Workflow:** [`daily-briefing.yml`](.github/workflows/daily-briefing.yml) — läuft täglich um 04:00 Uhr CEST (02:00 UTC).

### GitHub Secrets setzen

| Secret | Wert |
|---|---|
| `DISCORD_WEBHOOK_URL_DAILY` | Webhook-URL des Ziel-Discord-Channels |
| `TELEGRAM_BOT_TOKEN` | Telegram Bot Token (optional) |
| `TELEGRAM_CHAT_ID` | Telegram Channel/Chat-ID (optional) |

*Hinweis: Wenn die Telegram-Secrets nicht gesetzt sind, wird der Versand an Telegram automatisch übersprungen.*

---

## Individuelle Ankündigungen (R4/R5 Self-Service)

R4- und R5-Mitglieder können eigene Discord- und Telegram-Benachrichtigungen ganz einfach über ein Google Form anlegen und planen. Das Bearbeiten oder Löschen von Einträgen geschieht direkt im verknüpften Google Sheet — es ist kein separates Admin-Interface oder Programmierwissen nötig!

### 1. Google Form erstellen

Erstelle ein Google Formular mit folgenden Fragen. **Wichtig:** Die Titel müssen exakt so lauten, damit das Skript sie erkennt:

| Frage | Typ | Optionen / Hinweis |
|---|---|---|
| Nachricht | Absatz (Text) | Pflichtfeld |
| Titel (optional) | Kurzantwort (Text) | wird als Embed-Titel angezeigt |
| Bild-URL (optional) | Kurzantwort (Text) | Link zu einem Bild (z. B. Imgur, Discord-CDN), wird als Embed-Bild angezeigt |
| Wen benachrichtigen? (optional) | Kästchen (Checkboxen) | `Everyone`, `Gildenleitung`, `User` - Mehrfachauswahl möglich |
| Zeit-Option | Multiple Choice | `Sofort`, `In X Minuten`, `An einem Datum`, `Wiederkehrend` |
| Minuten | Kurzantwort (Zahl) | nur für "In X Minuten" |
| Datum | Datum | nur für "An einem Datum" |
| Uhrzeit (Datum) | Uhrzeit | nur für "An einem Datum" |
| Wochentag | Kästchen (Checkboxen) | `Montag`..`Sonntag`, Mehrfachauswahl möglich, nur für "Wiederkehrend" |
| Uhrzeit (Wiederkehrend) | Uhrzeit | nur für "Wiederkehrend" |
| End-Datum (optional) | Datum | nur für "Wiederkehrend" |

#### Bedingte Anzeige (Branching) einrichten

Branching funktioniert in Google Forms nur über **Abschnitte**, gesteuert von einer **Multiple Choice**- oder **Dropdown**-Frage (passt hier perfekt zur "Zeit-Option"):

1. Vier Abschnitte anlegen (Symbol "Abschnitt hinzufügen" in der rechten Werkzeugleiste):
   - Abschnitt 1: `Nachricht` + `Titel (optional)` + `Bild-URL (optional)` + `Wen benachrichtigen? (optional)` + `Zeit-Option`
   - Abschnitt 2: `Minuten`
   - Abschnitt 3: `Datum` + `Uhrzeit (Datum)`
   - Abschnitt 4: `Wochentag` + `Uhrzeit (Wiederkehrend)` + `End-Datum (optional)`
2. Bei der Frage "Zeit-Option" das ⋮-Menü öffnen → **"Bei Antwort zu Abschnitt wechseln"** aktivieren. Pro Antwortoption erscheint ein Dropdown zum Zielabschnitt:
   - `Sofort` → **Formular einreichen** (keine weiteren Felder nötig)
   - `In X Minuten` → Abschnitt 2
   - `An einem Datum` → Abschnitt 3
   - `Wiederkehrend` → Abschnitt 4
3. Bei den Abschnitten 2-4 jeweils das Abschnitts-Dropdown ("Weiter zu Abschnitt ...") auf **"Formular einreichen"** setzen, sonst würde nach dem Ausfüllen automatisch zum nächsten Abschnitt weitergesprungen.
4. Mit der Vorschau (Augen-Symbol oben rechts) alle vier Pfade testen.

*Den Formular-Link nur an vertrauenswürdige R4/R5-Mitglieder weitergeben.*

### 2. Antworten-Sheet vorbereiten

- Im Form-Editor unter "Antworten" auf das Sheets-Symbol klicken → verknüpftes Sheet erstellen.
- Im Sheet drei weitere Spalten **manuell** ganz rechts ergänzen (nur die Header eintragen, darunter leer lassen): `Status`, `LetzterVersand`, `Discord-Message-ID`.
- Notiere dir die Spreadsheet-ID aus der URL (`.../d/<ID>/edit`).

Sobald die Spalte `Discord-Message-ID` existiert, merkt sich das Skript die ID jeder gesendeten Nachricht. Wird eine Zeile im Sheet gelöscht oder wird eine wiederkehrende Erinnerung durch den Versand in der nächsten Woche ersetzt, löscht das Skript die alte zugehörige Discord-Nachricht automatisch. So bleibt im Channel immer nur die aktuelle Ankündigung stehen!

### 3. Google Service Account einrichten (kostenlos, keine Kreditkarte nötig)

1. Gehe zu [console.cloud.google.com](https://console.cloud.google.com) → neues Projekt anlegen.
2. "APIs & Services" → "Library" → **Google Sheets API** suchen und aktivieren.
3. "APIs & Services" → "Credentials" → "Create Credentials" → **Service Account**.
4. Im Service Account auf "Keys" → "Add Key" → "Create new key" → **JSON** auswählen und herunterladen.
5. Das Google Sheet aus Schritt 2 mit der E-Mail-Adresse des Service Accounts (`...@...iam.gserviceaccount.com`) mit der Berechtigung **Editor** teilen.

### 4. GitHub Secrets setzen

| Secret | Wert |
|---|---|
| `DISCORD_WEBHOOK_URL_CUSTOM` | Webhook-URL des Ziel-Channels |
| `GOOGLE_SHEET_ID` | Spreadsheet-ID aus Schritt 2 |
| `GOOGLE_SERVICE_ACCOUNT_KEY` | Kompletter Inhalt der heruntergeladenen JSON-Key-Datei aus Schritt 3 |
| `DISCORD_ROLE_ID_GILDENLEITUNG` | Rollen-ID der Gildenleitung-Rolle (optional, nur für Erwähnung nötig) |
| `DISCORD_ROLE_ID_USER` | Rollen-ID der User-Rolle (optional, nur für Erwähnung nötig) |
| `TELEGRAM_BOT_TOKEN` | Telegram Bot Token (optional) |
| `TELEGRAM_CHAT_ID` | Telegram Channel/Chat-ID (optional) |

**Rollen-ID in Discord herausfinden:**  
Discord-Einstellungen → Erweitert → **Entwicklermodus** aktivieren. Danach in den Server-Einstellungen unter "Rollen" mit Rechtsklick auf die jeweilige Rolle klicken → **ID kopieren**. Damit ein Rollen-Mention im Channel wirklich eine Benachrichtigung auslöst, muss in den Berechtigungen des Channels "@everyone erwähnen" oder die Erwähnung der spezifischen Rolle erlaubt sein.

Der Workflow [`custom-notifications.yml`](.github/workflows/custom-notifications.yml) prüft automatisch alle 15 Minuten, ob geplante Benachrichtigungen fällig sind, und ruft dabei [`Send-CustomNotifications.ps1`](Send-CustomNotifications.ps1) auf.

---

## ⚖️ Rechtlicher Hinweis & Disclaimer

Dieses Repository ist ein **inoffizielles, von Fans erstelltes Community-Tool**, das Spielern und Allianz-Leitungen (R4/R5) hilft, Benachrichtigungen und Zeitpläne zu organisieren.

* **Keine Verbindung zum Entwickler:** Dieses Projekt steht in keinerlei Verbindung zu den Entwicklern oder Herausgebern des Handyspiels *Last Asylum* und wird von diesen weder unterstützt, gesponsert noch offiziell gebilligt.
* **Markenrechte:** Alle Spieletitel, Namen, Grafiken und dazugehörigen Markenrechte sind Eigentum der jeweiligen Rechteinhaber.
* **Keine Garantie:** Die Nutzung dieses Tools erfolgt auf eigene Gefahr und ohne jegliche Gewährleistung oder Garantie.

---

## 📄 Lizenz

Dieses Projekt ist unter der [MIT-Lizenz](LICENSE) lizenziert.
