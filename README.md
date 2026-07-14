# LastAsylum

## Custom Notifications (R4/R5 self-service)

R4/R5 können eigene Discord-Benachrichtigungen über ein Google Form anlegen. Bearbeiten/Löschen
geschieht direkt im verknüpften Google Sheet (Zeile ändern bzw. löschen).

### 1. Google Form erstellen

Fragen (Titel exakt so, damit das Skript sie findet):

| Frage | Typ | Optionen / Hinweis |
|---|---|---|
| Nachricht | Absatz (Text) | Pflichtfeld |
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
- Im Sheet zwei weitere Spalten **manuell** ergänzen (Header, sonst leer lassen): `Status`, `LetzterVersand`.
- Notiere die Spreadsheet-ID aus der URL (`.../d/<ID>/edit`).

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

Der Workflow [`custom-notifications.yml`](.github/workflows/custom-notifications.yml) prüft alle 5
Minuten fällige Benachrichtigungen und ruft [`Send-CustomNotifications.ps1`](Send-CustomNotifications.ps1) auf.
