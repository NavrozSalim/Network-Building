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

Add-Type -Namespace ListingNetwork -Name Power -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
"@
[void][ListingNetwork.Power]::SetThreadExecutionState([uint32]"0x80000001")
[System.Net.ServicePointManager]::DefaultConnectionLimit = 16
[System.Net.ServicePointManager]::Expect100Continue = $false
$script:MasterDown = $false

function Invoke-Master {
    param(
        [string]$Method,
        [string]$Path,
        [hashtable]$Body
    )
    $params = @{
        Method           = $Method
        Uri              = "http://$($script:MasterIp):$($script:Port)$Path"
        Headers          = @{ "X-Network-Token" = $script:Token }
        TimeoutSec       = 20
        DisableKeepAlive = $true
        UseBasicParsing  = $true
    }
    if ($Body) {
        $params["ContentType"] = "application/json; charset=utf-8"
        $params["Body"] = ($Body | ConvertTo-Json -Compress)
    }
    $lastError = $null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $result = Invoke-RestMethod @params
            if ($script:MasterDown) {
                $script:MasterDown = $false
                Write-WorkerLog "Connected to the master again."
            }
            return $result
        } catch {
            $lastError = $_
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -ge 400 -and $code -lt 500) { throw }
            if ($attempt -lt 4) { Start-Sleep -Seconds (2 * $attempt) }
        }
    }
    throw $lastError
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

$botScript = {
    param($PythonExe, $ScriptPath, $ExcelPath, $Store)
    try {
        $argList = @($ScriptPath, $ExcelPath)
        if ($Store) { $argList += @("--store", $Store) }
        $output = & $PythonExe @argList 2>&1 | Out-String
        $output = $output.Trim()
        if ($output.Length -gt 4000) { $output = $output.Substring(0, 4000) }
        if (-not $output) { $output = "Bot finished." }
        if ($LASTEXITCODE -ne 0) {
            return @{ ok = $false; message = $output }
        }
        return @{ ok = $true; message = $output }
    } catch {
        return @{ ok = $false; message = $_.Exception.Message }
    }
}

function Get-PythonExe {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "C:\Program Files\Python312\python.exe",
        "C:\Program Files\Python313\python.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $found = Get-Command python -ErrorAction SilentlyContinue
    if ($found -and $found.Source -and $found.Source -notlike "*WindowsApps*") {
        return $found.Source
    }
    throw "Python 3.12 was not found on this laptop."
}

function Repair-ChromeFolder {
    param([string]$ScriptPath)
    $chrome = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
    if (-not (Test-Path -LiteralPath $chrome)) { return }
    $dirs = @(
        (Split-Path -Parent $ScriptPath),
        (Split-Path -Parent (Split-Path -Parent $ScriptPath))
    )
    foreach ($dir in $dirs) {
        $stores = Join-Path $dir "stores.json"
        if (-not (Test-Path -LiteralPath $stores)) { continue }
        $json = Get-Content -Raw -LiteralPath $stores | ConvertFrom-Json
        $current = [string]$json.chrome_user_data_dir
        if ($current -and (Test-Path -LiteralPath $current)) { continue }
        $json.chrome_user_data_dir = $chrome
        $json | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stores
        Write-WorkerLog "Chrome folder set to $chrome"
    }
}

function Get-BotLaunch {
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
    $python = Get-PythonExe
    Repair-ChromeFolder -ScriptPath $scriptPath
    return @{
        python = $python
        script = $scriptPath
        excel  = $localFile
        store  = ([string]$Task.store).Trim()
    }
}

function Start-BotTask {
    param($Task, $Launch)
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($botScript)
    [void]$ps.AddArgument([string]$Launch.python)
    [void]$ps.AddArgument([string]$Launch.script)
    [void]$ps.AddArgument([string]$Launch.excel)
    [void]$ps.AddArgument([string]$Launch.store)
    $handle = $ps.BeginInvoke()
    return @{
        task     = $Task
        runspace = $runspace
        shell    = $ps
        handle   = $handle
    }
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
                    } elseif ($code -eq 404) {
                        Write-WorkerLog "The master removed task $($active.task.id). This laptop is free."
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
                        $launch = Get-BotLaunch -Task $response.task
                        Write-WorkerLog "Excel saved. Starting the bot."
                        $active = Start-BotTask -Task $response.task -Launch $launch
                        $ready = $false
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
        if (-not $script:MasterDown) {
            $script:MasterDown = $true
            Write-WorkerLog "Lost the master at http://$($script:MasterIp):$($script:Port). Check that the master window is open. Retrying every few seconds..."
        }
    }
    Start-Sleep -Seconds $script:HeartbeatSeconds
}
