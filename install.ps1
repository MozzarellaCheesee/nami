#Requires -Version 5.1
<#
.SYNOPSIS
    Скрипт установки Nami Music Server для Windows Server и Windows Desktop.
.DESCRIPTION
    Загружает последний релиз nami-server из GitHub, настраивает директорию установки,
    добавляет правило в Брандмауэр Windows (порт 4533), создаёт ярлык и фоновую задачу
    автозапуска, запускает сервер и открывает веб-мастер первичной настройки.
.PARAMETER Repo
    GitHub-репозиторий в формате "Owner/Repo". По умолчанию: MozzarellaCheesee/nami.
.PARAMETER InstallDir
    Путь установки. По умолчанию: $env:ProgramData\Nami (или $env:LOCALAPPDATA\Nami без админ-прав).
.PARAMETER Port
    Порт сервера (по умолчанию: 4533).
.PARAMETER SkipBrowser
    Не открывать веб-браузер автоматически после завершения установки.
.NOTES
    Файл намеренно сохранён БЕЗ BOM. Основной способ запуска - `irm ... | iex`, а с BOM
    Invoke-Expression не разбирает блок param() и падает на первой же строке. Обратная сторона:
    при сохранении файла на диск и запуске через -File PowerShell 5.1 прочитает его в ANSI.
    Поэтому запускайте одной командой из .EXAMPLE; при повышении прав скрипт сам скачивает свою
    копию и пишет её уже с BOM.
.EXAMPLE
    irm https://raw.githubusercontent.com/MozzarellaCheesee/nami/main/install.ps1 | iex
#>

[CmdletBinding()]
param(
    [string]$Repo = "MozzarellaCheesee/nami",
    [string]$InstallDir = "$env:ProgramData\Nami",
    [int]$Port = 4533,
    [switch]$SkipBrowser,
    # Имя пользователя до самоподнятия через UAC. Нужно, чтобы задача автозапуска
    # регистрировалась на реального человека, а не на аккаунт, от которого нажали
    # "Да" в диалоге UAC (это может быть другой администратор).
    [string]$OriginalUser
)

$ErrorActionPreference = "Stop"

# Очистка и заголовок
Clear-Host
Write-Host @"
  _   _                 _ 
 | \ | | __ _ _ __ ___ (_)
 |  \| |/ _` | '_ ` _ \| |
 | |\  | (_| | | | | | | |
 |_| \_|\__,_|_| |_| |_|_|
  Windows Server Installer
"@ -ForegroundColor Cyan

Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

# 1. Проверка разрядности ОС
if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error "Nami Server требует 64-битную операционную систему Windows (x64)."
    exit 1
}

# 2. Проверка прав Администратора
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    # Сохраняем реального пользователя ДО подъёма прав: после -Verb RunAs
    # WindowsIdentity.GetCurrent() будет показывать того, кто подтвердил UAC
    # (не обязательно того же человека), а он нужен ниже для задачи автозапуска.
    if (-not $OriginalUser) { $OriginalUser = "$env:USERDOMAIN\$env:USERNAME" }
    $elevateArgs = "-NoProfile -ExecutionPolicy Bypass -File `"{0}`" -OriginalUser `"$OriginalUser`""
    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) {
        # Скрипт запущен через `irm ... | iex` — файла на диске нет, а
        # `Start-Process -Verb RunAs` не умеет поднимать код из памяти.
        #
        # Взять собственный текст из $MyInvocation.MyCommand.Definition НЕЛЬЗЯ: под iex там
        # лежит не текст скрипта, а путь внешнего файла (а при запуске прямо из консоли —
        # пусто). Во временный .ps1 записалась бы строка с путём, и права поднимались бы
        # для неё. Поэтому честно скачиваем себя заново.
        #
        # Файл пишем с BOM: PowerShell 5.1 читает файлы без BOM в ANSI, и весь русский текст
        # при запуске через -File превращается в кракозябры. Самому себе BOM ставить при этом
        # нельзя — тогда ломается `irm | iex`, ради которого всё и затевалось.
        $scriptPath = Join-Path $env:TEMP "nami-install-$(Get-Random).ps1"
        $selfUrl = "https://raw.githubusercontent.com/$Repo/main/install.ps1"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $selfText = Invoke-RestMethod -Uri $selfUrl -UseBasicParsing
            [System.IO.File]::WriteAllText($scriptPath, $selfText, [System.Text.UTF8Encoding]::new($true))
        } catch {
            Write-Warning "Не удалось получить скрипт для запроса прав Администратора: $($_.Exception.Message)"
            Write-Warning "Продолжаем без повышения прав: брандмауэр и автозапуск настроены не будут."
            $scriptPath = $null
        }
    }
    if ($scriptPath) {
        Write-Host "Запрос прав Администратора для настройки Брандмауэра и автозапуска..." -ForegroundColor Yellow
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList ($elevateArgs -f $scriptPath)
            exit 0
        } catch {
            Write-Warning "Пользователь отклонил запрос UAC. Продолжаем установку с правами текущего пользователя."
        }
    }

    if (-not $isAdmin) {
        $InstallDir = "$env:LOCALAPPDATA\Nami"
        Write-Warning "Установка будет выполнена локально в: $InstallDir"
        Write-Warning "Правило брандмауэра может потребовать ручного добавления."
    }
}

