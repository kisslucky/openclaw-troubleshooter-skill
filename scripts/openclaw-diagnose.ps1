param(
  [int]$Port = 18789,
  [int]$TailLines = 120,
  [string]$TracePath,
  [switch]$AsJson
)

$ErrorActionPreference = "Stop"

$OpenClawHome = Join-Path $env:USERPROFILE ".openclaw"
$GatewayLauncherPath = Join-Path $OpenClawHome "gateway.cmd"
$OpenClawConfigPath = Join-Path $OpenClawHome "openclaw.json"
$AgentModelsPath = Join-Path $OpenClawHome "agents\main\agent\models.json"
$LogDir = Join-Path $env:LOCALAPPDATA "Temp\openclaw"
$TaskName = "OpenClaw Gateway"
$ProxyRegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$SchTasksExe = Join-Path $env:SystemRoot "System32\schtasks.exe"
$NetshExe = Join-Path $env:SystemRoot "System32\netsh.exe"
$TaskKillExe = Join-Path $env:SystemRoot "System32\taskkill.exe"
$CommandOutputLimit = 4000
$LogTailLimit = 60
$AlertLimit = 12

function Write-TraceLine {
  param([string]$Message)

  if ([string]::IsNullOrWhiteSpace($TracePath)) {
    return
  }

  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
  Add-Content -Path $TracePath -Value $line
}

function Limit-Text {
  param(
    [string]$Value,
    [int]$MaxLength = 4000
  )

  if ([string]::IsNullOrEmpty($Value)) {
    return $Value
  }

  if ($Value.Length -le $MaxLength) {
    return $Value
  }

  return $Value.Substring(0, $MaxLength) + "... [truncated]"
}

function ConvertTo-PlainData {
  param($Value)

  if ($null -eq $Value) {
    return $null
  }

  if ($Value -is [string] -or $Value -is [ValueType]) {
    return $Value
  }

  if ($Value -is [System.Collections.IDictionary]) {
    $result = @{}
    foreach ($key in $Value.Keys) {
      $result[$key] = ConvertTo-PlainData -Value $Value[$key]
    }
    return $result
  }

  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $items = @()
    foreach ($item in $Value) {
      $items += ,(ConvertTo-PlainData -Value $item)
    }
    return $items
  }

  if ($Value.PSObject -and $Value.PSObject.Properties.Count -gt 0) {
    $result = @{}
    foreach ($property in $Value.PSObject.Properties) {
      if ($property.MemberType -notin @("AliasProperty", "CodeProperty", "NoteProperty", "Property", "ScriptProperty")) {
        continue
      }
      $result[$property.Name] = ConvertTo-PlainData -Value $property.Value
    }
    return $result
  }

  return [string]$Value
}

function Get-ValueOrDefault {
  param(
    $Value,
    $Default
  )

  if ($null -eq $Value) {
    return $Default
  }

  return $Value
}

function Get-JsonObject {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Invoke-CapturedProcess {
  param(
    [string]$FilePath,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 8
  )

  $command = Get-Command $FilePath -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    return [pscustomobject]@{
      available = $false
      file = $FilePath
      exit_code = $null
      stdout = ""
      stderr = "Command not found."
    }
  }

  $cmdExe = Join-Path $env:SystemRoot "System32\cmd.exe"
  $escapedCommand = '"' + $command.Source.Replace('"', '""') + '"'
  foreach ($argument in $Arguments) {
    $value = [string]$argument
    if ($value -match '[\s"]') {
      $escapedCommand += ' "' + $value.Replace('"', '\"') + '"'
    } else {
      $escapedCommand += ' ' + $value
    }
  }

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $cmdExe
  $startInfo.Arguments = "/d /c $escapedCommand"
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  [void]$process.Start()

  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    try {
      & $TaskKillExe /PID $process.Id /T /F | Out-Null
    } catch {
      try {
        $process.Kill()
      } catch {
      }
    }

    return [pscustomobject]@{
      available = $true
      file = $command.Source
      exit_code = $null
      stdout = ""
      stderr = "Process timed out after $TimeoutSeconds seconds."
    }
  }

  return [pscustomobject]@{
    available = $true
    file = $command.Source
    exit_code = $process.ExitCode
    stdout = Limit-Text -Value ($process.StandardOutput.ReadToEnd().Trim()) -MaxLength $CommandOutputLimit
    stderr = Limit-Text -Value ($process.StandardError.ReadToEnd().Trim()) -MaxLength $CommandOutputLimit
  }
}

