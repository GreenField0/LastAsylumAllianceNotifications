# LastAsylum

Automated notifications for the LastAsylum guild — daily schedule briefings and custom R4/R5 announcements delivered to Discord and Telegram via GitHub Actions.

---

## Daily Briefing

Posts the daily Alliance Duel and Survival schedule to Discord (and optionally Telegram) every morning. The schedule is defined in [`schedule.json`](schedule.json).

**Workflow:** [`daily-briefing.yml`](.github/workflows/daily-briefing.yml) — runs daily at 04:00 CEST (02:00 UTC).

### GitHub Secrets

| Secret | Value |
|---|---|
| `DISCORD_WEBHOOK_URL_DAILY` | Webhook URL of the target Discord channel |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token (optional) |
| `TELEGRAM_CHAT_ID` | Telegram channel/chat ID (optional) |

Telegram notifications are skipped if the secrets are not set.

---

## Custom Notifications (R4/R5 self-service)

R4/R5 can schedule their own Discord (and Telegram) notifications via a Google Form. Editing or deleting an entry is done directly in the linked Google Sheet — no separate admin UI required.

### 1. Create the Google Form

Question titles must match exactly so the script can find them:

| Question | Type | Options / Notes |
|---|---|---|
| Nachricht | Paragraph (long text) | Required |
| Titel (optional) | Short answer | Displayed as the Discord embed title |
| Bild-URL (optional) | Short answer | Image URL (e.g. Imgur, Discord CDN), shown as embed image |
| Wen benachrichtigen? (optional) | Checkboxes | `Everyone`, `Gildenleitung`, `User` — multiple selection allowed |
| Zeit-Option | Multiple choice | `Sofort`, `In X Minuten`, `An einem Datum`, `Wiederkehrend` |
| Minuten | Short answer (number) | Only for "In X Minuten" |
| Datum | Date | Only for "An einem Datum" |
| Uhrzeit (Datum) | Time | Only for "An einem Datum" |
| Wochentag | Checkboxes | `Montag`..`Sonntag`, multiple selection, only for "Wiederkehrend" |
| Uhrzeit (Wiederkehrend) | Time | Only for "Wiederkehrend" |
| End-Datum (optional) | Date | Only for "Wiederkehrend" |

#### Setting up conditional sections (branching)

Google Forms branching only works with **sections** controlled by a **Multiple Choice** or **Dropdown** question — which fits "Zeit-Option":

1. Create four sections (use the "Add section" icon in the right toolbar):
   - Section 1: `Nachricht` + `Titel (optional)` + `Bild-URL (optional)` + `Wen benachrichtigen? (optional)` + `Zeit-Option`
   - Section 2: `Minuten`
   - Section 3: `Datum` + `Uhrzeit (Datum)`
   - Section 4: `Wochentag` + `Uhrzeit (Wiederkehrend)` + `End-Datum (optional)`
2. On the "Zeit-Option" question, open the ⋮ menu → **"Go to section based on answer"**. A dropdown appears for each answer option:
   - `Sofort` → **Submit form**
   - `In X Minuten` → Section 2
   - `An einem Datum` → Section 3
   - `Wiederkehrend` → Section 4
3. For sections 2–4, set the section footer dropdown ("Continue to section…") to **"Submit form"** to prevent falling through to the next section.
4. Test all four paths using the preview (eye icon, top right).

Share the form link only with R4/R5.

### 2. Prepare the response sheet

- In the Form editor, go to "Responses" and click the Sheets icon → create a linked sheet.
- Manually add three column headers at the end of row 1 (leave the cells below blank): `Status`, `LetzterVersand`, `Discord-Message-ID`.
- Note the Spreadsheet ID from the URL (`.../d/<ID>/edit`).

Once `Discord-Message-ID` exists, the script tracks each sent message's ID. If a row is deleted or a recurring reminder is replaced by the next week's message, the script automatically deletes the corresponding Discord message — only the current one ever remains.

