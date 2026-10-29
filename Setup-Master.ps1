# Run once on listing-master, as Administrator. Setup-Master.bat does that.
# Opens Windows so the workers can reach this laptop. No extra software.

$ErrorActionPreference = "Stop"
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$configPath = Join-Path $root "config.json"

Add-Type -AssemblyName System.Web.Extensions
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$config = $serializer.DeserializeObject([System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8))
$port = [int]$config["port"]
$prefix = "http://+:$port/"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Run Setup-Master.bat by right-clicking it and choosing Run as administrator."
    exit 1
}

$everyone = (New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")).Translate([System.Security.Principal.NTAccount]).Value
$existing = netsh http show urlacl url="$prefix" 2>&1 | Out-String
if ($existing -match [regex]::Escape($prefix)) {
    Write-Host "This PC can already listen on port $port."
} else {
    netsh http add urlacl url="$prefix" user="$everyone" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not allow port $port. Close other copies of the master window and run this again."
        exit 1
    }
    Write-Host "Allowed this PC to listen on port $port."
}

netsh advfirewall firewall delete rule name="Listing Network Master" | Out-Null
netsh advfirewall firewall add rule name="Listing Network Master" dir=in action=allow protocol=TCP localport=$port remoteip=localsubnet | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host "Could not add the firewall rule."
    exit 1
}

Write-Host ""
Write-Host "Master setup is done."
Write-Host "Next: double-click Start-Master.bat and leave that window open."
Write-Host "Then open a browser on this laptop to http://localhost:$port"