function Test-TcpEndpoint {
  param(
    [string]$HostName,
    [int]$Port,
    [int]$TimeoutMs = 2500
  )

  if ([string]::IsNullOrWhiteSpace($HostName)) {
    return $false
  }

  try {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
      $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
      if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
        return $false
      }

      $client.EndConnect($asyncResult)
      return $true
    } finally {
      $client.Dispose()
    }
  } catch {
    return $false
  }
}

function Normalize-ProxyUrl {
  param(
    [string]$Value,
    [string]$Kind = "http"
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }

  $trimmed = $Value.Trim()
  if ($trimmed -match "^[a-zA-Z][a-zA-Z0-9+.-]*://") {
    return $trimmed
  }

  if ($Kind -eq "socks") {
    return "socks5://$trimmed"
  }

  return "http://$trimmed"
}

function Test-ProxyEndpoint {
  param([string]$ProxyUrl)

  if ([string]::IsNullOrWhiteSpace($ProxyUrl)) {
    return $false
  }

  try {
    $uri = [Uri]$ProxyUrl
    return Test-TcpEndpoint -HostName $uri.Host -Port $uri.Port -TimeoutMs 1500
  } catch {
    return $false
  }
}

function Get-NoProxyValue {
  param([string]$ProxyOverride)

  $entries = @("127.0.0.1", "localhost")

  if (-not [string]::IsNullOrWhiteSpace($ProxyOverride)) {
    foreach ($rawEntry in ($ProxyOverride -split ";")) {
      $entry = $rawEntry.Trim()
      if (-not $entry) {
        continue
      }

      if ($entry -eq "<local>") {
        $entries += "*.local"
        continue
      }

      $entries += $entry
    }
  }

  return (($entries | Where-Object { $_ } | Select-Object -Unique) -join ",")
}

function Get-InternetProxyState {
  $settings = Get-ItemProperty -Path $ProxyRegistryPath
  $proxyEnable = [int](Get-ValueOrDefault -Value $settings.ProxyEnable -Default 0)
  $proxyServer = [string](Get-ValueOrDefault -Value $settings.ProxyServer -Default "")
  $proxyOverride = [string](Get-ValueOrDefault -Value $settings.ProxyOverride -Default "")
  $autoConfigUrl = [string](Get-ValueOrDefault -Value $settings.AutoConfigURL -Default "")

  $resolved = [ordered]@{
    HTTP_PROXY = $null
    HTTPS_PROXY = $null
    ALL_PROXY = $null
    NO_PROXY = Get-NoProxyValue -ProxyOverride $proxyOverride
  }

  if ($proxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace($proxyServer)) {
    $proxyMap = @{}
    foreach ($segment in ($proxyServer -split ";")) {
      $part = $segment.Trim()
      if (-not $part) {
        continue
      }

      if ($part -match "^\s*([^=]+)=(.+?)\s*$") {
        $proxyMap[$matches[1].Trim().ToLowerInvariant()] = $matches[2].Trim()
      } else {
        $proxyMap["default"] = $part
      }
    }

    $httpRaw = Get-ValueOrDefault -Value $proxyMap["http"] -Default (Get-ValueOrDefault -Value $proxyMap["https"] -Default (Get-ValueOrDefault -Value $proxyMap["default"] -Default $null))
    $httpsRaw = Get-ValueOrDefault -Value $proxyMap["https"] -Default (Get-ValueOrDefault -Value $proxyMap["http"] -Default (Get-ValueOrDefault -Value $proxyMap["default"] -Default $null))
    $allRaw = Get-ValueOrDefault -Value $proxyMap["all"] -Default (Get-ValueOrDefault -Value $proxyMap["socks"] -Default (Get-ValueOrDefault -Value $proxyMap["default"] -Default $null))

    $resolved.HTTP_PROXY = Normalize-ProxyUrl -Value $httpRaw -Kind "http"
    $resolved.HTTPS_PROXY = Normalize-ProxyUrl -Value $httpsRaw -Kind "http"
    $resolved.ALL_PROXY = Normalize-ProxyUrl -Value $allRaw -Kind $(if ($proxyMap.ContainsKey("socks")) { "socks" } else { "http" })
  }

  $summary =
    if ($resolved.HTTP_PROXY -or $resolved.HTTPS_PROXY -or $resolved.ALL_PROXY) {
      "proxy active"
    } elseif ($proxyEnable -eq 1 -and $proxyServer) {
      "proxy configured but unavailable"
    } elseif ($autoConfigUrl) {
      "auto-config url present; direct currently assumed"
    } else {
      "direct"
    }

  return [pscustomobject]@{
    summary = $summary
    proxy_enable = $proxyEnable
    proxy_server = $proxyServer
    proxy_override = $proxyOverride
    auto_config_url = $autoConfigUrl
    environment = $resolved
  }
}