Write-Host "[1/6] Подготовка рабочей директории..." -ForegroundColor Cyan
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Write-Host "      Папка установки: $InstallDir" -ForegroundColor Gray

$versionFile = Join-Path $InstallDir "version.txt"
$binPath = Join-Path $InstallDir "nami-server.exe"
$currentVersion = $null
if (Test-Path $binPath) {
    try { $currentVersion = ((& $binPath --version 2>$null) -split '\s+')[-1].TrimStart('v') } catch {}
}
if (-not $currentVersion -and (Test-Path $versionFile)) {
    $currentVersion = (Get-Content $versionFile -Raw).Trim().TrimStart('v')
}
if (-not $currentVersion) {
    # Сначала https: сервер поднимает мастер настройки только по TLS (см. server/src/main.rs),
    # и обычный http-запрос к нему просто не отвечает. Сертификат самоподписанный, поэтому на
    # время запроса проверку отключаем и сразу возвращаем обратно - глобальную настройку нельзя
    # оставлять выключенной, ниже по скрипту идут запросы к GitHub.
    $prevCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $currentVersion = (Invoke-RestMethod -Uri "https://127.0.0.1`:$Port/api/health" -TimeoutSec 2).version
    } catch {
        try { $currentVersion = (Invoke-RestMethod -Uri "http://127.0.0.1`:$Port/api/health" -TimeoutSec 2).version } catch {}
    } finally {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCallback
    }
}
$earlyTargetVersion = $null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $earlyRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "Nami-Windows-Installer"; "Accept" = "application/vnd.github+json" }
    $earlyTargetVersion = $earlyRelease.tag_name.TrimStart('v')
} catch {}
$upToDate = $false
if ($currentVersion -and $earlyTargetVersion -and $currentVersion.TrimStart('v') -eq $earlyTargetVersion) {
    Write-Host "      ✓ Обновления нет: у вас уже установлена последняя версия $currentVersion." -ForegroundColor Green
    $upToDate = $true
}
if ($currentVersion -and $earlyTargetVersion) {
    Write-Host "      Доступно обновление: $currentVersion → $earlyTargetVersion" -ForegroundColor Cyan
}

# 3. Проверка и автоматическая установка FFmpeg
Write-Host "[2/6] Проверка медиа-библиотеки FFmpeg..." -ForegroundColor Cyan
$ffmpegCmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($ffmpegCmd) {
    Write-Host "      ✓ FFmpeg обнаружен в системе: $($ffmpegCmd.Source)" -ForegroundColor Green
} else {
    Write-Host "      FFmpeg не найден. Попытка автоматической установки через winget..." -ForegroundColor Yellow
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    $installed = $false
    if ($wingetCmd) {
        try {
            Start-Process winget -ArgumentList "install -e --id Gyan.FFmpeg --scope machine --accept-source-agreements --accept-package-agreements --silent" -Wait -NoNewWindow
            # winget правит PATH в реестре, а текущий процесс держит его старое значение. Без
            # перечтения только что установленный (или уже стоявший) ffmpeg считается отсутствующим.
            $env:PATH = (@(
                [Environment]::GetEnvironmentVariable('PATH', 'Machine'),
                [Environment]::GetEnvironmentVariable('PATH', 'User')
            ) | Where-Object { $_ }) -join ';'
            $ffmpegCmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
            if ($ffmpegCmd) {
                Write-Host "      ✓ FFmpeg успешно установлен в систему: $($ffmpegCmd.Source)" -ForegroundColor Green
                $installed = $true
            }
        } catch {
            Write-Warning "Не удалось автоматически установить FFmpeg через winget."
        }
    }
    if (-not $installed) {
        Write-Host "      ⚠️  FFmpeg не установлен. Для включения транскодинга на лету выполните:" -ForegroundColor DarkYellow
        Write-Host "           winget install Gyan.FFmpeg" -ForegroundColor White
    }
}

