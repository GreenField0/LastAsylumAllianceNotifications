<#
.SYNOPSIS
    Sends scheduled custom announcements from a Google Sheet to Discord and Telegram.
    Supports multiple alliances configured via a JSON structure.
#>
[CmdletBinding()]
param (
    [string]$ConfigJson = $env:ALLIANCES_CONFIG
)

if ([string]::IsNullOrWhiteSpace($ConfigJson)) {
    Write-Error "ALLIANCES_CONFIG environment variable is not defined or empty."
    exit 1
}

# 1. Parse Alliances config
try {
    $Alliances = $ConfigJson | ConvertFrom-Json
}
catch {
    Write-Error "Failed to parse ALLIANCES_CONFIG JSON. Exception: $_"
    exit 1
}

# Helper function to generate Google OAuth token from JSON object
function New-GoogleServiceAccountToken {
    param (
        [Parameter(Mandatory=$true)]
        [object]$ServiceAccountJson
    )

    $Scopes = "https://www.googleapis.com/auth/spreadsheets"

    try {
        $Header = @{
            alg = "RS256"
            typ = "JWT"
        }
        $HeaderBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($Header | ConvertTo-Json -Compress))) -replace '\+','-' -replace '/','_' -replace '='

        $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $Claim = @{
            iss   = $ServiceAccountJson.client_email
            scope = $Scopes
            aud   = "https://oauth2.googleapis.com/token"
            exp   = $Now + 3600
            iat   = $Now
        }
        $ClaimBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($Claim | ConvertTo-Json -Compress))) -replace '\+','-' -replace '/','_' -replace '='

        $SignatureInput = "$HeaderBase64.$ClaimBase64"
        
        $RSA = [System.Security.Cryptography.RSA]::Create()
        $RSA.ImportFromPem($ServiceAccountJson.private_key)
        $SignatureBytes = $RSA.SignData([System.Text.Encoding]::UTF8.GetBytes($SignatureInput), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $SignatureBase64 = [Convert]::ToBase64String($SignatureBytes) -replace '\+','-' -replace '/','_' -replace '='

        $Jwt = "$SignatureInput.$SignatureBase64"

        $Body = @{
            grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer"
            assertion  = $Jwt
        }

        $Response = Invoke-RestMethod -Uri "https://oauth2.googleapis.com/token" -Method Post -Body $Body -Form
        return $Response.access_token
    } catch {
        Write-Error "Failed to generate Google token: $_"
        return $null
    }
}

# 2. Load Global State for known IDs
$StateFilePath = ".\.custom-notifications-state.json"
$GlobalState = @{}
if (Test-Path $StateFilePath) {
    try {
        $FileContent = Get-Content -Raw -Path $StateFilePath | ConvertFrom-Json
        foreach ($Property in $FileContent.PSObject.Properties) {
            $GlobalState[$Property.Name] = @($Property.Value)
        }
    } catch {
        Write-Warning "Could not parse $StateFilePath. Starting with fresh state."
    }
}