function Test-HttpsEndpoint {
  param(
    [string]$Url,
    [string]$ProxyUrl = $null,
    [int]$TimeoutSeconds = 5
  )

  if (-not ("System.Net.Http.HttpClientHandler" -as [type])) {
    try {
      Add-Type -AssemblyName System.Net.Http -ErrorAction Stop | Out-Null
    } catch {
      return [pscustomobject]@{
        success = $false
        status_code = $null
        error = "System.Net.Http is unavailable on this PowerShell runtime."
      }
    }
  }

  $handler = [System.Net.Http.HttpClientHandler]::new()
  $disposeHandler = $true

  try {
    if (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
      $proxyUri = [Uri]$ProxyUrl
      if ($proxyUri.Scheme -notin @("http", "https")) {
        return [pscustomobject]@{
          success = $false
          status_code = $null
          error = "Proxy scheme '$($proxyUri.Scheme)' is not probed by this checker."
        }
      }

      $handler.UseProxy = $true
      $handler.Proxy = [System.Net.WebProxy]::new($ProxyUrl)
    }

    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $disposeHandler = $false

    try {
      $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $Url)
      $response = $client.SendAsync($request).GetAwaiter().GetResult()
      return [pscustomobject]@{
        success = $true
        status_code = [int]$response.StatusCode
        error = $null
      }
    } finally {
      $client.Dispose()
      if ($disposeHandler) {
        $handler.Dispose()
      }
    }
  } catch {
    if ($disposeHandler) {
      $handler.Dispose()
    }

    return [pscustomobject]@{
      success = $false
      status_code = $null
      error = $_.Exception.Message
    }
  }
}

function Resolve-ProviderBaseUrl {
  param(
    [string]$Provider,
    [hashtable]$ProviderBaseUrlMap
  )

  if ($ProviderBaseUrlMap.ContainsKey($Provider)) {
    return $ProviderBaseUrlMap[$Provider]
  }

  switch ($Provider) {
    "openai-codex" { return "https://chatgpt.com/backend-api/v1" }
    "codex" { return "https://chatgpt.com/backend-api/v1" }
    "openai" { return "https://api.openai.com/v1/models" }
    "gemini" { return "https://generativelanguage.googleapis.com/v1beta/openai/v1/models" }
    "bailian" { return "https://coding.dashscope.aliyuncs.com/v1/models" }
    "moonshot" { return "https://api.deepseek.com/v1/models" }
    default { return $null }
  }
}

