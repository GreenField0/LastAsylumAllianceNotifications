<#
.SYNOPSIS
    Polls a Google Sheet (fed by a Google Form) for custom R4/R5 notifications and
    posts due ones to a dedicated Discord channel via webhook.

.DESCRIPTION
    R4/R5 submit notifications through a Google Form with one of four timing options:
      - Sofort                 (send immediately)
      - In X Minuten            (send N minutes after form submission)
      - An einem Datum          (send on a specific date + time, once)
      - Wiederkehrend           (send every week on a given weekday + time, until an
                                 optional end date)

    This script authenticates to the Google Sheets API using a service-account JWT
    (self-signed, RS256 - no extra PowerShell modules required), reads all form
    responses, determines which ones are due, sends them to Discord, and writes the
    resulting status back to the sheet (Status / LetzterVersand / Discord-Message-ID columns)
    so nothing is sent twice. Editing or deleting a row in the sheet is enough to change or
    cancel a notification - there is no separate "admin UI".

    Each sent message's Discord message ID is written back into the "Discord-Message-ID"
    column. On every run the script compares the IDs currently present in the sheet against
    the IDs it remembers from the previous run (state file, committed back to the repo by the
    workflow): any ID that disappeared - because its row was deleted, or because a recurring
    reminder got superseded by this week's new message - is deleted from Discord too, so only
    the current message ever remains.

    Expected column headers in the response sheet (exact match, case-sensitive):
      Timestamp | Zeitstempel   (added automatically by Google Forms)
      Nachricht
      Titel (optional)           (used as Discord embed title)
      Bild-URL (optional)        (used as Discord embed image)
      Wen benachrichtigen? (optional)  (Kästchen - Everyone | Gildenleitung | User)
      Zeit-Option                (Sofort | In X Minuten | An einem Datum | Wiederkehrend)
      Minuten
      Datum
      Uhrzeit (Datum)
      Wochentag                  (Kästchen/Checkboxen, Mehrfachauswahl - Montag..Sonntag)
      Uhrzeit (Wiederkehrend)
      End-Datum (optional)
      Status                     (script-managed - add manually, leave blank)
      LetzterVersand             (script-managed - add manually, leave blank)
      Discord-Message-ID         (script-managed - add manually, leave blank)

.PARAMETER WebhookUrl
    The target Discord Webhook URL. Defaults to the environment variable DISCORD_WEBHOOK_URL_CUSTOM.

.PARAMETER SpreadsheetId
    The ID of the Google Sheet (from its URL). Defaults to the environment variable GOOGLE_SHEET_ID.

.PARAMETER ServiceAccountKeyJson
    The raw JSON content of the Google service-account key file. Defaults to the
    environment variable GOOGLE_SERVICE_ACCOUNT_KEY.

.PARAMETER SheetName
    The name of the sheet/tab containing the form responses. Defaults to 'Formularantworten 1'.

.PARAMETER TimeZoneId
    IANA time zone used to interpret all dates/times in the sheet. Defaults to 'Europe/Berlin'.

.PARAMETER RoleIdGildenleitung
    Discord role ID to ping when "Gildenleitung" is selected. Defaults to the
    environment variable DISCORD_ROLE_ID_GILDENLEITUNG.

.PARAMETER RoleIdUser
    Discord role ID to ping when "User" is selected. Defaults to the environment
    variable DISCORD_ROLE_ID_USER.

.PARAMETER StateFilePath
    Path to a small file remembering which Discord message IDs were known after the last
    run, so removed/superseded ones can be deleted. Defaults to '.\.custom-notifications-known-ids.txt'.

.INPUTS
    None.

.OUTPUTS
    None.

.EXAMPLE
    .\Send-CustomNotifications.ps1
#>
[CmdletBinding()]
param (
    [string]$WebhookUrl = $env:DISCORD_WEBHOOK_URL_CUSTOM,
    [string]$SpreadsheetId = $env:GOOGLE_SHEET_ID,
    [string]$ServiceAccountKeyJson = $env:GOOGLE_SERVICE_ACCOUNT_KEY,
    [string]$SheetName = 'Formularantworten 1',
    [string]$TimeZoneId = 'Europe/Berlin',
    [string]$RoleIdGildenleitung = $env:DISCORD_ROLE_ID_GILDENLEITUNG,
    [string]$RoleIdUser = $env:DISCORD_ROLE_ID_USER,
    [string]$StateFilePath = '.\.custom-notifications-known-ids.txt'
)

