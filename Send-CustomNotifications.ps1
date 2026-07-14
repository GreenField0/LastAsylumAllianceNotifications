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
    resulting status back to the sheet (Status / LetzterVersand columns) so nothing
    is sent twice. Editing or deleting a row in the sheet is enough to change or
    cancel a notification - there is no separate "admin UI".

    Expected column headers in the response sheet (exact match, case-sensitive):
      Timestamp | Zeitstempel   (added automatically by Google Forms)
      Nachricht
      Zeit-Option                (Sofort | In X Minuten | An einem Datum | Wiederkehrend)
      Minuten
      Datum
      Uhrzeit (Datum)
      Wochentag                  (Kästchen/Checkboxen, Mehrfachauswahl - Montag..Sonntag)
      Uhrzeit (Wiederkehrend)
      End-Datum (optional)
      Status                     (script-managed - add manually, leave blank)
      LetzterVersand             (script-managed - add manually, leave blank)

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
    [string]$TimeZoneId = 'Europe/Berlin'
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
    param([string]$WebhookUrl, [string]$Message)
    try {
        $Payload = @{ content = $Message } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $Payload -ContentType 'application/json' | Out-Null
        return $true
    }
    catch {
        Write-Warning "Discord-Versand fehlgeschlagen: $_"
        return $false
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
$ColMap = @{}
for ($i = 0; $i -lt $HeaderRow.Count; $i++) { $ColMap[$HeaderRow[$i]] = $i + 1 }

function Get-ColIndex {
    param([string[]]$Names)
    foreach ($Name in $Names) { if ($ColMap.ContainsKey($Name)) { return $ColMap[$Name] } }
    return $null
}

$TimestampCol = Get-ColIndex @('Timestamp', 'Zeitstempel')
$NachrichtCol = Get-ColIndex @('Nachricht')
$ZeitOptionCol = Get-ColIndex @('Zeit-Option')
$MinutenCol = Get-ColIndex @('Minuten')
$DatumCol = Get-ColIndex @('Datum')
$UhrzeitDatumCol = Get-ColIndex @('Uhrzeit (Datum)')
$WochentagCol = Get-ColIndex @('Wochentag')
$UhrzeitWiederkehrendCol = Get-ColIndex @('Uhrzeit (Wiederkehrend)')
$EndDatumCol = Get-ColIndex @('End-Datum (optional)', 'End-Datum')
$StatusCol = Get-ColIndex @('Status')
$LetzterVersandCol = Get-ColIndex @('LetzterVersand')

if (-not $NachrichtCol -or -not $ZeitOptionCol -or -not $StatusCol -or -not $LetzterVersandCol) {
    Write-Error "Pflichtspalten fehlen im Sheet (benötigt: Nachricht, Zeit-Option, Status, LetzterVersand). Bitte 'Status' und 'LetzterVersand' als leere Spalten am Ende ergänzen."
    exit 1
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

foreach ($Row in ($Values | Select-Object -Skip 1)) {
    $RowNumber++

    $Nachricht = Get-Cell $Row $NachrichtCol
    if (-not $Nachricht) { continue }

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
        if (Send-DiscordNotification -WebhookUrl $WebhookUrl -Message $Nachricht) {
            $SentCount++
            foreach ($Key in $PostSendUpdates.Keys) {
                $Updates += @{ Row = $RowNumber; Col = $Key; Value = $PostSendUpdates[$Key] }
            }
        }
        else {
            Write-Warning "Zeile $RowNumber`: wird beim nächsten Lauf erneut versucht."
        }
    }
}

# --- 6. Write status/timestamp updates back to the sheet in one batch -----------

if ($Updates.Count -gt 0) {
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

Write-Output "Fertig. $SentCount Benachrichtigung(en) gesendet, $($Updates.Count) Sheet-Zelle(n) aktualisiert."