foreach ($Alliance in $Alliances) {
    if (-not $Alliance.custom_notifications -or $Alliance.custom_notifications.enabled -eq $false) {
        Write-Verbose "Custom notifications disabled for alliance $($Alliance.id) - skipping."
        continue
    }

    $Config = $Alliance.custom_notifications

    if ([string]::IsNullOrWhiteSpace($Config.google_sheet_id)) {
        Write-Warning "Alliance $($Alliance.id): Google Sheet ID is missing."
        continue
    }

    # Generate token using the nested JSON object
    $GoogleToken = New-GoogleServiceAccountToken -ServiceAccountJson $Config.google_service_account_key
    if (-not $GoogleToken) {
        Write-Error "Alliance $($Alliance.id): Could not generate Google Service Account token. Skipping."
        continue
    }

    # Get local time based on alliance timezone
    try {
        $TimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($Alliance.timezone)
        $NowLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $TimeZone)
    } catch {
        Write-Warning "Alliance $($Alliance.id): Unknown timezone '$($Alliance.timezone)' - skipping."
        continue
    }

    # Fetch rows
    $SheetApiUrl = "https://sheets.googleapis.com/v4/spreadsheets/$($Config.google_sheet_id)/values/A:M"
    try {
        $Response = Invoke-RestMethod -Uri $SheetApiUrl -Headers @{ Authorization = "Bearer $GoogleToken" } -ErrorAction Stop
        $Rows = $Response.values
    } catch {
        Write-Error "Alliance $($Alliance.id): Failed to fetch Google Sheet. Exception: $_"
        continue
    }

    if ($null -eq $Rows -or $Rows.Count -le 1) {
        Write-Verbose "Alliance $($Alliance.id): No entries found in Google Sheet."
        continue
    }

    $Headers = $Rows[0]
    
    $ColIndices = @{
        Message = $Headers.IndexOf("Nachricht")
        Title = $Headers.IndexOf("Titel (optional)")
        Image = $Headers.IndexOf("Bild-URL (optional)")
        Mentions = $Headers.IndexOf("Wen benachrichtigen? (optional)")
        TimeOption = $Headers.IndexOf("Zeit-Option")
        Minutes = $Headers.IndexOf("Minuten")
        Date = $Headers.IndexOf("Datum")
        TimeDate = $Headers.IndexOf("Uhrzeit (Datum)")
        Weekday = $Headers.IndexOf("Wochentag")
        TimeRecurring = $Headers.IndexOf("Uhrzeit (Wiederkehrend)")
        EndDate = $Headers.IndexOf("End-Datum (optional)")
        Status = $Headers.IndexOf("Status")
        LastSent = $Headers.IndexOf("LetzterVersand")
        DiscordMessageId = $Headers.IndexOf("Discord-Message-ID")
    }

    # Validate essential columns
    if ($ColIndices.Message -eq -1 -or $ColIndices.TimeOption -eq -1) {
        Write-Error "Alliance $($Alliance.id): Sheet is missing mandatory columns ('Nachricht' or 'Zeit-Option')."
        continue
    }

    # Determine required extra columns
    $MissingExtraColumns = @()
    if ($ColIndices.Status -eq -1) { $MissingExtraColumns += "Status" }
    if ($ColIndices.LastSent -eq -1) { $MissingExtraColumns += "LetzterVersand" }
    if ($ColIndices.DiscordMessageId -eq -1) { $MissingExtraColumns += "Discord-Message-ID" }
    if ($MissingExtraColumns.Count -gt 0) {
        Write-Warning "Alliance $($Alliance.id): The following optional columns were not found in the sheet: $($MissingExtraColumns -join ', '). Ensure you added them at the end."
    }

    $KnownIdsForAlliance = @()
    if ($GlobalState.Contains($Alliance.id)) {
        $KnownIdsForAlliance = $GlobalState[$Alliance.id]
    }

    $ActiveMessageIdsThisRun = @()
    $RowsUpdated = $false

    for ($i = 1; $i -lt $Rows.Count; $i++) {
        $Row = $Rows[$i]

        $GetValue = {
            param($ColIndex)
            if ($ColIndex -ge 0 -and $ColIndex -lt $Row.Count) {
                return $Row[$ColIndex].Trim()
            }
            return ""
        }

        $MessageText = &$GetValue $ColIndices.Message
        $TimeOption = &$GetValue $ColIndices.TimeOption
        $Status = &$GetValue $ColIndices.Status
        $LastSent = &$GetValue $ColIndices.LastSent
        $CurrentMessageId = &$GetValue $ColIndices.DiscordMessageId

        if ([string]::IsNullOrWhiteSpace($MessageText)) { continue }

        $ShouldSend = $false

        switch ($TimeOption) {
            "Sofort" {
                if ($Status -ne "Gesendet") {
                    $ShouldSend = $true
                }
            }
            "In X Minuten" {
                if ($Status -ne "Gesendet") {
                    $TimestampStr = &$GetValue 0
                    $MinutesStr = &$GetValue $ColIndices.Minutes
                    if ([int]::TryParse($MinutesStr, [ref]$null)) {
                        $Minutes = [int]$MinutesStr
                        if ($TimestampStr -match "(\d{1,2})\.(\d{1,2})\.(\d{4}) (\d{1,2}):(\d{2}):(\d{2})") {
                            $TimestampDate = [DateTime]::ParseExact($TimestampStr, "dd.MM.yyyy HH:mm:ss", $null)
                            if ($NowLocal -ge $TimestampDate.AddMinutes($Minutes)) {
                                $ShouldSend = $true
                            }
                        }
                    }
                }
            }
            "An einem Datum" {
                if ($Status -ne "Gesendet") {
                    $DateStr = &$GetValue $ColIndices.Date
                    $TimeStr = &$GetValue $ColIndices.TimeDate
                    if (-not [string]::IsNullOrWhiteSpace($DateStr) -and -not [string]::IsNullOrWhiteSpace($TimeStr)) {
                        try {
                            $TargetDateTime = [DateTime]::ParseExact("$DateStr $TimeStr", "dd.MM.yyyy HH:mm", $null)
                            if ($NowLocal -ge $TargetDateTime) {
                                $ShouldSend = $true
                            }
                        } catch {
                            Write-Warning "Alliance $($Alliance.id) Row $($i + 1): Invalid Date/Time format: '$DateStr $TimeStr'"
                        }
                    }
                }
            }
            "Wiederkehrend" {
                $EndDateStr = &$GetValue $ColIndices.EndDate
                if (-not [string]::IsNullOrWhiteSpace($EndDateStr)) {
                    try {
                        $EndDate = [DateTime]::ParseExact($EndDateStr, "dd.MM.yyyy", $null).AddDays(1)
                        if ($NowLocal -ge $EndDate) {
                            if ($Status -ne "Abgelaufen") {
                                $Rows[$i][$ColIndices.Status] = "Abgelaufen"
                                $RowsUpdated = $true
                            }
                            continue
                        }
                    } catch {}
                }

                $WeekdayStr = &$GetValue $ColIndices.Weekday
                $TimeStr = &$GetValue $ColIndices.TimeRecurring

                if (-not [string]::IsNullOrWhiteSpace($WeekdayStr) -and -not [string]::IsNullOrWhiteSpace($TimeStr)) {
                    $Weekdays = $WeekdayStr -split ", "
                    
                    $GermanDayMap = @{
                        "Montag" = "Monday"
                        "Dienstag" = "Tuesday"
                        "Mittwoch" = "Wednesday"
                        "Donnerstag" = "Thursday"
                        "Freitag" = "Friday"
                        "Samstag" = "Saturday"
                        "Sonntag" = "Sunday"
                    }

                    $CurrentDayNameDe = ""
                    foreach ($DeDay in $GermanDayMap.Keys) {
                        if ($GermanDayMap[$DeDay] -eq $NowLocal.DayOfWeek.ToString()) {
                            $CurrentDayNameDe = $DeDay
                            break
                        }
                    }

                    if ($Weekdays -contains $CurrentDayNameDe) {
                        if (-not [string]::IsNullOrWhiteSpace($TimeStr)) {
                            try {
                                $TargetTime = [TimeSpan]::Parse($TimeStr + ":00")
                                if ($NowLocal.TimeOfDay -ge $TargetTime) {
                                    $TodayStr = $NowLocal.ToString("dd.MM.yyyy")
                                    if ($LastSent -ne $TodayStr) {
                                        $ShouldSend = $true
                                    }
                                }
                            } catch {
                                Write-Warning "Alliance $($Alliance.id) Row $($i + 1): Invalid recurring time format: '$TimeStr'"
                            }
                        }
                    }
                }
            }
        }

        if ($ShouldSend) {
            Write-Output "Alliance $($Alliance.id) Row $($i + 1): Sending notification..."
            $EmbedTitle = &$GetValue $ColIndices.Title
            $ImageUrl = &$GetValue $ColIndices.Image
            $MentionsStr = &$GetValue $ColIndices.Mentions

            $PingPrefix = ""
            if (-not [string]::IsNullOrWhiteSpace($MentionsStr)) {
                $MentionList = $MentionsStr -split ", "
                $Pings = @()
                if ($MentionList -contains "Everyone") { $Pings += "@everyone" }
                if ($MentionList -contains "Gildenleitung" -and -not [string]::IsNullOrWhiteSpace($Config.role_id_gildenleitung)) { $Pings += "<@&$($Config.role_id_gildenleitung)>" }
                if ($MentionList -contains "User" -and -not [string]::IsNullOrWhiteSpace($Config.role_id_user)) { $Pings += "<@&$($Config.role_id_user)>" }
                if ($Pings.Count -gt 0) {
                    $PingPrefix = ($Pings -join " ") + "`n`n"
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($CurrentMessageId) -and -not [string]::IsNullOrWhiteSpace($Config.discord_webhook)) {
                try {
                    Invoke-RestMethod -Uri "$($Config.discord_webhook)/messages/$CurrentMessageId" -Method Delete
                    Write-Output "Alliance $($Alliance.id) Row $($i + 1): Deleted old Discord message $CurrentMessageId."
                } catch {
                    Write-Warning "Alliance $($Alliance.id) Row $($i + 1): Could not delete old Discord message ($CurrentMessageId)."
                }
            }

            $NewMessageId = ""
            if (-not [string]::IsNullOrWhiteSpace($Config.discord_webhook)) {
                $Payload = [ordered]@{
                    content = $PingPrefix + $MessageText
                }

                if (-not [string]::IsNullOrWhiteSpace($EmbedTitle) -or -not [string]::IsNullOrWhiteSpace($ImageUrl)) {
                    $Embed = [ordered]@{}
                    if (-not [string]::IsNullOrWhiteSpace($EmbedTitle)) {
                        $Embed.title = $EmbedTitle
                        $Embed.color = 16711680 # Red
                    }
                    if (-not [string]::IsNullOrWhiteSpace($ImageUrl)) {
                        $Embed.image = @{ url = $ImageUrl }
                    }
                    $Payload.embeds = @($Embed)
                }

                $JsonPayload = $Payload | ConvertTo-Json -Depth 5

                try {
                    $DiscordResponse = Invoke-RestMethod -Uri "$($Config.discord_webhook)?wait=true" -Method Post -Body $JsonPayload -ContentType 'application/json'
                    if ($DiscordResponse.id) {
                        $NewMessageId = $DiscordResponse.id
                    }
                } catch {
                    Write-Error "Alliance $($Alliance.id) Row $($i + 1): Failed to send Discord webhook. Exception: $_"
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($Config.telegram_bot_token) -and -not [string]::IsNullOrWhiteSpace($Config.telegram_chat_id)) {
                $TextHtml = $MessageText -replace '<@&\d+>', '' -replace '<@\!?\d+>', '' -replace '<#\d+>', '' -replace '@(everyone|here)', ''
                $TextHtml = $TextHtml.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
                $TextHtml = $TextHtml -replace '(?m)^[\*\-]\s+', '• '
                $TextHtml = $TextHtml -replace '(?m)^#+\s*(.+)$', '<b>$1</b>'
                $TextHtml = $TextHtml -replace '(?m)^[-*_]{3,}\s*$', '──────────'
                $TextHtml = $TextHtml -replace '\*\*(.+?)\*\*', '<b>$1</b>'
                $TextHtml = $TextHtml -replace '~~(.+?)~~', '<s>$1</s>'
                $TextHtml = $TextHtml -replace '(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)', '<i>$1</i>'
                $TextHtml = $TextHtml -replace '_(.+?)_', '<i>$1</i>'
                $TextHtml = ($TextHtml -replace '(\r?\n){3,}', "`n`n").Trim()

                if (-not [string]::IsNullOrWhiteSpace($EmbedTitle)) {
                    $TextHtml = "<b>$EmbedTitle</b>`n`n$TextHtml"
                }
                
                if (-not [string]::IsNullOrWhiteSpace($ImageUrl)) {
                    $TelegramPayload = @{
                        chat_id    = $Config.telegram_chat_id
                        photo      = $ImageUrl
                        caption    = $TextHtml
                        parse_mode = 'HTML'
                    } | ConvertTo-Json -Depth 3
                    $TgUrl = "https://api.telegram.org/bot$($Config.telegram_bot_token)/sendPhoto"
                } else {
                    $TelegramPayload = @{
                        chat_id                  = $Config.telegram_chat_id
                        text                     = $TextHtml
                        parse_mode               = 'HTML'
                        disable_web_page_preview = $true
                    } | ConvertTo-Json -Depth 3
                    $TgUrl = "https://api.telegram.org/bot$($Config.telegram_bot_token)/sendMessage"
                }

                try {
                    Invoke-RestMethod -Uri $TgUrl -Method Post -Body $TelegramPayload -ContentType 'application/json' | Out-Null
                }
                catch {
                    Write-Warning "Alliance $($Alliance.id) Row $($i + 1): Failed to send Telegram notification. Exception: $_"
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($Config.callmebot_phone) -and -not [string]::IsNullOrWhiteSpace($Config.callmebot_apikey)) {
                $WhatsAppText = $MessageText -replace '\*\*(.+?)\*\*', '*$1*'
                $WhatsAppText = $WhatsAppText -replace '~~(.+?)~~', '~$1~'
                if (-not [string]::IsNullOrWhiteSpace($EmbedTitle)) {
                    $WhatsAppText = "*$EmbedTitle*`n`n$WhatsAppText"
                }
                $EncodedText = [System.Uri]::EscapeDataString($WhatsAppText)
                $CallMeBotUri = "https://api.callmebot.com/whatsapp.php?phone=$($Config.callmebot_phone)&text=${EncodedText}&apikey=$($Config.callmebot_apikey)"
                try {
                    Invoke-RestMethod -Uri $CallMeBotUri -Method Get | Out-Null
                }
                catch {
                    Write-Warning "Failed to send WhatsApp notification via CallMeBot for $($Alliance.id). Exception: $_"
                }
            }

            while ($Rows[$i].Count -le $ColIndices.DiscordMessageId) {
                $Rows[$i] += ""
            }

            if ($TimeOption -eq "Wiederkehrend") {
                $Rows[$i][$ColIndices.LastSent] = $NowLocal.ToString("dd.MM.yyyy")
            } else {
                $Rows[$i][$ColIndices.Status] = "Gesendet"
                $Rows[$i][$ColIndices.LastSent] = $NowLocal.ToString("dd.MM.yyyy HH:mm:ss")
            }
            
            if (-not [string]::IsNullOrWhiteSpace($NewMessageId)) {
                $Rows[$i][$ColIndices.DiscordMessageId] = $NewMessageId
                $CurrentMessageId = $NewMessageId
            }
            $RowsUpdated = $true
        }

        if (-not [string]::IsNullOrWhiteSpace($CurrentMessageId)) {
            $ActiveMessageIdsThisRun += $CurrentMessageId
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Config.discord_webhook)) {
        foreach ($OldId in $KnownIdsForAlliance) {
            if ($ActiveMessageIdsThisRun -notcontains $OldId -and -not [string]::IsNullOrWhiteSpace($OldId)) {
                try {
                    Invoke-RestMethod -Uri "$($Config.discord_webhook)/messages/$OldId" -Method Delete
                    Write-Output "Alliance $($Alliance.id): Cleaned up deleted/expired Discord message ($OldId)."
                } catch {
                    Write-Warning "Alliance $($Alliance.id): Could not delete orphaned Discord message ($OldId)."
                }
            }
        }
    }

    $GlobalState[$Alliance.id] = $ActiveMessageIdsThisRun

    if ($RowsUpdated) {
        $UpdateRange = "A1:M"
        $UpdatePayload = @{
            range = $UpdateRange
            values = $Rows
        } | ConvertTo-Json -Depth 5
        
        $UpdateUrl = "https://sheets.googleapis.com/v4/spreadsheets/$($Config.google_sheet_id)/values/$UpdateRange`?valueInputOption=USER_ENTERED"
        
        try {
            Invoke-RestMethod -Uri $UpdateUrl -Headers @{ Authorization = "Bearer $GoogleToken" } -Method Put -Body $UpdatePayload -ContentType 'application/json' | Out-Null
            Write-Output "Alliance $($Alliance.id): Google Sheet updated successfully."
        } catch {
            Write-Error "Alliance $($Alliance.id): Failed to update Google Sheet. Exception: $_"
        }
    }
}

$GlobalState | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFilePath -NoNewline