if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
    Write-Error "Webhook URL is not defined. Please set the DISCORD_WEBHOOK_URL_CUSTOM environment variable."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($SpreadsheetId)) {
    Write-Error "Spreadsheet ID is not defined. Please set the GOOGLE_SHEET_ID environment variable."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ServiceAccountKeyJson)) {
    Write-Error "Service account key is not defined. Please set the GOOGLE_SERVICE_ACCOUNT_KEY environment variable."
    exit 1
}

# --- Helper functions --------------------------------------------------------

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-GoogleServiceAccountToken {
    param (
        [Parameter(Mandatory)] [string]$ClientEmail,
        [Parameter(Mandatory)] [string]$PrivateKeyPem,
        [Parameter(Mandatory)] [string]$Scope
    )

    $Now = [DateTimeOffset]::UtcNow
    $HeaderJson = @{ alg = 'RS256'; typ = 'JWT' } | ConvertTo-Json -Compress
    $ClaimsJson = @{
        iss   = $ClientEmail
        scope = $Scope
        aud   = 'https://oauth2.googleapis.com/token'
        iat   = $Now.ToUnixTimeSeconds()
        exp   = $Now.AddHours(1).ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress

    $HeaderB64 = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes($HeaderJson))
    $ClaimsB64 = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes($ClaimsJson))
    $SigningInput = "$HeaderB64.$ClaimsB64"

    $Rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $Rsa.ImportFromPem($PrivateKeyPem)
        $Signature = $Rsa.SignData(
            [System.Text.Encoding]::UTF8.GetBytes($SigningInput),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
    }
    finally {
        $Rsa.Dispose()
    }

    $Jwt = "$SigningInput.$(ConvertTo-Base64Url $Signature)"

    $TokenResponse = Invoke-RestMethod -Uri 'https://oauth2.googleapis.com/token' -Method Post -Body @{
        grant_type = 'urn:ietf:params:oauth:grant-type:jwt-bearer'
        assertion  = $Jwt
    }

    return $TokenResponse.access_token
}

function ConvertTo-ColumnLetter {
    param([int]$Index)
    $Letter = ''
    $N = $Index
    while ($N -gt 0) {
        $Rem = ($N - 1) % 26
        $Letter = [char](65 + $Rem) + $Letter
        $N = [int](($N - 1) / 26)
    }
    return $Letter
}

function Get-Cell {
    param($RowValues, [Nullable[int]]$ColIndex)
    if (-not $ColIndex -or $ColIndex -gt $RowValues.Count) { return $null }
    $Value = $RowValues[$ColIndex - 1]
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return $Value
}

