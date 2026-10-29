# Run on each worker laptop. Leave this window open.
# The laptop tells the master when it is free, takes one task, then becomes free again.

$ErrorActionPreference = "Continue"
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

Add-Type -AssemblyName System.Web.Extensions
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$config = $serializer.DeserializeObject([System.IO.File]::ReadAllText((Join-Path $root "config.json"), [System.Text.Encoding]::UTF8))

$script:MasterIp = [string]$config["masterIp"]
$script:Port = [int]$config["port"]
$script:Token = [string]$config["token"]
$script:HeartbeatSeconds = [int]$config["heartbeatSeconds"]
if ($script:HeartbeatSeconds -lt 2) { $script:HeartbeatSeconds = 2 }
$script:Bots = @{}
if ($config.ContainsKey("bots") -and $config["bots"]) {
    foreach ($botKey in @($config["bots"].Keys)) {
        $botRow = $config["bots"][$botKey]
        $botScript = [string]$botRow["script"]
        if ($botScript) { $script:Bots[[string]$botKey] = $botScript }
    }
}
$script:WorkerName = $env:COMPUTERNAME

if ($script:WorkerName -match "master") {
    Write-Host "This is the master laptop ($script:WorkerName)."
    Write-Host "Double-click Start-Master.bat on this PC. Start-Worker.bat is for the other laptops."
    exit 1
}

function Get-LanIpv4 {
    try {
        $items = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
            $_.IPAddress -like "192.168.*" -and $_.AddressState -eq "Preferred"
        })
        if ($items.Count -gt 0) { return [string]$items[0].IPAddress }
    } catch {
    }
    return ""
}

function Invoke-Master {
    param(
        [string]$Method,
        [string]$Path,
        [hashtable]$Body
    )
    $params = @{
        Method      = $Method
        Uri         = "http://$($script:MasterIp):$($script:Port)$Path"
        Headers     = @{ "X-Network-Token" = $script:Token }
        TimeoutSec  = 15
    }
    if ($Body) {
        $params["ContentType"] = "application/json; charset=utf-8"
        $params["Body"] = ($Body | ConvertTo-Json -Compress)
    }
    return Invoke-RestMethod @params
}

function Write-WorkerLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date).ToString("HH:mm:ss"), $Message
    Write-Host $line
}

$jobScript = {
    param($Kind, $Seconds, $Command)
    try {
        if ($Kind -eq "echo") {
            $sec = 20
            if ($null -ne $Seconds -and "$Seconds" -ne "") { $sec = [int]$Seconds }
            if ($sec -lt 1) { $sec = 1 }
            if ($sec -gt 3600) { $sec = 3600 }
            Start-Sleep -Seconds $sec
            return @{ ok = $true; message = "Finished the test task after $sec seconds." }
        }
        if ($Kind -eq "command") {
            if ([string]::IsNullOrWhiteSpace([string]$Command)) {
                return @{ ok = $false; message = "This task has no command." }
            }
            $output = & powershell.exe -NoProfile -NonInteractive -Command $Command 2>&1 | Out-String
            $output = $output.Trim()
            if ($output.Length -gt 4000) { $output = $output.Substring(0, 4000) }
            if (-not $output) { $output = "Command finished." }
            if ($LASTEXITCODE -ne 0) {
                return @{ ok = $false; message = $output }
            }
            return @{ ok = $true; message = $output }
        }
        return @{ ok = $false; message = "Unknown task kind: $Kind" }
    } catch {
        return @{ ok = $false; message = $_.Exception.Message }
    }
}

function Get-BotCommand {
    param($Task)
    $botId = [string]$Task.bot
    if (-not $script:Bots.ContainsKey($botId)) {
        throw "This laptop does not know the bot '$botId'. Copy the new config.json here and start the worker again."
    }
    $scriptPath = [string]$script:Bots[$botId]
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "The bot file was not found: $scriptPath"
    }
    $jobDir = Join-Path $root "jobs"
    New-Item -ItemType Directory -Force -Path $jobDir | Out-Null
    $ext = [System.IO.Path]::GetExtension([string]$Task.fileName).ToLowerInvariant()
    if ($ext -ne ".xlsx" -and $ext -ne ".xls") { $ext = ".xlsx" }
    $localFile = Join-Path $jobDir ([string]$Task.id + $ext)
    $fileUri = "http://$($script:MasterIp):$($script:Port)/api/files/$([string]$Task.id)"
    $progress = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
        Invoke-WebRequest -Uri $fileUri -Headers @{ "X-Network-Token" = $script:Token } -OutFile $localFile -TimeoutSec 120 -UseBasicParsing
    } finally {
        $ProgressPreference = $progress
    }
    if (-not (Test-Path -LiteralPath $localFile) -or (Get-Item -LiteralPath $localFile).Length -lt 1) {
        throw "The Excel file did not download."
    }
    $command = 'python "' + $scriptPath.Replace('"', "") + '" "' + $localFile.Replace('"', "") + '"'
    $store = ([string]$Task.store).Trim()
    if ($store) { $command += ' --store "' + $store.Replace('"', "") + '"' }
    return $command
}

