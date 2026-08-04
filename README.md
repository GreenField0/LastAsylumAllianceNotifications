# LastAsylum

*🇩🇪 [Hier geht es zur deutschen Version (German Version)](README_de.md)*  
> 📌 **Alliance Guides:** [📅 Schedule](docs/guides/SCHEDULE_en.md) | [📜 Rules & SvS](docs/guides/ALLIANCE_RULES_en.md) | [🦸 Heroes](docs/guides/HEROES_GUIDE_en.md) | [🦅 Ravens](docs/guides/RAVENS_GUIDE_en.md) | [💎 Tips](docs/guides/BEGINNER_TIPS_en.md) | [🎁 Gift Codes](docs/guides/GIFT_CODES_en.md)

🌟 **[Visit our Interactive Web App](https://eikewessels.github.io/LastAsylumAllianceNotifications/)** for automatic timezone conversion and a premium reading experience!

Automated notifications for the LastAsylum guild — daily schedule briefings and custom R4/R5 announcements delivered to Discord and Telegram via GitHub Actions.

---

## Daily Briefing

Posts the daily Alliance Duel and Survival schedule to Discord (and optionally Telegram) every morning. The schedule is defined in [`schedule.json`](schedule.json).

**Workflow:** [`daily-briefing.yml`](.github/workflows/daily-briefing.yml) — runs daily at 04:00 CEST (02:00 UTC).

### Manage and add alliances

You manage the entire configuration in your repository's GitHub settings:
1. In your repository, go to **Settings** -> **Secrets and variables** -> **Actions**.
2. Create a new **Repository secret** with the exact name `ALLIANCES_CONFIG`.
3. The content of this secret is a JSON array. To add a new alliance, simply copy the block of the existing alliance, append it at the bottom separated by a comma, and change the values.

**Example of TWO alliances in the secret:**
```json
[
  {
    "id": "alliance-main",
    "timezone": "Europe/London",
    "daily_briefing": {
      "enabled": true,
      "send_time": "05:00",
      "languages": ["en"],
      "discord_webhook": "https://discord.com/api/webhooks/...",
      "role_id_ping": "123456789012345678",
      "telegram_bot_token": "",
      "telegram_chat_id": ""
    },
    "custom_notifications": {
      "enabled": true,
      "discord_webhook": "https://discord.com/api/webhooks/...",
      "google_sheet_id": "1A2B3C...",
      "google_service_account_key": {
        "type": "service_account",
        "project_id": "...",
        "private_key": "..."
      },
      "role_id_gildenleitung": "1234...",
      "role_id_user": "5678...",
      "telegram_bot_token": "",
      "telegram_chat_id": ""
    }
  }
]
```

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

---

## ⚖️ Disclaimer & Legal Notice

This repository is an **unofficial, fan-made community tool** designed to assist players and alliance leaders (R4/R5) in managing notifications and schedules for their guild.

* **No Affiliation:** This project is not affiliated with, endorsed, sponsored, or specifically approved by the developers or publishers of the mobile game *Last Asylum*.
* **Trademarks:** All game titles, names, assets, and related trademarks are property of their respective owners.
* **No Warranty:** This tool is provided "as is" without warranty of any kind. See the [LICENSE](LICENSE) file for more details.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