function ConvertTo-LocalDateTime {
    param([string]$Value)
    if (-not $Value) { return $null }
    $Cultures = @(
        [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
        [System.Globalization.CultureInfo]::InvariantCulture
        [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
    )
    foreach ($Culture in $Cultures) {
        $Parsed = [datetime]::MinValue
        if ([datetime]::TryParse($Value, $Culture, [System.Globalization.DateTimeStyles]::None, [ref]$Parsed)) {
            return $Parsed
        }
    }
    Write-Warning "Konnte Datum/Zeit nicht parsen: '$Value'"
    return $null
}

function ConvertTo-TimeSpanValue {
    param([string]$Value)
    if (-not $Value) { return $null }
    $Parsed = [timespan]::Zero
    if ([timespan]::TryParse($Value, [ref]$Parsed)) { return $Parsed }
    $DateTimeValue = ConvertTo-LocalDateTime $Value
    if ($DateTimeValue) { return $DateTimeValue.TimeOfDay }
    Write-Warning "Konnte Uhrzeit nicht parsen: '$Value'"
    return $null
}

function Send-DiscordNotification {
    param(
        [string]$WebhookUrl,
        [string]$Message,
        [string]$Title,
        [string]$ImageUrl,
        [string]$MentionPrefix,
        [hashtable]$AllowedMentions
    )
    try {
        $Payload = @{}
        if ($AllowedMentions) { $Payload.allowed_mentions = $AllowedMentions }

        if ($Title -or $ImageUrl) {
            # Mentions only ping when they're in the message "content", not inside an embed.
            $Embed = @{ description = $Message; color = 0x5865F2 }
            if ($Title) { $Embed.title = $Title }
            if ($ImageUrl) { $Embed.image = @{ url = $ImageUrl } }
            $Payload.embeds = @($Embed)
            if ($MentionPrefix) { $Payload.content = $MentionPrefix }
        }
        else {
            $Payload.content = if ($MentionPrefix) { "$MentionPrefix $Message" } else { $Message }
        }

        # '?wait=true' makes Discord return the created message (incl. its ID) instead of an
        # empty response, so we can store it and delete it again later if needed.
        $Json = $Payload | ConvertTo-Json -Depth 4 -Compress
        $Response = Invoke-RestMethod -Uri "${WebhookUrl}?wait=true" -Method Post -Body $Json -ContentType 'application/json'
        return [pscustomobject]@{ Success = $true; MessageId = $Response.id }
    }
    catch {
        Write-Warning "Discord-Versand fehlgeschlagen: $_"
        return [pscustomobject]@{ Success = $false; MessageId = $null }
    }
}

$WeekdayMap = @{
    'Sonntag'    = [DayOfWeek]::Sunday
    'Montag'     = [DayOfWeek]::Monday
    'Dienstag'   = [DayOfWeek]::Tuesday
    'Mittwoch'   = [DayOfWeek]::Wednesday
    'Donnerstag' = [DayOfWeek]::Thursday
    'Freitag'    = [DayOfWeek]::Friday
    'Samstag'    = [DayOfWeek]::Saturday
}

# --- 1. Authenticate against the Google Sheets API ---------------------------

try {
    $ServiceAccount = $ServiceAccountKeyJson | ConvertFrom-Json
    $AccessToken = New-GoogleServiceAccountToken -ClientEmail $ServiceAccount.client_email `
        -PrivateKeyPem $ServiceAccount.private_key `
        -Scope 'https://www.googleapis.com/auth/spreadsheets'
}
catch {
    Write-Error "Google-Authentifizierung fehlgeschlagen: $_"
    exit 1
}

# --- 2. Read the current sheet contents ---------------------------------------

try {
    $EncodedRange = [uri]::EscapeDataString("'$SheetName'")
    $GetUri = "https://sheets.googleapis.com/v4/spreadsheets/$SpreadsheetId/values/$EncodedRange"
    $SheetResponse = Invoke-RestMethod -Uri $GetUri -Headers @{ Authorization = "Bearer $AccessToken" }
}
catch {
    Write-Error "Konnte Google Sheet nicht lesen: $_"
    exit 1
}

$Values = $SheetResponse.values
if (-not $Values -or $Values.Count -lt 2) {
    Write-Output "Keine Einträge im Sheet gefunden."
    exit 0
}

# --- 3. Map header names to column indices -------------------------------------

$HeaderRow = $Values[0]
Write-Output "DEBUG: Sheet header row ($($HeaderRow.Count) columns): $($HeaderRow -join ' | ')"

$ColMap = @{}
for ($i = 0; $i -lt $HeaderRow.Count; $i++) {
    $Header = $HeaderRow[$i]
    if ([string]::IsNullOrWhiteSpace($Header)) { continue }
    if ($ColMap.ContainsKey($Header)) {
        Write-Warning "Doppelter Spalten-Header '$Header' in Spalte $($i + 1) ignoriert (erste Fundstelle: Spalte $($ColMap[$Header]) wird verwendet)."
    }
    else {
        $ColMap[$Header] = $i + 1
    }
}

function Get-ColIndex {
    param([string[]]$Names)
    foreach ($Name in $Names) { if ($ColMap.ContainsKey($Name)) { return $ColMap[$Name] } }
    return $null
}

$TimestampCol = Get-ColIndex @('Timestamp', 'Zeitstempel')
$NachrichtCol = Get-ColIndex @('Nachricht')
$TitelCol = Get-ColIndex @('Titel (optional)', 'Titel')
$BildUrlCol = Get-ColIndex @('Bild-URL (optional)', 'Bild-URL')
$MentionCol = Get-ColIndex @('Wen benachrichtigen? (optional)', 'Wen benachrichtigen?')
$ZeitOptionCol = Get-ColIndex @('Zeit-Option')
$MinutenCol = Get-ColIndex @('Minuten', 'Anzahl Minuten')
$DatumCol = Get-ColIndex @('Datum')
$UhrzeitDatumCol = Get-ColIndex @('Uhrzeit (Datum)')
$WochentagCol = Get-ColIndex @('Wochentag')
$UhrzeitWiederkehrendCol = Get-ColIndex @('Uhrzeit (Wiederkehrend)')
$EndDatumCol = Get-ColIndex @('End-Datum (optional)', 'End-Datum')
$StatusCol = Get-ColIndex @('Status')
$LetzterVersandCol = Get-ColIndex @('LetzterVersand')
$MessageIdCol = Get-ColIndex @('Discord-Message-ID', 'Message-ID')

Write-Output "DEBUG: Spalten-Mapping: Status=$StatusCol, LetzterVersand=$LetzterVersandCol, Discord-Message-ID=$MessageIdCol, Nachricht=$NachrichtCol"

if (-not $NachrichtCol -or -not $ZeitOptionCol -or -not $StatusCol -or -not $LetzterVersandCol) {
    Write-Error "Pflichtspalten fehlen im Sheet (benötigt: Nachricht, Zeit-Option, Status, LetzterVersand). Bitte 'Status' und 'LetzterVersand' als leere Spalten am Ende ergänzen."
    exit 1
}

# Optional columns fail silently by design (older rows may not have them yet), but a missing
# column because of a typo/renamed form question is a common source of "feature does nothing"
# bugs - so log which optional columns were actually detected.
$OptionalColumns = [ordered]@{
    'Titel'                = $TitelCol
    'Bild-URL'             = $BildUrlCol
    'Wen benachrichtigen?' = $MentionCol
    'End-Datum'            = $EndDatumCol
    'Discord-Message-ID'   = $MessageIdCol
}
foreach ($Name in $OptionalColumns.Keys) {
    if (-not $OptionalColumns[$Name]) {
        Write-Warning "Optionale Spalte '$Name' wurde NICHT gefunden - zugehöriges Feature bleibt inaktiv. Gefundene Header im Sheet: $($HeaderRow -join ' | ')"
    }
}

# --- 4. Determine "now" in the configured time zone -----------------------------

try {
    $TimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
}
catch {
    Write-Error "Unbekannte Zeitzone '$TimeZoneId': $_"
    exit 1
}
$NowLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $TimeZone)

# --- 5. Walk through every response row and decide what's due -------------------

$Updates = @()
$SentCount = 0
$RowNumber = 1
# Tracks the Discord message ID belonging to each still-existing row - initialized from the
# sheet, overwritten when a row sends a new message. Used at the end to spot IDs that vanished
# (row deleted, or a recurring reminder got replaced by this week's message) so they can be
# deleted from Discord too.
$RowMessageId = @{}

foreach ($Row in ($Values | Select-Object -Skip 1)) {
    $RowNumber++

    $Nachricht = Get-Cell $Row $NachrichtCol
    if (-not $Nachricht) { continue }

    $ExistingMessageId = Get-Cell $Row $MessageIdCol
    if ($ExistingMessageId) { $RowMessageId[$RowNumber] = $ExistingMessageId }

    $ZeitOption = Get-Cell $Row $ZeitOptionCol
    $Status = Get-Cell $Row $StatusCol
    if ($Status -in @('Cancelled', 'Beendet')) { continue }

    $ShouldSend = $false
    $PostSendUpdates = @{}

    switch ($ZeitOption) {
        'Sofort' {
            if ($Status -ne 'Sent') {
                $ShouldSend = $true
                $PostSendUpdates[$StatusCol] = 'Sent'
            }
        }
        'In X Minuten' {
            if ($Status -ne 'Sent') {
                $Timestamp = ConvertTo-LocalDateTime (Get-Cell $Row $TimestampCol)
                $Minutes = Get-Cell $Row $MinutenCol
                if ($Timestamp -and $Minutes) {
                    $Target = $Timestamp.AddMinutes([double]$Minutes)
                    if ($NowLocal -ge $Target) {
                        $ShouldSend = $true
                        $PostSendUpdates[$StatusCol] = 'Sent'
                    }
                }
            }
        }
        'An einem Datum' {
            if ($Status -ne 'Sent') {
                $Datum = ConvertTo-LocalDateTime (Get-Cell $Row $DatumCol)
                $Uhrzeit = ConvertTo-TimeSpanValue (Get-Cell $Row $UhrzeitDatumCol)
                if ($Datum -and $Uhrzeit) {
                    $Target = $Datum.Date.Add($Uhrzeit)
                    if ($NowLocal -ge $Target) {
                        $ShouldSend = $true
                        $PostSendUpdates[$StatusCol] = 'Sent'
                    }
                }
            }
        }
        'Wiederkehrend' {
            $EndDatum = ConvertTo-LocalDateTime (Get-Cell $Row $EndDatumCol)
            if ($EndDatum -and $NowLocal.Date -gt $EndDatum.Date) {
                if ($Status -ne 'Beendet') {
                    $Updates += @{ Row = $RowNumber; Col = $StatusCol; Value = 'Beendet' }
                }
                continue
            }

            # "Wochentag" is a Checkboxes question (multiple weekdays possible), Google Forms
            # exports the selected values as a single comma-separated cell, e.g. "Montag, Mittwoch".
            $WochentagRaw = Get-Cell $Row $WochentagCol
            $Wochentage = @()
            if ($WochentagRaw) { $Wochentage = $WochentagRaw -split ',\s*' | ForEach-Object { $_.Trim() } }

            $Uhrzeit = ConvertTo-TimeSpanValue (Get-Cell $Row $UhrzeitWiederkehrendCol)
            $LetzterVersand = ConvertTo-LocalDateTime (Get-Cell $Row $LetzterVersandCol)

            $IsDueDay = $Wochentage | Where-Object { $WeekdayMap.ContainsKey($_) -and $WeekdayMap[$_] -eq $NowLocal.DayOfWeek }
            if ($IsDueDay -and $Uhrzeit) {
                $TimeReached = $NowLocal.TimeOfDay -ge $Uhrzeit
                $AlreadySentToday = $LetzterVersand -and ($LetzterVersand.Date -eq $NowLocal.Date)
                if ($TimeReached -and -not $AlreadySentToday) {
                    $ShouldSend = $true
                    $PostSendUpdates[$LetzterVersandCol] = $NowLocal.ToString('yyyy-MM-dd')
                }
            }
        }
        default {
            Write-Warning "Zeile $RowNumber`: Unbekannte oder leere Zeit-Option '$ZeitOption' - übersprungen."
        }
    }

    if ($ShouldSend) {
        $Titel = Get-Cell $Row $TitelCol
        $BildUrl = Get-Cell $Row $BildUrlCol

        # "Wen benachrichtigen?" is a Checkboxes question too - map selected labels to actual
        # Discord mention syntax. Mentions only ping when they're in "content", not in an embed,
        # and only for roles/parse-types explicitly whitelisted via "allowed_mentions".
        $MentionRaw = Get-Cell $Row $MentionCol
        $MentionLabels = @()
        if ($MentionRaw) { $MentionLabels = $MentionRaw -split ',\s*' | ForEach-Object { $_.Trim() } }

        $MentionParts = @()
        $AllowedRoles = @()
        $ParseEveryone = $false
        foreach ($Label in $MentionLabels) {
            switch ($Label) {
                'Everyone' { $MentionParts += '@everyone'; $ParseEveryone = $true }
                'Gildenleitung' {
                    if ($RoleIdGildenleitung) { $MentionParts += "<@&$RoleIdGildenleitung>"; $AllowedRoles += $RoleIdGildenleitung }
                    else { Write-Warning "Zeile $RowNumber`: 'Gildenleitung' ausgewählt, aber DISCORD_ROLE_ID_GILDENLEITUNG ist nicht gesetzt." }
                }
                'User' {
                    if ($RoleIdUser) { $MentionParts += "<@&$RoleIdUser>"; $AllowedRoles += $RoleIdUser }
                    else { Write-Warning "Zeile $RowNumber`: 'User' ausgewählt, aber DISCORD_ROLE_ID_USER ist nicht gesetzt." }
                }
                default { Write-Warning "Zeile $RowNumber`: Unbekannte Mention-Option '$Label'." }
            }
        }
        $MentionPrefix = $MentionParts -join ' '
        $AllowedMentions = @{ parse = @(); roles = $AllowedRoles; users = @() }
        if ($ParseEveryone) { $AllowedMentions.parse = @('everyone') }

        $SendResult = Send-DiscordNotification -WebhookUrl $WebhookUrl -Message $Nachricht -Title $Titel -ImageUrl $BildUrl `
            -MentionPrefix $MentionPrefix -AllowedMentions $AllowedMentions
        if ($SendResult.Success) {
            $SentCount++
            foreach ($Key in $PostSendUpdates.Keys) {
                $Updates += @{ Row = $RowNumber; Col = $Key; Value = $PostSendUpdates[$Key] }
            }
            if ($MessageIdCol -and $SendResult.MessageId) {
                $Updates += @{ Row = $RowNumber; Col = $MessageIdCol; Value = $SendResult.MessageId }
                $RowMessageId[$RowNumber] = $SendResult.MessageId
            }
        }
        else {
            Write-Warning "Zeile $RowNumber`: wird beim nächsten Lauf erneut versucht."
        }
    }
}

