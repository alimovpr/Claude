#Requires -Version 5.1
<#
  Мост Claude <-> 1С («почтовый ящик»).

  Сервер сам забирает задания из приватного git-репозитория, выполняет их
  Конфигуратором в пакетном режиме (без окон) и кладёт обратно текстовый лог.
  Входящие порты не нужны: сервер только ходит наружу в GitHub и Telegram.

  Запуск (Планировщик Windows):
    раз в минуту:  powershell -NoProfile -ExecutionPolicy Bypass -File C:\1cb\bridge.ps1
    раз в сутки:   powershell -NoProfile -ExecutionPolicy Bypass -File C:\1cb\bridge.ps1 -Nightly

  Выполняются только действия из белого списка и только для расширений из config.json.
  Рабочая база меняется только после команды /ok_<id> в Telegram от владельца
  и только в разрешённое окно времени.

  ВАЖНО: файл должен быть сохранён в UTF-8 с BOM (иначе PowerShell 5.1 ломает кириллицу).
#>
param([switch]$Nightly)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cfg       = Get-Content "$Root\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$Repo      = "$Root\repo"
$Work      = "$Root\work"
$Backup    = "$Root\backups"
$Out       = "$Root\out"
$StateFile = "$Root\state.json"
$LockFile  = "$Root\bridge.lock"
$LogFile   = "$Root\bridge.log"

# Путь к git.exe: функция Git ниже иначе вызывала бы сама себя
$GitExe = (Get-Command git -CommandType Application | Select-Object -First 1).Source

$Actions = @('check-copy', 'load-copy', 'build-epf', 'deploy-prod', 'dump-prod')

foreach ($d in @($Work, $Backup, $Out)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null } }

function Log([string]$msg) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" -Encoding UTF8
}

# --- git -------------------------------------------------------------------

function Git {
    # git пишет прогресс в stderr; в PS 5.1 при Stop это превращается в исключение
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $o = & $GitExe -C $Repo @args 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    if ($code -ne 0) { throw "git $($args -join ' '): $($o -join "`n")" }
    $o
}

function Push-Repo([string]$message) {
    Git add -A | Out-Null
    $changes = Git status --porcelain
    if (-not $changes) { return }
    Git commit -q -m $message | Out-Null
    for ($i = 1; $i -le 3; $i++) {
        try { Git pull -q --rebase origin main | Out-Null; Git push -q origin main | Out-Null; return }
        catch { if ($i -eq 3) { throw }; Start-Sleep -Seconds (5 * $i) }
    }
}

function New-Worktree([string]$ref) {
    $wt = "$Work\wt"
    if (Test-Path $wt) {
        try { Git worktree remove --force $wt | Out-Null } catch {}
        Remove-Item $wt -Recurse -Force -ErrorAction SilentlyContinue
    }
    Git worktree prune | Out-Null
    Git worktree add -q --detach $wt "origin/$ref" | Out-Null
    $wt
}

# --- Telegram --------------------------------------------------------------

function Send-Tg([string]$text) {
    if (-not $Cfg.Telegram.Token) { return }
    $body = @{ chat_id = $Cfg.Telegram.ChatId; text = $text } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$($Cfg.Telegram.Token)/sendMessage" -Method Post `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
    } catch { Log "Telegram: $_" }
}