# 4. Скачивание или сборка бинарника
Write-Host "[3/6] Получение бинарника Nami Server..." -ForegroundColor Cyan
$downloadSucceeded = $false

if ($upToDate) {
    # Версия уже последняя - шаг скачивания не нужен, но установка не обязана
    # на этом останавливаться: брандмауэр, служба, ярлыки и т.п. ниже по скрипту
    # должны выполниться в любом случае (например при переустановке или ремонте).
    Write-Host "      ✓ Бинарник уже актуальной версии, скачивание не требуется" -ForegroundColor Green
    $downloadSucceeded = $true
    $targetVersion = $currentVersion
} else {

$assetZip = "nami-server-windows-x86_64.zip"
$assetExe = "nami-server-windows-x86_64.exe"

try {
    Write-Host "      Запрос последнего релиза из GitHub ($Repo)..." -ForegroundColor Gray
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    $apiUrl = "https://api.github.com/repos/$Repo/releases"
    $headers = @{ "User-Agent" = "Nami-Windows-Installer"; "Accept" = "application/vnd.github+json" }
    $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction SilentlyContinue
    
    $downloadUrl = $null
    $targetVersion = $null
    if ($releases) {
        foreach ($rel in $releases) {
            if ($rel.assets) {
                $zipAsset = $rel.assets | Where-Object { $_.name -like "*windows-x86_64*.zip" } | Select-Object -First 1
                if ($zipAsset) {
                    $downloadUrl = $zipAsset.browser_download_url
                    $targetVersion = $rel.tag_name.TrimStart('v')
                    $isZip = $true
                    break
                }
                $exeAsset = $rel.assets | Where-Object { $_.name -like "*windows-x86_64*.exe" } | Select-Object -First 1
                if ($exeAsset) {
                    $downloadUrl = $exeAsset.browser_download_url
                    $targetVersion = $rel.tag_name.TrimStart('v')
                    $isZip = $false
                    break
                }
            }
        }
    }
    
    if (-not $downloadUrl) {
        $downloadUrl = "https://github.com/$Repo/releases/download/v0.1.1-beta.1/$assetZip"
        $targetVersion = "0.1.1-beta.1"
        $isZip = $true
    }

    if ($currentVersion) {
        Write-Host "      Обновление: $currentVersion → $targetVersion" -ForegroundColor Cyan
    }
    
    Write-Host "      Загрузка с: $downloadUrl" -ForegroundColor Gray
    # Расширение обязано быть настоящим: Expand-Archive отказывается работать с чем угодно,
    # кроме .zip, и падает на .tmp с "неподдерживаемый формат файла архива".
    $tempFile = Join-Path $env:TEMP $(if ($isZip) { "nami-server-download.zip" } else { "nami-server-download.exe" })
    
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing

    # Остановим предыдущий запущенный процесс, если он работает. Задачу автозапуска
    # тоже временно отключаем: иначе при RestartCount=3 планировщик может успеть
    # перезапустить только что убитый процесс за то же мгновение, и старый
    # nami-server.exe снова заблокирует файл к моменту Copy-Item.
    $namiTask = Get-ScheduledTask -TaskName "NamiServer" -ErrorAction SilentlyContinue
    if ($namiTask) { Disable-ScheduledTask -TaskName "NamiServer" -ErrorAction SilentlyContinue | Out-Null }
    Get-Process "nami-server" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # Copy-Item с повтором: файл ещё может быть занят, если процесс не успел
    # освободить хендл (антивирус, медленное завершение и т.п.).
    function Copy-BinaryWithRetry([string]$From, [string]$To) {
        for ($i = 1; $i -le 5; $i++) {
            try { Copy-Item -Path $From -Destination $To -Force; return $true } catch {
                if ($i -eq 5) { throw }
                Start-Sleep -Milliseconds 500
            }
        }
    }

    if ($isZip) {
        Write-Host "      Распаковка архива..." -ForegroundColor Gray
        $tempExtract = Join-Path $env:TEMP "nami-extract-$(Get-Random)"
        Expand-Archive -Path $tempFile -DestinationPath $tempExtract -Force

        $foundExe = Get-ChildItem -Path $tempExtract -Filter "nami-server*.exe" -Recurse | Select-Object -First 1
        if ($foundExe) {
            $downloadSucceeded = Copy-BinaryWithRetry -From $foundExe.FullName -To $binPath
        }
        # Мост Discord (Rich Presence) едет в том же архиве; сервер находит его рядом с собой.
        $bridgeSrc = Get-ChildItem -Path $tempExtract -Filter "discord-bridge" -Directory -Recurse | Select-Object -First 1
        if ($bridgeSrc) {
            $bridgeDst = Join-Path $InstallDir "discord-bridge"
            New-Item -ItemType Directory -Force -Path $bridgeDst | Out-Null
            Copy-Item -Path (Join-Path $bridgeSrc.FullName "*") -Destination $bridgeDst -Force -ErrorAction SilentlyContinue
            Write-Host "      Мост Discord установлен: $bridgeDst" -ForegroundColor Green
        }
        Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        $downloadSucceeded = Copy-BinaryWithRetry -From $tempFile -To $binPath
    }
    if ($namiTask) { Enable-ScheduledTask -TaskName "NamiServer" -ErrorAction SilentlyContinue | Out-Null }
    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
} catch {
    Write-Warning "      Не удалось скачать предсобранный релиз: $($_.Exception.Message)"
}

# Запасной вариант: локальная компиляция, если есть cargo
if (-not $downloadSucceeded -or -not (Test-Path $binPath)) {
    $cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
    if ($cargoCmd) {
        Write-Host "      Обнаружен компилятор Rust (cargo). Сборка nami-server из исходников..." -ForegroundColor Yellow
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        $repoRoot = Split-Path -Parent $scriptDir
        
        if (Test-Path (Join-Path $repoRoot "server\Cargo.toml")) {
            Push-Location (Join-Path $repoRoot "server")
            cargo build --release
            Pop-Location
            $builtExe = Join-Path $repoRoot "server\target\release\nami-server.exe"
            if (Test-Path $builtExe) {
                Copy-Item -Path $builtExe -Destination $binPath -Force
                $downloadSucceeded = $true
            }
        }
    }
}

}

