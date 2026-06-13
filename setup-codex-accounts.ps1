#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$DeviceCodeRequestTimeoutSeconds = 90
$LoginSessionTimeoutMinutes = 30

if (-not ("CcSwitch.ProcessLineCollector" -as [type])) {
    Add-Type -TypeDefinition @"
namespace CcSwitch {
    public sealed class ProcessLineCollector {
        private readonly System.Collections.Concurrent.ConcurrentQueue<string> queue;

        public ProcessLineCollector(System.Collections.Concurrent.ConcurrentQueue<string> queue) {
            this.queue = queue;
        }

        public void OnDataReceived(object sender, System.Diagnostics.DataReceivedEventArgs eventArgs) {
            if (eventArgs.Data != null) {
                this.queue.Enqueue(eventArgs.Data);
            }
        }
    }
}
"@
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Test-IsWindows {
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Join-ProcessArguments {
    param([Parameter(Mandatory)][string[]]$Arguments)

    return ($Arguments | ForEach-Object {
        if ($_ -match '^[^\s"]+$') {
            $_
        }
        else {
            '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
        }
    }) -join " "
}

function Get-CurrentPowerShellPath {
    if ($PSVersionTable.PSEdition -eq "Core") {
        return (Get-Command pwsh -ErrorAction Stop).Source
    }

    return (Get-Command powershell.exe -ErrorAction Stop).Source
}

function ConvertTo-PowerShellSingleQuotedString {
    param([Parameter(Mandatory)][string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function Stop-ProcessTree {
    param([Parameter(Mandatory)][int]$ProcessId)

    try {
        Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object { $_.ParentProcessId -eq $ProcessId } |
            ForEach-Object { Stop-ProcessTree -ProcessId ([int]$_.ProcessId) }
    }
    catch {
        # Process-tree cleanup is best-effort only.
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
    catch {
        # The process may already have exited.
    }
}

function Find-SupportedBrowser {
    $candidates = @(
        [PSCustomObject]@{
            Name = "Google Chrome"
            Kind = "chrome"
            Path = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        },
        [PSCustomObject]@{
            Name = "Google Chrome"
            Kind = "chrome"
            Path = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
        },
        [PSCustomObject]@{
            Name = "Google Chrome"
            Kind = "chrome"
            Path = "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
        },
        [PSCustomObject]@{
            Name = "Microsoft Edge"
            Kind = "edge"
            Path = "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        },
        [PSCustomObject]@{
            Name = "Microsoft Edge"
            Kind = "edge"
            Path = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        }
    )

    return $candidates |
        Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path) } |
        Select-Object -First 1
}

function Stop-IsolatedBrowser {
    param([Parameter(Mandatory)][string]$ProfilePath)

    try {
        Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object {
                $_.Name -in @("chrome.exe", "msedge.exe") -and
                $_.CommandLine -and
                $_.CommandLine.IndexOf(
                    $ProfilePath,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -ge 0
            } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
    }
    catch {
        # Cleanup is best-effort only.
    }
}

function Remove-DirectoryWithRetry {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }

    Write-Warn "The temporary browser folder could not be removed: $Path"
}

function Start-IsolatedBrowser {
    param(
        [Parameter(Mandatory)]$Browser,
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$Url
    )

    Stop-IsolatedBrowser -ProfilePath $ProfilePath
    Remove-DirectoryWithRetry -Path $ProfilePath
    New-Item -ItemType Directory -Path $ProfilePath -Force | Out-Null

    $privateFlag = if ($Browser.Kind -eq "edge") { "--inprivate" } else { "--incognito" }

    Start-Process -FilePath $Browser.Path -ArgumentList @(
        "--user-data-dir=`"$ProfilePath`"",
        $privateFlag,
        "--new-window",
        $Url
    ) | Out-Null
}

function New-CodexProcessInfo {
    param(
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$Command
    )

    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Get-CurrentPowerShellPath
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.EnvironmentVariables["CODEX_HOME"] = $CodexHome
    $info.Arguments = Join-ProcessArguments -Arguments @(
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        $Command
    )
    return $info
}

function New-CodexAppServerProcessInfo {
    param([Parameter(Mandatory)][string]$CodexHome)

    $codexPath = (Get-Command codex -ErrorAction Stop).Source
    $codexCommand = "& " +
        (ConvertTo-PowerShellSingleQuotedString -Value $codexPath) +
        " -c 'cli_auth_credentials_store=`"file`"' app-server --stdio"

    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Get-CurrentPowerShellPath
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.EnvironmentVariables["CODEX_HOME"] = $CodexHome
    $info.Arguments = Join-ProcessArguments -Arguments @(
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        $codexCommand
    )
    return $info
}

function Send-AppServerMessage {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)]$Message
    )

    $json = $Message | ConvertTo-Json -Compress -Depth 20
    $Process.StandardInput.WriteLine($json)
    $Process.StandardInput.Flush()
}

function ConvertFrom-AppServerLine {
    param([string]$Line)

    $trimmed = $Line.Trim()
    if (-not $trimmed.StartsWith("{")) {
        return $null
    }

    try {
        return $trimmed | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-JsonPropertyValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Test-CodexAuth {
    param([Parameter(Mandatory)][string]$CodexHome)

    $authPath = Join-Path $CodexHome "auth.json"
    if (-not (Test-Path -LiteralPath $authPath)) {
        return $false
    }

    $file = Get-Item -LiteralPath $authPath
    if ($file.Length -lt 100) {
        return $false
    }

    try {
        Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json | Out-Null
    }
    catch {
        return $false
    }

    $statusParams = @{
        CodexHome = $CodexHome
        Command   = "& codex login status"
    }
    $info = New-CodexProcessInfo @statusParams

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    $process.Start() | Out-Null
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $combined = "$stdout`n$stderr"
    return ($process.ExitCode -eq 0 -and $combined -match "Logged in")
}

function Protect-LoginOutput {
    param([string[]]$Lines)

    return $Lines | ForEach-Object {
        $line = $_
        $line = $line -replace '("userCode"\s*:\s*")[^"]+(")', '$1[device code hidden]$2'
        foreach ($match in [regex]::Matches($line, "(?i)\b[A-Z0-9]{4,8}-[A-Z0-9]{4,8}\b")) {
            $candidate = $match.Value.ToUpperInvariant()
            if (Test-DeviceCodeCandidate -Candidate $candidate -Line $line) {
                $line = $line.Replace($match.Value, "[device code hidden]")
            }
        }
        $line
    }
}

function Test-DeviceCodeCandidate {
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Line,
        [switch]$AllowContextFromPreviousLine
    )

    $normalized = $Candidate.ToUpperInvariant()
    $blockedPhrases = @(
        "COMMAND-LINE",
        "DEVICE-CODE",
        "LOGIN-STATUS",
        "NO-PROFILE",
        "NO-LOGO",
        "NONINTERACTIVE"
    )

    if ($blockedPhrases -contains $normalized) {
        return $false
    }

    $hasDeviceCodeContext = $Line -match "(?i)\b(device code|verification code|user code|enter code|code)\b"
    if ($hasDeviceCodeContext) {
        return $true
    }

    if ($AllowContextFromPreviousLine) {
        return $true
    }

    return $false
}

function Test-DeviceCodeRateLimit {
    param([string[]]$Lines)

    $combined = ($Lines -join "`n")
    return (
        $combined -match "(?i)\b429\b" -or
        $combined -match "(?i)Too Many Requests" -or
        $combined -match "(?i)device code request failed"
    )
}

function Get-CodexLoginFailureMessage {
    param([string[]]$Lines)

    $combined = ($Lines -join "`n")

    if (Test-DeviceCodeRateLimit -Lines $Lines) {
        return "OpenAI is temporarily limiting device-code requests.`n`nWait 15 to 30 minutes, then run the script again.`nDo not retry repeatedly.`nDo not run codex logout for this error."
    }

    if ($combined -match "(?i)access_denied|authorization denied|user denied|cancel") {
        return "Codex sign-in was cancelled or denied.`n`nRun the script again when you are ready to sign in."
    }

    if ($combined -match "(?i)expired|invalid_grant|invalid device") {
        return "The device code expired or is no longer valid.`n`nRun the script again and finish the browser sign-in within 15 minutes."
    }

    if ($combined -match "(?i)network|timeout|timed out|ECONN|ENOTFOUND|EAI_AGAIN|TLS|certificate|proxy") {
        return "Codex sign-in failed because of a network, proxy, or certificate problem.`n`nCheck your network connection, VPN, proxy, or firewall, then try again."
    }

    return "Codex sign-in failed.`n`nCheck the original Codex output above, then try again."
}

function Write-OriginalCodexOutput {
    param([string[]]$Lines)

    Write-Host ""
    Write-Warn "Original Codex output:"

    $protectedLines = @(Protect-LoginOutput -Lines $Lines | Select-Object -Last 20)
    if ($protectedLines.Count -eq 0) {
        Write-Host "(no output captured)"
        return
    }

    $protectedLines | ForEach-Object {
        Write-Host $_
    }
}

function Invoke-CodexDeviceLogin {
    param(
        [Parameter(Mandatory)][int]$AccountNumber,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)]$Browser
    )

    $accountLabel = "Codex Account $AccountNumber"
    $authPath = Join-Path $CodexHome "auth.json"
    $backupPath = $null
    $profilePath = Join-Path $env:TEMP (
        "ccswitch-codex-login-account-{0}-{1}" -f $AccountNumber, [guid]::NewGuid().ToString("N")
    )

    New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null

    if (Test-Path -LiteralPath $authPath) {
        $backupPath = "$authPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $authPath -Destination $backupPath -Force
    }

    $info = New-CodexAppServerProcessInfo -CodexHome $CodexHome
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info

    $queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $allLines = [System.Collections.Generic.List[string]]::new()

    $collector = [CcSwitch.ProcessLineCollector]::new($queue)
    $outputHandler = [System.Diagnostics.DataReceivedEventHandler][System.Delegate]::CreateDelegate(
        [System.Diagnostics.DataReceivedEventHandler],
        $collector,
        "OnDataReceived"
    )
    $errorHandler = [System.Diagnostics.DataReceivedEventHandler][System.Delegate]::CreateDelegate(
        [System.Diagnostics.DataReceivedEventHandler],
        $collector,
        "OnDataReceived"
    )

    $process.add_OutputDataReceived($outputHandler)
    $process.add_ErrorDataReceived($errorHandler)

    $deviceUrl = "https://auth.openai.com/codex/device"
    $deviceCode = $null
    $loginId = $null
    $codeDeadline = (Get-Date).AddSeconds($DeviceCodeRequestTimeoutSeconds)
    $loginDeadline = (Get-Date).AddMinutes($LoginSessionTimeoutMinutes)
    $loginCompleted = $false
    $loginError = $null
    $authPollIntervalSeconds = 5

    try {
        Write-Step "Sign in to $accountLabel"
        Write-Host "Waiting for a device code..."

        $process.Start() | Out-Null
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        $initializeMessage = @{
            method = "initialize"
            id     = 1
            params = @{
                clientInfo = @{
                    name    = "cc_switch_codex_multi_account"
                    title   = "CC Switch Codex Multi Account Setup"
                    version = "0.1.0"
                }
            }
        }
        Send-AppServerMessage -Process $process -Message $initializeMessage

        $initializedMessage = @{
            method = "initialized"
            params = @{}
        }
        Send-AppServerMessage -Process $process -Message $initializedMessage

        $loginStartMessage = @{
            method = "account/login/start"
            id     = 2
            params = @{
                type = "chatgptDeviceCode"
            }
        }
        Send-AppServerMessage -Process $process -Message $loginStartMessage

        while (-not $deviceCode) {
            $line = $null
            while ($queue.TryDequeue([ref]$line)) {
                $allLines.Add($line)
                $message = ConvertFrom-AppServerLine -Line $line

                if ($message -and (Get-JsonPropertyValue -Object $message -Name "id") -eq 2) {
                    $messageError = Get-JsonPropertyValue -Object $message -Name "error"
                    if ($messageError) {
                        Write-OriginalCodexOutput -Lines $allLines
                        throw (Get-CodexLoginFailureMessage -Lines $allLines)
                    }

                    $result = Get-JsonPropertyValue -Object $message -Name "result"
                    $resultType = Get-JsonPropertyValue -Object $result -Name "type"
                    $resultUserCode = Get-JsonPropertyValue -Object $result -Name "userCode"
                    $resultVerificationUrl = Get-JsonPropertyValue -Object $result -Name "verificationUrl"
                    if (
                        $resultType -eq "chatgptDeviceCode" -and
                        $resultUserCode -and
                        $resultVerificationUrl
                    ) {
                        $deviceCode = [string]$resultUserCode
                        $deviceUrl = [string]$resultVerificationUrl
                        $loginId = [string](Get-JsonPropertyValue -Object $result -Name "loginId")
                    }
                }

                $line = $null
            }

            if ($process.HasExited) {
                Write-OriginalCodexOutput -Lines $allLines
                throw (Get-CodexLoginFailureMessage -Lines $allLines)
            }

            if ((Get-Date) -gt $codeDeadline) {
                Write-OriginalCodexOutput -Lines $allLines
                throw "Codex app-server did not return a device code within $DeviceCodeRequestTimeoutSeconds seconds.`n`nThis script reads the official app-server JSON field result.userCode. Update Codex CLI or check the original output above."
            }

            if ((Get-Date) -gt $loginDeadline) {
                Stop-ProcessTree -ProcessId $process.Id
                Write-OriginalCodexOutput -Lines $allLines
                throw "The sign-in session timed out after $LoginSessionTimeoutMinutes minutes.`n`nRun the script again. The device code itself may expire earlier, so finish the browser sign-in soon after the code appears."
            }

            Start-Sleep -Milliseconds 150
        }

        Write-Host ""
        Write-Host "Device code from Codex app-server: $deviceCode" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "This code expires in 15 minutes."
        Write-Host "Do not share it."
        Write-Host "A private browser window will open now."
        Write-Host "Sign in with the account you want to save as $accountLabel."
        Write-Host ""

        $browserParams = @{
            Browser     = $Browser
            ProfilePath = $profilePath
            Url         = $deviceUrl
        }
        Start-IsolatedBrowser @browserParams

        $nextAuthCheck = (Get-Date).AddSeconds($authPollIntervalSeconds)
        while (-not $loginCompleted) {
            $line = $null
            while ($queue.TryDequeue([ref]$line)) {
                $allLines.Add($line)
                $message = ConvertFrom-AppServerLine -Line $line

                if ($message -and (Get-JsonPropertyValue -Object $message -Name "method") -eq "account/login/completed") {
                    $params = Get-JsonPropertyValue -Object $message -Name "params"
                    $notificationLoginId = [string](Get-JsonPropertyValue -Object $params -Name "loginId")
                    if (-not $loginId -or $notificationLoginId -eq $loginId) {
                        if (Get-JsonPropertyValue -Object $params -Name "success") {
                            $loginCompleted = $true
                        }
                        else {
                            $loginError = [string](Get-JsonPropertyValue -Object $params -Name "error")
                        }
                    }
                }

                $line = $null
            }

            if ($loginError) {
                Write-OriginalCodexOutput -Lines $allLines
                throw "Codex sign-in failed.`n`nOriginal error: $loginError"
            }

            if ($process.HasExited) {
                Write-OriginalCodexOutput -Lines $allLines
                throw (Get-CodexLoginFailureMessage -Lines $allLines)
            }

            if ((Get-Date) -gt $loginDeadline) {
                Stop-ProcessTree -ProcessId $process.Id
                Write-OriginalCodexOutput -Lines $allLines
                throw "The sign-in session timed out after $LoginSessionTimeoutMinutes minutes.`n`nRun the script again. The device code itself may expire earlier, so finish the browser sign-in soon after the code appears."
            }

            if ((Get-Date) -ge $nextAuthCheck) {
                if (Test-CodexAuth -CodexHome $CodexHome) {
                    $loginCompleted = $true
                }
                $nextAuthCheck = (Get-Date).AddSeconds($authPollIntervalSeconds)
            }

            Start-Sleep -Milliseconds 500
        }

        if (-not (Test-CodexAuth -CodexHome $CodexHome)) {
            throw "The sign-in finished, but auth.json could not be verified.`n`nThe saved login file is missing, incomplete, or not accepted by codex login status. Run the script again for this account."
        }

        if ($backupPath -and (Test-Path -LiteralPath $backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force
            $backupPath = $null
        }

        Write-Ok "$accountLabel login verified."
        return $authPath
    }
    catch {
        if (Test-Path -LiteralPath $authPath) {
            Remove-Item -LiteralPath $authPath -Force -ErrorAction SilentlyContinue
        }

        if ($backupPath -and (Test-Path -LiteralPath $backupPath)) {
            Move-Item -LiteralPath $backupPath -Destination $authPath -Force
            $backupPath = $null
        }

        throw
    }
    finally {
        if (-not $process.HasExited) {
            Stop-ProcessTree -ProcessId $process.Id
        }

        try { $process.remove_OutputDataReceived($outputHandler) } catch {}
        try { $process.remove_ErrorDataReceived($errorHandler) } catch {}
        $process.Dispose()

        Stop-IsolatedBrowser -ProfilePath $profilePath
        Start-Sleep -Milliseconds 500
        Remove-DirectoryWithRetry -Path $profilePath
    }
}

function Copy-AuthForCcSwitch {
    param(
        [Parameter(Mandatory)][int]$AccountNumber,
        [Parameter(Mandatory)][string]$AuthPath
    )

    Get-Content -LiteralPath $AuthPath -Raw | Set-Clipboard

    Write-Host ""
    Write-Ok "Authentication data was copied to the clipboard."
    Write-Host ""
    Write-Host "In CC Switch, create or edit a Codex provider:"
    Write-Host "  Type: OpenAI Official"
    Write-Host "  Name: Codex Account $AccountNumber"
    Write-Host "  API Key: leave it empty"
    Write-Host "  auth.json: paste with Ctrl+V"
    Write-Host ""
    Write-Warn "The clipboard now contains sensitive login data. Do not share it."
    Write-Warn "This prompt has no script timeout."
    Read-Host "Save the provider in CC Switch, then press Enter to continue"
}

function Read-AccountCount {
    while ($true) {
        $value = Read-Host "How many Codex accounts do you want to add? [2]"
        if ([string]::IsNullOrWhiteSpace($value)) {
            return 2
        }

        $number = 0
        if ([int]::TryParse($value, [ref]$number) -and $number -ge 1 -and $number -le 100) {
            return $number
        }

        Write-Warn "Enter a number from 1 to 100."
    }
}

function Confirm-ExistingAuthAction {
    param([int]$AccountNumber)

    while ($true) {
        $choice = Read-Host "A valid login already exists for Codex Account $AccountNumber. [R]euse, [N]ew login, [S]kip, [Q]uit"
        switch ($choice.Trim().ToUpperInvariant()) {
            "R" { return "reuse" }
            "N" { return "new" }
            "S" { return "skip" }
            "Q" { return "quit" }
            default { Write-Warn "Enter R, N, S, or Q." }
        }
    }
}

try {
    Clear-Host
    Write-Step "Environment check"

    if (-not (Test-IsWindows)) {
        throw "This script currently supports Windows only.`n`nRun it on Windows 10 or Windows 11."
    }

    if ($PSVersionTable.PSVersion -lt [version]"5.1") {
        throw "PowerShell 5.1 or later is required.`n`nRun this script with Windows PowerShell 5.1 or PowerShell 7+."
    }

    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codexCommand) {
        throw "Codex CLI was not found.`n`nInstall Codex CLI, reopen PowerShell, then run this script again."
    }

    $browser = Find-SupportedBrowser
    if (-not $browser) {
        throw "Google Chrome or Microsoft Edge was not found.`n`nInstall Google Chrome or Microsoft Edge, then run this script again."
    }

    if (-not (Get-Command Set-Clipboard -ErrorAction SilentlyContinue)) {
        throw "Set-Clipboard is not available in this PowerShell session.`n`nRun this script in a normal Windows PowerShell or PowerShell 7 session."
    }

    $writeTest = Join-Path $env:USERPROFILE ".codex-account-write-test-$PID.tmp"
    try {
        Set-Content -LiteralPath $writeTest -Value "test" -Encoding utf8
        Remove-Item -LiteralPath $writeTest -Force
    }
    catch {
        throw "The script cannot write to your user profile folder.`n`nOriginal error: $($_.Exception.Message)"
    }

    Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
    Write-Host "Codex CLI: $(& codex --version)"
    Write-Host "Browser: $($browser.Name)"

    if ($env:CODEX_HOME) {
        Write-Warn "CODEX_HOME is currently set to: $env:CODEX_HOME"
        Write-Warn "This script will not change that value. Each login uses its own isolated process."
    }

    Write-Host ""
    Write-Ok "Environment check passed."
    Write-Ok "This device is ready."

    $accountCount = Read-AccountCount

    for ($accountNumber = 1; $accountNumber -le $accountCount; $accountNumber++) {
        $codexHome = Join-Path $env:USERPROFILE ".codex-account-$accountNumber"
        $authPath = Join-Path $codexHome "auth.json"

        if (Test-CodexAuth -CodexHome $codexHome) {
            $action = Confirm-ExistingAuthAction -AccountNumber $accountNumber
            if ($action -eq "quit") {
                break
            }
            if ($action -eq "skip") {
                continue
            }
            if ($action -eq "new") {
                $loginParams = @{
                    AccountNumber = $accountNumber
                    CodexHome     = $codexHome
                    Browser       = $browser
                }
                $authPath = Invoke-CodexDeviceLogin @loginParams
            }
        }
        else {
            $loginParams = @{
                AccountNumber = $accountNumber
                CodexHome     = $codexHome
                Browser       = $browser
            }
            $authPath = Invoke-CodexDeviceLogin @loginParams
        }

        $copyParams = @{
            AccountNumber = $accountNumber
            AuthPath      = $authPath
        }
        Copy-AuthForCcSwitch @copyParams
    }

    Write-Step "Finished"
    Write-Ok "Your Codex account files are ready."
    Write-Host ""
    Write-Host "Keep this folder structure:"
    Write-Host "  ~/.codex              = CC Switch live slot"
    Write-Host "  ~/.codex-account-1    = Codex Account 1 source"
    Write-Host "  ~/.codex-account-2    = Codex Account 2 source"
    Write-Host "  ~/.codex-account-N    = more account sources"
    Write-Host ""
    Write-Host "In CC Switch, enable Codex Account 1, then restart Codex or VS Code."
    Write-Warn "Do not use 'codex logout' to switch accounts."
}
catch {
    Write-Host ""
    Write-Host "Setup stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
