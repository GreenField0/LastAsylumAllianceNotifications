<#
.SYNOPSIS
    Polls a Google Sheet (fed by a Google Form) for custom R4/R5 notifications and
    posts due ones to a dedicated Discord channel via webhook. Supports multiple alliances.
#>
[CmdletBinding()]
param (
    [string]$SheetName = 'Formularantworten 1',
    [string]$ConfigJson = $env:ALLIANCES_CONFIG
)

if ([string]::IsNullOrWhiteSpace($ConfigJson)) {
    Write-Error "ALLIANCES_CONFIG environment variable is not defined or empty."
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
        $N = [Math]::Floor(($N - 1) / 26)
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
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
        return [pscustomobject]@{ Success = $true; MessageId = $null }
    }
    try {
        $Payload = @{}
        if ($AllowedMentions) { $Payload.allowed_mentions = $AllowedMentions }

        if ($Title -or $ImageUrl) {
            $Embed = @{ description = $Message; color = 0x5865F2 }
            if ($Title) { $Embed.title = $Title }
            if ($ImageUrl) { $Embed.image = @{ url = $ImageUrl } }
            $Payload.embeds = @($Embed)
            if ($MentionPrefix) { $Payload.content = $MentionPrefix }
        }
        else {
            $Payload.content = if ($MentionPrefix) { "$MentionPrefix $Message" } else { $Message }
        }

        $Json = $Payload | ConvertTo-Json -Depth 4 -Compress
        $Response = Invoke-RestMethod -Uri "${WebhookUrl}?wait=true" -Method Post -Body $Json -ContentType 'application/json'
        return [pscustomobject]@{ Success = $true; MessageId = $Response.id }
    }
    catch {
        Write-Warning "Discord-Versand fehlgeschlagen: $_"
        return [pscustomobject]@{ Success = $false; MessageId = $null }
    }
}