function Start-WorkerTask {
    param($Task)
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($jobScript)
    [void]$ps.AddArgument([string]$Task.kind)
    [void]$ps.AddArgument($Task.seconds)
    [void]$ps.AddArgument([string]$Task.command)
    $handle = $ps.BeginInvoke()
    return @{
        task     = $Task
        runspace = $runspace
        shell    = $ps
        handle   = $handle
    }
}

function Complete-WorkerTask {
    param($Active)
    $ok = $false
    $message = "The task ended without a result."
    try {
        $returned = $Active.shell.EndInvoke($Active.handle)
        $item = $returned | Select-Object -Last 1
        if ($item) {
            $ok = [bool]$item.ok
            if ($item.message) { $message = [string]$item.message }
        }
        $errors = $Active.shell.Streams.Error | ForEach-Object { $_.ToString() }
        if ($errors) {
            $extra = ($errors -join " ").Trim()
            if ($extra -and -not $item) {
                $ok = $false
                $message = $extra
            }
        }
    } catch {
        $ok = $false
        $message = $_.Exception.Message
    } finally {
        $Active.shell.Dispose()
        $Active.runspace.Close()
        $Active.runspace.Dispose()
    }
    return @{ ok = $ok; message = $message }
}

$ip = Get-LanIpv4
Write-Host ""
Write-Host "Worker laptop: $script:WorkerName"
Write-Host "Address:       $ip"
Write-Host "Master:        http://$($script:MasterIp):$($script:Port)"
Write-Host "Leave this window open. Closing it makes this laptop look offline."
Write-Host ""

$active = $null
while ($true) {
    try {
        if ($active) {
            Invoke-Master -Method Post -Path "/api/heartbeat" -Body @{
                name   = $script:WorkerName
                ip     = $ip
                state  = "busy"
                taskId = [string]$active.task.id
            } | Out-Null

            if ($active.handle.IsCompleted -and -not $active.result) {
                $active.result = Complete-WorkerTask -Active $active
            }
            if ($active.result) {
                $status = "done"
                if (-not $active.result.ok) { $status = "failed" }
                try {
                    Invoke-Master -Method Post -Path "/api/task-result" -Body @{
                        name    = $script:WorkerName
                        taskId  = [string]$active.task.id
                        status  = $status
                        message = [string]$active.result.message
                    } | Out-Null
                } catch {
                    $code = 0
                    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
                    if ($code -eq 409) {
                        Write-WorkerLog "The master gave task $($active.task.id) to another laptop."
                        $active = $null
                    } else {
                        throw
                    }
                }
                if ($active) {
                    if ($active.result.ok) {
                        Write-WorkerLog "Finished task $($active.task.id). This laptop is free."
                    } else {
                        Write-WorkerLog "Task $($active.task.id) failed. This laptop is free."
                        Write-WorkerLog $active.result.message
                    }
                    $active = $null
                }
            }
        } else {
            Invoke-Master -Method Post -Path "/api/heartbeat" -Body @{
                name   = $script:WorkerName
                ip     = $ip
                state  = "free"
                taskId = ""
            } | Out-Null

            $response = Invoke-Master -Method Post -Path "/api/next-job" -Body @{
                name = $script:WorkerName
                ip   = $ip
            }
            if ($response.task -and $response.task.id) {
                Write-WorkerLog "Got task $($response.task.id): $($response.task.title)"
                $ready = $true
                if ([string]$response.task.kind -eq "bot") {
                    try {
                        $response.task.command = Get-BotCommand -Task $response.task
                        $response.task.kind = "command"
                        Write-WorkerLog "Excel saved. Starting the bot."
                    } catch {
                        $ready = $false
                        $reason = $_.Exception.Message
                        Write-WorkerLog $reason
                        Invoke-Master -Method Post -Path "/api/task-result" -Body @{
                            name    = $script:WorkerName
                            taskId  = [string]$response.task.id
                            status  = "failed"
                            message = $reason
                        } | Out-Null
                    }
                }
                if ($ready) { $active = Start-WorkerTask -Task $response.task }
            }
        }
    } catch {
        Write-WorkerLog "Master is not reachable at http://$($script:MasterIp):$($script:Port). Trying again..."
    }
    Start-Sleep -Seconds $script:HeartbeatSeconds
}
