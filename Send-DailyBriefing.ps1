<#
.SYNOPSIS
    Sends the daily Alliance Duel and Survival schedule to a Discord channel.

.DESCRIPTION
    This script retrieves the current day of the week, loads the corresponding formatted
    markdown structure and image from an external schedule.json file, constructs the 
    payload, and dispatches it to Discord via Webhook.

.PARAMETER WebhookUrl
    The target Discord Webhook URL. Defaults to the environment variable DISCORD_WEBHOOK_URL_DAILY.

.PARAMETER SchedulePath
    The path to the JSON file containing the daily schedules. Defaults to '.\schedule.json'.

.PARAMETER MessageIdStorePath
    The path to a small file used to remember the ID of the last message sent via the
    webhook, so it can be deleted before the new one is posted. Defaults to
    '.\.last-message-id.txt'.

.INPUTS
    None.

.OUTPUTS
    None.

.EXAMPLE
    .\Send-DailyBriefing.ps1
#>
[CmdletBinding()]
param (
    # --- Channels ---
    [bool]$EnableDiscord = $true,
    [bool]$EnableTelegram = $true,
    [bool]$EnableCallMeBot = $false,

    # --- Credentials ---
    [string]$WebhookUrl = $env:DISCORD_WEBHOOK_URL_DAILY,
    [string]$SchedulePath = ".\schedule.json",
    [string]$MessageIdStorePath = ".\.last-message-id.txt",
    [string]$TelegramBotToken = $env:TELEGRAM_BOT_TOKEN,
    [string]$TelegramChatId = $env:TELEGRAM_CHAT_ID,
    [string]$CallMeBotPhone = $env:CALLMEBOT_PHONE,
    [string]$CallMeBotApiKey = $env:CALLMEBOT_APIKEY
)

if ($EnableDiscord -and [string]::IsNullOrWhiteSpace($WebhookUrl)) {
    Write-Error "Webhook URL is not defined. Please set the DISCORD_WEBHOOK_URL_DAILY environment variable."
    exit 1
}

if (-not (Test-Path $SchedulePath)) {
    Write-Error "Schedule file not found at path: $SchedulePath"
    exit 1
}

# 1. Determine current day of the week
$CurrentDay = (Get-Date).DayOfWeek.ToString()

# 2. Load and parse the schedule data from JSON
try {
    $ScheduleData = Get-Content -Raw -Path $SchedulePath | ConvertFrom-Json
}
catch {
    Write-Error "Failed to parse JSON file. Ensure $SchedulePath contains valid JSON."
    exit 1
}

# 3. Extract the specific data for today
$TodayData = $ScheduleData.$CurrentDay

if ($null -eq $TodayData) {
    Write-Error "No schedule data found for $CurrentDay in the JSON file."
    exit 1
}

# 4. Construct JSON Payload with Embed Structure for Image
$Payload = [ordered]@{
    content = $TodayData.content
    # embeds  = @(
    #     @{
    #         image = @{
    #             url = $TodayData.image
    #         }
    #     }
    # )
}

# 5. Delete the previous day's message (if any) so only the current one remains
if ($EnableDiscord -and (Test-Path $MessageIdStorePath)) {
    $PreviousMessageId = (Get-Content -Raw -Path $MessageIdStorePath).Trim()
    if (-not [string]::IsNullOrWhiteSpace($PreviousMessageId)) {
        try {
            Invoke-RestMethod -Uri "${WebhookUrl}/messages/$PreviousMessageId" -Method Delete
            Write-Output "Deleted previous message ($PreviousMessageId)."
        }
        catch {
            # Message may already have been deleted manually, or the ID/token is stale - not fatal.
            Write-Warning "Could not delete previous message ($PreviousMessageId): $_"
        }
    }
}

# 6. Execute HTTP POST Request to Discord
if ($EnableDiscord) {
    # Depth 4 is required to correctly serialize the nested embed array/hashtable
    # '?wait=true' makes Discord return the created message (incl. its ID) instead of an empty response
    $JsonPayload = $Payload | ConvertTo-Json -Depth 4

    try {
        $Response = Invoke-RestMethod -Uri "${WebhookUrl}?wait=true" -Method Post -Body $JsonPayload -ContentType 'application/json'
        Write-Output "Successfully sent daily briefing for $CurrentDay to Discord."

        # 7. Remember the new message ID for the next run
        if ($Response.id) {
            Set-Content -Path $MessageIdStorePath -Value $Response.id -NoNewline
        }
    }
    catch {
        Write-Error "Failed to send webhook. Exception: $_"
        exit 1
    }
}
else {
    Write-Verbose "Discord disabled – skipping."
}

# 8. Send Telegram notification (if enabled and credentials are provided)
if ($EnableTelegram -and -not [string]::IsNullOrWhiteSpace($TelegramBotToken) -and -not [string]::IsNullOrWhiteSpace($TelegramChatId)) {
    # Telegram supports a subset of HTML; build a plain-text version of the content.
    # The 'content' field from schedule.json is Markdown intended for Discord, so we
    # strip Discord-specific syntax and send it as-is (Telegram renders basic Markdown
    # with parse_mode=Markdown).
    $TelegramText = $TodayData.content

    $TelegramPayload = @{
        chat_id    = $TelegramChatId
        text       = $TelegramText
        parse_mode = 'Markdown'
    } | ConvertTo-Json -Depth 3

    try {
        Invoke-RestMethod -Uri "https://api.telegram.org/bot${TelegramBotToken}/sendMessage" -Method Post -Body $TelegramPayload -ContentType 'application/json' | Out-Null
        Write-Output "Successfully sent daily briefing for $CurrentDay to Telegram."
    }
    catch {
        # Telegram failure is non-fatal; Discord was already sent successfully.
        Write-Warning "Failed to send Telegram notification. Exception: $_"
    }
}
else {
    Write-Verbose "Telegram disabled or credentials not set – skipping Telegram notification."
}

# 9. Send WhatsApp notification via CallMeBot (if enabled and credentials are provided)
if ($EnableCallMeBot -and -not [string]::IsNullOrWhiteSpace($CallMeBotPhone) -and -not [string]::IsNullOrWhiteSpace($CallMeBotApiKey)) {
    # Convert the most common Discord markdown tokens to WhatsApp equivalents (best-effort)
    $WhatsAppText = $TodayData.content
    $WhatsAppText = $WhatsAppText -replace '\*\*(.+?)\*\*', '*$1*'  # **bold** -> *bold*
    $WhatsAppText = $WhatsAppText -replace '~~(.+?)~~', '~$1~'  # ~~strike~~ -> ~strike~

    $EncodedText = [System.Uri]::EscapeDataString($WhatsAppText)
    $CallMeBotUri = "https://api.callmebot.com/whatsapp.php?phone=${CallMeBotPhone}&text=${EncodedText}&apikey=${CallMeBotApiKey}"

    try {
        Invoke-RestMethod -Uri $CallMeBotUri -Method Get | Out-Null
        Write-Output "Successfully sent daily briefing for $CurrentDay to WhatsApp via CallMeBot."
    }
    catch {
        # CallMeBot failure is non-fatal.
        Write-Warning "Failed to send WhatsApp notification via CallMeBot. Exception: $_"
    }
}
else {
    Write-Verbose "CallMeBot disabled or credentials not set – skipping WhatsApp notification."
}