function Get-ProviderBaseUrlMap {
  $providerMap = @{}

  foreach ($path in @($OpenClawConfigPath, $AgentModelsPath)) {
    $json = Get-JsonObject -Path $path
    if ($null -eq $json -or $null -eq $json.providers) {
      continue
    }

    foreach ($property in $json.providers.PSObject.Properties) {
      if ($null -eq $property.Value) {
        continue
      }

      if (-not $providerMap.ContainsKey($property.Name) -and $property.Value.baseUrl) {
        $providerMap[$property.Name] = [string]$property.Value.baseUrl
      }
    }
  }

  return $providerMap
}

function Get-TaskInfo {
  try {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $action = $task.Actions | Select-Object -First 1
    return [pscustomobject]@{
      exists = $true
      state = [string]$task.State
      action = if ($null -ne $action) {
        if ($action.Arguments) {
          "$($action.Execute) $($action.Arguments)"
        } else {
          [string]$action.Execute
        }
      } else {
        $null
      }
      execute = if ($null -ne $action) { [string]$action.Execute } else { $null }
      arguments = if ($null -ne $action) { [string]$action.Arguments } else { $null }
    }
  } catch {
    $raw = Invoke-CapturedProcess -FilePath $SchTasksExe -Arguments @("/Query", "/TN", $TaskName, "/V", "/FO", "LIST")
    if ($raw.exit_code -ne 0) {
      return [pscustomobject]@{
        exists = $false
        state = $null
        action = $null
        execute = $null
        arguments = $null
      }
    }

    return [pscustomobject]@{
      exists = $true
      state = $null
      action = $raw.stdout
      execute = $null
      arguments = $null
    }
  }
}

function Get-ListenerInfo {
  param([int]$LocalPort)

  try {
    $connection = Get-NetTCPConnection -State Listen -LocalPort $LocalPort -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $connection) {
      throw "No listening socket found."
    }

    $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
    return [pscustomobject]@{
      listening = $true
      local_port = $LocalPort
      process_id = $connection.OwningProcess
      process_name = if ($null -ne $process) { $process.ProcessName } else { $null }
    }
  } catch {
    return [pscustomobject]@{
      listening = $false
      local_port = $LocalPort
      process_id = $null
      process_name = $null
    }
  }
}

function Get-CurrentLogPath {
  if (-not (Test-Path -LiteralPath $LogDir)) {
    return $null
  }

  $todayPath = Join-Path $LogDir ("openclaw-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
  if (Test-Path -LiteralPath $todayPath) {
    return $todayPath
  }

  $latest = Get-ChildItem -LiteralPath $LogDir -Filter "openclaw-*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($null -ne $latest) {
    return $latest.FullName
  }

  return $null
}

function Get-LogSummary {
  param(
    [string]$Path,
    [int]$LineCount
  )

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{
      path = $Path
      tail = @()
      alerts = @()
    }
  }

  $tail = @(Get-Content -LiteralPath $Path -Tail $LineCount -ErrorAction SilentlyContinue)
  $alerts = @($tail | Where-Object {
      $_ -match "429" -or
      $_ -match "quota" -or
      $_ -match "timeout" -or
      $_ -match "network connection error" -or
      $_ -match "ECONN" -or
      $_ -match "ETIMEDOUT" -or
      $_ -match "\berror\b"
    })

  return [pscustomobject]@{
    path = $Path
    tail = @($tail | Select-Object -Last $LogTailLimit)
    alerts = @($alerts | Select-Object -Last $AlertLimit)
  }
}

function Add-Finding {
  param(
    [System.Collections.Generic.List[object]]$Collection,
    [string]$Id,
    [string]$Severity,
    [string]$Message,
    [string[]]$SuggestedActions = @()
  )

  $Collection.Add([pscustomobject]@{
      id = $Id
      severity = $Severity
      message = $Message
      suggested_actions = @($SuggestedActions)
    }) | Out-Null
}

