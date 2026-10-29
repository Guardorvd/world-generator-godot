param(
    [Parameter(Mandatory=$true)][int]$Seconds,
    [Parameter(Mandatory=$true)][string]$Log,
    [Parameter(Mandatory=$true)][string]$Executable,
    [string[]]$Arguments = @()
)
$ErrorActionPreference = 'Stop'
$stdoutPath = [IO.Path]::GetFullPath($Log)
$stderrPath = $stdoutPath + '.stderr'
$process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
if (-not $process.WaitForExit($Seconds * 1000)) {
    & taskkill.exe /PID $process.Id /T /F | Out-Null
    Write-Output "EXTERNAL TIMEOUT: $Log"
    exit 124
}
$process.WaitForExit()
$result = [IO.File]::ReadAllText($stdoutPath) + [IO.File]::ReadAllText($stderrPath)
[IO.File]::WriteAllText($stdoutPath, $result)
Write-Output $result
if ($process.ExitCode -ne 0) { exit $process.ExitCode }
if ($result -match '(?m)^(SCRIPT ERROR:|ERROR:)') { exit 1 }
