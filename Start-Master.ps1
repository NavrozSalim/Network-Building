# Run on listing-master. Leave this window open.
# Workers call in, and this program gives each task to one free laptop.
# If every worker is busy, the task stays pending.

$ErrorActionPreference = "Stop"
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.Web
$script:Serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:Serializer.MaxJsonLength = 10485760

$config = $script:Serializer.DeserializeObject([System.IO.File]::ReadAllText((Join-Path $root "config.json"), [System.Text.Encoding]::UTF8))
$script:Port = [int]$config["port"]
$script:Token = [string]$config["token"]
$script:MasterIp = [string]$config["masterIp"]
$script:OfflineSeconds = [int]$config["offlineSeconds"]
if ($script:OfflineSeconds -lt 90) { $script:OfflineSeconds = 90 }
$script:KnownWorkers = @()
foreach ($name in $config["workers"]) { $script:KnownWorkers += [string]$name }
$script:Bots = @{}
if ($config.ContainsKey("bots") -and $config["bots"]) {
    foreach ($botKey in @($config["bots"].Keys)) {
        $botRow = $config["bots"][$botKey]
        $botLabel = [string]$botRow["label"]
        $botScript = [string]$botRow["script"]
        if (-not $botLabel) { $botLabel = [string]$botKey }
        if ($botScript) {
            $script:Bots[[string]$botKey] = @{ label = $botLabel; script = $botScript }
        }
    }
}

$script:Workers = @{}
$script:Tasks = New-Object System.Collections.ArrayList
$script:LanReady = $false
$script:DataDir = Join-Path $root "data"
$script:UploadDir = Join-Path $script:DataDir "uploads"
$script:StatePath = Join-Path $script:DataDir "state.json"
New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $script:UploadDir | Out-Null

function Write-Log {
    param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date).ToString("HH:mm:ss"), $Message)
}

function Get-Stamp {
    return [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Unwrap-Value {
    param($Value)
    while ($Value -is [System.Management.Automation.PSObject]) {
        $base = $Value.PSObject.BaseObject
        if ($null -eq $base -or $base -eq $Value -or $base -is [System.Management.Automation.PSCustomObject]) { break }
        $Value = $base
    }
    return $Value
}

function Convert-ToHashtable {
    param($Value)
    $Value = Unwrap-Value $Value
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in @($Value.Keys)) {
            $table[[string]$key] = Convert-ToHashtable $Value[$key]
        }
        return $table
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            [void]$list.Add((Convert-ToHashtable $item))
        }
        return $list
    }
    return [string]$Value
}

function ConvertTo-ApiJson {
    param($Value)
    $Value = Unwrap-Value $Value
    if ($null -eq $Value) { return "null" }
    if ($Value -is [bool]) {
        if ($Value) { return "true" }
        return "false"
    }
    if ($Value -is [string]) {
        return [System.Web.HttpUtility]::JavaScriptStringEncode($Value, $true)
    }
    if ($Value -is [ValueType]) {
        return $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($key in @($Value.Keys)) {
            $parts.Add((ConvertTo-ApiJson ([string]$key)) + ":" + (ConvertTo-ApiJson $Value[$key]))
        }
        return "{" + ($parts -join ",") + "}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) {
            $parts.Add((ConvertTo-ApiJson $item))
        }
        return "[" + ($parts -join ",") + "]"
    }
    return ConvertTo-ApiJson ([string]$Value)
}

function Get-Field {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in @($Object.Keys)) {
            if ([string]$key -eq $Name) { return $Object[$key] }
        }
    }
    return $null
}

function Resolve-WorkerName {
    param([string]$Name)
    $raw = ([string]$Name).Trim()
    if (-not $raw) { return "" }
    foreach ($known in $script:KnownWorkers) {
        if ($known.ToLowerInvariant() -eq $raw.ToLowerInvariant()) { return $known }
    }
    return $raw
}

function Get-TaskById {
    param([string]$TaskId)
    foreach ($task in @($script:Tasks)) {
        if ([string]$task.id -eq $TaskId) { return $task }
    }
    return $null
}

function Save-State {
    $workerList = New-Object System.Collections.ArrayList
    foreach ($key in @($script:Workers.Keys)) {
        [void]$workerList.Add($script:Workers[$key])
    }
    $payload = @{
        workers = $workerList
        tasks   = $script:Tasks
    }
    $json = ConvertTo-ApiJson $payload
    $temp = "$($script:StatePath).tmp"
    [System.IO.File]::WriteAllText($temp, $json, [System.Text.Encoding]::UTF8)
    [System.IO.File]::Copy($temp, $script:StatePath, $true)
    Remove-Item $temp -Force
}