function Add-Repair {
  param(
    [System.Collections.Generic.List[object]]$Collection,
    [string]$Id,
    [string]$Description,
    [bool]$SafeToAutoApply,
    [string]$SuggestedCommand
  )

  $Collection.Add([pscustomobject]@{
      id = $Id
      description = $Description
      safe_to_auto_apply = $SafeToAutoApply
      suggested_command = $SuggestedCommand
    }) | Out-Null
}

function Convert-CommandSnapshot {
  param($Value)

  if ($null -eq $Value) {
    return $null
  }

  return @{
    available = [bool](Get-ValueOrDefault -Value $Value.available -Default $false)
    file = [string](Get-ValueOrDefault -Value $Value.file -Default "")
    exit_code = $Value.exit_code
    stdout = [string](Get-ValueOrDefault -Value $Value.stdout -Default "")
    stderr = [string](Get-ValueOrDefault -Value $Value.stderr -Default "")
  }
}

function Convert-LogSnapshot {
  param($Value)

  if ($null -eq $Value) {
    return $null
  }

  return @{
    path = [string](Get-ValueOrDefault -Value $Value.path -Default "")
    tail = @($Value.tail | ForEach-Object { [string]$_ })
    alerts = @($Value.alerts | ForEach-Object { [string]$_ })
  }
}

$paths = [ordered]@{
  gateway_launcher = [pscustomobject]@{
    path = $GatewayLauncherPath
    exists = Test-Path -LiteralPath $GatewayLauncherPath
  }
  openclaw_config = [pscustomobject]@{
    path = $OpenClawConfigPath
    exists = Test-Path -LiteralPath $OpenClawConfigPath
  }
  agent_models = [pscustomobject]@{
    path = $AgentModelsPath
    exists = Test-Path -LiteralPath $AgentModelsPath
  }
  log_dir = [pscustomobject]@{
    path = $LogDir
    exists = Test-Path -LiteralPath $LogDir
  }
}

Write-TraceLine -Message "Resolving OpenClaw CLI commands."
$openclawCommand = Get-Command openclaw -ErrorAction SilentlyContinue
Write-TraceLine -Message "Running CLI status probes."
$gatewayStatus = if ($null -ne $openclawCommand) { Invoke-CapturedProcess -FilePath "openclaw" -Arguments @("gateway", "status") } else { $null }
$gatewayHealth = if ($null -ne $openclawCommand) { Invoke-CapturedProcess -FilePath "openclaw" -Arguments @("gateway", "health") } else { $null }
$deepStatus = if ($null -ne $openclawCommand) { Invoke-CapturedProcess -FilePath "openclaw" -Arguments @("status", "--deep") } else { $null }

Write-TraceLine -Message "Collecting task, listener, proxy, config, and log state."
$taskInfo = Get-TaskInfo
Write-TraceLine -Message "Collected scheduled task info."
$listenerInfo = Get-ListenerInfo -LocalPort $Port
Write-TraceLine -Message "Collected listener info."
$proxyState = Get-InternetProxyState
Write-TraceLine -Message "Collected user proxy settings."
$winHttpProxy = Invoke-CapturedProcess -FilePath $NetshExe -Arguments @("winhttp", "show", "proxy")
Write-TraceLine -Message "Collected WinHTTP proxy state."
$currentConfig = Get-JsonObject -Path $OpenClawConfigPath
Write-TraceLine -Message "Loaded OpenClaw config."
$currentModels = if ($null -ne $currentConfig) { $currentConfig.agents.defaults.model } else { $null }
$providerBaseUrlMap = Get-ProviderBaseUrlMap
Write-TraceLine -Message "Resolved provider base URLs."
$logPath = Get-CurrentLogPath
$openclawLog = Get-LogSummary -Path $logPath -LineCount $TailLines
Write-TraceLine -Message "Collected OpenClaw log summary."
$supervisorLog = Get-LogSummary -Path (Join-Path $LogDir "gateway-supervisor.log") -LineCount $TailLines
Write-TraceLine -Message "Collected supervisor log summary."
$proxyProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match "flclash|clash|mihomo|v2ray|sing-box|nekobox"
  } | Select-Object ProcessName, Id)
