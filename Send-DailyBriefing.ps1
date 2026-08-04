<#
.SYNOPSIS
    Sends the daily Alliance Duel and Survival schedule to a Discord channel.
    Supports multiple alliances configured via a JSON structure.
#>
[CmdletBinding()]
param (
    [string]$SchedulePath = ".\schedule.json",
    [string]$ConfigJson = $env:ALLIANCES_CONFIG
)

if ([string]::IsNullOrWhiteSpace($ConfigJson)) {
    Write-Error "ALLIANCES_CONFIG environment variable is not defined or empty."
    exit 1
}

if (-not (Test-Path $SchedulePath)) {
    Write-Error "Schedule file not found at path: $SchedulePath"
    exit 1
}

# 1. Load and parse the schedule data from JSON
try {
    $ScheduleData = Get-Content -Raw -Path $SchedulePath | ConvertFrom-Json
}
catch {
    Write-Error "Failed to parse JSON file. Ensure $SchedulePath contains valid JSON."
    exit 1
}

# 2. Parse Alliances config
try {
    $Alliances = $ConfigJson | ConvertFrom-Json
}
catch {
    Write-Error "Failed to parse ALLIANCES_CONFIG JSON. Exception: $_"
    exit 1
}

foreach ($Alliance in $Alliances) {
    if (-not $Alliance.daily_briefing -or $Alliance.daily_briefing.enabled -eq $false) {
        Write-Verbose "Daily briefing disabled for alliance $($Alliance.id) - skipping."
        continue
    }

    $Config = $Alliance.daily_briefing
    $StateFilePath = ".\.daily-state-$($Alliance.id).json"

    # 3. Determine timezone and local time
    try {
        $TimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($Alliance.timezone)
        $NowLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $TimeZone)
    } catch {
        Write-Warning "Alliance $($Alliance.id): Unknown timezone '$($Alliance.timezone)' - skipping."
        continue
    }

    $CurrentDay = $NowLocal.DayOfWeek.ToString()
    $TodayData = $ScheduleData.$CurrentDay

    if ($null -eq $TodayData) {
        Write-Warning "Alliance $($Alliance.id): No schedule data found for $CurrentDay."
        continue
    }

    # 4. Check if we reached the target time
    $TargetTimeSpan = [timespan]::Zero
    if (-not [timespan]::TryParse($Config.send_time, [ref]$TargetTimeSpan)) {
        Write-Warning "Alliance $($Alliance.id): Invalid send_time format '$($Config.send_time)' - should be e.g. '05:00'."
        continue
    }

    if ($NowLocal.TimeOfDay -lt $TargetTimeSpan) {
        Write-Verbose "Alliance $($Alliance.id): Target time $($Config.send_time) not reached yet (Local time: $($NowLocal.ToString('HH:mm')))."
        continue
    }

    # 5. Check if we already sent it today
    $State = @{ last_send_date = ""; last_message_id = "" }
    if (Test-Path $StateFilePath) {
        try {
            # Need to cast explicitly to hashtable/PSCustomObject for easier access
            $FileContent = Get-Content -Raw -Path $StateFilePath | ConvertFrom-Json
            if ($FileContent.last_send_date) { $State.last_send_date = $FileContent.last_send_date }
            if ($FileContent.last_message_id) { $State.last_message_id = $FileContent.last_message_id }
        } catch { }
    }

    $TodayString = $NowLocal.ToString('yyyy-MM-dd')
    if ($State.last_send_date -eq $TodayString) {
        Write-Verbose "Alliance $($Alliance.id): Already sent today."
        continue
    }

    # 6. Prepare Message Content based on requested languages
    $MessageParts = @()
    if (-not [string]::IsNullOrWhiteSpace($Config.role_id_ping)) {
        $MessageParts += "<@&$($Config.role_id_ping)>"
    }

    $Languages = $Config.languages
    if (-not $Languages) { $Languages = @("de") } # Default fallback

    foreach ($Lang in $Languages) {
        $Text = $TodayData.content.$Lang
        if ($Text) {
            $MessageParts += $Text
        } else {
            Write-Warning "Alliance $($Alliance.id): Language '$Lang' not found in schedule.json for $CurrentDay."
        }
    }

    if ($MessageParts.Count -eq 0 -or ($MessageParts.Count -eq 1 -and $Config.role_id_ping)) {
        Write-Warning "Alliance $($Alliance.id): Resulting message is empty, skipping."
        continue
    }

    # Combine all parts with a separator
    $FinalMessage = $MessageParts -join "`n`n---\n\n"

    $Payload = [ordered]@{
        content = $FinalMessage
    }

    $NewMessageId = ""

    # 7. Delete previous day's message on Discord
    if (-not [string]::IsNullOrWhiteSpace($Config.discord_webhook) -and -not [string]::IsNullOrWhiteSpace($State.last_message_id)) {
        try {
            Invoke-RestMethod -Uri "$($Config.discord_webhook)/messages/$($State.last_message_id)" -Method Delete
            Write-Output "Alliance $($Alliance.id): Deleted previous message ($($State.last_message_id))."
        }
        catch {
            Write-Warning "Alliance $($Alliance.id): Could not delete previous message ($($State.last_message_id)): $_"
        }
    }

    # 8. Send to Discord
    $DiscordSuccess = $false
    if (-not [string]::IsNullOrWhiteSpace($Config.discord_webhook)) {
        $JsonPayload = $Payload | ConvertTo-Json -Depth 4
        try {
            $Response = Invoke-RestMethod -Uri "$($Config.discord_webhook)?wait=true" -Method Post -Body $JsonPayload -ContentType 'application/json'
            Write-Output "Successfully sent daily briefing for $CurrentDay to Discord for $($Alliance.id)."
            if ($Response.id) { $NewMessageId = $Response.id }
            $DiscordSuccess = $true
        }
        catch {
            Write-Error "Failed to send Discord webhook for $($Alliance.id). Exception: $_"
        }
    } else {
        $DiscordSuccess = $true # If no discord configured, consider it a success so Telegram can still run and state saves
    }

    # If Discord failed completely, we skip saving state so it retries on the next cron run
    if (-not $DiscordSuccess) {
        continue
    }

    # 9. Send to Telegram
    if (-not [string]::IsNullOrWhiteSpace($Config.telegram_bot_token) -and -not [string]::IsNullOrWhiteSpace($Config.telegram_chat_id)) {
        $TextHtml = $FinalMessage -replace '<@&\d+>', '' -replace '<@\!?\d+>', '' -replace '<#\d+>', '' -replace '@(everyone|here)', ''
        $TextHtml = $TextHtml.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
        $TextHtml = $TextHtml -replace '(?m)^[\*\-]\s+', '• '
        $TextHtml = $TextHtml -replace '(?m)^#+\s*(.+)$', '<b>$1</b>'
        $TextHtml = $TextHtml -replace '(?m)^[-*_]{3,}\s*$', '──────────'
        $TextHtml = $TextHtml -replace '\*\*(.+?)\*\*', '<b>$1</b>'
        $TextHtml = $TextHtml -replace '~~(.+?)~~', '<s>$1</s>'
        $TextHtml = $TextHtml -replace '(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)', '<i>$1</i>'
        $TextHtml = $TextHtml -replace '_(.+?)_', '<i>$1</i>'
        $TextHtml = ($TextHtml -replace '(\r?\n){3,}', "`n`n").Trim()

        $TelegramPayload = @{
            chat_id                  = $Config.telegram_chat_id
            text                     = $TextHtml
            parse_mode               = 'HTML'
            disable_web_page_preview = $true
        } | ConvertTo-Json -Depth 3

        try {
            Invoke-RestMethod -Uri "https://api.telegram.org/bot$($Config.telegram_bot_token)/sendMessage" -Method Post -Body $TelegramPayload -ContentType 'application/json' | Out-Null
            Write-Output "Successfully sent daily briefing for $CurrentDay to Telegram for $($Alliance.id)."
        }
        catch {
            Write-Warning "Failed to send Telegram notification for $($Alliance.id). Exception: $_"
        }
    }

    # 10. Send WhatsApp notification via CallMeBot
    if (-not [string]::IsNullOrWhiteSpace($Config.callmebot_phone) -and -not [string]::IsNullOrWhiteSpace($Config.callmebot_apikey)) {
        $WhatsAppText = $FinalMessage -replace '\*\*(.+?)\*\*', '*$1*'
        $WhatsAppText = $WhatsAppText -replace '~~(.+?)~~', '~$1~'
        $EncodedText = [System.Uri]::EscapeDataString($WhatsAppText)
        $CallMeBotUri = "https://api.callmebot.com/whatsapp.php?phone=$($Config.callmebot_phone)&text=${EncodedText}&apikey=$($Config.callmebot_apikey)"
        try {
            Invoke-RestMethod -Uri $CallMeBotUri -Method Get | Out-Null
            Write-Output "Successfully sent daily briefing for $CurrentDay to WhatsApp via CallMeBot for $($Alliance.id)."
        }
        catch {
            Write-Warning "Failed to send WhatsApp notification via CallMeBot for $($Alliance.id). Exception: $_"
        }
    }

    # 11. Save State for next day
    $NewState = @{
        last_send_date = $TodayString
        last_message_id = $NewMessageId
    }
    $NewState | ConvertTo-Json | Set-Content -Path $StateFilePath -NoNewline
}