### 3. Google Service Account (free, no credit card required)

1. [console.cloud.google.com](https://console.cloud.google.com) → create a new project.
2. **APIs & Services** → **Library** → enable the **Google Sheets API**.
3. **APIs & Services** → **Credentials** → **Create Credentials** → **Service Account**.
4. Open the service account → **Keys** → **Add Key** → **Create new key** → download as **JSON**.
5. Share the sheet from step 2 with the service account's email address (`...@...iam.gserviceaccount.com`) as **Editor**.

### 4. Set GitHub Secrets

| Secret | Value |
|---|---|
| `DISCORD_WEBHOOK_URL_CUSTOM` | Webhook URL of the target Discord channel |
| `GOOGLE_SHEET_ID` | Spreadsheet ID from step 2 |
| `GOOGLE_SERVICE_ACCOUNT_KEY` | Full contents of the JSON key file from step 3 |
| `DISCORD_ROLE_ID_GILDENLEITUNG` | Role ID for the Gildenleitung role (optional) |
| `DISCORD_ROLE_ID_USER` | Role ID for the User role (optional) |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token (optional) |
| `TELEGRAM_CHAT_ID` | Telegram channel/chat ID (optional) |

**Finding a Discord role ID:** Enable Developer Mode in Discord (Settings → Advanced), then right-click a role in Server Settings → Roles → **Copy ID**. For role mentions to actually ping, the channel must also allow "Mention @everyone, @here and All Roles" or the specific role mention permission.

The workflow [`custom-notifications.yml`](.github/workflows/custom-notifications.yml) checks for due notifications every 15 minutes and runs [`Send-CustomNotifications.ps1`](Send-CustomNotifications.ps1).

R4/R5 können eigene Discord-Benachrichtigungen über ein Google Form anlegen. Bearbeiten/Löschen
geschieht direkt im verknüpften Google Sheet (Zeile ändern bzw. löschen).

### 1. Google Form erstellen

Fragen (Titel exakt so, damit das Skript sie findet):

| Frage | Typ | Optionen / Hinweis |
|---|---|---|
| Nachricht | Absatz (Text) | Pflichtfeld |
| Titel (optional) | Kurzantwort (Text) | wird als Embed-Titel angezeigt |
| Bild-URL (optional) | Kurzantwort (Text) | Link zu einem Bild (z.B. Imgur, Discord-CDN), wird als Embed-Bild angezeigt |
| Wen benachrichtigen? (optional) | Kästchen (Checkboxen) | `Everyone`, `Gildenleitung`, `User` - Mehrfachauswahl möglich |
| Zeit-Option | Multiple Choice | `Sofort`, `In X Minuten`, `An einem Datum`, `Wiederkehrend` |
| Minuten | Kurzantwort (Zahl) | nur für "In X Minuten" |
| Datum | Datum | nur für "An einem Datum" |
| Uhrzeit (Datum) | Uhrzeit | nur für "An einem Datum" |
| Wochentag | Kästchen (Checkboxen) | `Montag`..`Sonntag`, Mehrfachauswahl möglich, nur für "Wiederkehrend" |
| Uhrzeit (Wiederkehrend) | Uhrzeit | nur für "Wiederkehrend" |
| End-Datum (optional) | Datum | nur für "Wiederkehrend" |

#### Bedingte Anzeige (Branching) einrichten

Branching funktioniert in Google Forms nur über **Abschnitte**, gesteuert von einer **Multiple
Choice**- oder **Dropdown**-Frage (Checkboxen/Kurzantwort können keine Abschnitte auslösen) - passt
hier also zu "Zeit-Option":

1. Vier Abschnitte anlegen (Symbol "Abschnitt hinzufügen" in der rechten Werkzeugleiste):
   - Abschnitt 1: `Nachricht` + `Zeit-Option`
   - Abschnitt 2: `Minuten`
   - Abschnitt 3: `Datum` + `Uhrzeit (Datum)`
   - Abschnitt 4: `Wochentag` + `Uhrzeit (Wiederkehrend)` + `End-Datum (optional)`
2. Bei der Frage "Zeit-Option" das ⋮-Menü öffnen → **"Bei Antwort zu Abschnitt wechseln"**
   aktivieren. Pro Antwortoption erscheint ein Dropdown zum Zielabschnitt:
   - `Sofort` → **Formular einreichen** (keine weiteren Felder nötig)
   - `In X Minuten` → Abschnitt 2
   - `An einem Datum` → Abschnitt 3
   - `Wiederkehrend` → Abschnitt 4
3. Bei den Abschnitten 2-4 jeweils das Abschnitts-Dropdown ("Weiter zu Abschnitt ...") auf
   **"Formular einreichen"** setzen, sonst würde nach dem Ausfüllen automatisch zum nächsten
   Abschnitt weitergesprungen.
4. Mit der Vorschau (Augen-Symbol oben rechts) alle vier Pfade testen.

Den Formular-Link nur an R4/R5 weitergeben.

### 2. Antworten-Sheet vorbereiten

- Im Form-Editor unter "Antworten" auf das Sheets-Symbol klicken → verknüpftes Sheet erstellen.
- Im Sheet zwei weitere Spalten **manuell** ergänzen (Header, sonst leer lassen): `Status`, `LetzterVersand`, `Discord-Message-ID`.
- Notiere die Spreadsheet-ID aus der URL (`.../d/<ID>/edit`).

Sobald `Discord-Message-ID` existiert, merkt sich das Skript die ID jeder gesendeten Nachricht.
Wird eine Zeile im Sheet gelöscht, oder wird eine wiederkehrende Erinnerung durch die nächste
Woche ersetzt, löscht das Skript die zugehörige Discord-Nachricht automatisch - so bleibt immer
nur die aktuelle stehen.

### 3. Google Service Account (kostenlos, keine Kreditkarte nötig)

1. [console.cloud.google.com](https://console.cloud.google.com) → neues Projekt anlegen.
2. "APIs & Services" → "Library" → **Google Sheets API** aktivieren.
3. "APIs & Services" → "Credentials" → "Create Credentials" → **Service Account**.
4. Im Service Account → "Keys" → "Add Key" → "Create new key" → **JSON** herunterladen.
5. Das Sheet aus Schritt 2 mit der E-Mail-Adresse des Service Accounts (`...@...iam.gserviceaccount.com`) als **Editor** teilen.

### 4. GitHub Secrets setzen

| Secret | Wert |
|---|---|
| `DISCORD_WEBHOOK_URL_CUSTOM` | Webhook-URL des Ziel-Channels |
| `GOOGLE_SHEET_ID` | Spreadsheet-ID aus Schritt 2 |
| `GOOGLE_SERVICE_ACCOUNT_KEY` | Kompletter Inhalt der JSON-Key-Datei aus Schritt 3 |
| `DISCORD_ROLE_ID_GILDENLEITUNG` | Rollen-ID der Gildenleitung-Rolle (optional, nur für diese Mention nötig) |
| `DISCORD_ROLE_ID_USER` | Rollen-ID der User-Rolle (optional, nur für diese Mention nötig) |

Rollen-ID herausfinden: Discord-Einstellungen → Erweitert → Entwicklermodus aktivieren, dann in den
Server-Einstellungen unter "Rollen" per Rechtsklick auf die Rolle → "ID kopieren". Damit ein
Rollen-Mention wirklich pingt, muss außerdem in den Channel-Berechtigungen "@everyone erwähnen"
bzw. die jeweilige Rollen-Berechtigung erlaubt sein.

Der Workflow [`custom-notifications.yml`](.github/workflows/custom-notifications.yml) prüft alle 5
Minuten fällige Benachrichtigungen und ruft [`Send-CustomNotifications.ps1`](Send-CustomNotifications.ps1) auf.
