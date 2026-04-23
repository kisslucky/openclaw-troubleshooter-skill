param(
  [int]$Port = 18789,
  [switch]$RepairAllSafe,
  [switch]$RestartGateway,
  [switch]$StartGatewayTask,
  [switch]$InstallSupervisor,
  [string]$SupervisorSkillPath,
  [switch]$AsJson
)

$ErrorActionPreference = "Stop"

$TaskName = "OpenClaw Gateway"
$GatewayLauncherPath = Join-Path $env:USERPROFILE ".openclaw\gateway.cmd"
$SchTasksExe = Join-Path $env:SystemRoot "System32\schtasks.exe"
$TaskKillExe = Join-Path $env:SystemRoot "System32\taskkill.exe"
$DiagnosisScript = Join-Path $PSScriptRoot "openclaw-diagnose.ps1"

function Invoke-CapturedProcess {
  param(
    [string]$FilePath,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 15
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
    stdout = $process.StandardOutput.ReadToEnd().Trim()
    stderr = $process.StandardError.ReadToEnd().Trim()
  }
}

function Wait-ForListener {
  param(
    [int]$PortNumber,
    [int]$TimeoutSeconds = 20
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $listener = Get-NetTCPConnection -State Listen -LocalPort $PortNumber -ErrorAction Stop | Select-Object -First 1
      if ($null -ne $listener) {
        return $true
      }
    } catch {
    }

    Start-Sleep -Seconds 2
  }

  return $false
}

function Get-Diagnosis {
  return (& $DiagnosisScript -Port $Port -AsJson | ConvertFrom-Json)
}

function Find-SupervisorSkillRoot {
  param([string]$ExplicitPath)

  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
    $candidates += $ExplicitPath
  }

  $skillPackRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $candidates += (Join-Path $skillPackRoot "openclaw-supervisor-installer")
  $candidates += (Join-Path $env:USERPROFILE ".codex\skills\openclaw-supervisor-installer")

  foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
    $scriptPath = Join-Path $candidate "scripts\install-supervisor.ps1"
    if (Test-Path -LiteralPath $scriptPath) {
      return $candidate
    }
  }

  return $null
}

function Restart-OpenClawGateway {
  $result = Invoke-CapturedProcess -FilePath "openclaw" -Arguments @("gateway", "restart")
  if ($result.available -and $result.exit_code -eq 0) {
    [void](Wait-ForListener -PortNumber $Port -TimeoutSeconds 25)
    return $result
  }

  $null = Invoke-CapturedProcess -FilePath $SchTasksExe -Arguments @("/End", "/TN", $TaskName) -TimeoutSeconds 8
  $taskRun = Invoke-CapturedProcess -FilePath $SchTasksExe -Arguments @("/Run", "/TN", $TaskName) -TimeoutSeconds 8
  if ($taskRun.exit_code -eq 0) {
    [void](Wait-ForListener -PortNumber $Port -TimeoutSeconds 25)
    return $taskRun
  }

  if (Test-Path -LiteralPath $GatewayLauncherPath) {
    $cmdExe = Join-Path $env:SystemRoot "System32\cmd.exe"
    Start-Process -FilePath $cmdExe -ArgumentList @("/d", "/c", "`"$GatewayLauncherPath`"") -WindowStyle Hidden | Out-Null
    [void](Wait-ForListener -PortNumber $Port -TimeoutSeconds 25)
    return [pscustomobject]@{
      available = $true
      file = $GatewayLauncherPath
      exit_code = 0
      stdout = "Gateway launcher started directly."
      stderr = ""
    }
  }

  return $result
}

function Run-GatewayTask {
  return Invoke-CapturedProcess -FilePath $SchTasksExe -Arguments @("/Run", "/TN", $TaskName) -TimeoutSeconds 8
}

function Install-SupervisorFromSkill {
  param([string]$SkillRoot)

  if ([string]::IsNullOrWhiteSpace($SkillRoot)) {
    throw "Supervisor installer skill was not found."
  }

  $installScript = Join-Path $SkillRoot "scripts\install-supervisor.ps1"
  if (-not (Test-Path -LiteralPath $installScript)) {
    throw "Supervisor install script was not found at $installScript"
  }

  return & $installScript -Force -AsJson
}

$before = Get-Diagnosis
$actions = [System.Collections.Generic.List[object]]::new()
$performedGatewayRestart = $false

if ($RepairAllSafe) {
  if (-not $before.gateway.listener.listening) {
    $RestartGateway = $true
  } elseif ($before.cli.available -and $before.cli.gateway_health.exit_code -ne 0) {
    $RestartGateway = $true
  }
}

if ($RepairAllSafe -and -not $before.gateway.task.exists -and (Test-Path -LiteralPath $GatewayLauncherPath)) {
  $StartGatewayTask = $false
  $RestartGateway = $true
}

if ($RestartGateway) {
  $restartResult = Restart-OpenClawGateway
  $performedGatewayRestart = $true
  $actions.Add([pscustomobject]@{
      id = "restart_gateway"
      exit_code = $restartResult.exit_code
      stdout = $restartResult.stdout
      stderr = $restartResult.stderr
    }) | Out-Null
}

if ($StartGatewayTask -and $before.gateway.task.exists) {
  $taskResult = Run-GatewayTask
  [void](Wait-ForListener -PortNumber $Port -TimeoutSeconds 20)
  $performedGatewayRestart = $true
  $actions.Add([pscustomobject]@{
      id = "start_gateway_task"
      exit_code = $taskResult.exit_code
      stdout = $taskResult.stdout
      stderr = $taskResult.stderr
    }) | Out-Null
}

if ($InstallSupervisor) {
  $skillRoot = Find-SupervisorSkillRoot -ExplicitPath $SupervisorSkillPath
  $installResult = Install-SupervisorFromSkill -SkillRoot $skillRoot
  $actions.Add([pscustomobject]@{
      id = "install_supervisor"
      exit_code = 0
      stdout = $installResult
      stderr = ""
    }) | Out-Null
}

$after = Get-Diagnosis
if ($performedGatewayRestart -and -not $after.gateway.listener.listening) {
  Start-Sleep -Seconds 15
  [void](Wait-ForListener -PortNumber $Port -TimeoutSeconds 20)
  $after = Get-Diagnosis
}

$result = [pscustomobject]@{
  timestamp = (Get-Date).ToString("s")
  actions_taken = @($actions)
  before = $before
  after = $after
}

if ($AsJson) {
  $result | ConvertTo-Json -Depth 20
} else {
  $result
}