Write-TraceLine -Message "Collected local proxy process list."

$findings = [System.Collections.Generic.List[object]]::new()
$recommendedRepairs = [System.Collections.Generic.List[object]]::new()

if (-not $paths.gateway_launcher.exists) {
  Add-Finding -Collection $findings -Id "gateway.launcher.missing" -Severity "error" -Message "The local gateway launcher is missing." -SuggestedActions @("reinstall_openclaw")
}

if (-not $listenerInfo.listening) {
  Add-Finding -Collection $findings -Id "gateway.listener.missing" -Severity "error" -Message "The configured gateway port is not listening." -SuggestedActions @("restart_gateway", "restart_gateway_task")
  Add-Repair -Collection $recommendedRepairs -Id "restart_gateway" -Description "Restart the OpenClaw gateway." -SafeToAutoApply $true -SuggestedCommand "powershell -ExecutionPolicy Bypass -File .\scripts\openclaw-repair.ps1 -RepairAllSafe -AsJson"
}

if ($taskInfo.exists -and $taskInfo.action -match "openclaw-gateway-supervisor\.cmd") {
  Add-Finding -Collection $findings -Id "gateway.supervisor.installed" -Severity "info" -Message "The OpenClaw Gateway task already points at a supervisor-managed launcher." -SuggestedActions @("test_supervisor", "update_supervisor")
}

if ($openclawLog.alerts -match "429" -or $openclawLog.alerts -match "quota") {
  Add-Finding -Collection $findings -Id "provider.quota.exhausted" -Severity "warn" -Message "Recent OpenClaw logs contain quota-related provider errors." -SuggestedActions @("switch_model", "restore_provider_quota")
}

$knownModels = @()
$primaryModel = $null
$fallbackModels = @()

if ($null -ne $currentModels) {
  $primaryModel = [string]$currentModels.primary
  if ($null -ne $currentModels.fallbacks) {
    $fallbackModels = @($currentModels.fallbacks)
  }

  $knownModels += $primaryModel
  $knownModels += $fallbackModels
}

$routeChecks = @()
$primaryProviderRequiresProxy = $false
$workingProxyUrl = [string](Get-ValueOrDefault -Value $proxyState.environment.HTTPS_PROXY -Default $proxyState.environment.HTTP_PROXY)
$workingProxyAvailable = Test-ProxyEndpoint -ProxyUrl $workingProxyUrl

foreach ($modelId in @($knownModels | Where-Object { $_ } | Select-Object -Unique)) {
  Write-TraceLine -Message ("Checking model route reachability for {0}" -f $modelId)
  $provider = ($modelId -split "/", 2)[0]
  $probeUrl = Resolve-ProviderBaseUrl -Provider $provider -ProviderBaseUrlMap $providerBaseUrlMap

  if ([string]::IsNullOrWhiteSpace($probeUrl)) {
    continue
  }

  $uri = [Uri]$probeUrl
  $directTcp = Test-TcpEndpoint -HostName $uri.Host -Port $(if ($uri.Port -gt 0) { $uri.Port } else { 443 })
  $proxyHttp = if ($workingProxyAvailable) { Test-HttpsEndpoint -Url $probeUrl -ProxyUrl $workingProxyUrl } else { [pscustomobject]@{ success = $false; status_code = $null; error = "No working HTTP proxy endpoint detected." } }

  $check = [pscustomobject]@{
    model = $modelId
    provider = $provider
    probe_url = $probeUrl
    direct_tcp = $directTcp
    proxy_http = $proxyHttp
  }

  $routeChecks += $check

  if ($provider -in @("openai-codex", "codex", "openai") -and -not $directTcp -and $workingProxyAvailable -and $proxyHttp.success) {
    $primaryProviderRequiresProxy = $true
  }
}

