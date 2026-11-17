# Runs every local-setup script the way the student and Codex run them, on real Windows,
# and asserts the result of each scenario. Needs: Java 21 on PATH, MySQL on 3306 with
# root password $Password, mysql.exe on PATH. Run from the repo root (a path with spaces).
param([string]$Password = 'My Pass\word#1')

$ErrorActionPreference = 'Continue'
$repo = (Get-Location).Path
$props = Join-Path $repo 'backend\local.properties'
$results = New-Object System.Collections.ArrayList

# Runs a script the way a coding agent does: stdin/stdout/stderr are pipes, with a time limit.
# PipeClosed is false when the command ended but something it started still holds the
# output pipe open; an agent waiting for the output would then hang.
function Run($file, [string[]]$argList = @(), $stdin = $null, [switch]$NonInteractive, [int]$TimeoutSec = 300) {
    $psArgs = '-NoProfile -ExecutionPolicy Bypass'
    if ($NonInteractive) { $psArgs += ' -NonInteractive' }
    $psArgs += ' -File "' + (Join-Path $repo $file) + '"'
    foreach ($a in $argList) { $psArgs += ' ' + $a }
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe', $psArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.WorkingDirectory = $repo
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if ($null -ne $stdin) { $p.StandardInput.WriteLine($stdin) }
    $p.StandardInput.Close()
    $exited = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) { & taskkill.exe /T /F /PID $p.Id | Out-Null }
    $pipeClosed = $outTask.Wait(15000) -and $errTask.Wait(15000)
    $text = ''
    if ($outTask.IsCompleted) { $text += $outTask.Result }
    if ($errTask.IsCompleted) { $text += $errTask.Result }
    $code = if ($exited) { $p.ExitCode } else { -1 }
    Write-Host "----- $file $($argList -join ' ') (exit $code, exited $exited, pipe closed $pipeClosed)"
    Write-Host $text
    return @{ Code = $code; Text = $text; Exited = $exited; PipeClosed = $pipeClosed }
}
function Check($name, [bool]$ok, $detail = '') {
    [void]$results.Add([pscustomobject]@{ Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Check = $name; Detail = $detail })
    Write-Host ("===== {0} {1} {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}
function Healthy { try { return ((Invoke-RestMethod 'http://localhost:8080/api/health' -TimeoutSec 3) -match 'running') } catch { return $false } }
function PortOpen($port) { $c = New-Object Net.Sockets.TcpClient; try { $t = $c.ConnectAsync('127.0.0.1', $port); return ($t.Wait(1500) -and $c.Connected) } catch { return $false } finally { $c.Close() } }
function Sql($query) { $env:MYSQL_PWD = $Password; $r = (& mysql -u root -h 127.0.0.1 -N -e $query 2>&1 | ForEach-Object { "$_" }) -join ' '; Remove-Item Env:MYSQL_PWD; return $r }
function ServerPid { $c = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { return $c.OwningProcess } else { return $null } }
function SaveProps($pw) { [IO.File]::WriteAllText($props, "spring.datasource.password=$($pw.Replace('\', '\\'))`r`n") }

Write-Host "Repo: $repo"
Write-Host "PowerShell: $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"
Remove-Item $props -ErrorAction SilentlyContinue

# 1. Codex path before the student saved a password: must stop with a clear message, not hang.
$r = Run 'scripts\server.ps1' @('start', '-NoBrowser') -NonInteractive
Check 'agent start without saved password stops with message' ($r.Code -eq 1 -and $r.Text -match 'not saved yet') "exit $($r.Code)"

# 2. Student types the password at the prompt. CI can only offer it on stdin; Read-Host
#    -AsSecureString may read the console instead, so a timeout here is reported, not failed.
$r = Run 'scripts\server.ps1' @('start', '-NoBrowser') "$Password" -TimeoutSec 120
$saved = if (Test-Path $props) { Get-Content $props -Raw } else { '' }
if ($r.Exited) {
    Check 'password typed at the prompt is saved with escaped backslash' ($saved -match [regex]::Escape('spring.datasource.password=' + $Password.Replace('\', '\\'))) ($saved -replace "`r|`n", ' ')
} else {
    Write-Host '===== INFO password prompt does not read piped stdin (console only); saving the file directly'
}
if (-not ($r.Exited -and $r.Code -eq 0)) {
    & (Join-Path $repo 'scripts\server.ps1') stop | Out-Null
    SaveProps $Password
    $r = Run 'scripts\server.ps1' @('start', '-NoBrowser') -NonInteractive
}
Check 'agent start exits 0 and reports running' ($r.Code -eq 0 -and $r.Text -match 'The store is running') "exit $($r.Code)"
Check 'agent start closes its output pipe (agent does not hang)' ($r.Exited -and $r.PipeClosed)

# 3. The server outlives the process that started it.
Check 'server still answers after the start process exited' (Healthy)
Check 'database and 4 tables were created automatically' ((Sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='good_store'") -match '\b4\b')
$firstPid = ServerPid
$serverCmd = if ($firstPid) { (Get-CimInstance Win32_Process -Filter "ProcessId=$firstPid").CommandLine } else { '' }
Check 'port 8080 belongs to java running good-store-0.1.0.jar' ($serverCmd -match 'good-store-0\.1\.0\.jar') "pid $firstPid"
$pidFileValue = Get-Content (Join-Path $repo 'backend\logs\server.pid') -ErrorAction SilentlyContinue
Check 'server.pid holds the java process id' ("$pidFileValue" -eq "$firstPid") "file $pidFileValue"

# 4. Agent path once the password is saved; status and logs.
$r = Run 'scripts\server.ps1' @('status') -NonInteractive
Check 'status exits 0 while running' ($r.Code -eq 0)
$r = Run 'scripts\server.ps1' @('logs') -NonInteractive
Check 'logs shows the startup line' ($r.Code -eq 0 -and $r.Text -match 'Started GoodStoreApplication')

# 5. Self-test in Windows PowerShell 5.1 and in PowerShell 7.
$r = Run 'scripts\check.ps1' -NonInteractive
Check 'check.ps1 passes in Windows PowerShell 5.1' ($r.Code -eq 0 -and $r.Text -match 'ALL 13 CHECKS PASSED') "exit $($r.Code)"
$out = & pwsh -NoProfile -NonInteractive -File (Join-Path $repo 'scripts\check.ps1') 2>&1 | ForEach-Object { "$_" }
Check 'check.ps1 passes in PowerShell 7' ($LASTEXITCODE -eq 0 -and (($out -join ' ') -match 'ALL 13 CHECKS PASSED')) "exit $LASTEXITCODE"

# 6. Restart: the old server stops, the jar rebuilds while unlocked, the new server starts.
$r = Run 'scripts\server.ps1' @('start', '-NoBrowser') -NonInteractive
$secondPid = ServerPid
Check 'second start restarts with a new process' ($r.Code -eq 0 -and $secondPid -and $secondPid -ne $firstPid) "old $firstPid new $secondPid"
Check 'old server process is gone' (-not (Get-Process -Id $firstPid -ErrorAction SilentlyContinue))

# Thai culture (Buddhist calendar) must not break the dates check.ps1 sends.
$out = & pwsh -NoProfile -NonInteractive -Command "[cultureinfo]::CurrentCulture = 'th-TH'; & '$(Join-Path $repo 'scripts\check.ps1')'" 2>&1 | ForEach-Object { "$_" }
Check 'check.ps1 passes under th-TH culture' ($LASTEXITCODE -eq 0 -and (($out -join ' ') -match 'ALL 13 CHECKS PASSED')) "exit $LASTEXITCODE"

# 7. reset-db: confirm with YES, server stops, database is gone; next start rebuilds tables.
$r = Run 'scripts\reset-db.ps1' @() 'YES'
Check 'reset-db deletes the database and stops the server' ($r.Code -eq 0 -and -not (PortOpen 8080) -and -not ((Sql 'SHOW DATABASES') -match 'good_store')) "exit $($r.Code)"
$r = Run 'scripts\reset-db.ps1' @() 'no'
Check 'reset-db without YES deletes nothing' ($r.Code -eq 0 -and $r.Text -match 'Nothing was deleted')
$r = Run 'scripts\server.ps1' @('start', '-NoBrowser') -NonInteractive
Check 'start after reset recreates the tables' ($r.Code -eq 0 -and ((Sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='good_store'") -match '\b4\b'))

# 8. stop
$r = Run 'scripts\server.ps1' @('stop') -NonInteractive
Check 'stop frees port 8080' ($r.Code -eq 0 -and -not (PortOpen 8080))
$r = Run 'scripts\server.ps1' @('stop') -NonInteractive
Check 'stop when nothing runs is harmless' ($r.Code -eq 0 -and $r.Text -match 'was not running')

# 9. Error paths print the right fix.
SaveProps 'wrong-password'
$r = Run 'scripts\server.ps1' @('start', '-NoBrowser') -NonInteractive
Check 'wrong password is detected and the saved one deleted' ($r.Code -eq 1 -and $r.Text -match 'Wrong MySQL password' -and -not (Test-Path $props)) "exit $($r.Code)"
SaveProps $Password

$env:MYSQLPORT = '3399'
$r = Run 'scripts\server.ps1' @('start', '-NoBrowser') -NonInteractive
Remove-Item Env:MYSQLPORT
Check 'unreachable MySQL stops with a MySQL message' ($r.Code -eq 1 -and $r.Text -match 'MySQL') "exit $($r.Code)"

$savedHome = $env:JAVA_HOME
$env:JAVA_HOME = $env:JAVA_HOME_8_X64
$r = Run 'scripts\server.ps1' @('start', '-NoBrowser') -NonInteractive
$env:JAVA_HOME = $savedHome
Check 'old Java is rejected' ($r.Code -eq 1 -and $r.Text -match 'too old') "JAVA_HOME_8_X64=$env:JAVA_HOME_8_X64"

$env:JAVA_HOME = 'C:\no\such\jdk'
$r = Run 'scripts\server.ps1' @('start', '-NoBrowser') -NonInteractive
$env:JAVA_HOME = $savedHome
Check 'broken JAVA_HOME is explained' ($r.Code -eq 1 -and $r.Text -match 'JAVA_HOME points to a folder without Java')

$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 8080)
$listener.Start()
$r = Run 'scripts\server.ps1' @('start', '-NoBrowser') -NonInteractive
$listener.Stop()
Check 'port 8080 taken by another program is explained' ($r.Code -eq 1 -and $r.Text -match 'Another program') "exit $($r.Code)"

# Another Java program on 8080 (the JDK's jwebserver) must not be killed.
$other = Start-Process -FilePath (Join-Path (Split-Path -Parent (Get-Command java).Source) 'jwebserver.exe') -ArgumentList @('-p', '8080', '-b', '127.0.0.1') -PassThru -WindowStyle Hidden
for ($i = 0; $i -lt 20 -and -not (PortOpen 8080); $i++) { Start-Sleep -Milliseconds 500 }
$r = Run 'scripts\server.ps1' @('start', '-NoBrowser') -NonInteractive
Check 'another Java app on 8080 is left running' ($r.Code -eq 1 -and $r.Text -match 'Another program' -and -not $other.HasExited) "exit $($r.Code)"
Stop-Process -Id $other.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$r = Run 'scripts\check.ps1' -NonInteractive
Check 'check.ps1 with no server says to start it' ($r.Code -eq 1 -and $r.Text -match 'not running')

# 10. The double-click launchers (stdin from NUL so "pause" returns).
cmd /c "start.cmd < NUL" | Out-Host
Check 'start.cmd starts the server' (Healthy)
cmd /c "check.cmd < NUL" | Out-Host
cmd /c "stop.cmd < NUL" | Out-Host
Check 'stop.cmd stops the server' (-not (PortOpen 8080))

Write-Host ''
$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Host "$($results.Count - $failed) passed, $failed failed"
if ($failed -gt 0) { exit 1 }
