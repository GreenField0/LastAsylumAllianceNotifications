<#
.SYNOPSIS
    Sends the daily Alliance Duel and Survival schedule to a Discord channel.

.DESCRIPTION
    This script retrieves the current day of the week, loads the corresponding formatted
    markdown structure and image from an external schedule.json file, constructs the 
    payload, and dispatches it to Discord via Webhook.

.PARAMETER WebhookUrl
    The target Discord Webhook URL. Defaults to the environment variable DISCORD_WEBHOOK_URL.

.PARAMETER SchedulePath
    The path to the JSON file containing the daily schedules. Defaults to '.\schedule.json'.

.INPUTS
    None.

.OUTPUTS
    None.

.EXAMPLE
    .\Send-DailyBriefing.ps1
#>
[CmdletBinding()]
param (
    [string]$WebhookUrl = $env:DISCORD_WEBHOOK_URL,
    [string]$SchedulePath = ".\schedule.json"
)

if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
    Write-Error "Webhook URL is not defined. Please set the DISCORD_WEBHOOK_URL environment variable."
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
    embeds  = @(
        @{
            image = @{
                url = $TodayData.image
            }
        }
    )
}

# 5. Execute HTTP POST Request to Discord
# Depth 4 is required to correctly serialize the nested embed array/hashtable
$JsonPayload = $Payload | ConvertTo-Json -Depth 4

try {
    $Response = Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $JsonPayload -ContentType 'application/json'
    Write-Output "Successfully sent daily briefing for $CurrentDay to Discord."
}
catch {
    Write-Error "Failed to send webhook. Exception: $_"
    exit 1
}