function Get-State {
    if (Test-Path $StateFile) { $s = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    else { $s = [pscustomobject]@{} }
    foreach ($p in 'offset', 'approved', 'notified', 'lastError') {
        if (-not ($s.PSObject.Properties.Name -contains $p)) { $s | Add-Member $p $null }
    }
    if ($null -eq $s.offset) { $s.offset = 0 }
    $s.approved = @($s.approved | Where-Object { $_ })
    $s.notified = @($s.notified | Where-Object { $_ })
    $s
}

function Save-State($s) { $s | ConvertTo-Json -Depth 5 | Set-Content $StateFile -Encoding UTF8 }

# Забирает из Telegram команды /ok_<id>, принимает их только от владельца (ChatId)
function Update-Approvals($s) {
    if (-not $Cfg.Telegram.Token) { return }
    $url = "https://api.telegram.org/bot$($Cfg.Telegram.Token)/getUpdates?timeout=0&offset=$($s.offset)"
    try { $r = Invoke-RestMethod -Uri $url } catch { Log "Telegram getUpdates: $_"; return }
    foreach ($u in $r.result) {
        $s.offset = [int64]$u.update_id + 1
        $m = $u.message
        if (-not $m -or [int64]$m.from.id -ne [int64]$Cfg.Telegram.ChatId) { continue }
        if ($m.text -match '^/ok_([A-Za-z0-9]+)') {
            $id = $Matches[1]
            if ($s.approved -notcontains $id) { $s.approved += $id }
            Send-Tg "Принято: выкатка $id разрешена. Выполню в окно $($Cfg.DeployWindow.From)–$($Cfg.DeployWindow.To)."
        }
    }
}

function Test-DeployWindow {
    $now  = (Get-Date).TimeOfDay
    $from = [TimeSpan]::Parse($Cfg.DeployWindow.From)
    $to   = [TimeSpan]::Parse($Cfg.DeployWindow.To)
    ($now -ge $from) -and ($now -le $to)
}

# --- 1С --------------------------------------------------------------------

function Quote([string]$a) { '"' + ($a -replace '"', '\"') + '"' }

# Запускает Конфигуратор в пакетном режиме. Окно не появляется, результат — текст в /Out.
function Invoke-1C($Db, [string[]]$Cmd, [string]$Name) {
    $log = "$Work\$Name.log"
    if (Test-Path $log) { Remove-Item $log -Force }
    $all = @('DESIGNER', '/S', "$($Db.Server)\$($Db.Base)", '/N', $Db.User, '/P', $Db.Password,
             '/DisableStartupDialogs', '/DisableStartupMessages', '/Out', $log) + $Cmd
    $argLine = ($all | ForEach-Object { Quote $_ }) -join ' '
    $p = Start-Process -FilePath $Cfg.Platform -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden
    # Без -Encoding: PS 5.1 сам распознаёт BOM, иначе читает в кодировке Windows
    $text = ''
    if (Test-Path $log) { $text = (Get-Content $log -Raw) -as [string] }
    [pscustomobject]@{ Ok = ($p.ExitCode -eq 0); Code = $p.ExitCode; Log = "[$Name] код $($p.ExitCode)`n$text" }
}

# Хэш содержимого папки выгрузки (без служебного ConfigDumpInfo.xml) — чтобы заметить чужие правки
function Get-DirHash([string]$dir) {
    $dir = (Resolve-Path $dir).Path
    $lines = Get-ChildItem $dir -Recurse -File | Where-Object { $_.Name -ne 'ConfigDumpInfo.xml' } |
        Sort-Object FullName | ForEach-Object {
            $rel = $_.FullName.Substring($dir.Length).TrimStart('\')
            "$rel|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
        }
    $lines -join "`n"
}

function Stamp { Get-Date -Format 'yyyyMMdd_HHmmss' }

# --- действия --------------------------------------------------------------

function Invoke-Steps([scriptblock[]]$steps) {
    $logs = @()
    foreach ($s in $steps) {
        $r = & $s
        $logs += $r.Log
        if (-not $r.Ok) { return [pscustomobject]@{ Ok = $false; Log = ($logs -join "`n`n") } }
    }
    [pscustomobject]@{ Ok = $true; Log = ($logs -join "`n`n") }
}

function Do-CheckCopy($job) {
    Invoke-1C $Cfg.Copy @('/CheckModules', '-ThinClient', '-Server', '-Extension', $job.ext) 'check'
}

function Do-LoadCopy($job) {
    $wt  = New-Worktree $job.ref
    $src = "$wt\src\ext\$($job.ext)"
    if (-not (Test-Path $src)) { throw "В ветке $($job.ref) нет папки src/ext/$($job.ext)" }
    $bak = "$Backup\copy_$($job.ext)_$(Stamp).cfe"
    Invoke-Steps @(
        { Invoke-1C $Cfg.Copy @('/DumpCfg', $bak, '-Extension', $job.ext) 'backup' },
        { Invoke-1C $Cfg.Copy @('/LoadConfigFromFiles', $src, '-Extension', $job.ext) 'load' },
        { Invoke-1C $Cfg.Copy @('/UpdateDBCfg', '-Extension', $job.ext) 'update' },
        { Invoke-1C $Cfg.Copy @('/CheckModules', '-ThinClient', '-Server', '-Extension', $job.ext) 'check' }
    )
}

function Do-BuildEpf($job) {
    if ($job.name -notmatch '^[\w-]+$') { throw "Недопустимое имя обработки: $($job.name)" }
    $wt  = New-Worktree $job.ref
    $xml = "$wt\epf\$($job.name)\$($job.name).xml"
    if (-not (Test-Path $xml)) { throw "В ветке $($job.ref) нет файла epf/$($job.name)/$($job.name).xml" }
    $epf = "$Out\$($job.name).epf"
    $r = Invoke-1C $Cfg.Copy @('/LoadExternalDataProcessorOrReportFromFiles', $xml, $epf) 'build'
    if ($r.Ok) {
        if (-not (Test-Path "$Repo\out")) { New-Item -ItemType Directory "$Repo\out" | Out-Null }
        Copy-Item $epf "$Repo\out\" -Force
        $r.Log += "`nГотово: $epf (копия в out/ репозитория)"
    }
    $r
}

function Do-DumpProd {
    # Основная конфигурация — инкрементально; расширения — целиком (они небольшие)
    $cf  = "$Repo\src\cf"
    $ext = "$Repo\src\ext"
    if (-not (Test-Path $cf)) { New-Item -ItemType Directory $cf | Out-Null }
    if (Test-Path $ext) { Remove-Item $ext -Recurse -Force }
    New-Item -ItemType Directory $ext | Out-Null
    $r = Invoke-Steps @(
        { Invoke-1C $Cfg.Prod @('/DumpConfigToFiles', $cf, '-update', '-force') 'dump-cf' },
        { Invoke-1C $Cfg.Prod @('/DumpConfigToFiles', $ext, '-AllExtensions') 'dump-ext' }
    )
    # Неудачная выгрузка не должна попасть в git и затереть прошлую
    if (-not $r.Ok) { Git checkout -q -- src | Out-Null; Git clean -qfd -- src | Out-Null }
    $r
}

function Do-DeployProd($job) {
    # 1) Проверяем, что расширение в рабочей базе не меняли после ночной выгрузки
    $drift = "$Work\drift"
    if (Test-Path $drift) { Remove-Item $drift -Recurse -Force }
    $r = Invoke-1C $Cfg.Prod @('/DumpConfigToFiles', $drift, '-Extension', $job.ext) 'drift'
    if (-not $r.Ok) { return $r }
    $base = "$Repo\src\ext\$($job.ext)"
    if (-not (Test-Path $base) -or (Get-DirHash $drift) -ne (Get-DirHash $base)) {
        return [pscustomobject]@{ Ok = $false; Log = "Выкатка остановлена: расширение $($job.ext) в рабочей базе отличается от последней выгрузки (его кто-то менял). Нужна свежая выгрузка и повторная проверка на копии." }
    }
    # 2) Бэкап, загрузка, обновление, проверка
    $wt  = New-Worktree $job.ref
    $src = "$wt\src\ext\$($job.ext)"
    if (-not (Test-Path $src)) { throw "В ветке $($job.ref) нет папки src/ext/$($job.ext)" }
    $bak = "$Backup\prod_$($job.ext)_$(Stamp).cfe"
    $res = Invoke-Steps @(
        { Invoke-1C $Cfg.Prod @('/DumpCfg', $bak, '-Extension', $job.ext) 'backup' },
        { Invoke-1C $Cfg.Prod @('/LoadConfigFromFiles', $src, '-Extension', $job.ext) 'load' },
        { Invoke-1C $Cfg.Prod @('/UpdateDBCfg', '-Extension', $job.ext) 'update' },
        { Invoke-1C $Cfg.Prod @('/CheckModules', '-ThinClient', '-Server', '-Extension', $job.ext) 'check' }
    )
    $res.Log += "`nБэкап до выкатки: $bak"
    # 3) Обновляем выгрузку в main, чтобы она совпадала с рабочей базой
    if ($res.Ok) {
        Remove-Item $base -Recurse -Force
        $d = Invoke-1C $Cfg.Prod @('/DumpConfigToFiles', $base, '-Extension', $job.ext) 'dump-after'
        $res.Log += "`n" + $d.Log
    }
    $res
}

# --- обработка заданий -----------------------------------------------------

function Complete-Job($file, $job, $res) {
    $done = [ordered]@{
        id       = $job.id
        action   = $job.action
        ext      = $job.ext
        ref      = $job.ref
        ok       = $res.Ok
        finished = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        log      = if ($res.Log.Length -gt 50000) { $res.Log.Substring(0, 50000) + "`n…(обрезано)" } else { $res.Log }
    }
    $done | ConvertTo-Json -Depth 3 | Set-Content "$Repo\jobs\done\$($job.id).json" -Encoding UTF8
    Remove-Item $file.FullName -Force
    Push-Repo "Мост: $($job.id) $($job.action) — $(if ($res.Ok) { 'ок' } else { 'ошибка' })"
    $mark = if ($res.Ok) { 'OK' } else { 'ОШИБКА' }
    Send-Tg "$mark  $($job.id): $($job.action) $($job.ext)$($job.name)`n$($job.note)"
}

function Invoke-Job($file, $state) {
    $job = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $bad = $null
    if ($job.id -notmatch '^[A-Za-z0-9]+$') { $bad = "id только латиница и цифры" }
    elseif ($Actions -notcontains $job.action) { $bad = "действие не из белого списка: $($job.action)" }
    elseif (($job.action -in @('check-copy', 'load-copy', 'deploy-prod')) -and ($Cfg.Extensions -notcontains $job.ext)) { $bad = "расширение не разрешено в config.json: $($job.ext)" }
    elseif (($job.action -in @('load-copy', 'build-epf', 'deploy-prod')) -and ($job.ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$')) { $bad = "недопустимая ветка: $($job.ref)" }
    if ($bad) {
        if ($job.id -notmatch '^[A-Za-z0-9]+$') { $job | Add-Member -Force id ('bad' + (Stamp)) }
        Complete-Job $file $job ([pscustomobject]@{ Ok = $false; Log = "Задание отклонено: $bad" }); return
    }

    if ($job.action -eq 'deploy-prod') {
        if ($state.approved -notcontains $job.id) {
            if ($state.notified -notcontains $job.id) {
                Send-Tg "Выкатка в РАБОЧУЮ базу ждёт подтверждения`nЗадание: $($job.id)`nРасширение: $($job.ext)`nВетка: $($job.ref)`n$($job.note)`n`nРазрешить: /ok_$($job.id)"
                $state.notified += $job.id
            }
            return
        }
        if (-not (Test-DeployWindow)) { return }
    }

    Log "Старт $($job.id) $($job.action)"
    try {
        switch ($job.action) {
            'check-copy'  { $res = Do-CheckCopy $job }
            'load-copy'   { $res = Do-LoadCopy $job }
            'build-epf'   { $res = Do-BuildEpf $job }
            'dump-prod'   { $res = Do-DumpProd }
            'deploy-prod' { $res = Do-DeployProd $job }
        }
    } catch {
        $res = [pscustomobject]@{ Ok = $false; Log = "Исключение: $_" }
    }
    $state.notified = @($state.notified | Where-Object { $_ -ne $job.id })
    $state.approved = @($state.approved | Where-Object { $_ -ne $job.id })
    Log "Финиш $($job.id): $($res.Ok)"
    Complete-Job $file $job $res
}

# --- main ------------------------------------------------------------------

# Минутный запуск пропускает ход, если мост занят; ночной ждёт до 30 минут
for ($i = 0; Test-Path $LockFile; $i++) {
    if ((Get-Item $LockFile).LastWriteTime -lt (Get-Date).AddHours(-3)) { Remove-Item $LockFile -Force; break }
    if (-not $Nightly -or $i -ge 30) { exit 0 }
    Start-Sleep -Seconds 60
}
New-Item $LockFile -ItemType File -Force | Out-Null
$state = Get-State
try {
    Git pull -q --rebase origin main | Out-Null
    Git fetch -q --prune origin | Out-Null

    if ($Nightly) {
        $r = Do-DumpProd
        Set-Content "$Repo\jobs\done\nightly.log" $r.Log -Encoding UTF8
        Push-Repo "Ночная выгрузка $(Get-Date -Format 'yyyy-MM-dd')"
        if (-not $r.Ok) { Send-Tg "Ночная выгрузка 1С не удалась, лог: jobs/done/nightly.log" }
    } else {
        Update-Approvals $state
        Get-ChildItem "$Repo\jobs\inbox\*.json" | Sort-Object Name | ForEach-Object { Invoke-Job $_ $state }
    }
    $state.lastError = $null
} catch {
    $msg = "$_"
    Log "ОШИБКА: $msg"
    if ($state.lastError -ne $msg) { Send-Tg "Мост 1С: ошибка`n$msg"; $state.lastError = $msg }
} finally {
    Save-State $state
    if (Test-Path "$Work\wt") { try { Git worktree remove --force "$Work\wt" | Out-Null } catch {} }
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}
