#Requires -Version 5.1
<#
    User files backup to an external drive
    Windows 10 / 11 - language independent (folders are resolved via the system, not by name)
#>

$Host.UI.RawUI.WindowTitle = 'User files backup'

# ---------- Helpers ----------
function Format-Size([double]$b) {
    if ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
    else { '{0:N0} KB' -f ($b / 1KB) }
}

# Long path support (>260 chars)
function Get-LongPath([string]$p) {
    if ($p.Length -ge 248 -and -not $p.StartsWith('\\?\')) { '\\?\' + $p } else { $p }
}

function Get-ShellFolder([string]$Name) {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $v = (Get-ItemProperty -Path $key -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($v) { [Environment]::ExpandEnvironmentVariables($v) }
}

$sources = New-Object System.Collections.Generic.List[object]
function Add-Source([string]$Name, [string]$Path) {
    if (-not $Path) { return }
    $Path = $Path.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  - $Name not found, skipped" -ForegroundColor DarkGray; return
    }
    foreach ($s in $sources) {
        if ($Path -eq $s.Path -or $Path.StartsWith($s.Path + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "  - $Name ($Path) is already inside $($s.Name), skipped" -ForegroundColor DarkGray
            return
        }
    }
    $sources.Add([pscustomobject]@{ Name = $Name; Path = $Path })
    Write-Host "  + $Name : $Path" -ForegroundColor Green
}

Clear-Host
Write-Host '=== User files backup ===' -ForegroundColor Cyan
Write-Host "Computer: $env:COMPUTERNAME   User: $env:USERNAME`n"

# ---------- 1. Target drive + write test ----------
do {
    $ok = $false
    $in = (Read-Host 'Enter the target drive letter (e.g. E)').Trim().TrimEnd(':', '\').ToUpper()

    if ($in -notmatch '^[A-Z]$') { Write-Host 'Invalid drive letter.' -ForegroundColor Red; continue }

    $root = "$in`:\"
    if (-not (Test-Path -LiteralPath $root)) { Write-Host "Drive $root does not exist." -ForegroundColor Red; continue }

    Write-Host "Write test on $root ..." -NoNewline
    $test = Join-Path $root ("_writetest_{0}.tmp" -f [guid]::NewGuid())
    try {
        [IO.File]::WriteAllText($test, 'test')
        if ([IO.File]::ReadAllText($test) -ne 'test') { throw 'Read-back mismatch.' }
        Remove-Item -LiteralPath $test -Force
        Write-Host ' OK' -ForegroundColor Green
        $ok = $true
    }
    catch {
        Write-Host ' FAILED' -ForegroundColor Red
        Write-Host "Cannot write to $root - $($_.Exception.Message)" -ForegroundColor Red
        Remove-Item -LiteralPath $test -Force -ErrorAction SilentlyContinue
    }
} until ($ok)

# ---------- 2. Source folders (language independent) ----------
Write-Host "`nLooking for source folders:" -ForegroundColor Cyan

# OneDrive (personal + business) first, so redirected Desktop/Documents are not copied twice
$oneDrives = @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)
$oneDrives += Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue |
    ForEach-Object { (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).UserFolder }
$oneDrives = $oneDrives | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') } | Sort-Object -Unique
foreach ($od in $oneDrives) { Add-Source (Split-Path $od -Leaf) $od }

Add-Source 'Desktop'   ([Environment]::GetFolderPath('Desktop'))
Add-Source 'Documents' ([Environment]::GetFolderPath('MyDocuments'))
Add-Source 'Pictures'  ([Environment]::GetFolderPath('MyPictures'))
Add-Source 'Videos'    ([Environment]::GetFolderPath('MyVideos'))
$dl = Get-ShellFolder '{374DE290-123F-4565-9164-39C4925E467B}'
if (-not $dl) { $dl = Join-Path $env:USERPROFILE 'Downloads' }
Add-Source 'Downloads' $dl

if ($sources.Count -eq 0) { Write-Host 'Nothing to back up.' -ForegroundColor Yellow; Read-Host 'Press Enter to exit'; exit }

# ---------- 3. Collect files ----------
Write-Host "`nCounting files..." -ForegroundColor Cyan
$files = New-Object System.Collections.Generic.List[object]
foreach ($s in $sources) {
    Write-Progress -Activity 'Counting files...' -Status $s.Name -CurrentOperation $s.Path
    $base = $s.Path.Length
    Get-ChildItem -LiteralPath $s.Path -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable +scanErrors |
        ForEach-Object {
            $files.Add([pscustomobject]@{
                Src    = $_.FullName
                Rel    = Join-Path $s.Name $_.FullName.Substring($base).TrimStart('\')
                Size   = $_.Length
                Source = $s.Name
            })
        }
}
Write-Progress -Activity 'Counting files...' -Completed

$count      = $files.Count
$totalBytes = ($files | Measure-Object -Property Size -Sum).Sum
if (-not $totalBytes) { $totalBytes = 0 }
Write-Host "Files found: $count, total $(Format-Size $totalBytes)"

# ---------- 4. Free space check ----------
$free = ([IO.DriveInfo]::new($root)).AvailableFreeSpace
Write-Host "Free space on ${root}: $(Format-Size $free)"
if ($totalBytes -gt $free) {
    Write-Host 'WARNING: not enough free space for the full backup!' -ForegroundColor Yellow
    if ((Read-Host 'Continue anyway? (y/n)') -notmatch '^[yYiI]') { exit }
}

# ---------- 5. Copy ----------
$dest = Join-Path $root ('Backup_{0}_{1}_{2:yyyy-MM-dd_HH-mm}' -f $env:COMPUTERNAME, $env:USERNAME, (Get-Date))
[void][IO.Directory]::CreateDirectory($dest)
Write-Host "`nCopying to: $dest`n" -ForegroundColor Cyan

$errors    = New-Object System.Collections.Generic.List[string]
$swUpdate  = [Diagnostics.Stopwatch]::StartNew()
$swTotal   = [Diagnostics.Stopwatch]::StartNew()
$i = 0; $doneBytes = 0; $copied = 0

foreach ($f in $files) {
    $i++
    if ($i -eq 1 -or $swUpdate.ElapsedMilliseconds -ge 250) {
        $pct = if ($totalBytes -gt 0) { [math]::Min(100, [int](($doneBytes / $totalBytes) * 100)) } else { [int](($i / $count) * 100) }
        $eta = -1
        if ($doneBytes -gt 0 -and $swTotal.Elapsed.TotalSeconds -gt 3) {
            $eta = [int](($totalBytes - $doneBytes) / ($doneBytes / $swTotal.Elapsed.TotalSeconds))
        }
        Write-Progress -Activity "Copying - $($f.Source)" `
            -Status "$i / $count files  |  $(Format-Size $doneBytes) / $(Format-Size $totalBytes)  ($pct%)" `
            -CurrentOperation $f.Src -PercentComplete $pct -SecondsRemaining $eta
        $swUpdate.Restart()
    }

    $target = Join-Path $dest $f.Rel
    try {
        $targetDir = [IO.Path]::GetDirectoryName($target)
        [void][IO.Directory]::CreateDirectory((Get-LongPath $targetDir))
        [IO.File]::Copy((Get-LongPath $f.Src), (Get-LongPath $target), $true)
        $copied++
    }
    catch {
        $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        $errors.Add("$($f.Src)  ->  $msg")
    }
    $doneBytes += $f.Size
}
Write-Progress -Activity 'Copying' -Completed

# ---------- 6. Summary + log ----------
$log = Join-Path $dest 'backup_log.txt'
$summary = @(
    "Backup: $(Get-Date)"
    "Computer: $env:COMPUTERNAME  User: $env:USERNAME"
    "Sources:"
    ($sources | ForEach-Object { "  $($_.Name): $($_.Path)" })
    "Copied: $copied / $count files ($(Format-Size $totalBytes))"
    "Errors: $($errors.Count)"
    "Duration: $($swTotal.Elapsed.ToString('hh\:mm\:ss'))"
    ''
    '--- Failed files ---'
    $errors
    ''
    '--- Folders that could not be read during scan ---'
    ($scanErrors | ForEach-Object { $_.TargetObject })
)
$summary | Set-Content -LiteralPath $log -Encoding UTF8

Write-Host '=== DONE ===' -ForegroundColor Green
Write-Host "Copied: $copied / $count files ($(Format-Size $totalBytes))"
Write-Host "Duration: $($swTotal.Elapsed.ToString('hh\:mm\:ss'))"
if ($errors.Count -gt 0) { Write-Host "Errors: $($errors.Count) - details: $log" -ForegroundColor Yellow }
else { Write-Host "Log: $log" }

Read-Host "`nPress Enter to exit"