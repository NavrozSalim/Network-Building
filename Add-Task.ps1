# Add one task from the master laptop.
# Examples:
#   powershell -ExecutionPolicy Bypass -File .\Add-Task.ps1
#   powershell -ExecutionPolicy Bypass -File .\Add-Task.ps1 -Title "Check worker" -Seconds 30
#   powershell -ExecutionPolicy Bypass -File .\Add-Task.ps1 -Kind command -Command "hostname"

param(
    [string]$Title = "",
    [ValidateSet("echo", "command")]
    [string]$Kind = "echo",
    [int]$Seconds = 20,
    [string]$Command = ""
)

$ErrorActionPreference = "Stop"
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

Add-Type -AssemblyName System.Web.Extensions
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$config = $serializer.DeserializeObject([System.IO.File]::ReadAllText((Join-Path $root "config.json"), [System.Text.Encoding]::UTF8))

if (-not $Title) {
    $Title = "Test task " + (Get-Date).ToString("HH:mm:ss")
}

$body = @{
    title   = $Title
    kind    = $Kind
    seconds = $Seconds
    command = $Command
}

$uri = "http://127.0.0.1:$($config['port'])/api/tasks"
try {
    $response = Invoke-RestMethod -Method Post -Uri $uri -Headers @{ "X-Network-Token" = [string]$config["token"] } -ContentType "application/json; charset=utf-8" -Body ($body | ConvertTo-Json -Compress) -TimeoutSec 15
} catch {
    Write-Host "Could not reach the master. Double-click Start-Master.bat first, and leave that window open."
    exit 1
}

Write-Host "Added task $($response.task.id): $($response.task.title)"
Write-Host "Status: $($response.task.status)"
if ($response.task.status -eq "pending") {
    Write-Host "Every worker is busy, so this task is waiting."
}