function Restore-State {
    if (-not (Test-Path $script:StatePath)) { return }
    try {
        $loaded = Convert-ToHashtable ($script:Serializer.DeserializeObject([System.IO.File]::ReadAllText($script:StatePath, [System.Text.Encoding]::UTF8)))
        $script:Workers = @{}
        $workers = Get-Field $loaded "workers"
        if ($workers) {
            foreach ($worker in @($workers)) {
                $display = Resolve-WorkerName (Get-Field $worker "name")
                if (-not $display) { continue }
                $worker.name = $display
                $script:Workers[$display.ToLowerInvariant()] = $worker
            }
        }
        $script:Tasks = New-Object System.Collections.ArrayList
        $tasks = Get-Field $loaded "tasks"
        if ($tasks) {
            foreach ($task in @($tasks)) { [void]$script:Tasks.Add($task) }
        }
        Write-Log "Loaded saved tasks: $($script:Tasks.Count)"
    } catch {
        $bad = "$($script:StatePath).bad"
        Move-Item -Force $script:StatePath $bad
        Write-Log "Saved status could not be read. Started a fresh list."
    }
}

function Update-Presence {
    $now = [DateTime]::UtcNow
    $changed = $false
    foreach ($key in @($script:Workers.Keys)) {
        $worker = $script:Workers[$key]
        $seenText = [string]$worker.lastSeen
        $offline = $true
        if ($seenText) {
            try {
                $seen = [DateTime]::Parse($seenText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
                $offline = (($now - $seen.ToUniversalTime()).TotalSeconds -gt $script:OfflineSeconds)
            } catch {
                $offline = $true
            }
        }
        if ($offline -and [string]$worker.state -ne "offline") {
            $worker.state = "offline"
            $worker.taskId = ""
            $changed = $true
            Write-Log "$($worker.name) is offline"
        }
    }

    foreach ($task in @($script:Tasks)) {
        $status = [string]$task.status
        if ($status -ne "assigned" -and $status -ne "running") { continue }
        $owner = [string]$task.assignedTo
        $worker = $null
        if ($owner -and $script:Workers.ContainsKey($owner.ToLowerInvariant())) {
            $worker = $script:Workers[$owner.ToLowerInvariant()]
        }
        if (-not $worker -or [string]$worker.state -eq "offline") {
            $task.status = "pending"
            $task.assignedTo = ""
            $task.assignedAt = ""
            $task.message = "The worker went offline. Waiting for a free laptop."
            $changed = $true
            Write-Log "Task $($task.id) is pending again"
        }
    }

    if ($changed) { Save-State }
}

function Touch-Worker {
    param(
        [string]$Name,
        [string]$Ip,
        [string]$State,
        [string]$TaskId
    )
    $display = Resolve-WorkerName $Name
    if (-not $display) { return $null }
    $key = $display.ToLowerInvariant()
    if (-not $script:Workers.ContainsKey($key)) {
        $script:Workers[$key] = @{
            name     = $display
            ip       = ""
            state    = "offline"
            lastSeen = ""
            taskId   = ""
        }
    }
    $worker = $script:Workers[$key]
    $worker.name = $display
    if ($Ip) { $worker.ip = $Ip }
    $worker.state = $State
    $worker.taskId = $TaskId
    $worker.lastSeen = Get-Stamp
    return $worker
}

function Get-TaskTitle {
    param([string]$TaskId)
    $task = Get-TaskById $TaskId
    if ($task) { return [string]$task.title }
    return ""
}

function Copy-Task {
    param($Task)
    return @{
        id         = [string]$Task.id
        title      = [string]$Task.title
        kind       = [string]$Task.kind
        seconds    = $Task.seconds
        command    = [string]$Task.command
        bot        = [string]$Task.bot
        store      = [string]$Task.store
        fileName   = [string]$Task.fileName
        status     = [string]$Task.status
        assignedTo = [string]$Task.assignedTo
        message    = [string]$Task.message
        createdAt  = [string]$Task.createdAt
        finishedAt = [string]$Task.finishedAt
    }
}

function Get-StatusObject {
    Update-Presence
    $rows = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($known in $script:KnownWorkers) {
        $key = $known.ToLowerInvariant()
        $seen[$key] = $true
        if ($script:Workers.ContainsKey($key)) {
            $worker = $script:Workers[$key]
            [void]$rows.Add(@{
                name      = [string]$worker.name
                ip        = [string]$worker.ip
                state     = [string]$worker.state
                lastSeen  = [string]$worker.lastSeen
                taskId    = [string]$worker.taskId
                taskTitle = (Get-TaskTitle ([string]$worker.taskId))
            })
        } else {
            [void]$rows.Add(@{
                name      = $known
                ip        = ""
                state     = "offline"
                lastSeen  = ""
                taskId    = ""
                taskTitle = ""
            })
        }
    }
    foreach ($key in @($script:Workers.Keys)) {
        if ($seen.ContainsKey($key)) { continue }
        $worker = $script:Workers[$key]
        [void]$rows.Add(@{
            name      = [string]$worker.name
            ip        = [string]$worker.ip
            state     = [string]$worker.state
            lastSeen  = [string]$worker.lastSeen
            taskId    = [string]$worker.taskId
            taskTitle = (Get-TaskTitle ([string]$worker.taskId))
        })
    }

    $free = 0
    $busy = 0
    $offline = 0
    foreach ($row in $rows) {
        if ($row.state -eq "free") { $free += 1 }
        elseif ($row.state -eq "busy") { $busy += 1 }
        else { $offline += 1 }
    }

    $pending = 0
    $taskRows = New-Object System.Collections.ArrayList
    foreach ($task in @($script:Tasks)) {
        if ([string]$task.status -eq "pending") { $pending += 1 }
        [void]$taskRows.Add((Copy-Task $task))
    }

    return @{
        master   = $env:COMPUTERNAME
        now      = Get-Stamp
        lanReady = [bool]$script:LanReady
        masterIp = $script:MasterIp
        port     = $script:Port
        bots     = (Get-BotRows)
        counts   = @{
            free    = $free
            busy    = $busy
            offline = $offline
            pending = $pending
        }
        workers  = $rows
        tasks    = $taskRows
    }
}

function Get-BotRows {
    $order = @("etsy-create", "reverb-create", "reverb-stock", "reverb-sku")
    $rows = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($botKey in $order) {
        if (-not $script:Bots.ContainsKey($botKey)) { continue }
        $seen[$botKey] = $true
        [void]$rows.Add(@{ id = $botKey; label = [string]$script:Bots[$botKey].label })
    }
    foreach ($botKey in @($script:Bots.Keys)) {
        if ($seen.ContainsKey($botKey)) { continue }
        [void]$rows.Add(@{ id = [string]$botKey; label = [string]$script:Bots[$botKey].label })
    }
    return $rows
}

function New-PendingTask {
    param(
        [string]$Title,
        [string]$Kind,
        $Seconds,
        [string]$Command,
        [string]$Bot = "",
        [string]$Store = "",
        [string]$FileName = ""
    )
    if ($Kind -ne "echo" -and $Kind -ne "command" -and $Kind -ne "bot") {
        throw "Task kind must be echo, command, or bot."
    }
    $seconds = 20
    if ($null -ne $Seconds -and "$Seconds" -ne "") { $seconds = [int]$Seconds }
    if ($seconds -lt 1) { $seconds = 1 }
    if ($seconds -gt 3600) { $seconds = 3600 }
    if (-not $Title) { $Title = "Test task " + (Get-Date).ToString("HH:mm:ss") }
    $task = @{
        id         = [guid]::NewGuid().ToString("N").Substring(0, 8)
        title      = $Title
        kind       = $Kind
        seconds    = $seconds
        command    = $Command
        bot        = $Bot
        store      = $Store
        fileName   = $FileName
        status     = "pending"
        assignedTo = ""
        message    = "Waiting for a free laptop."
        createdAt  = Get-Stamp
        assignedAt = ""
        finishedAt = ""
    }
    [void]$script:Tasks.Add($task)
    return $task
}

function Assign-NextTask {
    param(
        [string]$Name,
        [string]$Ip
    )
    $display = Resolve-WorkerName $Name
    if (-not $display) { throw "Worker name is missing." }

    foreach ($task in @($script:Tasks)) {
        $status = [string]$task.status
        if ([string]$task.assignedTo -eq $display -and ($status -eq "assigned" -or $status -eq "running")) {
            Touch-Worker -Name $display -Ip $Ip -State "busy" -TaskId ([string]$task.id) | Out-Null
            Save-State
            return $task
        }
    }

    foreach ($task in @($script:Tasks)) {
        if ([string]$task.status -ne "pending") { continue }
        $task.status = "assigned"
        $task.assignedTo = $display
        $task.assignedAt = Get-Stamp
        $task.message = "Assigned to $display."
        Touch-Worker -Name $display -Ip $Ip -State "busy" -TaskId ([string]$task.id) | Out-Null
        Save-State
        Write-Log "Assigned task $($task.id) to $display"
        return $task
    }

    Touch-Worker -Name $display -Ip $Ip -State "free" -TaskId "" | Out-Null
    Save-State
    return $null
}

function Read-RequestBody {
    param($Request)
    $reader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
    try { $text = $reader.ReadToEnd() } finally { $reader.Close() }
    if ([string]::IsNullOrWhiteSpace($text)) { return @{} }
    return Convert-ToHashtable ($script:Serializer.DeserializeObject($text))
}

function Test-RequestToken {
    param($Request)
    $sent = [string]$Request.Headers["X-Network-Token"]
    return $sent -eq $script:Token
}

function Send-Response {
    param($Response, [int]$Status, [string]$ContentType, [string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    $Response.Headers["Cache-Control"] = "no-store"
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Write-Result {
    param($Response, $Result)
    if ($Result.FilePath) {
        $stream = [System.IO.File]::OpenRead([string]$Result.FilePath)
        try {
            $Response.StatusCode = [int]$Result.Status
            $Response.ContentType = [string]$Result.Type
            $Response.Headers["Cache-Control"] = "no-store"
            if ($Result.FileName) {
                $Response.Headers["Content-Disposition"] = 'attachment; filename="' + [string]$Result.FileName + '"'
            }
            $Response.ContentLength64 = $stream.Length
            $stream.CopyTo($Response.OutputStream)
        } finally {
            $stream.Close()
            $Response.OutputStream.Close()
        }
        return
    }
    Send-Response -Response $Response -Status $Result.Status -ContentType $Result.Type -Text $Result.Body
}

function Remove-TaskById {
    param([string]$TaskId)
    $kept = New-Object System.Collections.ArrayList
    foreach ($task in @($script:Tasks)) {
        if ([string]$task.id -eq $TaskId) { continue }
        [void]$kept.Add($task)
    }
    $script:Tasks = $kept
}

function Get-UploadPath {
    param($Task)
    $ext = [System.IO.Path]::GetExtension([string]$Task.fileName).ToLowerInvariant()
    if ($ext -ne ".xlsx" -and $ext -ne ".xls") { $ext = ".xlsx" }
    return Join-Path $script:UploadDir ([string]$Task.id + $ext)
}

function Get-PageHtml {
    $htmlPath = Join-Path $root "dashboard.html"
    $html = [System.IO.File]::ReadAllText($htmlPath, [System.Text.Encoding]::UTF8)
    return $html.Replace("__TOKEN__", $script:Token)
}

function Handle-Request {
    param($Request)
    $path = $Request.Url.AbsolutePath.TrimEnd("/")
    if (-not $path) { $path = "/" }
    $method = $Request.HttpMethod.ToUpperInvariant()

    if ($method -eq "GET" -and $path -eq "/") {
        return @{ Status = 200; Type = "text/html; charset=utf-8"; Body = (Get-PageHtml) }
    }
    if ($method -eq "GET" -and $path -eq "/favicon.ico") {
        return @{ Status = 204; Type = "text/plain"; Body = "" }
    }

    if (-not (Test-RequestToken $Request)) {
        return @{ Status = 401; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $false; message = "Wrong token." }) }
    }

    if ($method -eq "GET" -and $path -eq "/api/status") {
        return @{ Status = 200; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson (Get-StatusObject)) }
    }

    if ($method -eq "POST" -and $path -eq "/api/heartbeat") {
        $body = Read-RequestBody $Request
        $name = Resolve-WorkerName (Get-Field $body "name")
        if (-not $name) {
            return @{ Status = 400; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $false; message = "Worker name is missing." }) }
        }
        $state = [string](Get-Field $body "state")
        if ($state -ne "busy") { $state = "free" }
        $taskId = [string](Get-Field $body "taskId")
        if ($state -eq "free") { $taskId = "" }
        Touch-Worker -Name $name -Ip ([string](Get-Field $body "ip")) -State $state -TaskId $taskId | Out-Null
        if ($state -eq "busy" -and $taskId) {
            $task = Get-TaskById $taskId
            if ($task -and [string]$task.assignedTo -eq $name -and [string]$task.status -eq "assigned") {
                $task.status = "running"
                $task.message = "$name is working on this."
            }
        }
        Save-State
        return @{ Status = 200; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $true }) }
    }

    if ($method -eq "POST" -and $path -eq "/api/next-job") {
        $body = Read-RequestBody $Request
        $task = Assign-NextTask -Name ([string](Get-Field $body "name")) -Ip ([string](Get-Field $body "ip"))
        $copy = $null
        if ($task) { $copy = Copy-Task $task }
        return @{ Status = 200; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $true; task = $copy }) }
    }

    if ($method -eq "POST" -and $path -eq "/api/task-result") {
        $body = Read-RequestBody $Request
        $name = Resolve-WorkerName (Get-Field $body "name")
        $task = Get-TaskById ([string](Get-Field $body "taskId"))
        if (-not $task) {
            return @{ Status = 404; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $false; message = "Task was not found." }) }
        }
        $current = [string]$task.status
        if ($current -eq "done" -or $current -eq "failed") {
            return @{ Status = 200; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $true }) }
        }
        if ([string]$task.assignedTo -and [string]$task.assignedTo -ne $name) {
            return @{ Status = 409; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $false; message = "This task belongs to another laptop." }) }
        }
        $status = [string](Get-Field $body "status")
        if ($status -ne "failed") { $status = "done" }
        $task.status = $status
        $task.message = [string](Get-Field $body "message")
        $task.finishedAt = Get-Stamp
        $worker = Touch-Worker -Name $name -Ip "" -State "free" -TaskId ""
        if ($worker) { $worker.state = "free" }
        Save-State
        Write-Log "Task $($task.id) $status on $name"
        return @{ Status = 200; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $true }) }
    }

    if ($method -eq "GET" -and $path.StartsWith("/api/files/")) {
        $fileId = $path.Substring("/api/files/".Length)
        if ($fileId -notmatch "^[a-f0-9]{8}$") {
            return @{ Status = 404; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $false; message = "File was not found." }) }
        }
        $task = Get-TaskById $fileId
        if (-not $task) {
            return @{ Status = 404; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $false; message = "File was not found." }) }
        }
        $uploadPath = Get-UploadPath $task
        if (-not (Test-Path -LiteralPath $uploadPath)) {
            return @{ Status = 404; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $false; message = "File was not found." }) }
        }
        $downloadName = [System.IO.Path]::GetFileName([string]$task.fileName)
        if (-not $downloadName) { $downloadName = [System.IO.Path]::GetFileName($uploadPath) }
        return @{ Status = 200; Type = "application/octet-stream"; FilePath = $uploadPath; FileName = $downloadName }
    }

    if ($method -eq "POST" -and $path -eq "/api/tasks/upload") {
        $botId = ([string]$Request.Headers["X-Bot"]).Trim()
        $store = ([string]$Request.Headers["X-Store"]).Trim()
        $rawName = [Uri]::UnescapeDataString(([string]$Request.Headers["X-File-Name"]))
        $fileName = [System.IO.Path]::GetFileName($rawName)
        if (-not $script:Bots.ContainsKey($botId)) {
            return @{ Status = 400; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $false; message = "Choose an Etsy or Reverb bot." }) }
        }
        $ext = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()
        if ($ext -ne ".xlsx" -and $ext -ne ".xls") {
            return @{ Status = 400; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $false; message = "Choose an Excel file (.xlsx)." }) }
        }
        if ($store -match '["\r\n]' -or $store.Length -gt 40) {
            return @{ Status = 400; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $false; message = "Store code is not valid." }) }
        }
        $maxBytes = 80MB
        if ($Request.ContentLength64 -gt $maxBytes) {
            return @{ Status = 413; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $false; message = "That Excel file is larger than 80 MB." }) }
        }
        $label = [string]$script:Bots[$botId].label
        $title = $label
        if ($store) { $title = "$label $store" }
        $task = New-PendingTask -Title $title -Kind "bot" -Seconds 20 -Command "" -Bot $botId -Store $store -FileName $fileName
        $uploadPath = Get-UploadPath $task
        $fileStream = [System.IO.File]::Create($uploadPath)
        try {
            $Request.InputStream.CopyTo($fileStream)
        } finally {
            $fileStream.Close()
        }
        $length = (Get-Item -LiteralPath $uploadPath).Length
        if ($length -lt 1 -or $length -gt $maxBytes) {
            Remove-Item -LiteralPath $uploadPath -Force -ErrorAction SilentlyContinue
            Remove-TaskById $task.id
            $reason = "The Excel file was empty."
            if ($length -gt $maxBytes) { $reason = "That Excel file is larger than 80 MB." }
            return @{ Status = 400; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $false; message = $reason }) }
        }
        $task.message = "Waiting for a free laptop. File: $fileName"
        Save-State
        Write-Log "Task $($task.id) is pending ($title)"
        return @{ Status = 200; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $true; task = (Copy-Task $task) }) }
    }

    if ($method -eq "POST" -and $path -eq "/api/tasks") {
        $body = Read-RequestBody $Request
        $count = 1
        $countValue = Get-Field $body "count"
        if ($null -ne $countValue -and "$countValue" -ne "") { $count = [int]$countValue }
        if ($count -lt 1) { $count = 1 }
        if ($count -gt 20) { $count = 20 }
        $kind = [string](Get-Field $body "kind")
        if (-not $kind) { $kind = "echo" }
        $created = New-Object System.Collections.ArrayList
        for ($i = 1; $i -le $count; $i++) {
            $title = [string](Get-Field $body "title")
            if ($count -gt 1) {
                if (-not $title) { $title = "Test task" }
                $title = "$title $i"
            }
            $task = New-PendingTask -Title $title -Kind $kind -Seconds (Get-Field $body "seconds") -Command ([string](Get-Field $body "command"))
            [void]$created.Add((Copy-Task $task))
            Write-Log "Task $($task.id) is pending"
        }
        Save-State
        $first = $created[0]
        return @{ Status = 200; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $true; task = $first; tasks = $created }) }
    }

    if ($method -eq "POST" -and $path -eq "/api/tasks/clear-finished") {
        $kept = New-Object System.Collections.ArrayList
        foreach ($task in @($script:Tasks)) {
            $status = [string]$task.status
            if ($status -eq "done" -or $status -eq "failed") { continue }
            [void]$kept.Add($task)
        }
        $script:Tasks = $kept
        Save-State
        return @{ Status = 200; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $true }) }
    }

    return @{ Status = 404; Type = "application/json; charset=utf-8"; Body = (ConvertTo-ApiJson @{ ok = $false; message = "Not found." }) }
}