if ($primaryProviderRequiresProxy -and -not ($taskInfo.action -match "openclaw-gateway-supervisor\.cmd")) {
  Add-Finding -Collection $findings -Id "network.openai.proxy_required" -Severity "error" -Message "The current OpenAI or Codex route appears to require the local proxy, but the gateway task is not supervisor-managed." -SuggestedActions @("install_supervisor")
  Add-Repair -Collection $recommendedRepairs -Id "install_supervisor" -Description "Install or update the route-aware gateway supervisor." -SafeToAutoApply $false -SuggestedCommand "Invoke the sibling openclaw-supervisor-installer skill."
}

$openAiRouteProblem = @($routeChecks | Where-Object { $_.provider -in @("openai-codex", "codex", "openai") })
if ($openAiRouteProblem.Count -gt 0 -and -not ($openAiRouteProblem | Where-Object { $_.direct_tcp -or $_.proxy_http.success })) {
  Add-Finding -Collection $findings -Id "network.openai.unreachable" -Severity "error" -Message "OpenAI or Codex endpoints are unreachable on both direct and detected proxy routes." -SuggestedActions @("verify_network", "switch_model")
}

if ($supervisorLog.alerts -match "Route change prompt failed") {
  Add-Finding -Collection $findings -Id "gateway.supervisor.prompt_failed" -Severity "warn" -Message "The installed supervisor logged a route change prompt failure." -SuggestedActions @("test_supervisor", "review_gui_session")
}

Write-TraceLine -Message "Building diagnosis object."
$diagnosis = [pscustomobject]@{
  timestamp = (Get-Date).ToString("s")
  computer_name = $env:COMPUTERNAME
  openclaw_home = $OpenClawHome
  paths = $paths
  cli = [pscustomobject]@{
    available = $null -ne $openclawCommand
    path = if ($null -ne $openclawCommand) { $openclawCommand.Source } else { $null }
    gateway_status = $gatewayStatus
    gateway_health = $gatewayHealth
    status_deep = $deepStatus
  }
  gateway = [pscustomobject]@{
    task = $taskInfo
    listener = $listenerInfo
    supervisor = [pscustomobject]@{
      installed = $taskInfo.action -match "openclaw-gateway-supervisor\.cmd"
    }
  }
  proxy = [pscustomobject]@{
    internet_settings = $proxyState
    winhttp = $winHttpProxy
    local_proxy_processes = $proxyProcesses
  }
  models = [pscustomobject]@{
    primary = $primaryModel
    fallbacks = @($fallbackModels)
    route_checks = $routeChecks
  }
  providers = $providerBaseUrlMap
  logs = [pscustomobject]@{
    openclaw = $openclawLog
    supervisor = $supervisorLog
  }
  findings = @($findings)
  recommended_repairs = @($recommendedRepairs)
}