if (-not (Test-Path $binPath)) {
    Write-Error "Не удалось получить или собрать nami-server.exe. Проверьте интернет-соединение или наличие релизов на GitHub."
    exit 1
}
Write-Host "      ✓ Исполняемый файл готов: $binPath" -ForegroundColor Green
if ($targetVersion) {
    Set-Content -LiteralPath $versionFile -Value $targetVersion -Encoding ASCII
    if ($currentVersion) {
        Write-Host "      ✓ Сервер обновлён: $currentVersion → $targetVersion" -ForegroundColor Green
    } else {
        Write-Host "      ✓ Установлена версия $targetVersion" -ForegroundColor Green
    }
}

# 5. Настройка Брандмауэра Windows
Write-Host "[4/6] Настройка сетевого доступа (Брандмауэр Windows)..." -ForegroundColor Cyan
if ($isAdmin) {
    try {
        $ruleName = "Nami Music Server (TCP $Port)"
        $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if (-not $existingRule) {
            New-NetFirewallRule -DisplayName $ruleName `
                -Description "Разрешить входящие подключения к Hi-Res аудиосерверу Nami" `
                -Direction Inbound `
                -LocalPort $Port `
                -Protocol TCP `
                -Action Allow `
                -Profile Any `
                -Program $binPath | Out-Null
            Write-Host "      ✓ Правило брандмауэра успешно создано для порта $Port" -ForegroundColor Green
        } else {
            Write-Host "      ✓ Правило брандмауэра уже существует" -ForegroundColor Green
        }
    } catch {
        Write-Warning "      Не удалось настроить брандмауэр: $($_.Exception.Message)"
    }
} else {
    Write-Warning "      Пропуск настройки брандмауэра (требуются права Администратора)."
    Write-Warning "      Если смартфон не сможет подключиться, добавьте порт $Port TCP в исключения Брандмауэра."
}

# Порт передаётся серверу через NAMI_PORT (см. server/src/config.rs) — сам по себе
# параметр -Port иначе влиял бы только на правило брандмауэра и текст подсказок,
# а сервер продолжал бы слушать порт по умолчанию 4533.
# ВАЖНО: config.rs применяет NAMI_PORT ПОСЛЕ чтения config.toml, то есть переменная
# окружения перебивает порт, который пользователь позже выберет в мастере /setup.
# Поэтому переменную ставим только при нестандартном -Port, а при значении по
# умолчанию — снимаем (в обоих scope), чтобы не осталась висеть с прошлого запуска
# с другим портом и не мешала конфигу из мастера.
if ($Port -ne 4533) {
    [Environment]::SetEnvironmentVariable('NAMI_PORT', $Port, $(if ($isAdmin) { 'Machine' } else { 'User' }))
    $env:NAMI_PORT = $Port
} else {
    try { [Environment]::SetEnvironmentVariable('NAMI_PORT', $null, 'Machine') } catch {}
    try { [Environment]::SetEnvironmentVariable('NAMI_PORT', $null, 'User') } catch {}
    Remove-Item Env:\NAMI_PORT -ErrorAction SilentlyContinue
}

# 6. Ярлыки управления
# Ярлык ведёт НЕ на сам сервер, а на экран управления (`nami-server tui`). Раньше он запускал
# сервер напрямую: на экране висело чёрное консольное окно, закрытие которого выключало сервер,
# и понять по нему, работает ли что-то, было нельзя.
Write-Host "[5/6] Создание ярлыков..." -ForegroundColor Cyan
try {
    $wshShell = New-Object -ComObject WScript.Shell

    foreach ($folder in @([Environment]::GetFolderPath("Desktop"),
                          $(if ($isAdmin) { [Environment]::GetFolderPath("CommonPrograms") } else { [Environment]::GetFolderPath("Programs") }))) {
        $shortcutPath = Join-Path $folder "Nami - сервер.lnk"
        $shortcut = $wshShell.CreateShortcut($shortcutPath)
        # Запуск через powershell, а не напрямую: ярлык на exe с аргументом закрывает окно
        # сразу после выхода из TUI, и сообщение об ошибке (например «нужны права
        # администратора») человек не успевает прочитать.
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-NoProfile -NoExit -Command & '$binPath' tui"
        $shortcut.WorkingDirectory = $InstallDir
        $shortcut.Description = "Управление сервером Nami: включить, выключить, пользователи, библиотека"
        $shortcut.Save()
    }
    Write-Host "      ✓ Ярлык «Nami - сервер» создан на рабочем столе и в меню Пуск" -ForegroundColor Green
} catch {
    Write-Warning "      Не удалось создать ярлык: $($_.Exception.Message)"
}

# 7. Служба Windows и запуск
# Служба, а не задача планировщика: задача стартует по ВХОДУ пользователя (перезагрузили
# машину и не залогинились — сервера нет) и запускает обычное консольное приложение с окном.
# Служба поднимается вместе с Windows и живёт без окна вовсе.
Write-Host "[6/6] Запуск Nami Server..." -ForegroundColor Cyan
try {
    # Задача от прошлых версий больше не нужна: иначе сервер поднимался бы дважды —
    # службой и задачей — и второй экземпляр падал бы на занятом порту.
    if (Get-ScheduledTask -TaskName "NamiServer" -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName "NamiServer" -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "      Старая задача автозапуска удалена (её заменяет служба)." -ForegroundColor Gray
    }
} catch {}

$serviceReady = $false
if ($isAdmin) {
    try {
        # Всегда install, а не stop/start по факту существования: install переподключает
        # путь службы на актуальный exe, если служба существует, но зарегистрирована на
        # другую копию (переустановка в другую папку, сборка разработчика и т.п.) - раньше
        # stop/start запускал СТАРЫЙ путь как есть, без свежего config.toml, и пользователь
        # видел рабочий сайт через запасной процесс ниже, а после ручного запуска "той же"
        # службы попадал на пустой конфиг и мастер настройки заново.
        & $binPath service install 2>$null | Out-Null
        Start-Sleep -Seconds 2
        $svc = Get-Service -Name "NamiServer" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            $serviceReady = $true
            Write-Host "      ✓ Служба «NamiServer» работает и будет запускаться вместе с Windows" -ForegroundColor Green
        }
    } catch {
        Write-Warning "      Не удалось зарегистрировать службу: $($_.Exception.Message)"
    }
} else {
    Write-Warning "      Без прав Администратора служба не регистрируется."
}

if (-not $serviceReady) {
    # Запасной путь: без службы поднимаем обычный процесс, скрыв окно. Пользователь хотя бы
    # получит работающий сервер до конца сеанса.
    try {
        $running = Get-Process "nami-server" -ErrorAction SilentlyContinue
        if (-not $running) {
            Start-Process -FilePath $binPath -WorkingDirectory $InstallDir -WindowStyle Hidden
            Write-Host "      Сервер запущен как обычный процесс (до перезагрузки)." -ForegroundColor Yellow
        } else {
            Write-Host "      Сервер уже запущен (PID: $($running.Id))." -ForegroundColor Green
        }
    } catch {
        Write-Warning "      Не удалось запустить сервер: $($_.Exception.Message)"
    }
}

# Определение локального IP-адреса для подсказки подключения. Не фильтруем по конкретным
# именам адаптеров (Wi-Fi/Ethernet/...) — они зависят от локали и оборудования и не покрывают
# все варианты (USB-модемы, переименованные подключения и т.д.); вместо этого просто
# отбрасываем loopback, APIPA и явно виртуальные интерфейсы.
$localIP = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and
        $_.InterfaceAlias -notmatch "Loopback|vEthernet|Virtual|VPN"
    } |
    Select-Object -ExpandProperty IPAddress -First 1)

if (-not $localIP) { $localIP = "127.0.0.1" }

Start-Sleep -Seconds 2

# Именно https: без config.toml сервер поднимает ТОЛЬКО защищённый мастер настройки, чтобы
# пароль администратора не уходил открытым текстом. По http там никто не отвечает, и браузер
# показывал пустую страницу вместо мастера.
$setupUrl = "https://localhost:$Port/setup"
$lanSetupUrl = "https://$localIP`:$Port/setup"

if (-not $SkipBrowser) {
    try {
        Write-Host "      Открытие мастера настройки в браузере..." -ForegroundColor Gray
        Start-Process $setupUrl
    } catch {
        Write-Warning "      Не удалось открыть браузер автоматически. Откройте вручную: $setupUrl"
    }
}

Write-Host @"

======================================================================
  🎉 Nami Server успешно установлен и готов к работе!
======================================================================

  ШАГ 1. Первичная настройка (открыта в браузере):
         👉 $setupUrl
         (для настройки с других устройств: $lanSetupUrl)

         Браузер предупредит о сертификате - это нормально. Сертификат самоподписанный:
         он шифрует пароль по дороге, но подтвердить его некому. Нажмите «Дополнительно»
         и перейдите на страницу. Приложение сверяет отпечаток этого сертификата само.

  ШАГ 2. В мастере укажите:
         • Папку с музыкальной коллекцией (например: D:\Music);
         • Логин и пароль администратора (от 8 символов);
         • Нажмите «Сохранить конфигурацию».

  ШАГ 3. Перезапустите сервер: ярлык «Nami - сервер» на рабочем столе,
         первый пункт выключает, второе нажатие включает обратно.

  ШАГ 4. Сопряжение с Android-клиентом:
         • Снова откройте $lanSetupUrl
         • Отсканируйте отобразившийся QR-код камерой в приложении Nami:
           «Настройки» → «Подключить сервер» → «Сканировать QR».

  ДАЛЬШЕ. Ярлык «Nami - сервер» на рабочем столе показывает, работает ли сервер,
         по какому адресу подключаться и сколько треков в библиотеке. Там же
         включение и выключение, пользователи, папки и сканирование.

  Сервер работает службой Windows: запускается вместе с системой, ещё до входа
  в учётную запись, и не держит на экране консольного окна.

  Рабочая директория: $InstallDir
======================================================================

"@ -ForegroundColor Green