function Start-Listener {
    $listener = New-Object System.Net.HttpListener
    try {
        $listener.Prefixes.Add("http://+:$($script:Port)/")
        $listener.Start()
        $script:LanReady = $true
        return $listener
    } catch {
        try { $listener.Close() } catch { }
        $local = New-Object System.Net.HttpListener
        $local.Prefixes.Add("http://127.0.0.1:$($script:Port)/")
        $local.Start()
        $script:LanReady = $false
        return $local
    }
}

if ($env:NETWORK_SELFTEST -eq "1") {
    $script:StatePath = Join-Path $env:TEMP "listing-network-selftest.json"
    if (Test-Path $script:StatePath) { Remove-Item $script:StatePath -Force }
    $script:Workers = @{}
    $script:Tasks = New-Object System.Collections.ArrayList

    $sample = @{
        ok      = $true
        message = 'He said "hello"'
        counts  = @{ free = 1; busy = 2; offline = 0; pending = 1 }
    }
    $parsed = $script:Serializer.DeserializeObject((ConvertTo-ApiJson $sample))
    if ([int]$parsed["counts"]["pending"] -ne 1) { throw "Status JSON did not keep the pending count." }
    if ([string]$parsed["message"] -ne 'He said "hello"') { throw "Status JSON changed the message text." }

    for ($i = 1; $i -le 4; $i++) {
        New-PendingTask -Title "Test task $i" -Kind "echo" -Seconds 2 -Command "" | Out-Null
    }
    $taken = @()
    foreach ($name in @("listing-worker-1", "listing-worker-2", "listing-worker-3")) {
        $task = Assign-NextTask -Name $name -Ip "192.168.1.39"
        if (-not $task) { throw "$name did not receive a task." }
        $taken += [string]$task.id
    }
    $pending = @($script:Tasks | Where-Object { [string]$_.status -eq "pending" })
    if ($pending.Count -ne 1) { throw "Expected 1 pending task, got $($pending.Count)." }
    $same = Assign-NextTask -Name "listing-worker-1" -Ip "192.168.1.39"
    if ([string]$same.id -ne $taken[0]) { throw "A busy laptop was given a second task." }
    $finished = Get-TaskById $taken[0]
    $finished.status = "done"
    $next = Assign-NextTask -Name "listing-worker-1" -Ip "192.168.1.39"
    if (-not $next -or [string]$next.id -eq $taken[0]) { throw "The free laptop did not take the pending task." }
    $pending = @($script:Tasks | Where-Object { [string]$_.status -eq "pending" })
    if ($pending.Count -ne 0) { throw "A task stayed pending after a laptop was free." }
    ConvertTo-ApiJson (Get-StatusObject) | Out-Null

    $listenPort = 8799
    $probe = New-Object System.Net.HttpListener
    $probe.Prefixes.Add("http://127.0.0.1:$listenPort/")
    $probe.Start()
    $oldPort = $script:Port
    $script:Port = $listenPort
    $script:Workers = @{}
    $script:Tasks = New-Object System.Collections.ArrayList
    $script:UploadDir = Join-Path $env:TEMP "listing-network-uploads"
    if (Test-Path $script:UploadDir) { Remove-Item $script:UploadDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $script:UploadDir | Out-Null
    $client = {
        param($Port, $Token)
        $ErrorActionPreference = "Stop"
        Start-Sleep -Milliseconds 300
        $headers = @{ "X-Network-Token" = $Token }
        $base = "http://127.0.0.1:$Port"
        $web = New-Object System.Net.WebClient
        $web.Encoding = [System.Text.Encoding]::UTF8
        try {
            $pageText = $web.DownloadString("$base/")
        } catch {
            throw "The status page did not load: $($_.Exception.Message)"
        }
        if ($pageText -notmatch "Listing laptops") {
            $snippet = $pageText
            if ($snippet.Length -gt 160) { $snippet = $snippet.Substring(0, 160) }
            throw "The status page did not load. Body: $snippet"
        }
        if ($pageText -notmatch "Excel file") { throw "The status page has no Excel upload." }
        function Send-Json($Path, $Body) {
            return Invoke-RestMethod -Method Post -Uri "$base$Path" -Headers $headers -ContentType "application/json; charset=utf-8" -Body ($Body | ConvertTo-Json -Compress) -TimeoutSec 10
        }
        foreach ($name in @("listing-worker-1", "listing-worker-2", "listing-worker-3")) {
            Send-Json "/api/heartbeat" @{ name = $name; ip = "192.168.1.39"; state = "free"; taskId = "" } | Out-Null
        }
        $added = Send-Json "/api/tasks" @{ title = "Test task"; kind = "echo"; seconds = 5; count = 4 }
        if (@($added.tasks).Count -ne 4) { throw "Expected 4 tasks to be added." }
        $ids = @()
        foreach ($name in @("listing-worker-1", "listing-worker-2", "listing-worker-3")) {
            $job = Send-Json "/api/next-job" @{ name = $name; ip = "192.168.1.40" }
            if (-not $job.task.id) { throw "$name got no task over HTTP." }
            $ids += [string]$job.task.id
            Send-Json "/api/heartbeat" @{ name = $name; ip = "192.168.1.40"; state = "busy"; taskId = $job.task.id } | Out-Null
        }
        $status = Invoke-RestMethod -Method Get -Uri "$base/api/status" -Headers $headers -TimeoutSec 10
        if ([int]$status.counts.pending -ne 1) { throw "HTTP status pending was $($status.counts.pending)." }
        if ([int]$status.counts.busy -ne 3) { throw "HTTP status busy was $($status.counts.busy)." }
        Send-Json "/api/task-result" @{ name = "listing-worker-1"; taskId = $ids[0]; status = "done"; message = "Finished the test task." } | Out-Null
        $follow = Send-Json "/api/next-job" @{ name = "listing-worker-1"; ip = "192.168.1.39" }
        if (-not $follow.task.id -or $ids -contains [string]$follow.task.id) { throw "The freed laptop did not take the waiting task." }
        $status = Invoke-RestMethod -Method Get -Uri "$base/api/status" -Headers $headers -TimeoutSec 10
        if ([int]$status.counts.pending -ne 0) { throw "A task was still pending after a laptop became free." }
        $payload = [System.Text.Encoding]::UTF8.GetBytes("excel-test")
        $req = [System.Net.HttpWebRequest]::Create("$base/api/tasks/upload")
        $req.Method = "POST"
        $req.ContentType = "application/octet-stream"
        $req.Headers.Add("X-Network-Token", $Token)
        $req.Headers.Add("X-Bot", "etsy-create")
        $req.Headers.Add("X-Store", "GG")
        $req.Headers.Add("X-File-Name", [Uri]::EscapeDataString("create.xlsx"))
        $req.ContentLength = $payload.Length
        $outStream = $req.GetRequestStream()
        $outStream.Write($payload, 0, $payload.Length)
        $outStream.Close()
        $answer = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($answer.GetResponseStream())
        $uploaded = $reader.ReadToEnd()
        $reader.Close()
        $answer.Close()
        if ($uploaded -notmatch '"kind":"bot"' -or $uploaded -notmatch '"status":"pending"') {
            throw "Upload did not create a pending bot task. $uploaded"
        }
        $idMatch = [regex]::Match($uploaded, '"id":"([a-f0-9]{8})"')
        if (-not $idMatch.Success) { throw "Upload did not return a task id." }
        $fileClient = New-Object System.Net.WebClient
        $fileClient.Headers.Add("X-Network-Token", $Token)
        $got = $fileClient.DownloadData("$base/api/files/$($idMatch.Groups[1].Value)")
        $gotText = [System.Text.Encoding]::UTF8.GetString($got)
        if ($gotText -ne "excel-test") { throw "Downloaded file did not match the upload." }
    }
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript($client).AddArgument($listenPort).AddArgument($script:Token)
    $handle = $shell.BeginInvoke()
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    $pending = $probe.BeginGetContext($null, $null)
    while (-not $handle.IsCompleted -and [DateTime]::UtcNow -lt $deadline) {
        if (-not $pending.AsyncWaitHandle.WaitOne(300)) { continue }
        $context = $probe.EndGetContext($pending)
        $pending = $probe.BeginGetContext($null, $null)
        try {
            $result = Handle-Request $context.Request
            Write-Result -Response $context.Response -Result $result
        } catch {
            try {
                Send-Response -Response $context.Response -Status 500 -ContentType "application/json; charset=utf-8" -Text (ConvertTo-ApiJson @{ ok = $false; message = $_.Exception.Message })
            } catch { }
        }
    }
    $probe.Stop()
    $probe.Close()
    $script:Port = $oldPort
    if (-not $handle.IsCompleted) { throw "The HTTP check did not finish." }
    $shell.EndInvoke($handle) | Out-Null
    $clientErrors = @($shell.Streams.Error | ForEach-Object { $_.ToString() })
    $shell.Dispose()
    $runspace.Close()
    if ($clientErrors.Count -gt 0) { throw ($clientErrors -join " ") }
    if (Test-Path (Join-Path $env:TEMP "listing-network-uploads")) { Remove-Item (Join-Path $env:TEMP "listing-network-uploads") -Recurse -Force }
    if (Test-Path $script:StatePath) { Remove-Item $script:StatePath -Force }
    Write-Output "TEST_OK"
    exit 0
}

Add-Type -Namespace ListingNetwork -Name Power -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
"@
[void][ListingNetwork.Power]::SetThreadExecutionState([uint32]"0x80000001")

Restore-State
$listener = Start-Listener

Write-Host ""
Write-Host "Listing network master"
Write-Host "This PC: $env:COMPUTERNAME"
try {
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "127.*" })
    foreach ($address in $addresses) {
        Write-Host "Address: $($address.IPAddress)"
    }
    $matched = $false
    foreach ($address in $addresses) {
        if ($address.IPAddress -eq $script:MasterIp) { $matched = $true }
    }
    if (-not $matched) {
        Write-Host "config.json says the master is $($script:MasterIp), and this PC does not have that address."
        Write-Host "Put this PC's 192.168.1 address in config.json on every laptop, then start again."
    }
} catch {
}