Write-TraceLine -Message "Diagnosis complete."
if ($AsJson) {
  Add-Type -AssemblyName System.Web.Extensions
  $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $serializer.MaxJsonLength = 67108864
  $jsonReady = @{
    timestamp = (Get-Date).ToString("s")
    computer_name = [string]$env:COMPUTERNAME
    openclaw_home = [string]$OpenClawHome
    paths = @{
      gateway_launcher = @{
        path = [string]$paths.gateway_launcher.path
        exists = [bool]$paths.gateway_launcher.exists
      }
      openclaw_config = @{
        path = [string]$paths.openclaw_config.path
        exists = [bool]$paths.openclaw_config.exists
      }
      agent_models = @{
        path = [string]$paths.agent_models.path
        exists = [bool]$paths.agent_models.exists
      }
      log_dir = @{
        path = [string]$paths.log_dir.path
        exists = [bool]$paths.log_dir.exists
      }
    }
    cli = @{
      available = [bool]($null -ne $openclawCommand)
      path = if ($null -ne $openclawCommand) { [string]$openclawCommand.Source } else { $null }
      gateway_status = Convert-CommandSnapshot -Value $gatewayStatus
      gateway_health = Convert-CommandSnapshot -Value $gatewayHealth
      status_deep = Convert-CommandSnapshot -Value $deepStatus
    }
    gateway = @{
      task = @{
        exists = [bool]$taskInfo.exists
        state = if ($null -ne $taskInfo.state) { [string]$taskInfo.state } else { $null }
        action = if ($null -ne $taskInfo.action) { [string]$taskInfo.action } else { $null }
        execute = if ($null -ne $taskInfo.execute) { [string]$taskInfo.execute } else { $null }
        arguments = if ($null -ne $taskInfo.arguments) { [string]$taskInfo.arguments } else { $null }
      }
      listener = @{
        listening = [bool]$listenerInfo.listening
        local_port = [int]$listenerInfo.local_port
        process_id = $listenerInfo.process_id
        process_name = if ($null -ne $listenerInfo.process_name) { [string]$listenerInfo.process_name } else { $null }
      }
      supervisor = @{
        installed = [bool]($taskInfo.action -match "openclaw-gateway-supervisor\.cmd")
      }
    }
    proxy = @{
      internet_settings = @{
        summary = [string]$proxyState.summary
        proxy_enable = [int]$proxyState.proxy_enable
        proxy_server = [string]$proxyState.proxy_server
        proxy_override = [string]$proxyState.proxy_override
        auto_config_url = [string]$proxyState.auto_config_url
        environment = @{
          HTTP_PROXY = if ($proxyState.environment.HTTP_PROXY) { [string]$proxyState.environment.HTTP_PROXY } else { $null }
          HTTPS_PROXY = if ($proxyState.environment.HTTPS_PROXY) { [string]$proxyState.environment.HTTPS_PROXY } else { $null }
          ALL_PROXY = if ($proxyState.environment.ALL_PROXY) { [string]$proxyState.environment.ALL_PROXY } else { $null }
          NO_PROXY = if ($proxyState.environment.NO_PROXY) { [string]$proxyState.environment.NO_PROXY } else { $null }
        }
      }
      winhttp = Convert-CommandSnapshot -Value $winHttpProxy
      local_proxy_processes = @($proxyProcesses | ForEach-Object {
          @{
            process_name = [string]$_.ProcessName
            id = [int]$_.Id
          }
        })
    }
    models = @{
      primary = if ($primaryModel) { [string]$primaryModel } else { $null }
      fallbacks = @($fallbackModels | ForEach-Object { [string]$_ })
      route_checks = @($routeChecks | ForEach-Object {
          @{
            model = [string]$_.model
            provider = [string]$_.provider
            probe_url = [string]$_.probe_url
            direct_tcp = [bool]$_.direct_tcp
            proxy_http = @{
              success = [bool]$_.proxy_http.success
              status_code = $_.proxy_http.status_code
              error = if ($_.proxy_http.error) { [string]$_.proxy_http.error } else { $null }
            }
          }
        })
    }
    providers = @{}
    logs = @{
      openclaw = Convert-LogSnapshot -Value $openclawLog
      supervisor = Convert-LogSnapshot -Value $supervisorLog
    }
    findings = @($findings | ForEach-Object {
        @{
          id = [string]$_.id
          severity = [string]$_.severity
          message = [string]$_.message
          suggested_actions = @($_.suggested_actions | ForEach-Object { [string]$_ })
        }
      })
    recommended_repairs = @($recommendedRepairs | ForEach-Object {
        @{
          id = [string]$_.id
          description = [string]$_.description
          safe_to_auto_apply = [bool]$_.safe_to_auto_apply
          suggested_command = [string]$_.suggested_command
        }
      })
  }

  foreach ($providerName in $providerBaseUrlMap.Keys) {
    $jsonReady.providers[$providerName] = [string]$providerBaseUrlMap[$providerName]
  }

  $serializer.Serialize($jsonReady)
} else {
  $diagnosis
}