function Send-TelegramNotification {
    param(
        [string]$BotToken,
        [string]$ChatId,
        [string]$Message,
        [string]$Title
    )
    if ([string]::IsNullOrWhiteSpace($BotToken) -or [string]::IsNullOrWhiteSpace($ChatId)) { return }

    $Text = $Message -replace '<@&\d+>', '' -replace '<@\!?\d+>', '' -replace '<#\d+>', '' -replace '@(everyone|here)', ''
    $Text = $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    $Text = $Text -replace '(?m)^[\*\-]\s+', '• '
    $Text = $Text -replace '(?m)^#+\s*(.+)$', '<b>$1</b>'
    $Text = $Text -replace '(?m)^[-*_]{3,}\s*$', '──────────'
    $Text = $Text -replace '\*\*(.+?)\*\*', '<b>$1</b>'
    $Text = $Text -replace '~~(.+?)~~', '<s>$1</s>'
    $Text = $Text -replace '(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)', '<i>$1</i>'
    $Text = $Text -replace '_(.+?)_', '<i>$1</i>'

    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $CleanTitle = $Title.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
        $Text = "<b>$CleanTitle</b>`n`n$Text"
    }

    $Text = ($Text -replace '(\r?\n){3,}', "`n`n").Trim()

    $TelegramPayload = @{
        chat_id                  = $ChatId
        text                     = $Text
        parse_mode               = 'HTML'
        disable_web_page_preview = $true
    } | ConvertTo-Json -Depth 3

    try {
        Invoke-RestMethod -Uri "https://api.telegram.org/bot${BotToken}/sendMessage" -Method Post -Body $TelegramPayload -ContentType 'application/json' | Out-Null
    }
    catch {
        Write-Warning "Telegram-Versand fehlgeschlagen: $_"
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

# --- Parse Alliances Configuration ---
try {
    $Alliances = $ConfigJson | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse ALLIANCES_CONFIG JSON. Exception: $_"
    exit 1
}

foreach ($Alliance in $Alliances) {
    if (-not $Alliance.custom_notifications -or $Alliance.custom_notifications.enabled -eq $false) {
        Write-Verbose "Custom notifications disabled for alliance $($Alliance.id) - skipping."
        continue
    }

    $Config = $Alliance.custom_notifications
    $AllianceId = $Alliance.id
    $StateFilePath = ".\.custom-notifications-known-ids-$AllianceId.txt"
    $TimeZoneId = if (-not [string]::IsNullOrWhiteSpace($Alliance.timezone)) { $Alliance.timezone } else { 'Europe/Berlin' }

    if ([string]::IsNullOrWhiteSpace($Config.google_sheet_id) -or [string]::IsNullOrWhiteSpace($Config.google_service_account_key)) {
        Write-Warning "Alliance $AllianceId: Missing google_sheet_id or google_service_account_key. Skipping."
        continue
    }

    Write-Output "--- Processing Custom Notifications for Alliance: $AllianceId ---"

    # --- Determine "now" in the configured time zone ---
    try {
        $TimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
    } catch {
        Write-Warning "Unbekannte Zeitzone '$TimeZoneId'. Nutze UTC."
        $TimeZone = [System.TimeZoneInfo]::Utc
    }
    $NowLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $TimeZone)

    # --- Authenticate against the Google Sheets API ---
    try {
        $ServiceAccount = $Config.google_service_account_key
        if ($ServiceAccount -is [string]) {
            $ServiceAccount = $ServiceAccount | ConvertFrom-Json
        }

        $AccessToken = New-GoogleServiceAccountToken -ClientEmail $ServiceAccount.client_email `
            -PrivateKeyPem $ServiceAccount.private_key `
            -Scope 'https://www.googleapis.com/auth/spreadsheets'
    } catch {
        Write-Error "Alliance $AllianceId: Google-Authentifizierung fehlgeschlagen: $_"
        continue
    }

    # --- Read the current sheet contents ---
    try {
        $EncodedRange = [uri]::EscapeDataString("'$SheetName'")
        $GetUri = "https://sheets.googleapis.com/v4/spreadsheets/$($Config.google_sheet_id)/values/$EncodedRange"
        $SheetResponse = Invoke-RestMethod -Uri $GetUri -Headers @{ Authorization = "Bearer $AccessToken" }
    } catch {
        Write-Error "Alliance $AllianceId: Konnte Google Sheet nicht lesen: $_"
        continue
    }

    $Values = $SheetResponse.values
    if (-not $Values -or $Values.Count -lt 2) {
        Write-Output "Alliance $AllianceId: Keine Einträge im Sheet gefunden."
        continue
    }

    # --- Map header names to column indices ---
    $HeaderRow = $Values[0]
    $ColMap = @{}
    for ($i = 0; $i -lt $HeaderRow.Count; $i++) {
        $Header = $HeaderRow[$i]
        if ([string]::IsNullOrWhiteSpace($Header)) { continue }
        if (-not $ColMap.ContainsKey($Header)) {
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

    if (-not $NachrichtCol -or -not $ZeitOptionCol -or -not $StatusCol -or -not $LetzterVersandCol) {
        Write-Error "Alliance $AllianceId: Pflichtspalten fehlen im Sheet (Nachricht, Zeit-Option, Status, LetzterVersand)."
        continue
    }

    # --- Walk through every response row and decide what's due ---
    $Updates = @()
    $SentCount = 0
    $RowNumber = 1
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
        }

        if ($ShouldSend) {
            $Titel = Get-Cell $Row $TitelCol
            $BildUrl = Get-Cell $Row $BildUrlCol
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
                        if ($Config.role_id_gildenleitung) { $MentionParts += "<@&$($Config.role_id_gildenleitung)>"; $AllowedRoles += $Config.role_id_gildenleitung }
                    }
                    'User' {
                        if ($Config.role_id_user) { $MentionParts += "<@&$($Config.role_id_user)>"; $AllowedRoles += $Config.role_id_user }
                    }
                }
            }
            $MentionPrefix = $MentionParts -join ' '
            $AllowedMentions = @{ parse = @(); roles = $AllowedRoles; users = @() }
            if ($ParseEveryone) { $AllowedMentions.parse = @('everyone') }

            $SendResult = Send-DiscordNotification -WebhookUrl $Config.discord_webhook -Message $Nachricht -Title $Titel -ImageUrl $BildUrl `
                -MentionPrefix $MentionPrefix -AllowedMentions $AllowedMentions
            if ($SendResult.Success) {
                $SentCount++
                Send-TelegramNotification -BotToken $Config.telegram_bot_token -ChatId $Config.telegram_chat_id -Message $Nachricht -Title $Titel
                foreach ($Key in $PostSendUpdates.Keys) {
                    $Updates += @{ Row = $RowNumber; Col = $Key; Value = $PostSendUpdates[$Key] }
                }
                if ($MessageIdCol -and $SendResult.MessageId) {
                    $Updates += @{ Row = $RowNumber; Col = $MessageIdCol; Value = $SendResult.MessageId }
                    $RowMessageId[$RowNumber] = $SendResult.MessageId
                }
            }
            else {
                Write-Warning "Alliance $AllianceId: Zeile $RowNumber wird beim nächsten Lauf erneut versucht."
            }
        }
    }

    # --- Delete Discord messages whose row disappeared or got superseded ---
    $DeletedCount = 0
    if ($MessageIdCol -and -not [string]::IsNullOrWhiteSpace($Config.discord_webhook)) {
        $FinalIds = @($RowMessageId.Values | Where-Object { $_ })
        $PreviousIds = @()
        if (Test-Path $StateFilePath) {
            $PreviousIds = @(Get-Content -Path $StateFilePath -ErrorAction SilentlyContinue | Where-Object { $_ })
        }

        foreach ($Id in ($PreviousIds | Where-Object { $_ -notin $FinalIds })) {
            try {
                Invoke-RestMethod -Uri "$($Config.discord_webhook)/messages/$Id" -Method Delete
                $DeletedCount++
            }
            catch {
                Write-Warning "Alliance $AllianceId: Konnte Discord-Nachricht $Id nicht löschen (evtl. bereits manuell gelöscht): $_"
            }
        }

        Set-Content -Path $StateFilePath -Value $FinalIds
    }

    # --- Write status/timestamp updates back to the sheet in one batch ---
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
            Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$($Config.google_sheet_id)/values:batchUpdate" `
                -Method Post -Headers @{ Authorization = "Bearer $AccessToken" } -Body $BatchBody -ContentType 'application/json' | Out-Null
        }
        catch {
            Write-Error "Alliance $AllianceId: Konnte Sheet-Status nicht aktualisieren: $_"
        }
    }

    Write-Output "Alliance $AllianceId: Fertig. $SentCount Benachrichtigung(en) gesendet, $($Updates.Count) Sheet-Zelle(n) aktualisiert, $DeletedCount Discord-Nachricht(en) gelöscht."
}