# --- 6. Delete Discord messages whose row disappeared or got superseded --------

$DeletedCount = 0
if ($MessageIdCol) {
    $FinalIds = @($RowMessageId.Values | Where-Object { $_ })
    $PreviousIds = @()
    if (Test-Path $StateFilePath) {
        $PreviousIds = @(Get-Content -Path $StateFilePath -ErrorAction SilentlyContinue | Where-Object { $_ })
    }

    foreach ($Id in ($PreviousIds | Where-Object { $_ -notin $FinalIds })) {
        try {
            Invoke-RestMethod -Uri "${WebhookUrl}/messages/$Id" -Method Delete
            $DeletedCount++
        }
        catch {
            Write-Warning "Konnte Discord-Nachricht $Id nicht löschen (evtl. bereits manuell gelöscht): $_"
        }
    }

    Set-Content -Path $StateFilePath -Value $FinalIds
}

# --- 7. Write status/timestamp updates back to the sheet in one batch -----------

if ($Updates.Count -gt 0) {
    Write-Output "DEBUG: $($Updates.Count) Updates werden geschrieben:"
    foreach ($Update in $Updates) {
        Write-Output "  -> Row=$($Update.Row), Col=$($Update.Col) [$(ConvertTo-ColumnLetter $Update.Col)], Value='$($Update.Value)'"
    }

    $Data = @(
        foreach ($Update in $Updates) {
            @{
                range  = "'$SheetName'!$(ConvertTo-ColumnLetter $Update.Col)$($Update.Row)"
                values = @(, @($Update.Value))
            }
        }
    )
    $BatchBody = @{ valueInputOption = 'RAW'; data = $Data } | ConvertTo-Json -Depth 5

    try {
        Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$SpreadsheetId/values:batchUpdate" `
            -Method Post -Headers @{ Authorization = "Bearer $AccessToken" } -Body $BatchBody -ContentType 'application/json' | Out-Null
    }
    catch {
        Write-Error "Konnte Sheet-Status nicht aktualisieren: $_"
        exit 1
    }
}

Write-Output "Fertig. $SentCount Benachrichtigung(en) gesendet, $($Updates.Count) Sheet-Zelle(n) aktualisiert, $DeletedCount Discord-Nachricht(en) gelöscht."
