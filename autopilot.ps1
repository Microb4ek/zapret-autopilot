param([string]$Action = 'home')

# ZAPRET AUTOPILOT — обвязка над Flowseal zapret-discord-youtube:
# установка на чистый компьютер / починка -> диагностика -> тест всех стратегий -> запуск лучшей -> автозапуск,
# а если ни одна стратегия не открывает все сервисы — чистая переустановка zapret с GitHub.

$AppVersion = '1.3.0'
$AppDir     = $PSScriptRoot
# Данные отдельно от программы: копия программы в Загрузках и установленная в zapret\autopilot видят одно и то же
$DataDir    = Join-Path $env:ProgramData 'zapret-autopilot'
$StateFile  = Join-Path $DataDir 'state.json'
$TaskName   = 'zapret-autopilot'
$Repo       = 'Flowseal/zapret-discord-youtube'
$SelfFiles  = @('zapret-autopilot.bat', 'autopilot.ps1', 'README.md')

$ProgressPreference = 'SilentlyContinue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
# Английский вывод netsh/sc, как в service.bat
try { & chcp.com 437 > $null } catch {}

# ================= ВЫВОД =================

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Ok([string]$text)   { Say "  [OK] $text" Green }
function Warn([string]$text) { Say "  [?]  $text" Yellow }
function Bad([string]$text)  { Say "  [X]  $text" Red }
function Info([string]$text) { Say "  $text" Cyan }
function Step([string]$text) {
    Write-Host ""
    Say "============================================================" DarkCyan
    Say "  $text" Cyan
    Say "============================================================" DarkCyan
}

# Пауза, которая не съедает случайно нажатые во время тестов клавиши (как в test zapret.ps1)
function Wait-AnyKey([string]$message = 'Нажмите любую клавишу...') {
    Write-Host ""
    Say "  $message" Yellow
    try {
        while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
        [void][Console]::ReadKey($true)
    } catch {
        [void](Read-Host)
    }
}

function Ask-YesNo([string]$question, [bool]$default = $true) {
    $hint = 'Y/N, по умолчанию N'
    if ($default) { $hint = 'Y/N, по умолчанию Y' }
    $answer = Read-Host "  $question ($hint)"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    return ($answer.Trim() -match '^(y|yes|д|да)$')
}

# ================= СОСТОЯНИЕ =================

function Get-State {
    $state = @{}
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $obj = [IO.File]::ReadAllText($StateFile) | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $state[$p.Name] = $p.Value }
        } catch {
            Warn 'data\state.json повреждён — начинаю с чистого состояния'
        }
    }
    return $state
}

function Save-State([hashtable]$state) {
    if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
    [IO.File]::WriteAllText($StateFile, ($state | ConvertTo-Json -Depth 8), $Utf8NoBom)
}

# ================= НАСТРОЙКИ =================

$SettingsFile = Join-Path $DataDir 'settings.json'

function Get-DefaultSettings {
    return [ordered]@{
        Mode              = 'auto'                                       # auto | manual
        InstallDir        = (Join-Path ($env:SystemDrive + '\') 'zapret')
        DesktopShortcut   = $true
        StartMenuShortcut = $false
        Autostart         = $true
        UpdatePolicy      = 'broken'                                     # never | broken | always
        DefenderExclusion = 'ask'                                        # ask | always | never
        ClearDiscordCache = $true
        RemoveConflicts   = $true
        RequiredServices  = @()                                          # пусто = все группы из targets.txt
        SelfInstall       = $true
    }
}

function Get-Settings {
    $s = Get-DefaultSettings
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $obj = [IO.File]::ReadAllText($SettingsFile) | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) {
                if ($s.Contains($p.Name)) { $s[$p.Name] = $p.Value }
            }
            $s.RequiredServices = @($s.RequiredServices | Where-Object { $_ })
        } catch {
            Warn 'Файл настроек повреждён — использую стандартные настройки'
        }
    }
    return $s
}

function Save-Settings($s) {
    if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
    [IO.File]::WriteAllText($SettingsFile, ($s | ConvertTo-Json -Depth 4), $Utf8NoBom)
    $script:Settings = $s
}

function Test-AutoMode { return ($script:Settings.Mode -eq 'auto') }

# В режиме АВТО вопросы не задаются — берётся ответ по умолчанию
function Confirm-Action([string]$question, [bool]$default = $true) {
    if (Test-AutoMode) { return $default }
    return (Ask-YesNo $question $default)
}