if ($script:LanReady) {
    Write-Host "Workers use:  http://$($script:MasterIp):$($script:Port)"
    Write-Host "Open on this PC: http://localhost:$($script:Port)"
} else {
    Write-Host "The workers cannot connect yet."
    Write-Host "Right-click Setup-Master.bat, choose Run as administrator, then start this again."
    Write-Host "You can still open http://localhost:$($script:Port) on this PC."
}
Write-Host "Leave this window open."
Write-Host ""

$async = $listener.BeginGetContext($null, $null)
try {
    while ($listener.IsListening) {
        $signaled = $async.AsyncWaitHandle.WaitOne(2000)
        Update-Presence
        if (-not $signaled) { continue }
        $context = $null
        try {
            $context = $listener.EndGetContext($async)
        } catch {
            if (-not $listener.IsListening) { break }
        }
        $async = $listener.BeginGetContext($null, $null)
        if (-not $context) { continue }
        try {
            $result = Handle-Request $context.Request
            Write-Result -Response $context.Response -Result $result
        } catch {
            Write-Log $_.Exception.Message
            try {
                $errorBody = ConvertTo-ApiJson @{ ok = $false; message = $_.Exception.Message }
                Send-Response -Response $context.Response -Status 500 -ContentType "application/json; charset=utf-8" -Text $errorBody
            } catch { }
        }
    }
} finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
}