# Обратный отсчёт с возможностью нажать клавишу. Возвращает нажатую клавишу (ConsoleKeyInfo) или $null.
function Wait-Countdown([int]$seconds, [string]$template) {
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { return $null }
    for ($s = $seconds; $s -gt 0; $s--) {
        Write-Host ("`r  " + ($template -f $s) + '   ') -NoNewline -ForegroundColor Yellow
        for ($i = 0; $i -lt 10; $i++) {
            if ([Console]::KeyAvailable) { Write-Host ""; return [Console]::ReadKey($true) }
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host ""
    return $null
}

# ================= ПАПКА ZAPRET =================

function Test-ZapretDir([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $dir 'service.bat')) -and
           (Test-Path -LiteralPath (Join-Path $dir 'bin\winws.exe'))
}

# Папка zapret, даже повреждённая (например, антивирус удалил winws.exe) — такую можно починить
function Test-ZapretDirLoose([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
    $service = Join-Path $dir 'service.bat'
    if (Test-Path -LiteralPath $service) {
        return [bool](Select-String -LiteralPath $service -Pattern 'zapret' -SimpleMatch -Quiet)
    }
    return (Test-Path -LiteralPath (Join-Path $dir 'bin') -PathType Container) -and
           [bool](Get-ChildItem -LiteralPath $dir -Filter 'general*.bat' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}

# Чего не хватает для работы; пустой список — всё на месте
$RequiredFiles = @('service.bat', 'bin\winws.exe', 'bin\WinDivert.dll', 'bin\WinDivert64.sys', 'bin\cygwin1.dll',
                   'lists\list-general.txt', 'utils\test zapret.ps1')
function Get-ZapretProblems([string]$dir) {
    if (-not (Test-ZapretDirLoose $dir)) { return @('папка zapret') }
    $missing = @($RequiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dir $_)) })
    if (-not (Get-ChildItem -LiteralPath $dir -Filter 'general*.bat' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        $missing += 'general*.bat'
    }
    return $missing
}

# Пути, на которых zapret, по опыту Flowseal, часто не работает
function Test-BadPath([string]$dir) {
    if ($dir -match '[\u0400-\u04FF]') { return 'в пути есть русские буквы' }
    if ($env:OneDrive -and $dir.StartsWith($env:OneDrive.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return 'папка лежит в OneDrive' }
    return $null
}

# Куда ставить zapret: папка из настроек (по умолчанию C:\zapret, как советует Flowseal).
# Если там уже лежит что-то чужое — подпапка zapret внутри неё или соседняя папка с номером.
function Get-DefaultInstallDir {
    $base = $script:Settings.InstallDir
    if ([string]::IsNullOrWhiteSpace($base)) { $base = Join-Path ($env:SystemDrive + '\') 'zapret' }
    $base = [IO.Path]::GetFullPath($base).TrimEnd('\')
    $candidates = @($base, (Join-Path $base 'zapret'), "$base-discord-youtube") + @(2..9 | ForEach-Object { "$base-$_" })
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c)) { return $c }
        if (-not (Get-ChildItem -LiteralPath $c -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $c }
    }
    return "$base-$(Get-Date -Format 'yyyyMMddHHmmss')"
}

# Проверка пути, который пользователь вводит в настройках. $null — путь годится.
function Test-InstallPath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return 'путь пустой' }
    # Относительный путь достроился бы от C:\Windows\System32 (рабочая папка программы с правами администратора)
    if ($path -notmatch '^[A-Za-z]:\\') { return 'нужен полный путь с буквой диска, например D:\zapret' }
    try { $full = [IO.Path]::GetFullPath($path).TrimEnd('\') } catch { return 'это не путь к папке' }
    if ($full.Length -le 3) { return 'нельзя ставить прямо в корень диска — укажите папку, например D:\zapret' }
    if (-not (Test-Path -LiteralPath ($full.Substring(0, 3)))) { return "диска $($full.Substring(0, 2)) нет" }
    $forbidden = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE,
                   [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments')) |
                 Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    if ($forbidden -contains $full) { return 'это системная папка — укажите отдельную папку для zapret' }
    return $null
}

function Get-ZapretVersion([string]$dir) {
    $file = Join-Path $dir 'service.bat'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $m = Select-String -LiteralPath $file -Pattern 'set "LOCAL_VERSION=([^"]+)"' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

function Find-ZapretDirs {
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($AppDir)
    $candidates.Add((Split-Path $AppDir -Parent))

    $roots = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        $env:USERPROFILE,
        (Split-Path $AppDir -Parent)
    )
    $roots += @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { $_.Root })

    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object { $candidates.Add($_.FullName) }
    }

    $seen = @{}
    foreach ($c in $candidates) {
        if (-not (Test-ZapretDirLoose $c)) { continue }
        $full = [IO.Path]::GetFullPath($c).TrimEnd('\')
        if ($seen.ContainsKey($full.ToLowerInvariant())) { continue }
        $seen[$full.ToLowerInvariant()] = $true
        $full
    }
}

# -NoPrompt — для автоматического режима: ничего не спрашивать; из нескольких найденных
# берётся целая папка с самой новой версией. $null — zapret на компьютере нет.
function Resolve-ZapretDir([hashtable]$state, [switch]$ForceAsk, [switch]$NoPrompt) {
    if (-not $ForceAsk -and (Test-ZapretDirLoose $state.ZapretDir)) { return $state.ZapretDir }

    $found = @(Find-ZapretDirs)
    $choice = $null

    if ($NoPrompt) {
        # Папка из настроек — в первую очередь
        $preferred = ''
        try { $preferred = [IO.Path]::GetFullPath($script:Settings.InstallDir).TrimEnd('\') } catch {}
        if ($preferred -and (Test-ZapretDirLoose $preferred)) { $found = @($preferred) + $found }
        if ($found.Count -eq 0) { return $null }
        $choice = @($found | Sort-Object `
            @{ Expression = { $_ -ieq $preferred }; Descending = $true },
            @{ Expression = { (Get-ZapretProblems $_).Count -eq 0 }; Descending = $true },
            @{ Expression = { $v = Get-ZapretVersion $_; try { [version]$v } catch { [version]'0.0' } }; Descending = $true })[0]
    } elseif ($found.Count -eq 1 -and -not $ForceAsk) {
        $choice = $found[0]
        Info "Найден zapret: $choice"
    } else {
        Write-Host ""
        if ($found.Count -gt 0) {
            Say "  Найденные папки zapret:" Cyan
            for ($i = 0; $i -lt $found.Count; $i++) { Say "    $($i + 1). $($found[$i])" Gray }
        } else {
            Warn 'Папка zapret не найдена автоматически'
        }
        $answer = Read-Host '  Номер из списка или полный путь к папке zapret (Enter — отмена)'
        if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
        $answer = $answer.Trim().Trim('"')
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $found.Count) {
            $choice = $found[[int]$answer - 1]
        } else {
            $choice = $answer
        }
        if (-not (Test-ZapretDirLoose $choice)) {
            Bad "'$choice' не похоже на папку zapret (нет service.bat и general*.bat)"
            return $null
        }
    }

    $state.ZapretDir = [IO.Path]::GetFullPath($choice).TrimEnd('\')
    Save-State $state
    return $state.ZapretDir
}

# Стратегии — тот же список и порядок, что в service.bat / test zapret.ps1
function Get-Configs([string]$dir) {
    Get-ChildItem -LiteralPath $dir -Filter '*.bat' -File |
        Where-Object { $_.Name -notlike 'service*' } |
        Sort-Object { [Regex]::Replace($_.Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') }) }
}

# ================= СЛУЖБЫ И ПРОЦЕССЫ =================
# Через sc.exe, а не Get-Service: ServiceController держит хэндл SCM, и удалённая служба
# WinDivert зависает в "marked for deletion" — после этого winws не может стартовать.

function Test-SvcExists([string]$name) {
    $null = & sc.exe query $name 2>&1
    return ($LASTEXITCODE -eq 0)
}

# 1 = STOPPED, 3 = STOP_PENDING, 4 = RUNNING (числа не зависят от языка Windows)
function Get-SvcState([string]$name) {
    $out = @(& sc.exe query $name 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { return 0 }
    $nums = @($out | ForEach-Object { if ($_ -match ':\s+(\d+)\s+\S') { [int]$matches[1] } })
    if ($nums.Count -ge 2) { return $nums[1] }
    return 0
}

function Remove-Svc([string]$name) {
    if (-not (Test-SvcExists $name)) { return $true }
    $null = & sc.exe stop $name 2>&1
    for ($i = 0; $i -lt 25; $i++) {
        if ((Get-SvcState $name) -le 1) { break }
        Start-Sleep -Milliseconds 200
    }
    $null = & sc.exe delete $name 2>&1
    Start-Sleep -Milliseconds 300
    return -not (Test-SvcExists $name)
}

function Test-WinwsRunning { return [bool](Get-Process -Name 'winws' -ErrorAction SilentlyContinue) }

function Stop-Winws {
    $procs = @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 20 -and (Test-WinwsRunning); $i++) { Start-Sleep -Milliseconds 200 }
}

function Get-ServiceStrategy {
    $key = 'HKLM:\System\CurrentControlSet\Services\zapret'
    return (Get-ItemProperty -LiteralPath $key -Name 'zapret-discord-youtube' -ErrorAction SilentlyContinue).'zapret-discord-youtube'
}

# Полная остановка обхода (аналог service.bat -> Remove Services)
function Stop-Bypass([switch]$KeepService) {
    if (-not $KeepService -and (Test-SvcExists 'zapret')) {
        $strategy = Get-ServiceStrategy
        Warn "Установлена служба zapret (стратегия: $strategy) — удаляю: с ней тесты и .bat не запускаются"
        if (Remove-Svc 'zapret') { Ok 'Служба zapret удалена' } else { Bad 'Не удалось удалить службу zapret' }
    }
    Stop-Winws
    foreach ($n in 'WinDivert', 'WinDivert14') { [void](Remove-Svc $n) }
}

# Как в general*.bat: окно cmd скрыто, сам .bat и winws — свёрнуты
function Get-LaunchArgs([string]$batPath) {
    return "/c start `"zapret`" /min cmd /c call `"$batPath`""
}

function Get-RunningStrategy {
    $p = Get-Process -Name 'winws' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return $null }
    if ($p.MainWindowTitle -match '^zapret:\s*(.+)$') { return "$($matches[1]).bat" }
    if (Test-SvcExists 'zapret') { return "служба zapret ($(Get-ServiceStrategy))" }
    return 'неизвестная стратегия'
}

function Start-Strategy([string]$dir, [string]$bat) {
    $path = Join-Path $dir $bat
    if (-not (Test-Path -LiteralPath $path)) {
        Bad "Файл '$bat' не найден в $dir — запустите полный цикл (пункт 1)"
        return $false
    }
    if (Test-SvcExists 'zapret') {
        Warn 'Установлена служба zapret — она конфликтует с запуском .bat, удаляю её'
        [void](Remove-Svc 'zapret')
    }
    Stop-Winws

    Info "Запускаю $bat (свёрнуто)..."
    Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList (Get-LaunchArgs $path) -WorkingDirectory $dir -WindowStyle Hidden | Out-Null

    for ($i = 0; $i -lt 50; $i++) {
        if (Test-WinwsRunning) { Ok "Обход работает: $bat"; return $true }
        Start-Sleep -Milliseconds 200
    }
    Bad 'winws.exe не запустился за 10 секунд. Запустите стратегию вручную из папки zapret и посмотрите ошибку'
    return $false
}

# ================= АВТОЗАПУСК =================

function Get-AutostartTask { return Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }

function Get-AutostartBat {
    $task = Get-AutostartTask
    if (-not $task) { return $null }
    $argsLine = @($task.Actions)[0].Arguments
    if ($argsLine -match 'call "([^"]+)"') { return $matches[1] }
    return $null
}

function Enable-Autostart([string]$batPath) {
    if (Test-SvcExists 'zapret') {
        Warn 'Служба zapret запустила бы второй экземпляр обхода — удаляю её'
        [void](Remove-Svc 'zapret')
    }

    $user = $null
    try { $user = (Get-CimInstance Win32_ComputerSystem).UserName } catch {}
    if (-not $user) { $user = "$env:USERDOMAIN\$env:USERNAME" }

    try {
        $action    = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument (Get-LaunchArgs $batPath) -WorkingDirectory (Split-Path $batPath -Parent)
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description 'zapret-autopilot: запуск лучшей стратегии zapret при входе в Windows (свёрнуто)' -Force -ErrorAction Stop | Out-Null
        Ok "Автозапуск включён: $(Split-Path $batPath -Leaf) будет стартовать при входе в Windows, свёрнутым"
        return $true
    } catch {
        Bad "Не удалось создать задачу автозапуска: $($_.Exception.Message)"
        return $false
    }
}

function Disable-Autostart {
    if (-not (Get-AutostartTask)) { Info 'Автозапуск и так выключен'; return }
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Ok 'Автозапуск выключен'
    } catch {
        Bad "Не удалось удалить задачу: $($_.Exception.Message)"
    }
}

# ================= ДИАГНОСТИКА =================
# Те же проверки, что service.bat -> Run Diagnostics, но без вопросов: всё, что можно
# исправить, исправляется сразу (конфликтующие службы удаляются, кэш Discord чистится).

function Clear-DiscordCache {
    $variants = @(
        @{ Proc = 'Discord';            Name = 'Discord';             Dir = Join-Path $env:APPDATA 'discord' },
        @{ Proc = 'DiscordPTB';         Name = 'Discord PTB';         Dir = Join-Path $env:APPDATA 'discordptb' },
        @{ Proc = 'DiscordCanary';      Name = 'Discord Canary';      Dir = Join-Path $env:APPDATA 'discordcanary' },
        @{ Proc = 'DiscordDevelopment'; Name = 'Discord Development'; Dir = Join-Path $env:APPDATA 'discorddevelopment' }
    )
    $found = $false
    foreach ($v in $variants) {
        if (-not (Test-Path -LiteralPath $v.Dir)) { continue }
        $found = $true

        $procs = @(Get-Process -Name $v.Proc -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) {
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
            $script:DiscordWasClosed = $true
            Ok "$($v.Name) закрыт"
        }

        foreach ($sub in 'Cache', 'Code Cache', 'GPUCache') {
            $path = Join-Path $v.Dir $sub
            if (-not (Test-Path -LiteralPath $path)) { continue }
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $path) { Bad "Не удалось удалить $path" } else { Ok "Удалён кэш $($v.Name)\$sub" }
        }
    }
    if (-not $found) { Warn 'Discord не найден — чистить нечего' }
}

function Invoke-Diagnostics([string]$dir) {
    $running = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
    function Find-Running([string]$pattern) {
        @($running | Where-Object { $_.Name -match $pattern -or $_.DisplayName -match $pattern })
    }

    Info "Zapret установлен в: $dir"

    # Base Filtering Engine
    if ((Get-SvcState 'BFE') -eq 4) {
        Ok 'Base Filtering Engine работает'
    } else {
        $null = & sc.exe start BFE 2>&1
        Start-Sleep -Seconds 1
        if ((Get-SvcState 'BFE') -eq 4) { Ok 'Base Filtering Engine был остановлен — запустил' }
        else { Bad 'Base Filtering Engine не запущен и не запускается — без него zapret не работает' }
    }

    # Прокси
    $inet = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($inet -and $inet.ProxyEnable -eq 1) {
        Warn "Включён системный прокси: $($inet.ProxyServer). Отключите, если не пользуетесь им"
    } else {
        Ok 'Системный прокси выключен'
    }

    # TCP timestamps
    $tsLine = @(& netsh.exe interface tcp show global) | Where-Object { $_ -match 'timestamps' } | Select-Object -First 1
    if ($tsLine -and $tsLine -match 'enabled') {
        Ok 'TCP timestamps включены'
    } else {
        $null = & netsh.exe interface tcp set global timestamps=enabled 2>&1
        if ($LASTEXITCODE -ne 0) { Bad 'Не удалось включить TCP timestamps' }
        elseif ($tsLine) { Ok 'TCP timestamps были выключены — включил' }
        else { Ok 'TCP timestamps включены' }
    }

    # Конфликтующий софт
    if (Get-Process -Name 'AdguardSvc' -ErrorAction SilentlyContinue) {
        Bad 'Запущен Adguard — он может ломать Discord (github.com/Flowseal/zapret-discord-youtube/issues/417)'
    } else { Ok 'Adguard не найден' }

    if ((Find-Running 'Killer').Count) { Bad 'Найдены службы Killer — они конфликтуют с zapret' } else { Ok 'Killer не найден' }

    if (@($running | Where-Object { "$($_.Name) $($_.DisplayName)" -match 'Intel' -and "$($_.Name) $($_.DisplayName)" -match 'Connectivity' -and "$($_.Name) $($_.DisplayName)" -match 'Network' }).Count) {
        Bad 'Найдена Intel Connectivity Network Service — она конфликтует с zapret'
    } else { Ok 'Intel Connectivity не найден' }

    if ((Find-Running 'TracSrvWrapper|EPWD').Count) { Bad 'Найдены службы Check Point — они конфликтуют с zapret, удалите Check Point' } else { Ok 'Check Point не найден' }

    if ((Find-Running 'SmartByte').Count) { Bad 'Найдены службы SmartByte — отключите их в services.msc' } else { Ok 'SmartByte не найден' }

    # Путь
    if ($dir -match '[\u0400-\u04FF]') {
        Warn 'В пути к zapret есть кириллица. Если обход не работает — перенесите папку, например в C:\zapret'
    } else { Ok 'В пути нет кириллицы' }

    if ($env:OneDrive -and $dir.StartsWith($env:OneDrive.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Bad 'Zapret лежит в папке OneDrive. Если обход не работает — перенесите его, например в C:\zapret'
    } else { Ok 'Zapret не в OneDrive' }

    if (-not (Get-ChildItem -LiteralPath (Join-Path $dir 'bin') -Filter '*.sys' -ErrorAction SilentlyContinue)) {
        Bad 'В bin нет WinDivert64.sys — его мог удалить антивирус'
    }

    # VPN
    $vpn = Find-Running 'VPN'
    if ($vpn.Count) {
        Warn "Запущены VPN-службы: $(($vpn | ForEach-Object { $_.Name }) -join ', '). Некоторые VPN конфликтуют с zapret — отключите их"
    } else { Ok 'VPN-служб не найдено' }

    # Secure DNS
    $doh = @(Get-ChildItem -Recurse -Path 'HKLM:\System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\' -ErrorAction SilentlyContinue |
             Get-ItemProperty -ErrorAction SilentlyContinue | Where-Object { $_.DohFlags -gt 0 })
    if ($doh.Count) { Ok 'Secure DNS (DoH) настроен' }
    else { Warn 'Secure DNS не настроен: включите DoH в браузере (не провайдерский DNS) или в параметрах Windows 11' }

    # hosts
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if ((Test-Path -LiteralPath $hosts) -and (Select-String -LiteralPath $hosts -Pattern 'youtube\.com|youtu\.be' -Quiet)) {
        Warn 'В hosts есть записи для youtube.com / youtu.be — они могут мешать YouTube'
    }

    # WinDivert висит без winws
    $wdState = Get-SvcState 'WinDivert'
    if (-not (Test-WinwsRunning) -and ($wdState -eq 4 -or $wdState -eq 3)) {
        Warn 'winws не запущен, а служба WinDivert активна — удаляю WinDivert...'
        if (Remove-Svc 'WinDivert') {
            Ok 'WinDivert удалён'
        } elseif (Test-SvcExists 'GoodbyeDPI') {
            Warn 'WinDivert держит GoodbyeDPI — удаляю GoodbyeDPI и пробую снова'
            [void](Remove-Svc 'GoodbyeDPI')
            if (Remove-Svc 'WinDivert') { Ok 'WinDivert удалён после удаления GoodbyeDPI' }
            else { Bad 'WinDivert всё ещё не удаляется — проверьте, какой ещё обход его использует' }
        } else {
            Bad 'Не удалось удалить WinDivert — проверьте, какой ещё обход его использует'
        }
    }

    # Другие обходы
    $conflicts = @('GoodbyeDPI', 'discordfix_zapret', 'winws1', 'winws2' | Where-Object { Test-SvcExists $_ })
    if ($conflicts.Count) {
        if (-not $script:Settings.RemoveConflicts) {
            Bad "Найдены конфликтующие службы обхода: $($conflicts -join ', '). Удаление выключено в настройках — zapret может не работать"
        } elseif (Confirm-Action "Найдены мешающие службы обхода: $($conflicts -join ', '). Удалить их?" $true) {
            Warn "Удаляю конфликтующие службы обхода: $($conflicts -join ', ')"
            foreach ($s in $conflicts) {
                if (Remove-Svc $s) { Ok "Служба $s удалена" } else { Bad "Не удалось удалить службу $s" }
            }
            foreach ($n in 'WinDivert', 'WinDivert14') { [void](Remove-Svc $n) }
        }
    } else { Ok 'Других обходов (GoodbyeDPI и т.п.) не найдено' }

    # Кэш Discord
    if ($script:Settings.ClearDiscordCache) {
        Info 'Чищу кэш Discord (Stable, PTB, Canary, Development)...'
        Clear-DiscordCache
    } else {
        Info 'Очистка кэша Discord выключена в настройках'
    }
}

# ================= ТЕСТЫ =================

# Группы сервисов из заголовков "### Discord" в utils\targets.txt
function Get-TargetGroups([string]$dir) {
    $map = @{}
    $file = Join-Path $dir 'utils\targets.txt'
    if (-not (Test-Path -LiteralPath $file)) { return $map }
    $group = 'Прочее'
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        if ($line -match '^\s*###\s*(.+?)\s*$') { $group = ($matches[1] -replace '\s*\(.*\)$', ''); continue }
        if ($line -match '^\s*(\w+)\s*=\s*"(.+)"\s*$') { $map[$matches[1]] = $group }
    }
    return $map
}

function Get-GroupFor([hashtable]$groups, [string]$name) {
    if ($groups.ContainsKey($name)) { return $groups[$name] }
    # Цели по умолчанию из test zapret.ps1 называются "Discord Main", "YouTube Web"...
    return ($name -split '\s+')[0]
}

# Разбор utils\test results\test_results_*.txt:
#   Config: general (ALT).bat (Type: standard)
#     DiscordMain : HTTP:OK    TLS1.2:OK    TLS1.3:OK    | Ping: 23 ms
function Read-TestResults([string]$file, [string]$dir, $configs) {
    $byConfig = @{}
    $current = $null
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        if ($line -match '^=== ANALYTICS ===') { break }
        if ($line -match '^Config:\s*(.+?)\s*\(Type:\s*\w+\)\s*$') {
            $current = $matches[1]
            $byConfig[$current] = New-Object System.Collections.ArrayList
            continue
        }
        if ($current -and $line -match '^\s{2}(\S.*?)\s:\s(.*?)\|\s*Ping:\s*(.*)$') {
            [void]$byConfig[$current].Add(@{
                Name   = $matches[1].Trim()
                Tokens = @($matches[2].Trim() -split '\s+' | Where-Object { $_ })
                Ping   = $matches[3].Trim()
            })
        }
    }

    $groups = Get-TargetGroups $dir
    $list = @()
    $index = 0
    foreach ($cfg in $configs) {
        $index++
        $r = [ordered]@{
            Config = $cfg.Name; Index = $index; Started = $false; Full = $false
            OkTokens = 0; TotalTokens = 0; TargetsOk = 0; TargetsTotal = 0
            ServicesOk = 0; PingOk = 0; Failed = @(); Services = @()
        }

        if ($byConfig.ContainsKey($cfg.Name)) {
            $r.Started = $true
            $svc = [ordered]@{}
            foreach ($t in $byConfig[$cfg.Name]) {
                if ($t.Ping -match '^\d') { $r.PingOk++ }
                if ($t.Tokens.Count -eq 0) { continue }   # PING-only цель — информационная

                # UNSUP = curl не умеет этот TLS — не считается ни успехом, ни провалом
                $real = @($t.Tokens | Where-Object { $_ -notmatch ':UNSUP' })
                if ($real.Count -eq 0) { continue }
                $ok = @($real | Where-Object { $_ -match ':OK$' }).Count
                $r.OkTokens += $ok
                $r.TotalTokens += $real.Count
                $r.TargetsTotal++

                $group = Get-GroupFor $groups $t.Name
                if (-not $svc.Contains($group)) { $svc[$group] = @{ Ok = 0; Total = 0 } }
                $svc[$group].Total++
                if ($ok -eq $real.Count) {
                    $r.TargetsOk++
                    $svc[$group].Ok++
                } else {
                    $r.Failed += $t.Name
                }
            }
            $r.Services = @($svc.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Ok = $svc[$_].Ok; Total = $svc[$_].Total } })
            $r.ServicesOk = @($r.Services | Where-Object { $_.Ok -eq $_.Total }).Count
            # «Работает полностью» = открываются все обязательные сервисы из настроек (по умолчанию — все)
            $required = @($r.Services | Where-Object { @($script:Settings.RequiredServices) -contains $_.Name })
            if ($required.Count -eq 0) { $required = @($r.Services) }
            $r.Full = ($required.Count -gt 0 -and @($required | Where-Object { $_.Ok -ne $_.Total }).Count -eq 0)
        }
        $list += [pscustomobject]$r
    }

    # Лучшая: открывает всё -> больше сервисов целиком -> больше целей -> больше OK -> пинг
    return @($list | Sort-Object -Property `
        @{ Expression = 'Started';    Descending = $true },
        @{ Expression = 'Full';       Descending = $true },
        @{ Expression = 'ServicesOk'; Descending = $true },
        @{ Expression = 'TargetsOk';  Descending = $true },
        @{ Expression = 'OkTokens';   Descending = $true },
        @{ Expression = 'PingOk';     Descending = $true },
        @{ Expression = 'Index';      Descending = $false })
}

# Запуск родного utils\test zapret.ps1 из service.bat (Run Tests -> Standard -> All configs).
# Ответы на его вопросы подаются через stdin, результат читается из файла, который он сохраняет.
function Invoke-ZapretTests([string]$dir) {
    $script = Join-Path $dir 'utils\test zapret.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        Bad "Не найден $script — в этой версии zapret нет тестов"
        return $null
    }
    if (-not (Get-Command 'curl.exe' -ErrorAction SilentlyContinue)) {
        Bad 'Не найден curl.exe — без него тесты zapret не работают'
        return $null
    }

    $configs = @(Get-Configs $dir)
    if ($configs.Count -eq 0) { Bad 'В папке zapret нет ни одного general*.bat'; return $null }

    if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
    $answers = Join-Path $DataDir 'test-answers.txt'
    # 1 = Standard tests (HTTP/ping), 1 = All configs
    [IO.File]::WriteAllText($answers, "1`r`n1`r`n", (New-Object System.Text.ASCIIEncoding))

    $resultsDir = Join-Path $dir 'utils\test results'
    $started = Get-Date
    $timeoutSec = [Math]::Max(600, $configs.Count * 90 + 300)

    Info "Стратегий: $($configs.Count). Это займёт несколько минут, окно не закрывайте."
    Write-Host ""

    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`"" `
        -WorkingDirectory (Join-Path $dir 'utils') -NoNewWindow -RedirectStandardInput $answers -PassThru

    if (-not $proc.WaitForExit($timeoutSec * 1000)) {
        Bad "Тесты не закончились за $([int]($timeoutSec / 60)) мин — прерываю (возможно, в новой версии изменились вопросы test zapret.ps1)"
        $null = & taskkill.exe /PID $proc.Id /T /F 2>&1
        Stop-Winws
        return $null
    }
    Stop-Winws

    $file = Get-ChildItem -LiteralPath $resultsDir -Filter 'test_results_*.txt' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-5) } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $file) {
        Bad 'Тест не сохранил файл с результатами — смотрите вывод выше'
        return $null
    }

    $results = Read-TestResults $file.FullName $dir $configs
    if (-not @($results | Where-Object { $_.Started }).Count -and -not @($results | Where-Object { $_.TargetsTotal }).Count) {
        Warn "Не удалось разобрать $($file.Name) или ни одна стратегия не запустилась"
    }
    return $results
}

function Show-Results($results) {
    $results = @($results)
    if ($results.Count -eq 0) { Info 'Результатов пока нет'; return }

    $started = @($results | Where-Object { $_.Started })
    $svcNames = @()
    if ($started.Count) { $svcNames = @($started[0].Services | ForEach-Object { $_.Name }) }
    $nameW = [int][Math]::Max(12, ($results | ForEach-Object { $_.Config.Length } | Measure-Object -Maximum).Maximum)

    Write-Host ""
    $head = '  #   ' + 'Стратегия'.PadRight($nameW) + '  '
    foreach ($s in $svcNames) { $head += $s.PadRight([Math]::Max(7, $s.Length) + 2) }
    $head += 'Цели    Запросы'
    Say $head White

    $rank = 0
    foreach ($r in $results) {
        $rank++
        $line = '  ' + "$rank".PadRight(4) + $r.Config.PadRight($nameW) + '  '
        if (-not $r.Started) {
            Say ($line + 'не запустилась') DarkGray
            continue
        }
        foreach ($s in $svcNames) {
            $w = [Math]::Max(7, $s.Length) + 2
            $sv = @($r.Services | Where-Object { $_.Name -eq $s }) | Select-Object -First 1
            $cell = '-'
            if ($sv) { if ($sv.Ok -eq $sv.Total) { $cell = 'OK' } else { $cell = "$($sv.Ok)/$($sv.Total)" } }
            $line += $cell.PadRight($w)
        }
        $line += "$($r.TargetsOk)/$($r.TargetsTotal)".PadRight(8) + "$($r.OkTokens)/$($r.TotalTokens)"
        if ($rank -eq 1) { $line += '   <- лучшая' }

        $color = 'Red'
        if ($r.Full) { $color = 'Green' } elseif ($r.TargetsOk -gt 0) { $color = 'Yellow' }
        Say $line $color
    }
    Write-Host ""
    Say '  OK — все цели сервиса открываются; 2/4 — открывается часть; "Цели" — сколько адресов открылось целиком' DarkGray
}

# ================= ОБНОВЛЕНИЕ ZAPRET =================

function Get-LatestRelease {
    try {
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'zapret-autopilot' } -TimeoutSec 15
        $asset = @($r.assets | Where-Object { $_.name -like '*.zip' }) | Select-Object -First 1
        if ($asset) { return @{ Version = ($r.tag_name -replace '^v', ''); Url = $asset.browser_download_url } }
    } catch {}
    try {
        $v = (Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$Repo/main/.service/version.txt" -Headers @{ 'Cache-Control' = 'no-cache' } -TimeoutSec 10).Content.Trim()
        if ($v) { return @{ Version = $v; Url = "https://github.com/$Repo/releases/download/$v/zapret-discord-youtube-$v.zip" } }
    } catch {}
    return $null
}

# >0 — $a новее $b
function Compare-Version([string]$a, [string]$b) {
    try { return ([version]$a).CompareTo([version]$b) } catch {
        if ($a -eq $b) { return 0 }
        return 1
    }
}

# Что из старой папки сохраняется при удалении: bin (он перезаписывается новым) и сам autopilot, если лежит внутри
function Get-KeepNames([string]$dir) {
    $keep = @('bin', 'autopilot')
    $app = $AppDir.TrimEnd('\')
    if ($app -ieq $dir) {
        $keep += @('zapret-autopilot.bat', 'autopilot.ps1', 'README.md', 'data')
    } elseif ($app.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $keep += $app.Substring($dir.Length + 1).Split('\')[0]
    }
    return $keep
}

# Защита от удаления не той папки.
# -AllowBroken — для отката: после неудачного обновления в папке может уже не быть service.bat
function Test-SafeToWipe([string]$dir, [switch]$AllowBroken) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return 'папка zapret не выбрана' }
    if (-not $AllowBroken -and -not (Test-ZapretDir $dir)) { return 'в папке нет service.bat и bin\winws.exe' }
    if ($dir.Length -le 3) { return 'это корень диска' }

    $forbidden = @($env:USERPROFILE, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:APPDATA, $env:LOCALAPPDATA, $env:TEMP,
                   [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), (Join-Path $env:USERPROFILE 'Downloads')) |
                 Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    if ($forbidden -contains $dir) { return 'это системная или пользовательская папка, а не отдельная папка zapret' }

    # Чужие файлы в папке — если их много, скорее всего путь указан неверно
    $known = '^(bin|lists|utils|\.service|\.git.*|service\.bat|general.*\.bat|.*\.(md|txt)|LICENSE.*)$'
    $keep = Get-KeepNames $dir
    $foreignBytes = 0
    Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -notmatch $known -and $keep -notcontains $_.Name } | ForEach-Object {
        if ($_.PSIsContainer) {
            $foreignBytes += (Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        } else {
            $foreignBytes += $_.Length
        }
    }
    if ($foreignBytes -gt 50MB) { return "в папке $([int]($foreignBytes / 1MB)) МБ посторонних файлов — похоже, это не только zapret" }
    return $null
}

# Копия папки zapret в data\backup\zapret_<версия>_<дата> плюс <то же>.json со стратегией и автозапуском
# на момент копии — чтобы откат вернул не только файлы. Хранятся три последние; -Protect не удаляется.
function New-ZapretBackup([hashtable]$state, [string]$dir, [string]$Protect) {
    $keep = Get-KeepNames $dir
    $version = Get-ZapretVersion $dir
    if (-not $version) { $version = 'unknown' }
    $backupRoot = Join-Path $DataDir 'backup'
    $base = Join-Path $backupRoot ("zapret_{0}_{1}" -f $version, (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    # Две копии в одну секунду (откат сразу после обновления) не должны слиться в одну папку
    $backup = $base
    for ($n = 2; Test-Path -LiteralPath $backup; $n++) { $backup = "${base}_$n" }
    try {
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        Get-ChildItem -LiteralPath $dir -Force | Where-Object { $keep -notcontains $_.Name -or $_.Name -eq 'bin' } |
            Copy-Item -Destination $backup -Recurse -Force -ErrorAction Stop
    } catch {
        Bad "Не удалось сделать резервную копию: $($_.Exception.Message)"
        Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }

    $meta = [ordered]@{
        Version      = $version
        Created      = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        ZapretDir    = $dir
        BestConfig   = $state.BestConfig
        BestFull     = [bool]$state.BestFull
        LastRun      = $state.LastRun
        Results      = $state.Results
        AutostartBat = Get-AutostartBat
    }
    [IO.File]::WriteAllText($backup + '.json', ($meta | ConvertTo-Json -Depth 8), $Utf8NoBom)

    Get-ChildItem -LiteralPath $backupRoot -Directory | Sort-Object CreationTime -Descending | Select-Object -Skip 3 |
        Where-Object { $_.FullName -ine $Protect } | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($_.FullName + '.json') -Force -ErrorAction SilentlyContinue
        }

    Ok "Резервная копия v${version}: $backup"
    return $backup
}

function Get-ZapretBackups {
    $root = Join-Path $DataDir 'backup'
    if (-not (Test-Path -LiteralPath $root)) { return }
    Get-ChildItem -LiteralPath $root -Directory | Sort-Object CreationTime -Descending | ForEach-Object {
        $meta = $null
        $metaFile = $_.FullName + '.json'
        if (Test-Path -LiteralPath $metaFile) {
            try { $meta = [IO.File]::ReadAllText($metaFile) | ConvertFrom-Json } catch {}
        }
        [pscustomobject]@{
            Path    = $_.FullName
            Meta    = $meta
            Version = $(if ($meta) { $meta.Version } else { ($_.Name -split '_')[1] })
            Created = $(if ($meta) { $meta.Created } else { $_.CreationTime.ToString('yyyy-MM-dd HH:mm') })
        }
    }
}

# Кладёт файлы zapret из $srcRoot в $dir: всё, кроме bin (и самого autopilot), удаляется,
# bin перезаписывается пофайлово, лишнее из старого bin убирается. Возвращает список того, что не скопировалось.
function Install-ZapretFiles([string]$srcRoot, [string]$dir) {
    $keep = Get-KeepNames $dir

    $leftovers = @()
    Get-ChildItem -LiteralPath $dir -Force | Where-Object { $keep -notcontains $_.Name } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $_.FullName) { $leftovers += $_.Name }
    }
    if ($leftovers.Count) { Warn "Не удалось удалить: $($leftovers -join ', ') — будут перезаписаны" }

    $binDir = Join-Path $dir 'bin'
    if (-not (Test-Path -LiteralPath $binDir)) { New-Item -ItemType Directory -Path $binDir | Out-Null }
    $failed = @()
    foreach ($item in Get-ChildItem -LiteralPath $srcRoot -Force) {
        try {
            if ($item.Name -eq 'bin') {
                Get-ChildItem -LiteralPath $item.FullName -Force | Copy-Item -Destination $binDir -Recurse -Force -ErrorAction Stop
            } else {
                Copy-Item -LiteralPath $item.FullName -Destination $dir -Recurse -Force -ErrorAction Stop
            }
        } catch {
            $failed += $item.Name
        }
    }

    $srcBin = @(Get-ChildItem -LiteralPath (Join-Path $srcRoot 'bin') -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if ($srcBin.Count) {
        Get-ChildItem -LiteralPath $binDir -Force | Where-Object { $srcBin -notcontains $_.Name } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $failed
}

# Скачивает и распаковывает релиз в data\download; возвращает папку с service.bat или $null
function Get-ReleaseRoot($latest) {
    $work = Join-Path $DataDir 'download'
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $zip = Join-Path $work 'zapret.zip'
    $extract = Join-Path $work 'x'
    try {
        Info "Скачиваю zapret $($latest.Version) с GitHub..."
        Invoke-WebRequest -UseBasicParsing -Uri $latest.Url -OutFile $zip -TimeoutSec 180
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $extract)
    } catch {
        Bad "Не удалось скачать или распаковать zapret: $($_.Exception.Message)"
        return $null
    }

    $root = $extract
    if (-not (Test-ZapretDir $root)) {
        $root = @(Get-ChildItem -LiteralPath $extract -Directory | Where-Object { Test-ZapretDir $_.FullName } | ForEach-Object { $_.FullName }) | Select-Object -First 1
    }
    if (-not $root) { Bad 'В скачанном архиве нет service.bat и bin\winws.exe'; return $null }
    Ok "zapret $($latest.Version) скачан"
    return $root
}

function Clear-Download { Remove-Item -LiteralPath (Join-Path $DataDir 'download') -Recurse -Force -ErrorAction SilentlyContinue }

function Get-LatestOrFail {
    Info 'Проверяю последнюю версию zapret на GitHub...'
    $latest = Get-LatestRelease
    if (-not $latest) {
        Bad 'Не удалось связаться с GitHub. Проверьте, что интернет работает, и запустите программу ещё раз'
    }
    return $latest
}

# Возвращает 'updated' | 'latest' | 'failed'.
# -Repair — починка повреждённой папки: ставится последняя версия, даже если она та же самая.
# -AskFirst — в ручном режиме спросить перед обновлением (в режиме АВТО — без вопроса)
function Update-Zapret([hashtable]$state, [switch]$OnlyIfNewer, [switch]$Repair, [switch]$AskFirst) {
    $dir = $state.ZapretDir
    $reason = Test-SafeToWipe $dir -AllowBroken:$Repair
    if ($reason) { Bad "Отказываюсь переустанавливать zapret в '$dir': $reason"; return 'failed' }

    $latest = Get-LatestOrFail
    if (-not $latest) { return 'failed' }

    $local = Get-ZapretVersion $dir
    if ($local) { Info "Установлена: $local, на GitHub: $($latest.Version)" }
    if ($OnlyIfNewer -and -not $Repair -and $local -and (Compare-Version $latest.Version $local) -le 0) {
        Ok 'У вас уже последняя версия zapret'
        return 'latest'
    }
    if ($AskFirst -and -not (Confirm-Action "Обновить zapret с $local до $($latest.Version)? Старая версия сохранится для отката" $true)) {
        Info 'Обновление пропущено'
        return 'latest'
    }

    # 1. Скачать и распаковать (до остановки обхода — пока он ещё помогает достучаться до GitHub)
    $newRoot = Get-ReleaseRoot $latest
    if (-not $newRoot) { return 'failed' }

    # 2. Остановить обход, чтобы файлы bin не были заняты
    Stop-Bypass

    # 3. Резервная копия старой папки — из неё работает откат
    $backup = New-ZapretBackup $state $dir
    if (-not $backup) { Bad 'Обновление отменено: без резервной копии старый zapret не удаляю'; return 'failed' }

    # 4. Пользовательские настройки, которые не должны потеряться
    $userFiles = @()
    $userFiles += @(Get-ChildItem -LiteralPath (Join-Path $dir 'lists') -Filter '*-user.txt' -File -ErrorAction SilentlyContinue | ForEach-Object { "lists\$($_.Name)" })
    if (Test-Path -LiteralPath (Join-Path $dir 'utils\game_filter.enabled')) { $userFiles += 'utils\game_filter.enabled' }
    $hadUpdateCheck = Test-Path -LiteralPath (Join-Path $dir 'utils\check_updates.enabled')

    # 5-6. Удалить старый zapret, кроме bin, и поставить новый; bin — пофайлово поверх старого
    Info 'Удаляю старую версию (папка bin остаётся и будет перезаписана)...'
    $failed = @(Install-ZapretFiles $newRoot $dir)

    # 7. Вернуть пользовательские файлы
    foreach ($rel in $userFiles) {
        $src = Join-Path $backup $rel
        $dst = Join-Path $dir $rel
        if (Test-Path -LiteralPath $src) {
            New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue
        }
    }
    $updFlag = Join-Path $dir 'utils\check_updates.enabled'
    if (-not $hadUpdateCheck) { Remove-Item -LiteralPath $updFlag -Force -ErrorAction SilentlyContinue }
    if ($userFiles.Count) { Ok "Сохранены ваши настройки: $($userFiles -join ', ')" }

    Clear-Download

    if ($failed.Count) {
        Bad "Не удалось скопировать: $($failed -join ', '). Верните прошлую версию пунктом меню «Откатить обновление»"
        return 'failed'
    }
    # Скопировалось, но файлы уже исчезли — их удаляет антивирус; с этим разбирается Repair-Zapret
    if (-not (Test-ZapretDir $dir)) { Warn "Сразу после установки пропали: $(@(Get-ZapretProblems $dir) -join ', ')" }

    $state.Version = Get-ZapretVersion $dir
    $state.BestConfig = $null
    $state.BestFull = $false
    $state.Results = @()
    Save-State $state
    if ($Repair) { Ok "Zapret переустановлен начисто (v$($state.Version)): $dir" }
    else { Ok "Zapret обновлён до $($state.Version): $dir" }
    return 'updated'
}

# Установка на компьютер, где zapret нет (или он лежит в неудачном месте): последняя версия в C:\zapret
function Install-ZapretFresh([hashtable]$state) {
    $latest = Get-LatestOrFail
    if (-not $latest) { return $false }
    $root = Get-ReleaseRoot $latest
    if (-not $root) { return $false }

    $target = Get-DefaultInstallDir
    Info "Устанавливаю zapret в $target..."
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $failed = @(Install-ZapretFiles $root $target)
    Clear-Download

    if ($failed.Count) {
        Bad "Установка не удалась: не скопировалось $($failed -join ', ')"
        return $false
    }
    if (-not (Test-ZapretDir $target)) { Warn "Сразу после установки пропали: $(@(Get-ZapretProblems $target) -join ', ')" }

    $state.ZapretDir = $target
    $state.Version = Get-ZapretVersion $target
    $state.BestConfig = $null
    $state.BestFull = $false
    $state.Results = @()
    Save-State $state
    Ok "zapret $($state.Version) установлен в $target"
    return $true
}

# Защитник Windows считает winws.exe и WinDivert «HackTool» и удаляет их сразу после установки.
# Исключение добавляется только для папки zapret и только с согласия пользователя.
function Add-AntivirusExclusion([string]$dir, [string[]]$missing) {
    Write-Host ""
    Warn "Сразу после установки пропали файлы: $($missing -join ', ')"
    Warn 'Так делает антивирус: Защитник Windows считает winws.exe и WinDivert «хакерским инструментом» (HackTool),'
    Warn 'хотя это просто программа обхода блокировок. Без этих файлов zapret работать не может.'

    if (-not (Get-Command 'Add-MpPreference' -ErrorAction SilentlyContinue)) { return $false }
    switch ($script:Settings.DefenderExclusion) {
        'never'  { Info 'Исключения в Защитнике выключены в настройках'; return $false }
        'always' { Info 'Добавляю папку zapret в исключения Защитника (так задано в настройках)' }
        default  { if (-not (Ask-YesNo "Добавить папку '$dir' в исключения Защитника Windows? (только эту папку)" $true)) { return $false } }
    }
    try {
        Add-MpPreference -ExclusionPath $dir -ErrorAction Stop
        Ok 'Папка zapret добавлена в исключения Защитника Windows'
        return $true
    } catch {
        Bad "Защитник Windows не принял исключение: $($_.Exception.Message)"
        return $false
    }
}

function Show-AntivirusHelp([string]$dir) {
    Write-Host ""
    Bad 'Антивирус удаляет файлы zapret.'
    Say "  Добавьте папку $dir в исключения вашего антивируса" Yellow
    Say '  (в Защитнике Windows: Безопасность Windows -> Защита от вирусов и угроз -> Управление настройками -> Исключения),' Yellow
    Say '  затем снова запустите программу.' Yellow
}

# Проверяет файлы zapret и чинит папку чистой переустановкой. $true — всё на месте.
function Repair-Zapret([hashtable]$state) {
    $dir = $state.ZapretDir
    $missing = @(Get-ZapretProblems $dir)
    if ($missing.Count -eq 0) { Ok 'Все файлы zapret на месте'; return $true }

    Warn "Zapret повреждён — не хватает: $($missing -join ', ')"
    if (-not (Confirm-Action 'Переустановить zapret начисто? Ваши списки сохранятся, старая папка — в резервной копии' $true)) { return $false }
    Info 'Переустанавливаю начисто...'
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if ((Update-Zapret $state -Repair) -ne 'updated') { return $false }

        # Антивирус срабатывает не мгновенно
        Start-Sleep -Seconds 4
        $missing = @(Get-ZapretProblems $dir)
        if ($missing.Count -eq 0) { Ok 'Zapret починен'; return $true }

        if ($attempt -eq 1 -and -not (Add-AntivirusExclusion $dir $missing)) { break }
    }
    Show-AntivirusHelp $dir
    return $false
}

# ================= САМОУСТАНОВКА =================
# Программа копирует себя в <zapret>\autopilot и кладёт ярлык «Zapret» на рабочий стол:
# скачанный архив можно удалить, а запускать всё одним ярлыком.

function Get-ScriptVersion([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $m = Select-String -LiteralPath $path -Pattern "^\`$AppVersion\s*=\s*'([^']+)'" | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

# Куда кладутся ярлыки — отдельной функцией, чтобы их можно было подменить в тестах
function Get-ShortcutPath([string]$where) {
    if ($where -eq 'desktop') { return Join-Path ([Environment]::GetFolderPath('Desktop')) 'Zapret.lnk' }
    return Join-Path ([Environment]::GetFolderPath('Programs')) 'Zapret.lnk'
}

# Ярлык «Zapret» на рабочем столе и в меню «Пуск» — по настройкам; выключенный ярлык удаляется
# (только если это наш ярлык, чужой файл с таким именем не трогаем)
function Update-Shortcuts([string]$launcher) {
    $shell = New-Object -ComObject WScript.Shell
    $places = @(
        @{ Where = 'desktop';   On = [bool]$script:Settings.DesktopShortcut;   Name = 'на рабочем столе' },
        @{ Where = 'startmenu'; On = [bool]$script:Settings.StartMenuShortcut; Name = 'в меню «Пуск»' }
    )
    foreach ($p in $places) {
        $lnkPath = Get-ShortcutPath $p.Where
        try {
            $existing = $null
            if (Test-Path -LiteralPath $lnkPath) { $existing = $shell.CreateShortcut($lnkPath).TargetPath }
            if (-not $p.On) {
                if ($existing -and $existing -like '*zapret-autopilot.bat') {
                    Remove-Item -LiteralPath $lnkPath -Force -ErrorAction Stop
                    Ok "Ярлык $($p.Name) убран"
                }
                continue
            }
            if (-not $launcher -or $existing -ieq $launcher) { continue }
            $lnk = $shell.CreateShortcut($lnkPath)
            $lnk.TargetPath = $launcher
            $lnk.WorkingDirectory = Split-Path $launcher -Parent
            $lnk.Description = 'Zapret: включить, выключить или починить обход блокировок'
            $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
            $lnk.Save()
            Ok "Ярлык «Zapret» $($p.Name) — через него программа открывается в следующий раз"
        } catch {
            Warn "Не удалось обновить ярлык $($p.Name): $($_.Exception.Message)"
        }
    }
}

# Копия программы в <zapret>\autopilot (если включено) и ярлыки на неё
function Install-Self([string]$dir) {
    if (-not $script:Settings.SelfInstall) {
        Update-Shortcuts (Join-Path $AppDir 'zapret-autopilot.bat')
        return
    }
    $target = Join-Path $dir 'autopilot'
    if ($AppDir.TrimEnd('\') -ine $target) {
        $installed = Get-ScriptVersion (Join-Path $target 'autopilot.ps1')
        if (-not $installed -or (Compare-Version $AppVersion $installed) -ge 0) {
            try {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
                foreach ($f in $SelfFiles) {
                    $src = Join-Path $AppDir $f
                    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $target -Force -ErrorAction Stop }
                }
                # Пометка «скачано из интернета» копируется вместе с файлом — без этого ярлык
                # при каждом запуске показывал бы предупреждение безопасности Windows
                Get-ChildItem -LiteralPath $target -File | Unblock-File -ErrorAction SilentlyContinue
            } catch {
                Warn "Не удалось скопировать программу в $target : $($_.Exception.Message)"
                return
            }
        }
    }

    $launcher = Join-Path $target 'zapret-autopilot.bat'
    if (-not (Test-Path -LiteralPath $launcher)) { $launcher = Join-Path $AppDir 'zapret-autopilot.bat' }
    Update-Shortcuts $launcher
}

# Где сейчас лежит программа, на которую стоит смотреть ярлыкам
function Get-InstalledLauncher([hashtable]$state) {
    if ($script:Settings.SelfInstall -and $state.ZapretDir) {
        $l = Join-Path $state.ZapretDir 'autopilot\zapret-autopilot.bat'
        if (Test-Path -LiteralPath $l) { return $l }
    }
    return Join-Path $AppDir 'zapret-autopilot.bat'
}

# Перенос установленного zapret в другую папку (смена пути в настройках).
# Копируется всё, включая bin и autopilot; потом переключаются автозапуск и ярлыки, старая папка удаляется.
function Move-Zapret([hashtable]$state, [string]$newDir) {
    $old = $state.ZapretDir
    $newDir = [IO.Path]::GetFullPath($newDir).TrimEnd('\')
    if ($old -ieq $newDir) { return $true }
    if ($newDir.StartsWith($old + '\', [StringComparison]::OrdinalIgnoreCase)) { Bad 'Новая папка не может лежать внутри старой'; return $false }
    if ((Test-Path -LiteralPath $newDir) -and (Get-ChildItem -LiteralPath $newDir -Force | Select-Object -First 1)) {
        Bad "Папка $newDir не пустая — выберите пустую или новую папку"
        return $false
    }
    $reason = Test-SafeToWipe $old -AllowBroken
    if ($reason) { Bad "Не трогаю старую папку '$old': $reason"; return $false }

    $autoWasOn = [bool](Get-AutostartBat)
    Stop-Bypass
    Info "Переношу zapret: $old -> $newDir"
    try {
        New-Item -ItemType Directory -Path $newDir -Force | Out-Null
        Get-ChildItem -LiteralPath $old -Force | Copy-Item -Destination $newDir -Recurse -Force -ErrorAction Stop
    } catch {
        Bad "Не удалось скопировать: $($_.Exception.Message). zapret остался в старой папке"
        return $false
    }
    if (-not (Test-ZapretDir $newDir)) { Bad 'После копирования в новой папке нет нужных файлов — zapret остался в старой'; return $false }

    $state.ZapretDir = $newDir
    Save-State $state
    Ok "zapret перенесён в $newDir"

    if ($autoWasOn -and $state.BestConfig) { [void](Enable-Autostart (Join-Path $newDir $state.BestConfig)) }
    Install-Self $newDir

    # Старая папка: удаляется целиком, кроме программы, если она запущена прямо оттуда
    $keepRunning = $null
    if ($AppDir.StartsWith($old + '\', [StringComparison]::OrdinalIgnoreCase)) { $keepRunning = $AppDir.Substring($old.Length + 1).Split('\')[0] }
    Get-ChildItem -LiteralPath $old -Force | Where-Object { $_.Name -ne $keepRunning } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $keepRunning) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $old) { Info "Старую папку $old можно удалить вручную после закрытия программы" }
    else { Ok 'Старая папка удалена' }

    if ($state.BestConfig) { [void](Start-Strategy $newDir $state.BestConfig) }
    return $true
}

# Откат: вернуть zapret из резервной копии вместе с лучшей стратегией и автозапуском того времени.
# Текущая версия перед этим тоже сохраняется, так что откат можно отменить таким же откатом.
function Restore-Zapret([hashtable]$state) {
    $backups = @(Get-ZapretBackups)
    if ($backups.Count -eq 0) {
        Info 'Резервных копий нет — откатывать нечего. Они появляются при обновлении zapret'
        return $false
    }

    Write-Host ""
    if (Test-ZapretDir $state.ZapretDir) {
        Say "  Сейчас установлено: v$(Get-ZapretVersion $state.ZapretDir) в $($state.ZapretDir)" Gray
    } elseif ($state.ZapretDir) {
        Say "  Сейчас: zapret в $($state.ZapretDir) повреждён или удалён" Yellow
    }
    Say '  Резервные копии (новые сверху):' Cyan
    for ($i = 0; $i -lt $backups.Count; $i++) {
        $b = $backups[$i]
        $extra = ''
        if ($b.Meta -and $b.Meta.BestConfig) { $extra = ", лучшая стратегия: $($b.Meta.BestConfig)" }
        Say "    $($i + 1). v$($b.Version) — копия от $($b.Created)$extra" Gray
    }
    $answer = Read-Host "  Какую версию вернуть? (1-$($backups.Count), Enter — 1, 0 — отмена)"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = '1' }
    $answer = $answer.Trim()
    if ($answer -eq '0') { return $false }
    if ($answer -notmatch '^\d+$' -or [int]$answer -lt 1 -or [int]$answer -gt $backups.Count) {
        Bad 'Нет такого номера'
        return $false
    }
    $chosen = $backups[[int]$answer - 1]
    if (-not (Test-ZapretDir $chosen.Path)) {
        Bad "Копия повреждена: в $($chosen.Path) нет service.bat и bin\winws.exe"
        return $false
    }

    # Возвращаем в ту папку, из которой копия делалась
    $target = $state.ZapretDir
    if ($chosen.Meta -and $chosen.Meta.ZapretDir) { $target = $chosen.Meta.ZapretDir }
    if ($state.ZapretDir -and $target -ine $state.ZapretDir) {
        Warn "Копия сделана для папки $target, а сейчас выбрана $($state.ZapretDir) — верну в $target"
    }
    if (-not $target) { Bad 'Не знаю, в какую папку возвращать — выберите папку zapret в меню'; return $false }
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

    $reason = Test-SafeToWipe $target -AllowBroken
    if ($reason) { Bad "Отказываюсь заменять файлы в '$target': $reason"; return $false }

    if (-not (Ask-YesNo "Заменить zapret в '$target' версией v$($chosen.Version)? Текущая версия тоже сохранится" $true)) {
        return $false
    }

    Stop-Bypass

    if (Test-ZapretDir $target) {
        $current = New-ZapretBackup $state $target -Protect $chosen.Path
        if (-not $current) { Bad 'Откат отменён: не удалось сохранить текущую версию'; return $false }
    }

    Info "Возвращаю v$($chosen.Version)..."
    $failed = @(Install-ZapretFiles $chosen.Path $target)
    if ($failed.Count -or -not (Test-ZapretDir $target)) {
        Bad "Откат прошёл с ошибками ($($failed -join ', ')). Закройте программы, которые могут держать файлы zapret, и повторите"
        return $false
    }

    $state.ZapretDir = $target
    $state.Version = Get-ZapretVersion $target
    if ($chosen.Meta) {
        $state.BestConfig = $chosen.Meta.BestConfig
        $state.BestFull = [bool]$chosen.Meta.BestFull
        $state.LastRun = $chosen.Meta.LastRun
        $state.Results = $chosen.Meta.Results
    } else {
        $state.BestConfig = $null
        $state.BestFull = $false
        $state.Results = @()
    }
    if ($state.BestConfig -and -not (Test-Path -LiteralPath (Join-Path $target $state.BestConfig))) { $state.BestConfig = $null }
    Save-State $state
    Ok "Zapret возвращён к v$($state.Version): $target"

    # Автозапуск — как был на момент копии
    $savedAuto = $null
    if ($chosen.Meta) { $savedAuto = $chosen.Meta.AutostartBat }
    $currentAuto = Get-AutostartBat
    if ($savedAuto -and (Test-Path -LiteralPath $savedAuto)) {
        if ($currentAuto -ine $savedAuto) { [void](Enable-Autostart $savedAuto) }
        else { Ok "Автозапуск: $(Split-Path $savedAuto -Leaf), без изменений" }
    } elseif ($currentAuto -and -not (Test-Path -LiteralPath $currentAuto)) {
        Warn "Автозапуск указывал на $(Split-Path $currentAuto -Leaf), которого в этой версии нет — выключаю"
        Disable-Autostart
    }

    if ($state.BestConfig) {
        if (Ask-YesNo "Запустить $($state.BestConfig)?" $true) { [void](Start-Strategy $target $state.BestConfig) }
    } else {
        Info 'Для этой версии лучшая стратегия не записана — подберите её пунктом 1'
    }
    return $true
}

# ================= ЦИКЛ =================

# Автозапуск приводится к настройке «Включать обход при запуске Windows»
function Sync-Autostart([string]$batPath) {
    if (-not $script:Settings.Autostart) {
        if (Get-AutostartTask) { Info 'Автозапуск выключен в настройках — убираю задачу'; Disable-Autostart }
        return
    }
    if ((Get-AutostartBat) -ieq $batPath) {
        Ok 'Автозапуск уже настроен на эту стратегию'
    } else {
        [void](Enable-Autostart $batPath)
    }
}

# -Auto — автоматический режим: папка уже выбрана и проверена, вопросов не задаётся
function Invoke-Cycle([hashtable]$state, [switch]$SkipDiagnostics, [switch]$NoUpdate, [switch]$Auto) {
    if ($Auto) { $dir = $state.ZapretDir } else { $dir = Resolve-ZapretDir $state }
    if (-not $dir) { return }

    Step 'Подготовка: останавливаю текущий обход'
    Stop-Bypass
    Ok 'winws остановлен'

    if (-not $SkipDiagnostics) {
        Step 'Диагностика (как service.bat -> Run Diagnostics)'
        Invoke-Diagnostics $dir
    }

    Step 'Тесты: все стратегии (как service.bat -> Run Tests -> All configs)'
    $results = Invoke-ZapretTests $dir
    if (-not $results) {
        # Проверить стратегии не вышло (нет curl, тест сломан) — лучше стандартная general.bat, чем ничего
        $fallback = 'general.bat'
        if ($Auto -and (Test-Path -LiteralPath (Join-Path $dir $fallback))) {
            Warn "Не удалось проверить стратегии — включаю стандартную $fallback"
            $state.BestConfig = $fallback
            $state.BestFull = $false
            $state.LastRun = (Get-Date -Format 'yyyy-MM-dd HH:mm')
            $state.Results = @()
            Save-State $state
            if (Start-Strategy $dir $fallback) { Sync-Autostart (Join-Path $dir $fallback) }
        }
        return
    }

    $best = $results[0]
    $state.Version = Get-ZapretVersion $dir
    $state.LastRun = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    $state.Results = $results
    $state.BestConfig = $null
    $state.BestFull = $false
    if ($best.Started -and $best.TargetsOk -gt 0) {
        $state.BestConfig = $best.Config
        $state.BestFull = [bool]$best.Full
    }
    Save-State $state

    Step 'Итоги'
    Show-Results $results

    if (-not $best.Full) {
        Warn 'Ни одна стратегия не открывает все нужные сервисы одновременно'
        if ($NoUpdate) {
        } elseif ($script:Settings.UpdatePolicy -eq 'never') {
            Info 'Обновление zapret выключено в настройках'
        } else {
            Step 'Обновление zapret с GitHub'
            if ((Update-Zapret $state -OnlyIfNewer -AskFirst) -eq 'updated') {
                Info 'Повторяю проверку на новой версии...'
                Invoke-Cycle $state -NoUpdate -Auto:$Auto
                if (-not $Auto) {
                    Write-Host ""
                    Info 'Если с новой версией стало хуже — пункт 10 «Откатить обновление» в меню для опытных вернёт прошлую'
                }
                return
            }
        }
    }

    if (-not $state.BestConfig) {
        Bad 'Ни одна стратегия ничего не открыла — обход не запускаю. Проверьте предупреждения диагностики выше'
        return
    }

    Step 'Запуск лучшей стратегии'
    if ($best.Full) { Ok "Лучшая: $($best.Config) — открывает все сервисы" }
    else { Warn "Лучшая из имеющихся: $($best.Config) — не открываются: $($best.Failed -join ', ')" }

    if (Start-Strategy $dir $best.Config) {
        Sync-Autostart (Join-Path $dir $best.Config)
    }
    if ($script:DiscordWasClosed -and -not $Auto) { Info 'Discord был закрыт для очистки кэша — запустите его заново' }
}

# ================= АВТОМАТИЧЕСКИЙ РЕЖИМ =================
# Всё за пользователя: найти или установить zapret, починить, подобрать стратегию, включить, поставить на автозапуск.

function Invoke-AutoSetup([hashtable]$state) {
    $script:DiscordWasClosed = $false

    Step 'Ищу zapret на компьютере'
    $dir = Resolve-ZapretDir $state -NoPrompt
    if (-not $dir) {
        $target = Get-DefaultInstallDir
        if (-not (Confirm-Action "zapret на компьютере не найден. Установить последнюю версию в $target ?" $true)) { return }
        Info 'zapret на компьютере нет — устанавливаю последнюю версию'
        if (-not (Install-ZapretFresh $state)) { return }
    } else {
        $state.ZapretDir = $dir
        Save-State $state
        $ver = Get-ZapretVersion $dir
        if ($ver) { Ok "Найден zapret $ver в $dir" } else { Ok "Найден zapret в $dir" }
    }

    Step 'Проверяю, что все файлы zapret на месте'
    if (-not (Repair-Zapret $state)) { return }

    if ($script:Settings.UpdatePolicy -eq 'always') {
        Step 'Проверяю обновления zapret (в настройках: всегда последняя версия)'
        [void](Update-Zapret $state -OnlyIfNewer -AskFirst)
    }
    Install-Self $state.ZapretDir

    Invoke-Cycle $state -Auto

    # Не заработало вообще ничего — последние меры
    if (-not $state.BestConfig) {
        $missing = @(Get-ZapretProblems $state.ZapretDir)
        $badPath = Test-BadPath $state.ZapretDir
        $cleanDir = Get-DefaultInstallDir
        if ($missing.Count) {
            # Файлы пропали уже во время проверки — тоже антивирус
            Step 'Файлы zapret пропали во время проверки — чиню'
            if (Repair-Zapret $state) { Invoke-Cycle $state -Auto -NoUpdate }
        } elseif ($badPath -and -not (Test-BadPath $cleanDir) -and
                  (Confirm-Action "zapret лежит в неудачном месте ($badPath). Поставить чистую копию в $cleanDir ?" $true)) {
            Step "Zapret лежит в неудачном месте ($badPath) — ставлю чистую копию в $cleanDir"
            if (Install-ZapretFresh $state) {
                if (Repair-Zapret $state) {
                    Install-Self $state.ZapretDir
                    Invoke-Cycle $state -Auto -NoUpdate
                }
            }
        }
    }

    Show-Summary $state
}

function Show-Summary([hashtable]$state) {
    Step 'Готово'
    $running = Test-WinwsRunning
    if (-not $state.BestConfig -or -not $running) {
        Bad 'Включить обход не получилось.'
        Say '  Что можно сделать:' Yellow
        Say '   - отключите VPN и прокси, если они есть, и запустите программу ещё раз;' Yellow
        Say '   - если выше были красные строки [X] — это и есть причина, они подсказывают, что сделать;' Yellow
        Say "   - подробный отчёт сохранён в $(Join-Path $DataDir 'last-run.log')" Yellow
        return
    }

    $best = @($state.Results | Where-Object { $_.Config -eq $state.BestConfig }) | Select-Object -First 1
    $okNames = @(); $badNames = @()
    if ($best) {
        $okNames  = @($best.Services | Where-Object { $_.Ok -eq $_.Total } | ForEach-Object { $_.Name })
        $badNames = @($best.Services | Where-Object { $_.Ok -ne $_.Total } | ForEach-Object { $_.Name })
    }

    Write-Host ""
    if ($state.BestFull) {
        Say "  ВСЁ РАБОТАЕТ: $($okNames -join ', ')" Green
    } elseif ($okNames.Count) {
        Say "  РАБОТАЕТ ЧАСТИЧНО. Открываются: $($okNames -join ', ')" Yellow
        if ($badNames.Count) { Say "  Не открываются: $($badNames -join ', ') — для них сейчас нет рабочей настройки, попробуйте «Починить» через пару дней" Yellow }
    } else {
        Say "  Обход включён ($($state.BestConfig))" Yellow
    }
    Write-Host ""
    if (Get-AutostartBat) { Say '  Обход будет включаться сам при каждом запуске компьютера.' Gray }
    Say '  На панели задач будет свёрнутое окно «zapret» — не закрывайте его, это и есть обход.' Gray
    $where = @()
    if ($script:Settings.DesktopShortcut) { $where += 'на рабочем столе' }
    if ($script:Settings.StartMenuShortcut) { $where += 'в меню «Пуск»' }
    if ($where.Count) { Say "  Если что-то перестанет работать — откройте ярлык «Zapret» $($where -join ' или ') и выберите «Починить»." Gray }
    else { Say "  Если что-то перестанет работать — запустите $(Get-InstalledLauncher $state) и выберите «Починить»." Gray }
    if ($script:DiscordWasClosed) {
        Write-Host ""
        Say '  Discord был закрыт, чтобы очистить его кэш, — откройте его заново.' Cyan
    }
}

# ================= ГЛАВНЫЙ ЭКРАН (ДЛЯ ВСЕХ) =================

function Test-Ready([hashtable]$state) {
    return [bool]($state.BestConfig -and (Test-ZapretDirLoose $state.ZapretDir) -and
                  (@(Get-ZapretProblems $state.ZapretDir).Count -eq 0) -and
                  (Test-Path -LiteralPath (Join-Path $state.ZapretDir $state.BestConfig)))
}

# Режим АВТО при открытии программы: сам настраивает или сам включает обход и закрывается.
# Нажатая во время отсчёта клавиша — остаться в меню. $true — программу можно закрывать.
function Invoke-AutoOnOpen([hashtable]$state) {
    Say '  Режим АВТО' Cyan
    if (-not (Test-Ready $state)) {
        if (-not $state.ZapretDir) {
            Say '  Сейчас программа сама найдёт или установит zapret, подберёт лучшую настройку' Gray
            Say '  и включит обход. Это займёт 5–10 минут, Discord будет закрыт.' Gray
        } else {
            Say '  Zapret нужно починить или заново настроить — программа сделает это сама (5–10 минут).' Gray
        }
        Write-Host ""
        Say '  [Enter] — начать сразу    5 — настройки    9 — меню для опытных    0 — выход' DarkGray
        $key = Wait-Countdown 10 'Начну через {0} с.'
        if ($key) {
            switch ($key.KeyChar) {
                '0' { return $true }
                '5' { Show-Settings $state; return $false }
                '9' { Show-Menu; return $false }
            }
            if ($key.Key -eq 'Escape') { return $true }
        }
        Invoke-AutoSetup $state
    } elseif (-not (Test-WinwsRunning)) {
        [void](Invoke-StartBest $state)
    } else {
        return $false   # уже работает — человек открыл программу, чтобы что-то сделать
    }
    Write-Host ""
    Say '  Нажмите любую клавишу, чтобы открыть меню' DarkGray
    $key = Wait-Countdown 15 'Окно закроется через {0} с.'
    return (-not $key)
}

function Show-Home {
    $first = $true
    while ($true) {
        $state = Get-State
        Clear-Host
        Write-Host ""
        Say '  ZAPRET — обход блокировок Discord и YouTube' White
        Say '  ---------------------------------------------' DarkGray
        Write-Host ""

        if ($first -and (Test-AutoMode)) {
            $first = $false
            if (Invoke-AutoOnOpen $state) { return }
            continue
        }
        $first = $false

        # Первый запуск, поломка или настройка не подобрана — предлагаем сделать всё одной кнопкой
        if (-not (Test-Ready $state)) {
            if (-not $state.ZapretDir) {
                Say '  Программа сама найдёт zapret на компьютере (или установит, если его нет),' Gray
                Say '  подберёт настройку, которая лучше всего работает у вашего провайдера,' Gray
                Say '  включит обход и сделает так, чтобы он включался сам вместе с компьютером.' Gray
            } elseif (@(Get-ZapretProblems $state.ZapretDir).Count) {
                Say '  Zapret повреждён. Программа сама его починит и заново настроит.' Yellow
            } else {
                Say '  Нужно подобрать настройку обхода под ваш интернет.' Gray
            }
            Write-Host ""
            Say '  Это займёт 5–10 минут. Во время проверки интернет может ненадолго' Gray
            Say '  пропадать, а Discord будет закрыт — это нормально.' Gray
            Write-Host ""
            Say '  [Enter]  Начать' Green
            Say '     5     Настройки (папка установки, ярлыки, режим АВТО...)' Gray
            Say '     9     Меню для опытных' DarkGray
            Say '     0     Выход' DarkGray
            Write-Host ""
            $choice = Read-Host '  Ваш выбор'
            switch ($choice) {
                '0' { return }
                '5' { Show-Settings $state }
                '9' { Show-Menu }
                default { Invoke-AutoSetup $state; Wait-AnyKey }
            }
            continue
        }

        $running = Test-WinwsRunning
        if ($running) { Say '  [ ОБХОД ВКЛЮЧЁН ]' Green } else { Say '  [ ОБХОД ВЫКЛЮЧЕН ]' Red }

        $best = @($state.Results | Where-Object { $_.Config -eq $state.BestConfig }) | Select-Object -First 1
        if ($best) {
            $okNames = @($best.Services | Where-Object { $_.Ok -eq $_.Total } | ForEach-Object { $_.Name })
            $badNames = @($best.Services | Where-Object { $_.Ok -ne $_.Total } | ForEach-Object { $_.Name })
            if ($okNames.Count) { Say "  Открываются: $($okNames -join ', ')" Gray }
            if ($badNames.Count) { Say "  Не открываются: $($badNames -join ', ')" Yellow }
        }
        $autoOn = [bool](Get-AutostartBat)
        if ($autoOn) { Say '  Включается сам при запуске компьютера' Gray }
        else { Say '  Сам при запуске компьютера НЕ включается' Yellow }
        Say "  Последняя проверка: $($state.LastRun)" DarkGray

        Write-Host ""
        if ($running) {
            Say '  [Enter]  Закрыть это окно (обход продолжит работать)' Green
            Say '     1     Перезапустить обход' Gray
        } else {
            Say '  [Enter]  Включить обход' Green
        }
        Say '     2     Выключить обход' Gray
        Say '     3     Что-то не работает? Починить и настроить заново' Gray
        if ($autoOn) { Say '     4     Не включать обход при запуске компьютера' Gray }
        else { Say '     4     Включать обход сам при запуске компьютера' Gray }
        Say '     5     Настройки (папка установки, ярлыки, режим АВТО...)' Gray
        Say '     9     Меню для опытных' DarkGray
        Say '     0     Выход' DarkGray
        Write-Host ""
        $choice = Read-Host '  Ваш выбор'

        if ([string]::IsNullOrWhiteSpace($choice)) {
            if ($running) { return }
            $choice = '1'
        }
        switch ($choice.Trim()) {
            '1' {
                if (Invoke-StartBest $state) {
                    Start-Sleep -Seconds 1
                } elseif (Ask-YesNo 'Включить не получилось. Починить и настроить заново?' $true) {
                    Invoke-AutoSetup $state
                    Wait-AnyKey
                }
            }
            '2' { Stop-Bypass -KeepService; Ok 'Обход выключен'; Start-Sleep -Seconds 1 }
            '3' { Invoke-AutoSetup $state; Wait-AnyKey }
            '4' {
                $script:Settings.Autostart = -not $autoOn
                Save-Settings $script:Settings
                Sync-Autostart (Join-Path $state.ZapretDir $state.BestConfig)
                Start-Sleep -Seconds 2
            }
            '5' { Show-Settings $state }
            '9' { Show-Menu }
            '0' { return }
        }
    }
}

# ================= ЭКРАН НАСТРОЕК =================

function Format-YesNo($v) { if ($v) { return 'да' } return 'нет' }

# Группы сервисов в порядке utils\targets.txt (Discord, YouTube, Google, Cloudflare...)
function Get-ServiceGroups([string]$dir) {
    $file = $null
    if ($dir) { $file = Join-Path $dir 'utils\targets.txt' }
    if (-not $file -or -not (Test-Path -LiteralPath $file)) { return @('Discord', 'YouTube', 'Google', 'Cloudflare') }
    $groups = New-Object System.Collections.Generic.List[string]
    $group = $null
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        if ($line -match '^\s*###\s*(.+?)\s*$') { $group = ($matches[1] -replace '\s*\(.*\)$', ''); continue }
        if ($group -and $line -match '^\s*\w+\s*=\s*"https?://' -and -not $groups.Contains($group)) { $groups.Add($group) }
    }
    if ($groups.Count -eq 0) { return @('Discord', 'YouTube', 'Google', 'Cloudflare') }
    return $groups.ToArray()
}

function Edit-RequiredServices([hashtable]$state) {
    $all = @(Get-ServiceGroups $state.ZapretDir)
    $chosen = New-Object System.Collections.Generic.List[string]
    foreach ($g in @($script:Settings.RequiredServices)) { if ($all -contains $g) { $chosen.Add($g) } }
    while ($true) {
        Write-Host ""
        Say '  Какие сервисы обязательно должны работать? Если ни одна настройка не открывает их все,' Gray
        Say '  программа попробует обновить zapret. Остальные сервисы тоже проверяются, но не обязательны.' Gray
        for ($i = 0; $i -lt $all.Count; $i++) {
            $mark = ' '
            if ($chosen.Count -eq 0 -or $chosen.Contains($all[$i])) { $mark = 'x' }
            Say "    $($i + 1). [$mark] $($all[$i])" Gray
        }
        $in = Read-Host '  Номер — включить/выключить, A — все, Enter — готово'
        if ([string]::IsNullOrWhiteSpace($in)) { break }
        $in = $in.Trim()
        if ($in -match '^[aAаА]$') { $chosen.Clear(); continue }
        if ($in -match '^\d+$' -and [int]$in -ge 1 -and [int]$in -le $all.Count) {
            $g = $all[[int]$in - 1]
            if ($chosen.Count -eq 0) { foreach ($x in $all) { $chosen.Add($x) } }   # «все» -> явный список
            if ($chosen.Contains($g)) {
                # Пустой список означает «все», поэтому последний снять нельзя
                if ($chosen.Count -eq 1) { Warn 'Хотя бы один сервис должен быть обязательным' }
                else { [void]$chosen.Remove($g) }
            } else {
                $chosen.Add($g)
            }
            if ($chosen.Count -eq $all.Count) { $chosen.Clear() }
        }
    }
    $script:Settings.RequiredServices = @($chosen)
    Save-Settings $script:Settings
}

function Edit-InstallDir([hashtable]$state) {
    Write-Host ""
    Say "  Сейчас: $($script:Settings.InstallDir)" Gray
    Say '  Совет: короткий путь без русских букв, например C:\zapret или D:\Programs\zapret' DarkGray
    $in = Read-Host '  Новая папка для zapret (Enter — оставить как есть)'
    if ([string]::IsNullOrWhiteSpace($in)) { return }
    $path = $in.Trim().Trim('"')
    $err = Test-InstallPath $path
    if ($err) { Bad "Не подходит: $err"; Wait-AnyKey; return }
    $path = [IO.Path]::GetFullPath($path).TrimEnd('\')
    $bad = Test-BadPath $path
    if ($bad -and -not (Ask-YesNo "В этом пути проблема ($bad) — zapret там часто не работает. Всё равно выбрать?" $false)) { return }

    $script:Settings.InstallDir = $path
    Save-Settings $script:Settings
    Ok "Папка установки: $path"

    if ($state.ZapretDir -and (Test-ZapretDirLoose $state.ZapretDir) -and $state.ZapretDir -ine $path) {
        if (Ask-YesNo "zapret сейчас установлен в $($state.ZapretDir). Перенести его в $path ?" $true) {
            [void](Move-Zapret $state $path)
        } else {
            Info 'Хорошо, установленный zapret остаётся на месте. Новая папка будет использована при следующей чистой установке'
        }
    }
    Wait-AnyKey
}

function Show-Settings([hashtable]$state) {
    $updNames = @{ never = 'никогда'; broken = 'только если перестал работать'; always = 'всегда ставить последнюю версию' }
    $defNames = @{ ask = 'спрашивать'; always = 'добавлять без вопроса'; never = 'никогда не добавлять' }
    while ($true) {
        $s = $script:Settings
        Clear-Host
        Write-Host ""
        Say '  НАСТРОЙКИ' White
        Say '  ---------------------------------------------' DarkGray
        Write-Host ""
        $modeText = 'РУЧНОЙ — показывает меню и спрашивает перед изменениями'
        if ($s.Mode -eq 'auto') { $modeText = 'АВТО — при открытии сам всё делает, без вопросов' }
        $req = 'все'
        if (@($s.RequiredServices).Count) { $req = @($s.RequiredServices) -join ', ' }

        $rows = @(
            @('1',  'Режим работы',                              $modeText),
            @('2',  'Папка для установки zapret',                $s.InstallDir),
            @('3',  'Ярлык на рабочем столе',                    (Format-YesNo $s.DesktopShortcut)),
            @('4',  'Ярлык в меню «Пуск»',                       (Format-YesNo $s.StartMenuShortcut)),
            @('5',  'Включать обход при запуске Windows',        (Format-YesNo $s.Autostart)),
            @('6',  'Обновлять zapret',                          $updNames[$s.UpdatePolicy]),
            @('7',  'Исключение в Защитнике Windows',            $defNames[$s.DefenderExclusion]),
            @('8',  'Чистить кэш Discord при настройке',         (Format-YesNo $s.ClearDiscordCache)),
            @('9',  'Удалять мешающие программы (GoodbyeDPI…)',  (Format-YesNo $s.RemoveConflicts)),
            @('10', 'Обязательные сервисы',                      $req),
            @('11', 'Копировать программу в папку zapret',       (Format-YesNo $s.SelfInstall))
        )
        foreach ($r in $rows) { Say ('  {0,4}   {1,-44} {2}' -f $r[0], $r[1], $r[2]) Gray }
        Write-Host ""
        if ($state.ZapretDir) { Say "  zapret сейчас установлен в: $($state.ZapretDir)" DarkGray }
        Say '     R   Вернуть стандартные настройки' DarkGray
        Say '     0   Назад (всё сохраняется сразу)' DarkGray
        Write-Host ""
        $c = Read-Host '  Что изменить'
        if ([string]::IsNullOrWhiteSpace($c)) { $c = '0' }
        $launcherChanged = $false

        switch ($c.Trim().ToUpperInvariant()) {
            '0'  { return }
            '1'  { if ($s.Mode -eq 'auto') { $s.Mode = 'manual' } else { $s.Mode = 'auto' } }
            '2'  { Edit-InstallDir $state; continue }
            '3'  { $s.DesktopShortcut = -not $s.DesktopShortcut; $launcherChanged = $true }
            '4'  { $s.StartMenuShortcut = -not $s.StartMenuShortcut; $launcherChanged = $true }
            '5'  { $s.Autostart = -not $s.Autostart }
            '6'  { $s.UpdatePolicy = @{ never = 'broken'; broken = 'always'; always = 'never' }[$s.UpdatePolicy] }
            '7'  { $s.DefenderExclusion = @{ ask = 'always'; always = 'never'; never = 'ask' }[$s.DefenderExclusion] }
            '8'  { $s.ClearDiscordCache = -not $s.ClearDiscordCache }
            '9'  { $s.RemoveConflicts = -not $s.RemoveConflicts }
            '10' { Edit-RequiredServices $state; continue }
            '11' { $s.SelfInstall = -not $s.SelfInstall; $launcherChanged = $true }
            { $_ -eq 'R' -or $_ -eq 'К' } {
                if (Ask-YesNo 'Вернуть все настройки к стандартным?' $false) {
                    $s = Get-DefaultSettings
                    $launcherChanged = $true
                    $c = '5'   # автозапуск тоже привести к стандарту
                }
            }
        }
        Save-Settings $s

        # Применяем сразу то, что видно в системе
        if ($launcherChanged) {
            if ($s.SelfInstall -and $state.ZapretDir -and (Test-ZapretDirLoose $state.ZapretDir)) { Install-Self $state.ZapretDir }
            else { Update-Shortcuts (Get-InstalledLauncher $state) }
            Start-Sleep -Seconds 1
        }
        if ($c.Trim() -eq '5' -and $state.BestConfig -and $state.ZapretDir) {
            Sync-Autostart (Join-Path $state.ZapretDir $state.BestConfig)
            Start-Sleep -Seconds 1
        }
    }
}

# ================= МЕНЮ ДЛЯ ОПЫТНЫХ =================

function Show-Header([hashtable]$state) {
    Clear-Host
    Write-Host ""
    Say "  ZAPRET AUTOPILOT v$AppVersion" White
    Say '  ----------------------------------------' DarkGray

    if (Test-ZapretDir $state.ZapretDir) {
        Say "  Zapret:      $($state.ZapretDir)  (v$(Get-ZapretVersion $state.ZapretDir))" Gray
    } else {
        Say '  Zapret:      папка не выбрана' Red
    }

    if ($state.BestConfig) {
        if ($state.BestFull) { Say "  Лучшая:      $($state.BestConfig)  [все сервисы работают, проверено $($state.LastRun)]" Green }
        else { Say "  Лучшая:      $($state.BestConfig)  [открывает не всё, проверено $($state.LastRun)]" Yellow }
    } else {
        Say '  Лучшая:      ещё не определена — запустите пункт 1' DarkGray
    }

    $auto = Get-AutostartBat
    if ($auto) { Say "  Автозапуск:  $(Split-Path $auto -Leaf)" Green }
    else { Say '  Автозапуск:  выключен' DarkGray }

    $runningNow = Get-RunningStrategy
    if ($runningNow) { Say "  Сейчас:      работает ($runningNow)" Green }
    else { Say '  Сейчас:      обход не запущен' DarkGray }
    Say '  ----------------------------------------' DarkGray
}

function Show-Menu {
    while ($true) {
        $state = Get-State
        Show-Header $state
        Write-Host ""
        Say '  :: ГЛАВНОЕ' Cyan
        Say '     1. Полный цикл: диагностика -> тесты -> запуск лучшей' Gray
        Say '     2. Запустить лучшую стратегию' Gray
        Say '     3. Остановить обход' Gray
        Write-Host ""
        Say '  :: АВТОЗАПУСК' Cyan
        Say '     4. Включить автозапуск лучшей стратегии' Gray
        Say '     5. Выключить автозапуск' Gray
        Write-Host ""
        Say '  :: ОТДЕЛЬНО' Cyan
        Say '     6. Только диагностика' Gray
        Say '     7. Только тесты (без диагностики и обновления)' Gray
        Say '     8. Результаты последней проверки' Gray
        Write-Host ""
        Say '  :: ВЕРСИЯ ZAPRET' Cyan
        Say '     9. Переустановить zapret начисто с GitHub' Gray
        $backupCount = @(Get-ZapretBackups).Count
        if ($backupCount) { Say "     10. Откатить обновление (резервных копий: $backupCount)" Gray }
        else { Say '     10. Откатить обновление (копий пока нет)' DarkGray }
        Say '     11. Выбрать другую папку zapret' Gray
        Say '     12. Настройки (режим АВТО, папка установки, ярлыки...)' Gray
        Write-Host ""
        Say '  ----------------------------------------' DarkGray
        Say '     0. Назад' Gray
        Write-Host ""
        $choice = Read-Host '  Выберите пункт (0-12)'

        switch ($choice) {
            '1' { Invoke-Cycle $state; Wait-AnyKey }
            '2' { [void](Invoke-StartBest $state); Wait-AnyKey }
            '3' { Stop-Bypass -KeepService; Ok 'Обход остановлен'; Wait-AnyKey }
            '4' {
                if (-not $state.BestConfig) { Warn 'Лучшая стратегия ещё не определена — сначала пункт 1' }
                else { [void](Enable-Autostart (Join-Path $state.ZapretDir $state.BestConfig)) }
                Wait-AnyKey
            }
            '5' { Disable-Autostart; Wait-AnyKey }
            '6' {
                $dir = Resolve-ZapretDir $state
                if ($dir) { Step 'Диагностика'; Invoke-Diagnostics $dir }
                Wait-AnyKey
            }
            '7' { Invoke-Cycle $state -SkipDiagnostics -NoUpdate; Wait-AnyKey }
            '8' {
                if ($state.Results) { Say "  Проверка от $($state.LastRun), zapret v$($state.Version)" Cyan; Show-Results $state.Results }
                else { Info 'Проверок ещё не было' }
                Wait-AnyKey
            }
            '9' {
                $dir = Resolve-ZapretDir $state
                if ($dir -and (Ask-YesNo "Удалить zapret в '$dir' (кроме bin) и поставить последнюю версию с GitHub? Списки *-user.txt сохранятся" $false)) {
                    if ((Update-Zapret $state -Repair) -eq 'updated') { Info 'Теперь запустите полный цикл (пункт 1), чтобы подобрать стратегию' }
                }
                Wait-AnyKey
            }
            '10' { Step 'Откат обновления zapret'; [void](Restore-Zapret $state); Wait-AnyKey }
            '11' { [void](Resolve-ZapretDir $state -ForceAsk); Wait-AnyKey }
            '12' { Show-Settings $state }
            '0' { return }
        }
    }
}

function Invoke-StartBest([hashtable]$state) {
    if (-not (Test-ZapretDir $state.ZapretDir) -or -not $state.BestConfig) {
        Warn 'Лучшая стратегия ещё не определена — сначала запустите полный цикл'
        return $false
    }
    return (Start-Strategy $state.ZapretDir $state.BestConfig)
}

# ================= ТОЧКА ВХОДА =================

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Bad 'Нужны права администратора — запускайте через zapret-autopilot.bat'
    Wait-AnyKey
    exit 1
}

$Host.UI.RawUI.WindowTitle = 'Zapret'
if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
$script:DiscordWasClosed = $false

# Версия 1.0 хранила данные в папке программы — переносим
$oldData = Join-Path $AppDir 'data'
if ((Test-Path -LiteralPath (Join-Path $oldData 'state.json')) -and -not (Test-Path -LiteralPath $StateFile)) {
    Get-ChildItem -LiteralPath $oldData -Force | Copy-Item -Destination $DataDir -Recurse -Force -ErrorAction SilentlyContinue
}

$logged = $false
if ($Action -notin 'start', 'stop') {
    try { Start-Transcript -Path (Join-Path $DataDir 'last-run.log') -Force | Out-Null; $logged = $true } catch {}
}

try {
    $script:Settings = Get-Settings
    $state = Get-State
    switch ($Action.ToLowerInvariant()) {
        'home'  { Show-Home }
        'menu'  { Show-Menu }
        'settings' { Show-Settings $state }
        # Команда auto — всегда без вопросов, даже если в настройках выбран ручной режим
        'auto'  { $script:Settings.Mode = 'auto'; Invoke-AutoSetup $state; Wait-AnyKey }
        'cycle' { Invoke-Cycle $state; Wait-AnyKey }
        'test'  { Invoke-Cycle $state -SkipDiagnostics -NoUpdate; Wait-AnyKey }
        'diag'  {
            $dir = Resolve-ZapretDir $state
            if ($dir) { Step 'Диагностика'; Invoke-Diagnostics $dir }
            Wait-AnyKey
        }
        'start' {
            if (-not (Invoke-StartBest $state)) { Wait-AnyKey } else { Start-Sleep -Seconds 2 }
        }
        'stop'  { Stop-Bypass -KeepService; Ok 'Обход остановлен'; Start-Sleep -Seconds 2 }
        'rollback' { Step 'Откат обновления zapret'; [void](Restore-Zapret $state); Wait-AnyKey }
        default { Bad "Неизвестная команда '$Action'. Доступны: auto, menu, settings, cycle, start, stop, diag, test, rollback"; Wait-AnyKey }
    }
} finally {
    if ($logged) { try { Stop-Transcript | Out-Null } catch {} }
}
