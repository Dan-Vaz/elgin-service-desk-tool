# ==============================================================================
# Elgin Service Desk Tool
# Ferramenta online de instalacao, limpeza, diagnostico e suporte para Windows
# Interface em WPF/XAML - tema claro/escuro com toggle em tempo real.
#
# Execucao recomendada via Gist Raw URL (chamado por um .bat de atalho):
# powershell.exe -NoProfile -STA -Command "`$env:ELGIN_SERVICE_DESK_URL='RAW_URL_DO_GIST'; irm `$env:ELGIN_SERVICE_DESK_URL | iex"
#
# Como o script e sempre baixado fresco do Gist a cada execucao, nao ha
# mecanismo de auto-update: a versao mais recente e sempre a que roda.
# ==============================================================================

#requires -Version 5.1

param(
    [switch]$Silent,
    [string]$SourceUrl = $env:ELGIN_SERVICE_DESK_URL,
    [switch]$NoElevatePrompt
)

$ErrorActionPreference = "Stop"

try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName PresentationCore       -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase             -ErrorAction Stop
} catch {
    Write-Host "Nao foi possivel carregar WPF (PresentationFramework). Execute em Windows com interface grafica." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# ==============================================================================
# CONFIGURACAO GLOBAL
# ==============================================================================
$global:AppName       = "Elgin Service Desk Tool"
$global:AppVersion    = "3.0"
$global:SchemaVersion = 1
$global:BasePath      = Join-Path $env:ProgramData "ElginServiceDesk"
$global:ConfigPath    = Join-Path $global:BasePath  "Config"
$global:AssetsPath    = Join-Path $global:BasePath  "Assets"
$global:ReportsPath   = Join-Path $global:BasePath  "Relatorios"
$global:ConfigFile    = Join-Path $global:ConfigPath "apps.json"
$global:ExtraConfigFile   = Join-Path $global:ConfigPath "extra_apps.json"
$global:PrinterConfigFile = Join-Path $global:ConfigPath "printers_config.json"
$global:PrinterCacheFile  = Join-Path $global:BasePath   "printers_cache.json"
$global:UiPrefsFile   = Join-Path $global:ConfigPath "ui_prefs.json"
$global:ChecklistStateFile = Join-Path $global:ConfigPath "checklist_state.json"
$global:LogFile       = Join-Path $global:BasePath   "servicedesk.log"
$global:LogoFile      = Join-Path $global:AssetsPath "logo-elgin.png"
$global:IconFile      = Join-Path $global:AssetsPath "app-elgin.ico"
$global:LogoUrl       = "https://i.ibb.co/XfXbR88H/Logo.png"
$global:FormIcon      = $null

# URL do RemoveWindowsAI fixada num commit especifico (nao "main") para reduzir
# risco de supply chain: se o repositorio de terceiro for comprometido depois
# deste commit, esta ferramenta continua executando so o codigo ja auditado.
$global:RemoveWindowsAIUrl = "https://raw.githubusercontent.com/zoicware/RemoveWindowsAI/47a0b26d43e400e6109933f27cb24629e8a59251/RemoveWindowsAi.ps1"

$global:IsAdmin       = $false
$global:HasWinget     = $false
$global:HasChoco      = $false
$global:HasInternet   = $false
$global:WingetPath    = $null
$global:ChocoPath     = $null
$global:AppsList        = New-Object System.Collections.ArrayList
$global:ExtraAppsList   = New-Object System.Collections.ArrayList
$global:PrintersList     = New-Object System.Collections.ArrayList

$global:StatusLabel     = $null
$global:LogTextBox      = $null
$global:MainWindow      = $null
$global:CurrentTheme    = "Dark"
$global:CurrentSection  = "Instalar"
$global:LogErrorCount   = 0
$global:BellBadgeLabel  = $null
$global:BellBadgeBorder = $null
$global:NavButtons      = $null
$global:ShowSectionRef  = $null

function Get-Brush { param([string]$Hex) [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex) }

# Le um brush do dicionario de recursos ATUAL da janela principal (dark/light).
# Usado para colorir programaticamente (ex.: destaque do item de menu ativo)
# sem hardcodar hex - assim acompanha o tema quando o usuario alterna.
function Get-ThemeBrush {
    param([Parameter(Mandatory=$true)][string]$Key)
    if ($global:MainWindow -eq $null) { return $null }
    try { return $global:MainWindow.TryFindResource($Key) } catch { return $null }
}

# ==============================================================================
# FUNCOES BASE
# ==============================================================================
function Test-IsAdmin {
    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Show-Info    { param([string]$Message,[string]$Title=$global:AppName) [System.Windows.MessageBox]::Show($Message,$Title,[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Information) | Out-Null }
function Show-Warning { param([string]$Message,[string]$Title=$global:AppName) [System.Windows.MessageBox]::Show($Message,$Title,[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Warning) | Out-Null }
function Show-ErrorBox{ param([string]$Message,[string]$Title=$global:AppName) [System.Windows.MessageBox]::Show($Message,$Title,[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Error) | Out-Null }
function Confirm-Action {
    param([string]$Message,[string]$Title="Confirmacao")
    return ([System.Windows.MessageBox]::Show($Message,$Title,[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Question) -eq [System.Windows.MessageBoxResult]::Yes)
}

function Initialize-Folders {
    foreach ($path in @($global:BasePath,$global:ConfigPath,$global:AssetsPath,$global:ReportsPath)) {
        if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
    try {
        if ((Test-Path $global:LogFile) -and (Get-Item $global:LogFile -EA SilentlyContinue).Length -gt 5MB) {
            $rotated = $global:LogFile + ".1"
            if (Test-Path $rotated) { Remove-Item $rotated -Force -EA SilentlyContinue }
            Rename-Item -Path $global:LogFile -NewName ([System.IO.Path]::GetFileName($rotated)) -Force -EA SilentlyContinue
        }
    } catch {}
}

function Write-Log {
    param([Parameter(Mandatory=$true)][string]$Message,[ValidateSet("INFO","WARN","ERROR","SUCCESS")][string]$Level="INFO")
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $line      = "[{0}][{1}] {2}" -f $timestamp,$Level,$Message
        Add-Content -Path $global:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($global:LogTextBox -ne $null) {
            $global:LogTextBox.AppendText($line + [Environment]::NewLine)
            $global:LogTextBox.ScrollToEnd()
        }
        if ($Level -eq "ERROR") {
            $global:LogErrorCount++
            try {
                if ($global:BellBadgeLabel -ne $null) { $global:BellBadgeLabel.Text = [string]$global:LogErrorCount }
                if ($global:BellBadgeBorder -ne $null) { $global:BellBadgeBorder.Visibility = "Visible" }
            } catch {}
        }
    } catch {}
}

Initialize-Folders

# Reabre a propria ferramenta como Administrador via UAC, re-executando o
# mesmo comando irm/iex a partir do Gist (nao ha .exe proprio para relancar,
# ja que o script e sempre baixado fresco).
function Request-AdminElevation {
    param([string]$Url,[switch]$SilentMode)
    if (Test-IsAdmin) { return $true }
    if ([string]::IsNullOrWhiteSpace($Url)) {
        Write-Log -Message "[ELEVATE] SourceUrl vazia - nao e possivel montar o comando de elevacao." -Level "ERROR"
        return $false
    }
    $message = "Para instalar aplicativos, limpar componentes do Windows, executar reparos e usar o desinstalador avancado, a ferramenta precisa de permissao administrativa.`n`nO Windows exibira a janela oficial do UAC. A ferramenta nao coleta, nao armazena e nao visualiza credenciais.`n`nDeseja reabrir agora como Administrador?"
    $shouldElevate = $true
    if (-not $SilentMode) { $shouldElevate = Confirm-Action $message "Permissao administrativa necessaria" }
    if (-not $shouldElevate) { return $false }
    try {
        $safeUrl = $Url.Replace("'","''")
        $command = "`$env:ELGIN_SERVICE_DESK_URL='$safeUrl'; irm `$env:ELGIN_SERVICE_DESK_URL | iex"
        Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-STA","-Command",$command) -Verb RunAs | Out-Null
        return $true
    } catch {
        Write-Log -Message ("[ELEVATE] Falha ao solicitar elevacao: {0}" -f $_.Exception.Message) -Level "ERROR"
        Show-ErrorBox ("Nao foi possivel solicitar elevacao administrativa.`n`n{0}" -f $_.Exception.Message)
        return $false
    }
}

if (-not $NoElevatePrompt -and -not (Test-IsAdmin)) {
    $elevated = Request-AdminElevation -Url $SourceUrl -SilentMode:$Silent
    if ($elevated) { exit 0 }
}

function Set-Status {
    param([string]$Text,[ValidateSet("INFO","WARN","ERROR","SUCCESS")][string]$Level="INFO")
    if ($global:StatusLabel -ne $null) { $global:StatusLabel.Text = $Text }
    Write-Log -Message $Text -Level $Level
}

function Update-SessionPath {
    try {
        $machinePath = [Environment]::GetEnvironmentVariable("Path","Machine")
        $userPath    = [Environment]::GetEnvironmentVariable("Path","User")
        $paths       = @($machinePath,$userPath,$env:Path) -join ";"
        $chocoBin    = Join-Path $env:ProgramData "chocolatey\bin"
        if ((Test-Path $chocoBin) -and ($paths -notlike "*$chocoBin*")) { $paths = $paths + ";" + $chocoBin }
        $wingetAliasDir = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
        if ((Test-Path $wingetAliasDir) -and ($paths -notlike "*$wingetAliasDir*")) { $paths = $paths + ";" + $wingetAliasDir }
        $env:Path = $paths
    } catch { Write-Log -Message ("Falha ao atualizar PATH: {0}" -f $_.Exception.Message) -Level "WARN" }
}

function Resolve-WingetExe {
    try {
        $pkg = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation) {
            $w = Join-Path $pkg.InstallLocation "winget.exe"
            if (Test-Path $w) { return $w }
        }
    } catch {}
    try {
        $waRoot = Join-Path $env:ProgramFiles "WindowsApps"
        if (Test-Path $waRoot) {
            $cands = Get-ChildItem $waRoot -Directory -Filter "Microsoft.DesktopAppInstaller_*" -ErrorAction SilentlyContinue |
                     ForEach-Object {
                        $v = [version]"0.0.0.0"
                        if ($_.Name -match 'DesktopAppInstaller_(\d+\.\d+\.\d+\.\d+)_') { try { $v=[version]$matches[1] } catch {} }
                        [PSCustomObject]@{ Path=(Join-Path $_.FullName "winget.exe"); Ver=$v }
                     } | Where-Object { Test-Path $_.Path } | Sort-Object Ver -Descending
            if ($cands -and $cands.Count -gt 0) { return $cands[0].Path }
        }
    } catch {}
    $alias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
    if (Test-Path $alias) { return $alias }
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c -and $c.Source -and (Test-Path $c.Source)) { return $c.Source }
    return $null
}

function Resolve-ChocoExe {
    $c = Get-Command choco.exe -ErrorAction SilentlyContinue
    if ($c -and $c.Source -and (Test-Path $c.Source)) { return $c.Source }
    $d = Join-Path $env:ProgramData "chocolatey\bin\choco.exe"
    if (Test-Path $d) { return $d }
    return $null
}

function Test-InternetConnection {
    try { $ping = New-Object System.Net.NetworkInformation.Ping; $r=$ping.Send("1.1.1.1",2000); return ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) } catch { return $false }
}

function Update-Prerequisites {
    Update-SessionPath
    $global:IsAdmin     = Test-IsAdmin
    $global:WingetPath  = Resolve-WingetExe
    $global:ChocoPath   = Resolve-ChocoExe
    $global:HasWinget   = ($global:WingetPath -ne $null)
    $global:HasChoco    = ($global:ChocoPath  -ne $null)
    $global:HasInternet = Test-InternetConnection
}

function Get-CommandPathSafe {
    param([Parameter(Mandatory=$true)][string]$Name)
    if ($Name -eq "winget") { $w = if($global:WingetPath){$global:WingetPath}else{Resolve-WingetExe}; if($w){return $w} }
    if ($Name -eq "choco")  { $c = if($global:ChocoPath){$global:ChocoPath}else{Resolve-ChocoExe};   if($c){return $c} }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $Name
}

function ConvertTo-ProcessArgumentString {
    param([string[]]$Arguments=@())
    $quote   = [char]34
    $escaped = foreach ($arg in @($Arguments)) {
        if ($null -eq $arg) { continue }
        $text       = [string]$arg
        $needsQuote = $text.Contains(' ') -or $text.Contains("`t") -or $text.Contains([string]$quote)
        $text       = $text.Replace([string]$quote,([string]$quote+[string]$quote))
        if ($needsQuote) { ([string]$quote+$text+[string]$quote) } else { $text }
    }
    return ($escaped -join ' ')
}

# -- Win32: trazer janelas de instaladores para frente --
# Por causa do foreground-lock do Windows, instaladores as vezes abrem ATRAS
# da ferramenta. Estas APIs restauram e ativam a janela do processo do
# instalador. Carregado uma unica vez (guarda por PSTypeName evita erro de
# re-definicao em iex).
if (-not ([System.Management.Automation.PSTypeName]'Elgin.Win32').Type) {
    try {
        Add-Type -Namespace Elgin -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
'@ -ErrorAction Stop
    } catch {}
}

# Espera o processo criar a janela principal e a traz para frente (clicavel).
function Set-WindowForeground {
    param($Proc,[int]$TimeoutSeconds=15)
    if ($null -eq $Proc) { return }
    if (-not ([System.Management.Automation.PSTypeName]'Elgin.Win32').Type) { return }
    $swFG = [System.Diagnostics.Stopwatch]::StartNew()
    while ($swFG.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $h = [IntPtr]::Zero
        try { $Proc.Refresh(); if (-not $Proc.HasExited) { $h = $Proc.MainWindowHandle } } catch { break }
        if ($h -ne [IntPtr]::Zero) {
            try {
                [Elgin.Win32]::ShowWindow($h, 9) | Out-Null                              # SW_RESTORE
                [Elgin.Win32]::SetWindowPos($h,[IntPtr](-1),0,0,0,0,0x0003) | Out-Null   # HWND_TOPMOST | NOMOVE|NOSIZE
                [Elgin.Win32]::SetWindowPos($h,[IntPtr](-2),0,0,0,0,0x0003) | Out-Null   # HWND_NOTOPMOST
                [Elgin.Win32]::BringWindowToTop($h) | Out-Null
                [Elgin.Win32]::SetForegroundWindow($h) | Out-Null
            } catch {}
            return
        }
        try { if ($Proc.HasExited) { return } } catch { return }
        Start-Sleep -Milliseconds 250
    }
    $swFG.Stop()
}

function Invoke-ManagedProcess {
    param([Parameter(Mandatory=$true)][string]$FilePath,[string[]]$Arguments=@(),[string]$Description="Processo",[int]$TimeoutSeconds=0)
    $argLine = ConvertTo-ProcessArgumentString -Arguments $Arguments
    Write-Log -Message ("{0}: {1} {2}" -f $Description,$FilePath,$argLine)
    $proc = $null
    try {
        $quote=[char]34
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $env:ComSpec
        # Roda atraves do cmd.exe com 2>&1 para mesclar stderr em stdout num
        # unico pipe - evita o deadlock classico de redirecionamento (ler um
        # stream ate o fim enquanto o outro, ainda nao lido, enche o buffer e
        # trava o processo filho). So existe um stream para ler de forma
        # sincrona depois do processo terminar.
        $psi.Arguments              = "/d /s /c "+$quote+$quote+$FilePath+$quote+" "+$argLine+" 2>&1"+$quote
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $false
        $psi.CreateNoWindow         = $true
        $psi.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $output = $proc.StandardOutput.ReadToEnd()
        $errorText = ""

        $waitMs = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds * 1000 } else { [int]::MaxValue }
        $exited = $proc.WaitForExit($waitMs)
        if (-not $exited) {
            try{$proc.Kill()}catch{}
            return [PSCustomObject]@{ExitCode=-999;Output=$output;Error=("Timeout apos {0}s" -f $TimeoutSeconds)}
        }

        $exit      = try { $proc.ExitCode } catch { -1 }
        if ($output -and $output.Trim()) { Write-Log -Message $output.Trim() }
        return [PSCustomObject]@{ExitCode=$exit;Output=$output;Error=$errorText}
    } catch {
        Write-Log -Message ("Falha em {0}: {1}" -f $Description,$_.Exception.Message) -Level "ERROR"
        return [PSCustomObject]@{ExitCode=-1;Output="";Error=$_.Exception.Message}
    } finally {
        if ($proc -ne $null) { try { $proc.Dispose() } catch {} }
    }
}

function Invoke-ConsoleCommand {
    param([Parameter(Mandatory=$true)][string]$CommandLine,[string]$Description="Comando",[int]$TimeoutSeconds=45)
    Write-Log -Message ("{0}: {1}" -f $Description,$CommandLine)
    $proc=$null
    try {
        $quote=[char]34
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $env:ComSpec
        $psi.Arguments              = "/d /s /c "+$quote+$CommandLine+" 2>&1"+$quote
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $false
        $psi.CreateNoWindow         = $true
        $psi.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $output = $proc.StandardOutput.ReadToEnd()
        $errorText = ""
        $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try{$proc.Kill()}catch{}
            return [PSCustomObject]@{ExitCode=-999;Output=$output;Error=("Timeout apos {0}s" -f $TimeoutSeconds)}
        }
        $exit=try{$proc.ExitCode}catch{-1}
        if ($output)    { Write-Log -Message $output.Trim() }
        if ($errorText) { Write-Log -Message $errorText.Trim() -Level "WARN" }
        return [PSCustomObject]@{ExitCode=$exit;Output=$output;Error=$errorText}
    } catch {
        Write-Log -Message ("Falha em {0}: {1}" -f $Description,$_.Exception.Message) -Level "ERROR"
        return [PSCustomObject]@{ExitCode=-1;Output="";Error=$_.Exception.Message}
    } finally {
        if ($proc -ne $null) { try { $proc.Dispose() } catch {} }
    }
}

# ==============================================================================
# BRANDING - baixa a logo oficial e gera o .ico usado na janela/taskbar
# ==============================================================================
function Save-LogoIconFile {
    param([string]$PngPath,[string]$IcoPath)
    try {
        $src=[System.Drawing.Image]::FromFile($PngPath)
        $sizes=@(16,24,32,48,64,128,256)
        $blocks=@()
        foreach($s in $sizes){
            $bmp=New-Object System.Drawing.Bitmap($s,$s)
            $g=[System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode=[System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.DrawImage($src,0,0,$s,$s); $g.Dispose()
            $ms=New-Object System.IO.MemoryStream
            $bmp.Save($ms,[System.Drawing.Imaging.ImageFormat]::Png)
            $blocks+=,($ms.ToArray()); $bmp.Dispose(); $ms.Dispose()
        }
        $src.Dispose()
        $out=New-Object System.IO.MemoryStream
        $bw=New-Object System.IO.BinaryWriter($out)
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
        $offset=6+16*$sizes.Count
        for($i=0;$i -lt $sizes.Count;$i++){
            $s=$sizes[$i]; $d=$blocks[$i]; $wb=if($s -ge 256){0}else{$s}
            $bw.Write([byte]$wb); $bw.Write([byte]$wb); $bw.Write([byte]0); $bw.Write([byte]0)
            $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$d.Length); $bw.Write([uint32]$offset)
            $offset+=$d.Length
        }
        foreach($d in $blocks){ $bw.Write($d) }
        $bw.Flush(); [System.IO.File]::WriteAllBytes($IcoPath,$out.ToArray()); $out.Dispose()
        return $true
    } catch { Write-Log -Message ("Nao foi possivel gerar o icone: {0}" -f $_.Exception.Message) -Level "WARN"; return $false }
}

function Initialize-BrandingAssets {
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        if (-not (Test-Path $global:LogoFile)) {
            $dlOk=$false
            try {
                Invoke-WebRequest -Uri $global:LogoUrl -OutFile $global:LogoFile -UseBasicParsing -Headers @{ "User-Agent"="Mozilla/5.0 (Windows NT 10.0; Win64; x64)" } -ErrorAction Stop
                $dlOk=$true
            } catch {}
            if (-not $dlOk) {
                $curl="$env:SystemRoot\System32\curl.exe"
                if (-not (Test-Path $curl)) { $curl="$env:SystemRoot\SysWOW64\curl.exe" }
                if (Test-Path $curl) { try { & $curl -L --silent --fail -A "Mozilla/5.0" -o $global:LogoFile $global:LogoUrl | Out-Null; if($LASTEXITCODE -eq 0){$dlOk=$true} } catch {} }
            }
            if ($dlOk) { Write-Log -Message "Logo oficial configurada." } else { Write-Log -Message "Nao foi possivel baixar a logo oficial." -Level "WARN" }
        }
        if ((Test-Path $global:LogoFile) -and -not (Test-Path $global:IconFile)) {
            [void](Save-LogoIconFile -PngPath $global:LogoFile -IcoPath $global:IconFile)
        }
        if (Test-Path $global:IconFile) {
            try { $global:FormIcon = New-Object System.Drawing.Icon($global:IconFile) } catch {}
        }
    } catch { Write-Log -Message ("Branding: {0}" -f $_.Exception.Message) -Level "WARN" }
}

# ==============================================================================
# TEMA (claro/escuro) - troca em tempo real via ResourceDictionary
# ==============================================================================
# Todo o XAML principal referencia cores via {DynamicResource BrushXxx}. Trocar
# de tema so exige limpar e recarregar Window.Resources.MergedDictionaries -
# o WPF reavalia sozinho qualquer DynamicResource consumido em qualquer lugar
# da arvore visual, sem precisar tocar em cada controle na mao.
function Get-ThemeResourceDictionaryXaml {
    param([ValidateSet("Dark","Light")][string]$Theme)
    if ($Theme -eq "Light") {
        return @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <SolidColorBrush x:Key="BrushWindowBg"    Color="#F3F4F6"/>
    <SolidColorBrush x:Key="BrushSidebarBg"   Color="#FFFFFF"/>
    <SolidColorBrush x:Key="BrushSidebarBrd"  Color="#E5E7EB"/>
    <SolidColorBrush x:Key="BrushSurface"     Color="#FFFFFF"/>
    <SolidColorBrush x:Key="BrushSurfaceAlt"  Color="#F9FAFB"/>
    <SolidColorBrush x:Key="BrushBorder"      Color="#E5E7EB"/>
    <SolidColorBrush x:Key="BrushText"        Color="#1F2937"/>
    <SolidColorBrush x:Key="BrushTextMuted"   Color="#6B7280"/>
    <SolidColorBrush x:Key="BrushTextFaint"   Color="#9CA3AF"/>
    <SolidColorBrush x:Key="BrushAccent"      Color="#219AF9"/>
    <SolidColorBrush x:Key="BrushAccentHover" Color="#1C87DB"/>
    <SolidColorBrush x:Key="BrushSuccess"     Color="#16A34A"/>
    <SolidColorBrush x:Key="BrushDanger"      Color="#DC2626"/>
    <SolidColorBrush x:Key="BrushWarning"     Color="#D97706"/>
    <SolidColorBrush x:Key="BrushTopBarBg"    Color="#FFFFFF"/>
    <SolidColorBrush x:Key="BrushStatusBarBg" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="BrushHover"       Color="#F3F4F6"/>
    <SolidColorBrush x:Key="BrushActiveNav"   Color="#EFF6FF"/>
    <SolidColorBrush x:Key="BrushInputBg"     Color="#F9FAFB"/>
    <SolidColorBrush x:Key="BrushInputBorder" Color="#D1D5DB"/>
</ResourceDictionary>
'@
    }
    return @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <SolidColorBrush x:Key="BrushWindowBg"    Color="#18181B"/>
    <SolidColorBrush x:Key="BrushSidebarBg"   Color="#1C1C1E"/>
    <SolidColorBrush x:Key="BrushSidebarBrd"  Color="#2A2A2A"/>
    <SolidColorBrush x:Key="BrushSurface"     Color="#232326"/>
    <SolidColorBrush x:Key="BrushSurfaceAlt"  Color="#1E1E1E"/>
    <SolidColorBrush x:Key="BrushBorder"      Color="#3F3F46"/>
    <SolidColorBrush x:Key="BrushText"        Color="#F4F4F5"/>
    <SolidColorBrush x:Key="BrushTextMuted"   Color="#9CA3AF"/>
    <SolidColorBrush x:Key="BrushTextFaint"   Color="#6B7280"/>
    <SolidColorBrush x:Key="BrushAccent"      Color="#219AF9"/>
    <SolidColorBrush x:Key="BrushAccentHover" Color="#3FADFB"/>
    <SolidColorBrush x:Key="BrushSuccess"     Color="#16A34A"/>
    <SolidColorBrush x:Key="BrushDanger"      Color="#EF4444"/>
    <SolidColorBrush x:Key="BrushWarning"     Color="#F59E0B"/>
    <SolidColorBrush x:Key="BrushTopBarBg"    Color="#1C1C1E"/>
    <SolidColorBrush x:Key="BrushStatusBarBg" Color="#1C1C1E"/>
    <SolidColorBrush x:Key="BrushHover"       Color="#2A2A2E"/>
    <SolidColorBrush x:Key="BrushActiveNav"   Color="#26262A"/>
    <SolidColorBrush x:Key="BrushInputBg"     Color="#1E1E1E"/>
    <SolidColorBrush x:Key="BrushInputBorder" Color="#3F3F46"/>
</ResourceDictionary>
'@
}

function Get-UiPrefs {
    if (Test-Path $global:UiPrefsFile) {
        try { return (Get-Content $global:UiPrefsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch {}
    }
    return [PSCustomObject]@{ Theme = "Dark" }
}

function Save-UiPrefs {
    param([string]$Theme)
    try { [PSCustomObject]@{ Theme = $Theme } | ConvertTo-Json | Out-File $global:UiPrefsFile -Encoding UTF8 -Force } catch {}
}

function Set-AppTheme {
    param([ValidateSet("Dark","Light")][string]$Theme)
    if ($global:MainWindow -eq $null) { return }
    $xamlText = Get-ThemeResourceDictionaryXaml -Theme $Theme
    $reader   = [System.Xml.XmlNodeReader]::new([xml]$xamlText)
    $dict     = [System.Windows.Markup.XamlReader]::Load($reader)
    $global:MainWindow.Resources.MergedDictionaries.Clear()
    $global:MainWindow.Resources.MergedDictionaries.Add($dict)
    $global:CurrentTheme = $Theme
    Save-UiPrefs -Theme $Theme
    if ($global:BtnTemaToggle -ne $null) {
        $global:BtnTemaToggle.Content = if ($Theme -eq "Dark") { "Tema: Escuro" } else { "Tema: Claro" }
    }
    # Reaplica o destaque do item de menu ativo com os brushes do novo tema
    # (o destaque foi setado programaticamente, entao nao acompanha
    # DynamicResource sozinho - precisa ser refeito apos a troca).
    if ($global:ShowSectionRef -ne $null) { & $global:ShowSectionRef -Key $global:CurrentSection }
}

# Janelas de dialogo (Show-AddExtraAppDialog, etc.) sao objetos Window
# separados - o Owner so controla Z-order/ciclo de vida, NAO faz o WPF
# procurar DynamicResource nos recursos da janela principal. Por isso cada
# dialogo precisa receber sua propria copia do dicionario de tema atual.
function Set-DialogTheme {
    param([Parameter(Mandatory=$true)]$Dialog)
    $xamlText = Get-ThemeResourceDictionaryXaml -Theme $global:CurrentTheme
    $reader   = [System.Xml.XmlNodeReader]::new([xml]$xamlText)
    $dict     = [System.Windows.Markup.XamlReader]::Load($reader)
    $Dialog.Resources.MergedDictionaries.Add($dict)
}

# ==============================================================================
# ESTATISTICAS DE SISTEMA (CPU / RAM / Disco) - usadas na barra superior
# ==============================================================================
function Get-SystemStatsSnapshot {
    $cpuText = "N/A"; $ramText = "N/A"; $diskText = "N/A"
    try {
        $cpu = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
        if ($cpu -ne $null) { $cpuText = ("{0}%" -f [int]$cpu) }
    } catch {}
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os.TotalVisibleMemorySize -gt 0) {
            $pct = (($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100
            $ramText = ("{0}%" -f [int][math]::Round($pct))
        }
    } catch {}
    try {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        if ($disk -ne $null) { $diskText = ("{0} GB livres" -f [math]::Round($disk.FreeSpace / 1GB,1)) }
    } catch {}
    return [PSCustomObject]@{ Cpu=$cpuText; Ram=$ramText; Disk=$diskText }
}

# ==============================================================================
# CHECKLIST DE FORMATACAO / CONFIGURACAO - guia passo a passo pra padronizar
# a preparacao de maquina nova (formatacao/entrega), com progresso salvo por
# maquina. Estrutura fixa (2 niveis: item + sub-itens), sem persistencia de
# "quem" marcou - so o estado marcado/desmarcado de cada item, por Id estavel.
# ==============================================================================
function Get-ChecklistDefinition {
    return @(
        [PSCustomObject]@{ Id="hostname";         Text="Solicitar exclusao do Hostname";                Children=@() }
        [PSCustomObject]@{ Id="bitlocker";        Text="Pegar chave de Bitlocker do SSD antigo (Backup)"; Children=@() }
        [PSCustomObject]@{ Id="licenca_office";   Text="Verificar Licenca de Office do colaborador";     Children=@() }
        [PSCustomObject]@{ Id="softwares_padrao"; Text="Instalar Softwares da Lista Padrao";             Children=@() }
        [PSCustomObject]@{ Id="dominio";          Text="Subir o Dominio";                                Children=@() }
        [PSCustomObject]@{ Id="login_usuario"; Text="Login do Usuario"; Children=@(
            [PSCustomObject]@{ Id="login_office_ativ"; Text="Validar instalacao e ativacao do Office (licenca)" }
            [PSCustomObject]@{ Id="login_outlook";     Text="Configurar Outlook" }
            [PSCustomObject]@{ Id="login_teams";       Text="Configurar Teams" }
            [PSCustomObject]@{ Id="login_onedrive";    Text="Configurar OneDrive" }
        )}
        [PSCustomObject]@{ Id="softwares_extras"; Text="Instalar Softwares Extras"; Children=@(
            [PSCustomObject]@{ Id="extra_easyinventory"; Text="Easy Inventory" }
            [PSCustomObject]@{ Id="extra_ocs";           Text="OCS" }
            [PSCustomObject]@{ Id="extra_hpdell";        Text="HP ou DELL Support" }
            [PSCustomObject]@{ Id="extra_bitdefender";   Text="Bitdefender" }
            [PSCustomObject]@{ Id="extra_netskope";      Text="Netskope (apos configurar Outlook)" }
            [PSCustomObject]@{ Id="extra_linkus";        Text="Linkus VoIP (Opcional)" }
        )}
        [PSCustomObject]@{ Id="restaurar_backup"; Text="Restaurar Backup (Caso necessario)"; Children=@(
            [PSCustomObject]@{ Id="backup_chrome";      Text="Restaurar pasta do Chrome" }
            [PSCustomObject]@{ Id="backup_edge";        Text="Restaurar Pasta do Edge" }
            [PSCustomObject]@{ Id="backup_downloads";   Text="Restaurar Downloads e pastas especificas" }
            [PSCustomObject]@{ Id="backup_mapeamento";  Text="Restaurar Mapeamento de Unidades de rede" }
        )}
    )
}

function Get-ChecklistState {
    $result = @{}
    if (Test-Path $global:ChecklistStateFile) {
        try {
            $json = Get-Content $global:ChecklistStateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($prop in $json.PSObject.Properties) { $result[$prop.Name] = [bool]$prop.Value }
        } catch { Write-Log -Message ("Falha ao carregar checklist_state.json: {0}" -f $_.Exception.Message) -Level "WARN" }
    }
    return $result
}

function Save-ChecklistState {
    param([hashtable]$State)
    try { $State | ConvertTo-Json | Out-File $global:ChecklistStateFile -Encoding UTF8 -Force } catch {}
}

# ==============================================================================
# BANCO DE APLICATIVOS (Lista Padrao - Winget / Chocolatey)
# ==============================================================================
function Get-DefaultAppList {
    return @(
        [PSCustomObject]@{Name="AnyDesk";                         Winget="AnyDesk.AnyDesk";               Choco="anydesk.install";         Scope="";TimeoutSeconds=600; Enabled=$true}
        [PSCustomObject]@{Name="RustDesk";                        Winget="RustDesk.RustDesk";             Choco="rustdesk";                Scope="";TimeoutSeconds=600; Enabled=$true}
        [PSCustomObject]@{Name="Microsoft Teams";                 Winget="Microsoft.Teams";               Choco="microsoft-teams.install"; Scope="";TimeoutSeconds=900; Enabled=$true}
        [PSCustomObject]@{Name="Adobe Acrobat Reader";            Winget="Adobe.Acrobat.Reader.64-bit";   Choco="adobereader";             Scope="";TimeoutSeconds=900; Enabled=$true}
        [PSCustomObject]@{Name="Google Chrome";                   Winget="Google.Chrome";                 Choco="googlechrome";            Scope="";TimeoutSeconds=600; Enabled=$true}
        [PSCustomObject]@{Name="7-Zip";                           Winget="7zip.7zip";                     Choco="7zip";                    Scope="";TimeoutSeconds=300; Enabled=$true}
        [PSCustomObject]@{Name="Oracle Java Runtime Environment"; Winget="Oracle.JavaRuntimeEnvironment"; Choco="";                        Scope="";TimeoutSeconds=900; Enabled=$true}
        [PSCustomObject]@{Name="Lightshot";                       Winget="Skillbrains.Lightshot";         Choco="lightshot.install";       Scope="";TimeoutSeconds=300; Enabled=$true}
        [PSCustomObject]@{Name="Microsoft Office";                Winget="Microsoft.Office";              Choco="";                        Scope="";TimeoutSeconds=5400;Enabled=$true}
    )
}

function Initialize-AppDatabase {
    if (-not (Test-Path $global:ConfigFile)) {
        [PSCustomObject]@{SchemaVersion=$global:SchemaVersion;Apps=@(Get-DefaultAppList)} |
            ConvertTo-Json -Depth 5 | Out-File $global:ConfigFile -Encoding UTF8 -Force
    }
}

function Import-AppDatabase {
    $global:AppsList.Clear()
    try {
        $json = Get-Content $global:ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($json.PSObject.Properties['Apps']) {
            foreach ($item in @($json.Apps)) { [void]$global:AppsList.Add($item) }
        } else {
            foreach ($item in @($json)) { [void]$global:AppsList.Add($item) }
        }
    } catch {
        Write-Log -Message ("Falha ao carregar banco de apps: {0}. Usando lista padrao." -f $_.Exception.Message) -Level "ERROR"
        foreach ($app in Get-DefaultAppList) { [void]$global:AppsList.Add($app) }
    }
}

function Export-AppDatabase {
    try {
        [PSCustomObject]@{SchemaVersion=$global:SchemaVersion;Apps=@($global:AppsList)} |
            ConvertTo-Json -Depth 5 | Out-File $global:ConfigFile -Encoding UTF8 -Force
        Write-Log -Message "Banco de aplicativos salvo." -Level "SUCCESS"; return $true
    } catch { Show-ErrorBox ("Falha ao salvar banco.`n`n{0}" -f $_.Exception.Message); return $false }
}

function Reset-AppDatabaseToDefault {
    $global:AppsList.Clear()
    foreach ($app in Get-DefaultAppList) { [void]$global:AppsList.Add($app) }
    return Export-AppDatabase
}

# Protege customizacoes do tecnico: se o schema do apps.json local estiver
# desatualizado em relacao ao script, faz backup do arquivo atual antes de
# repor a lista padrao (evita perder apps adicionados manualmente sem aviso).
function Update-LegacyDefaultListIfNeeded {
    if (-not (Test-Path $global:ConfigFile)) { return }
    try {
        $json = Get-Content $global:ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $cur  = if ($json.PSObject.Properties['SchemaVersion']) { [int]$json.SchemaVersion } else { 0 }
        if ($cur -lt $global:SchemaVersion) {
            $bkPath = Join-Path $global:ConfigPath ("apps_v{0}_{1}.json" -f $cur,(Get-Date -Format "yyyyMMdd-HHmmss"))
            Copy-Item $global:ConfigFile $bkPath -Force -EA SilentlyContinue
            Write-Log -Message ("Schema de apps.json v{0} -> v{1}. Backup em: {2}. Restaurando lista padrao." -f $cur,$global:SchemaVersion,$bkPath) -Level "WARN"
            [void](Reset-AppDatabaseToDefault)
        }
    } catch { Write-Log -Message ("Falha ao verificar schema de apps.json: {0}" -f $_.Exception.Message) -Level "WARN" }
}

# ==============================================================================
# PACOTE EXTRA - instaladores hospedados onde a empresa preferir (ex.: GitHub
# Releases). Cadastre pela aba "Pacote Extra"; fica salvo em extra_apps.json.
# ==============================================================================
function Initialize-ExtraDatabase {
    if (-not (Test-Path $global:ExtraConfigFile)) {
        @() | ConvertTo-Json -Depth 5 | Out-File $global:ExtraConfigFile -Encoding UTF8 -Force
    }
}

function Import-ExtraDatabase {
    $global:ExtraAppsList.Clear()
    try {
        $json = Get-Content $global:ExtraConfigFile -Raw -EA Stop | ConvertFrom-Json -EA Stop
        foreach ($item in @($json)) { [void]$global:ExtraAppsList.Add($item) }
    } catch { Write-Log -Message ("Falha ao carregar extra_apps.json: {0}" -f $_.Exception.Message) -Level "WARN" }
}

function Export-ExtraDatabase {
    try {
        @($global:ExtraAppsList) | ConvertTo-Json -Depth 5 | Out-File $global:ExtraConfigFile -Encoding UTF8 -Force
        Write-Log -Message "Pacote Extra salvo." -Level "SUCCESS"; return $true
    } catch { Show-ErrorBox ("Falha ao salvar extra_apps.json.`n`n{0}" -f $_.Exception.Message); return $false }
}

$script:AddExtraDialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Adicionar ao Pacote Extra" Height="320" Width="480"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="{DynamicResource BrushSurface}">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Nome do software:" Foreground="{DynamicResource BrushTextMuted}" Margin="0,0,0,4"/>
        <TextBox x:Name="TxtNome" Grid.Row="1" Height="30" Padding="6,4" Background="{DynamicResource BrushInputBg}" Foreground="{DynamicResource BrushText}" BorderBrush="{DynamicResource BrushInputBorder}"/>
        <TextBlock Grid.Row="2" Text="URL de download direto (.exe/.msi):" Foreground="{DynamicResource BrushTextMuted}" Margin="0,14,0,4"/>
        <TextBox x:Name="TxtUrl" Grid.Row="3" Height="30" Padding="6,4" Background="{DynamicResource BrushInputBg}" Foreground="{DynamicResource BrushText}" BorderBrush="{DynamicResource BrushInputBorder}"/>
        <CheckBox x:Name="ChkMsi" Grid.Row="4" Content="Arquivo .msi (usa msiexec automaticamente)" Foreground="{DynamicResource BrushText}" Margin="0,14,0,0"/>
        <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="BtnCancelar" Content="Cancelar" Width="100" Height="34" Margin="0,0,10,0" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0"/>
            <Button x:Name="BtnSalvar" Content="Salvar" Width="120" Height="34" Background="{DynamicResource BrushSuccess}" Foreground="White" BorderThickness="0" FontWeight="Bold"/>
        </StackPanel>
    </Grid>
</Window>
'@

function Show-AddExtraAppDialog {
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:AddExtraDialogXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow
    Set-DialogTheme -Dialog $dlg

    $txtNome = $dlg.FindName("TxtNome")
    $txtUrl  = $dlg.FindName("TxtUrl")
    $chkMsi  = $dlg.FindName("ChkMsi")
    $btnSalvar   = $dlg.FindName("BtnSalvar")
    $btnCancelar = $dlg.FindName("BtnCancelar")

    $global:ExtraDialogResult = $null
    $btnSalvar.Add_Click({
        $n = $txtNome.Text.Trim(); $u = $txtUrl.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($n)) { Show-Warning "Informe o nome."; return }
        if ([string]::IsNullOrWhiteSpace($u) -or $u -notmatch "^https?://") { Show-Warning "Informe uma URL valida (https://)."; return }
        $isMsi = $chkMsi.IsChecked
        $ext   = if ($isMsi) { ".msi" } else { [System.IO.Path]::GetExtension($u) }
        $global:ExtraDialogResult = [PSCustomObject]@{
            Name=$n; Url=$u; SilentArgs=if($isMsi){@("/qn","/norestart")}else{@()}
            Ext=$ext; IsMSI=$isMsi; TimeoutSeconds=1800; Enabled=$true
        }
        $dlg.DialogResult = $true
        $dlg.Close()
    }.GetNewClosure())
    $btnCancelar.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() }.GetNewClosure())
    [void]$dlg.ShowDialog()
    return $global:ExtraDialogResult
}

# Baixa o instalador (cascata de 4 metodos, do mais compativel com proxy
# corporativo/Netskope ao mais generico), executa e traz a janela para
# frente, e remove o arquivo temporario ao final.
function Install-DirectApp {
    param([Parameter(Mandatory=$true)]$App)
    $appName = [string]$App.Name
    $url     = [string]$App.Url
    $isMSI   = [bool]$App.IsMSI
    $ext     = [string]$App.Ext
    $timeout = 1800
    try { if ($App.TimeoutSeconds -and [int]$App.TimeoutSeconds -gt 0) { $timeout=[int]$App.TimeoutSeconds } } catch {}

    if ([string]::IsNullOrWhiteSpace($url)) {
        Write-Log -Message ("[EXTRA] URL nao configurada para '{0}'." -f $appName) -Level "WARN"
        return $false
    }

    $safeName = ($appName -replace '[^a-zA-Z0-9]','_')
    $tempFile = Join-Path $env:TEMP ("elgin_extra_{0}_{1}{2}" -f $safeName,[guid]::NewGuid().ToString("N").Substring(0,8),$ext)

    try {
        Set-Status ("Baixando {0}..." -f $appName)
        Write-Log -Message ("[EXTRA] Iniciando download: {0}" -f $url) -Level "INFO"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

        $downloadOk = $false; $lastError = ""

        # Metodo 1: curl.exe (WinHTTP + cert store do sistema - melhor
        # compatibilidade com proxies corporativos tipo Netskope/Zscaler).
        $curlExe = "$env:SystemRoot\System32\curl.exe"
        if (-not (Test-Path $curlExe)) { $curlExe = "$env:SystemRoot\SysWOW64\curl.exe" }
        if (Test-Path $curlExe) {
            try {
                $curlArgs = @("-L","--fail","--silent","--show-error","-A","Mozilla/5.0 (Windows NT 10.0; Win64; x64)","-o",$tempFile,$url)
                $curlRes = Invoke-ManagedProcess -FilePath $curlExe -Arguments $curlArgs -Description "[EXTRA] Download curl" -TimeoutSeconds $timeout
                if ($curlRes.ExitCode -eq 0 -and (Test-Path $tempFile)) { $downloadOk = $true; Write-Log -Message "[EXTRA] Download via curl.exe OK." }
                else { $lastError = ("curl exit {0}: {1}" -f $curlRes.ExitCode,([string]$curlRes.Error).Trim()); Write-Log -Message ("[EXTRA] curl.exe falhou: {0}" -f $lastError) -Level "WARN" }
            } catch { $lastError = $_.Exception.Message; Write-Log -Message ("[EXTRA] curl.exe excecao: {0}" -f $lastError) -Level "WARN" }
        }

        # Metodo 2: Invoke-WebRequest/WebClient num processo filho (nao trava
        # a UI porque roda fora da thread principal via processo separado).
        if (-not $downloadOk) {
            $dlScript = $null
            try {
                $dlScript = Join-Path $env:TEMP ("elgin_dl_{0}.ps1" -f [guid]::NewGuid().ToString("N").Substring(0,8))
                $scriptBody = @'
param([string]$Url,[string]$Dest)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
$ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
try {
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -Headers @{ "User-Agent" = $ua }
    exit 0
} catch {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        $wc.Headers.Add("User-Agent", $ua)
        $wc.DownloadFile($Url, $Dest)
        exit 0
    } catch { exit 2 }
}
'@
                Set-Content -Path $dlScript -Value $scriptBody -Encoding UTF8 -Force
                $dlArgs = @("-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",$dlScript,$url,$tempFile)
                $dlRes  = Invoke-ManagedProcess -FilePath "powershell.exe" -Arguments $dlArgs -Description "[EXTRA] Download IWR/WebClient" -TimeoutSeconds $timeout
                if ($dlRes.ExitCode -eq 0 -and (Test-Path $tempFile)) { $downloadOk = $true; Write-Log -Message "[EXTRA] Download via IWR/WebClient (filho) OK." }
                else { $lastError = ("IWR/WebClient exit {0}" -f $dlRes.ExitCode); Write-Log -Message ("[EXTRA] IWR/WebClient falhou: {0}" -f $lastError) -Level "WARN" }
            } catch { $lastError = $_.Exception.Message; Write-Log -Message ("[EXTRA] IWR/WebClient excecao: {0}" -f $lastError) -Level "WARN" }
            finally { if ($dlScript -and (Test-Path $dlScript)) { Remove-Item $dlScript -Force -EA SilentlyContinue } }
        }

        # Metodo 3: BITS Transfer (assincrono).
        if (-not $downloadOk) {
            $bitsJob = $null
            try {
                Import-Module BitsTransfer -ErrorAction Stop
                $bitsJob = Start-BitsTransfer -Source $url -Destination $tempFile -Asynchronous -ErrorAction Stop
                $swBITS  = [System.Diagnostics.Stopwatch]::StartNew()
                while ($bitsJob.JobState -in @('Transferring','Connecting','Queued','Suspended')) {
                    Start-Sleep -Milliseconds 400
                    if ($swBITS.Elapsed.TotalSeconds -gt 180) { Remove-BitsTransfer $bitsJob -EA SilentlyContinue; throw "Timeout BITS apos 180s" }
                }
                $swBITS.Stop()
                if ($bitsJob.JobState -eq 'Transferred') { Complete-BitsTransfer $bitsJob -ErrorAction Stop; $downloadOk = $true; Write-Log -Message "[EXTRA] Download via BITS OK." }
                else { throw ("BITS estado final: {0}" -f $bitsJob.JobState) }
            } catch {
                $lastError = $_.Exception.Message
                Write-Log -Message ("[EXTRA] BITS falhou: {0}" -f $lastError) -Level "WARN"
                try { if ($bitsJob) { Remove-BitsTransfer $bitsJob -EA SilentlyContinue } } catch {}
            }
        }

        # Metodo 4: Invoke-WebRequest direto na thread atual (ultimo recurso).
        if (-not $downloadOk) {
            try {
                $prev = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
                Invoke-WebRequest -Uri $url -OutFile $tempFile -UseBasicParsing -Headers @{"User-Agent"="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"} -ErrorAction Stop
                $ProgressPreference = $prev; $downloadOk = $true; Write-Log -Message "[EXTRA] Download via Invoke-WebRequest direto OK."
            } catch { $ProgressPreference = $prev; $lastError = $_.Exception.Message }
        }

        if (-not $downloadOk) {
            Write-Log -Message ("[EXTRA] Todos os metodos falharam para '{0}'. Ultimo erro: {1}" -f $appName,$lastError) -Level "ERROR"
            Show-Warning ("Falha ao baixar '{0}'.`n`nUltimo erro:`n{1}`n`nSe voce usa Netskope/Zscaler, tente acessar a URL no navegador para confirmar que o arquivo existe." -f $appName,$lastError)
            return $false
        }

        $fileSize = (Get-Item $tempFile).Length
        if ($fileSize -lt 10240) {
            Write-Log -Message ("[EXTRA] Arquivo suspeito ({0:N0} bytes) para '{1}'." -f $fileSize,$appName) -Level "ERROR"
            Show-Warning ("O arquivo baixado para '{0}' tem apenas {1:N0} bytes. Verifique a URL configurada ou se um proxy bloqueou o download." -f $appName,$fileSize)
            return $false
        }
        Write-Log -Message ("[EXTRA] Download concluido: {0:N0} bytes" -f $fileSize) -Level "INFO"

        Set-Status ("Aguardando instalacao de {0}..." -f $appName)
        if ($isMSI) {
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList ("/i `"$tempFile`" /norestart") -PassThru -ErrorAction Stop
        } else {
            $proc = Start-Process -FilePath $tempFile -PassThru -ErrorAction Stop
        }
        Set-WindowForeground -Proc $proc -TimeoutSeconds 15

        $exited = $proc.WaitForExit($timeout * 1000)
        if (-not $exited) { try{$proc.Kill()}catch{}; Write-Log -Message ("[EXTRA] Timeout em {0}" -f $appName) -Level "ERROR"; return $false }
        $exitCode = try { $proc.ExitCode } catch { -1 }
        $ok = ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq 1641)
        if ($ok) { Write-Log -Message ("[EXTRA] {0} instalado com sucesso." -f $appName) -Level "SUCCESS" }
        else     { Write-Log -Message ("[EXTRA] {0} encerrou com codigo {1}." -f $appName,$exitCode) -Level "ERROR" }
        return $ok
    } catch {
        Write-Log -Message ("[EXTRA] Excecao em {0}: {1}" -f $appName,$_.Exception.Message) -Level "ERROR"
        return $false
    } finally {
        Start-Sleep -Seconds 2
        if ($tempFile -and (Test-Path $tempFile)) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    }
}

# ==============================================================================
# GERENCIADORES DE PACOTES (Lista Padrao)
# ==============================================================================
function Test-AppInstalled {
    param([string]$WingetId)
    if (-not $global:HasWinget -or [string]::IsNullOrWhiteSpace($WingetId)) { return $false }
    try {
        $winget = Get-CommandPathSafe -Name "winget"
        $r = Invoke-ManagedProcess -FilePath $winget `
             -Arguments @("list","--id",$WingetId,"--exact","--accept-source-agreements","--disable-interactivity") `
             -Description ("[CHECK] winget list {0}" -f $WingetId) -TimeoutSeconds 30
        return ($r.ExitCode -eq 0 -and $r.Output -match [regex]::Escape($WingetId))
    } catch { return $false }
}

function Install-OnlineApp {
    param([Parameter(Mandatory=$true)]$App)
    $appName=[string]$App.Name; $wingetId=[string]$App.Winget; $chocoId=[string]$App.Choco
    $scope=""; try{$scope=[string]$App.Scope}catch{$scope=""}
    $timeout=1800; try{if($App.TimeoutSeconds -and [int]$App.TimeoutSeconds -gt 0){$timeout=[int]$App.TimeoutSeconds}}catch{}
    $installed=$false; $triedAny=$false; $detail=""
    Update-Prerequisites

    if ($global:HasWinget -and -not [string]::IsNullOrWhiteSpace($wingetId)) {
        $triedAny=$true
        Set-Status ("Verificando {0}..." -f $appName)
        if (Test-AppInstalled -WingetId $wingetId) {
            Write-Log -Message ("[INSTALL] {0} ja instalado (winget). Pulando." -f $appName) -Level "INFO"; return $true
        }
        $winget=Get-CommandPathSafe -Name "winget"
        $wargs=@("install","--id",$wingetId,"--exact","--source","winget","--silent",
                 "--accept-package-agreements","--accept-source-agreements","--disable-interactivity")
        if (-not [string]::IsNullOrWhiteSpace($scope)) { $wargs+=@("--scope",$scope) }
        Set-Status ("Instalando {0} via winget..." -f $appName)
        $r=Invoke-ManagedProcess -FilePath $winget -Arguments $wargs -Description ("[INSTALL] winget {0}" -f $appName) -TimeoutSeconds $timeout
        if ($r.ExitCode -eq 0 -or $r.ExitCode -eq -1978335189 -or $r.ExitCode -eq 3010) { $installed=$true }
        if (-not $installed) {
            if (Test-AppInstalled -WingetId $wingetId) { $installed=$true }
            else { $detail=("winget ExitCode {0}" -f $r.ExitCode) }
        }
    }

    if (-not $installed -and $global:HasChoco -and -not [string]::IsNullOrWhiteSpace($chocoId)) {
        $triedAny=$true
        $choco=Get-CommandPathSafe -Name "choco"
        Set-Status ("Instalando {0} via Chocolatey..." -f $appName)
        $r=Invoke-ManagedProcess -FilePath $choco -Arguments @("install",$chocoId,"-y","--no-progress","--accept-license") -Description ("[INSTALL] choco {0}" -f $appName) -TimeoutSeconds $timeout
        if ($r.ExitCode -eq 0 -or $r.ExitCode -eq 3010 -or $r.ExitCode -eq 1641) { $installed=$true }
        elseif (([string]$r.Output) -match "already installed") { $installed=$true }
        else { $detail=("choco ExitCode {0}" -f $r.ExitCode) }
    }

    if ($installed) { Write-Log -Message ("[INSTALL] {0} concluido." -f $appName) -Level "SUCCESS" }
    elseif (-not $triedAny) { Write-Log -Message ("[INSTALL] {0} nao instalado: sem gerenciador/ID compativel." -f $appName) -Level "ERROR" }
    else { Write-Log -Message ("[INSTALL] Falha: {0}. {1}" -f $appName,$detail) -Level "ERROR" }
    return $installed
}

function Get-WingetVersion {
    if (-not $global:HasWinget -or -not $global:WingetPath) { return "" }
    try {
        $r = Invoke-ManagedProcess -FilePath $global:WingetPath -Arguments @("--version") -Description "[CHECK] winget --version" -TimeoutSeconds 20
        if ($r.ExitCode -eq 0 -and $r.Output) { return ([string]$r.Output).Trim() }
    } catch {}
    return ""
}

# Repara o winget (App Installer): re-registra o pacote via AppXManifest, com
# fallback para Reset-AppxPackage. Se o pacote nem existir, sinaliza Missing.
function Repair-Winget {
    Set-Status "Reparando Winget (App Installer)..."
    $pkg = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pkg) {
        Write-Log -Message "[REPAIR] Winget ausente." -Level "WARN"
        Update-Prerequisites
        return [PSCustomObject]@{ Ok=$false; Missing=$true }
    }
    try {
        $manifest = Join-Path $pkg.InstallLocation "AppXManifest.xml"
        if (Test-Path $manifest) {
            Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ForceApplicationShutdown -ErrorAction Stop
            Write-Log -Message "[REPAIR] Winget re-registrado." -Level "SUCCESS"
        }
    } catch { Write-Log -Message ("[REPAIR] Re-registro falhou: {0}" -f $_.Exception.Message) -Level "WARN" }
    Update-Prerequisites
    if (-not $global:HasWinget -and (Get-Command Reset-AppxPackage -ErrorAction SilentlyContinue)) {
        try { $pkg | Reset-AppxPackage -ErrorAction Stop; Write-Log -Message "[REPAIR] Reset-AppxPackage executado." -Level "INFO" } catch {}
        Update-Prerequisites
    }
    return [PSCustomObject]@{ Ok=$global:HasWinget; Missing=$false }
}

function Install-WingetPackageManager {
    Update-Prerequisites
    if ($global:HasWinget) { Show-Info "Winget ja esta instalado."; return }
    if (-not (Confirm-Action "Deseja instalar o Winget/App Installer usando o pacote oficial da Microsoft?" "Instalar Winget")) { return }
    $wingetUrl  = "https://aka.ms/getwinget"
    $wingetTemp = Join-Path $env:TEMP "Microsoft.DesktopAppInstaller.msixbundle"
    try {
        Set-Status "Baixando Winget/App Installer..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
        $dlOk = $false; $dlErr = ""
        $curlExe = "$env:SystemRoot\System32\curl.exe"
        if (-not (Test-Path $curlExe)) { $curlExe = "$env:SystemRoot\SysWOW64\curl.exe" }
        if (Test-Path $curlExe) {
            try {
                $curlArgs = @("-L","--fail","--silent","--show-error","-A","Mozilla/5.0 (Windows NT 10.0; Win64; x64)","-o",$wingetTemp,$wingetUrl)
                $cr = Invoke-ManagedProcess -FilePath $curlExe -Arguments $curlArgs -Description "[WINGET] Download curl" -TimeoutSeconds 600
                if ($cr.ExitCode -eq 0 -and (Test-Path $wingetTemp)) { $dlOk = $true } else { $dlErr = ("curl exit {0}" -f $cr.ExitCode) }
            } catch { $dlErr = $_.Exception.Message }
        }
        if (-not $dlOk) {
            try {
                $prev = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
                Invoke-WebRequest -Uri $wingetUrl -OutFile $wingetTemp -UseBasicParsing -Headers @{"User-Agent"="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"} -ErrorAction Stop
                $ProgressPreference = $prev; $dlOk = $true
            } catch { $ProgressPreference = $prev; $dlErr = $_.Exception.Message }
        }
        if (-not $dlOk) { Show-ErrorBox ("Falha ao baixar Winget. Todos os metodos falharam.`n`nUltimo erro: {0}" -f $dlErr); return }
        Set-Status "Instalando Winget/App Installer..."
        Add-AppxPackage -Path $wingetTemp -ErrorAction Stop
        Update-Prerequisites
        if ($global:HasWinget) { Show-Info "Winget instalado com sucesso." }
        else { Show-Warning "Instalador executado, mas winget nao foi localizado. Reinicie o PowerShell/computador." }
    } catch { Show-ErrorBox ("Falha ao instalar Winget.`n`n{0}" -f $_.Exception.Message) }
    finally { if (Test-Path $wingetTemp) { Remove-Item $wingetTemp -Force -EA SilentlyContinue } }
}

function Install-ChocolateyPackageManager {
    Update-Prerequisites
    if ($global:HasChoco) { Show-Info "Chocolatey ja esta instalado."; return }
    if (-not $global:IsAdmin) { Show-Warning "A instalacao do Chocolatey requer Administrador."; return }
    if (-not (Confirm-Action "Deseja instalar o Chocolatey usando o script oficial?" "Instalar Chocolatey")) { return }
    try {
        $tempScript = Join-Path $env:TEMP "install_chocolatey.ps1"
        Set-Status "Baixando instalador oficial do Chocolatey..."
        Invoke-WebRequest -Uri "https://community.chocolatey.org/install.ps1" -OutFile $tempScript -UseBasicParsing -ErrorAction Stop
        Set-Status "Instalando Chocolatey..."
        $result = Invoke-ManagedProcess -FilePath "powershell.exe" -Arguments @("-NoProfile","-File",$tempScript) -Description "Instalacao do Chocolatey" -TimeoutSeconds 600
        Start-Sleep -Seconds 2; Update-SessionPath; Update-Prerequisites
        $defaultChoco = Join-Path $env:ProgramData "chocolatey\bin\choco.exe"
        if ($global:HasChoco -or (Test-Path $defaultChoco)) {
            $global:HasChoco = $true; Set-Status "Chocolatey instalado com sucesso." "SUCCESS"
            Show-Info "Chocolatey instalado com sucesso.`n`nSe 'choco' nao for reconhecido, feche e abra a ferramenta novamente."
        } else { Show-Warning ("Instalador retornou ExitCode {0}, mas choco.exe nao foi localizado. Verifique os Logs." -f $result.ExitCode) }
    } catch { Show-ErrorBox ("Falha ao instalar Chocolatey.`n`n{0}" -f $_.Exception.Message) }
    finally { if (Test-Path $tempScript) { Remove-Item $tempScript -Force -EA SilentlyContinue } }
}

# ==============================================================================
# BUSCA ONLINE (winget search / choco search)
# ==============================================================================
function ConvertFrom-WingetOutput {
    param([string]$Output)
    $rows=New-Object System.Collections.ArrayList
    $lines=@($Output -split "`r?`n")
    $sep=-1
    for ($i=0;$i -lt $lines.Count;$i++){ if ($lines[$i] -match '^\s*-{5,}\s*$') { $sep=$i; break } }
    if ($sep -lt 1) { return @($rows) }
    $header=$lines[$sep-1]
    $starts=New-Object System.Collections.ArrayList; [void]$starts.Add(0)
    for ($i=2;$i -lt $header.Length;$i++){ if ($header[$i] -ne ' ' -and $header[$i-1] -eq ' ' -and $header[$i-2] -eq ' ') { [void]$starts.Add($i) } }
    if ($starts.Count -lt 2) { return @($rows) }
    $nameStart=[int]$starts[0]; $idStart=[int]$starts[1]; $idEnd=if($starts.Count -ge 3){[int]$starts[2]}else{-1}
    for ($i=$sep+1;$i -lt $lines.Count;$i++){
        $line=$lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.Length -le $idStart) { continue }
        $name=$line.Substring($nameStart,[Math]::Min($idStart,$line.Length)-$nameStart).Trim()
        $id = if ($idEnd -gt $idStart -and $line.Length -ge $idEnd) { $line.Substring($idStart,$idEnd-$idStart).Trim() } else { $line.Substring([Math]::Min($idStart,$line.Length)).Trim() }
        if ($id -match '\s') { $id=($id -split '\s+')[0] }
        if ($name -and $id -and $id -match '^[A-Za-z0-9][A-Za-z0-9.+_\-]*$') {
            [void]$rows.Add([PSCustomObject]@{Source="Winget";Name=$name;Id=$id})
        }
    }
    return @($rows)
}

function ConvertFrom-ChocoOutput {
    param([string]$Output)
    $rows=New-Object System.Collections.ArrayList
    foreach ($line in @($Output -split "`r?`n")) {
        $l=$line.Trim()
        if ([string]::IsNullOrWhiteSpace($l)-or -not $l.Contains("|")) { continue }
        $parts=@($l.Split("|"))
        if ($parts.Count -ge 2) { $id=$parts[0].Trim(); $ver=$parts[1].Trim(); if ($id) { [void]$rows.Add([PSCustomObject]@{Source="Chocolatey";Name=$id;Id=$id;Version=$ver}) } }
    }
    return @($rows)
}

function Search-SoftwarePackages {
    param([string]$Query)
    Update-Prerequisites
    $safeQ=([string]$Query).Replace([string][char]34,"")
    $rows=New-Object System.Collections.ArrayList
    if ($global:HasWinget) {
        $winget=Get-CommandPathSafe -Name "winget"
        $r=Invoke-ManagedProcess -FilePath $winget -Arguments @("search",$safeQ,"--source","winget","--accept-source-agreements","--disable-interactivity") -Description ("[SEARCH] winget {0}" -f $safeQ) -TimeoutSeconds 60
        foreach ($row in @(ConvertFrom-WingetOutput -Output $r.Output)) { [void]$rows.Add($row) }
    }
    if ($global:HasChoco) {
        $choco=Get-CommandPathSafe -Name "choco"
        $r=Invoke-ManagedProcess -FilePath $choco -Arguments @("search",$safeQ,"--limit-output") -Description ("[SEARCH] choco {0}" -f $safeQ) -TimeoutSeconds 60
        foreach ($row in @(ConvertFrom-ChocoOutput -Output $r.Output)) { [void]$rows.Add($row) }
    }
    return @($rows)
}

function Export-InstallReport {
    param([hashtable]$Results,[string]$Section="Instalacao")
    $path  = Join-Path $global:ReportsPath ("{0}-{1}-{2}.txt" -f $Section,$env:COMPUTERNAME,(Get-Date -Format "yyyyMMdd-HHmmss"))
    $ok    = @($Results.Values | Where-Object { $_ }).Count
    $fail  = @($Results.Values | Where-Object { -not $_ }).Count
    $lines = @(
        ("Relatorio de {0} - {1} v{2}" -f $Section,$global:AppName,$global:AppVersion),
        ("Gerado em:  {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")),
        ("Computador: {0}" -f $env:COMPUTERNAME),
        ("Usuario:    {0}" -f $env:USERNAME),
        "============================================================"
    )
    foreach ($key in ($Results.Keys | Sort-Object)) {
        $st = if ($Results[$key]) { "[OK]     " } else { "[FALHOU] " }
        $lines += ("{0}{1}" -f $st,$key)
    }
    $lines += "============================================================"
    $lines += ("Total: {0}  |  Sucesso: {1}  |  Falhas: {2}" -f $Results.Count,$ok,$fail)
    $lines | Out-File $path -Encoding UTF8 -Force
    Write-Log -Message ("[INSTALL] Relatorio salvo em {0}" -f $path) -Level "SUCCESS"
    return $path
}

# ==============================================================================
# LIMPEZA, REDE E IMPRESSAO
# ==============================================================================
function Invoke-CleanupOperation {
    param([switch]$IncludeWindowsTemp)
    $targets=@($env:TEMP)
    if ($IncludeWindowsTemp -and $global:IsAdmin) { $targets+=(Join-Path $env:WINDIR "Temp") }
    foreach ($target in @($targets)) {
        if ($target -and (Test-Path $target)) {
            Set-Status ("Limpando temporarios em {0}..." -f $target)
            Get-ChildItem -Path $target -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            Write-Log -Message ("[CLEANUP] Temporarios limpos em {0}" -f $target) -Level "SUCCESS"
        }
    }
}

function Clear-WindowsUpdateCache {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    foreach ($svc in @("wuauserv","bits")) { try{Stop-Service -Name $svc -Force -EA SilentlyContinue}catch{} }
    Start-Sleep -Seconds 2
    $dp=Join-Path $env:WINDIR "SoftwareDistribution\Download"
    if (Test-Path $dp) { Get-ChildItem -Path $dp -Force -Recurse -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue }
    foreach ($svc in @("bits","wuauserv")) { try{Start-Service -Name $svc -EA SilentlyContinue}catch{} }
    Write-Log -Message "[CLEANUP] Cache do Windows Update limpo." -Level "SUCCESS"
    Show-Info "Cache do Windows Update limpo."
}

function Clear-GeolocationCache {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    $paths=@((Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Geolocation"),(Join-Path $env:ProgramData "Microsoft\Windows\LfSvc"))
    try{Stop-Service -Name "lfsvc" -Force -EA SilentlyContinue}catch{}
    Start-Sleep -Seconds 1
    foreach ($path in @($paths)) { if (Test-Path $path) { Get-ChildItem -Path $path -Force -Recurse -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue } }
    try{Restart-Service -Name "lfsvc" -Force -EA Stop}catch{try{Start-Service -Name "lfsvc" -EA SilentlyContinue}catch{}}
    Write-Log -Message "[CLEANUP] Cache de geolocalizacao limpo e lfsvc reiniciado." -Level "SUCCESS"
    Show-Info "Cache de geolocalizacao limpo."
}

function Invoke-NetworkTool {
    param([string]$Action)
    if (-not $global:IsAdmin -and $Action -in @("Reset Winsock","Renew IP")) { Show-Warning "Esta acao requer Administrador."; return }
    switch ($Action) {
        "Flush DNS"     { Invoke-ConsoleCommand "ipconfig /flushdns" "[NETWORK] Flush DNS" 60 | Out-Null; Show-Info "Cache DNS limpo." }
        "Renew IP"      { Invoke-ConsoleCommand "ipconfig /release & ipconfig /renew" "[NETWORK] Renew IP" 120 | Out-Null; Show-Info "IP renovado." }
        "Reset Winsock" { Invoke-ConsoleCommand "netsh winsock reset" "[NETWORK] Reset Winsock" 120 | Out-Null; Show-Info "Reset Winsock executado. Reinicie o computador." }
        "Ping Google"   { $r=Invoke-ConsoleCommand "ping 8.8.8.8 -n 4" "[NETWORK] Ping" 60; Show-Info $r.Output "Resultado do Ping" }
        "Teste DNS"     { $r=Invoke-ConsoleCommand "nslookup google.com" "[NETWORK] DNS" 60; Show-Info ($r.Output+$r.Error) "Resultado DNS" }
    }
}

function Reset-PrintSpooler {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    try {
        Stop-Service spooler -Force -EA SilentlyContinue
        $spool=Join-Path $env:SystemRoot "System32\spool\PRINTERS"
        if (Test-Path $spool) { Get-ChildItem $spool -Force -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue }
        Start-Service spooler -EA SilentlyContinue
        Write-Log -Message "[PRINT] Spooler reiniciado e fila limpa." -Level "SUCCESS"; Show-Info "Spooler reiniciado e fila de impressao limpa."
    } catch { Show-ErrorBox ("Falha ao reiniciar spooler.`n`n{0}" -f $_.Exception.Message) }
}

# Remove componentes de IA/Copilot do Windows via script de terceiro
# (zoicware/RemoveWindowsAI). URL fixada num commit especifico (ver
# $global:RemoveWindowsAIUrl) para reduzir risco de supply chain.
function Invoke-RemoveWindowsAI {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    $pinnedUrl = $global:RemoveWindowsAIUrl
    Write-Log -Message "[AI] Solicitando Remove IA do Windows (RemoveWindowsAI, commit fixado)." -Level "WARN"
    $warning = "Esta ferramenta abrira o RemoveWindowsAI em uma nova janela do Windows PowerShell 5.1.`n`nSera aplicado:`nSet-ExecutionPolicy Unrestricted -Scope CurrentUser -Force`nSet-ExecutionPolicy Unrestricted -Scope Process -Force`n`nDepois sera executado o script oficial, numa versao fixada (nao a mais recente do repositorio):`n$pinnedUrl`n`nATENCAO: no script que sera aberto, NAO selecione as opcoes com Triangulo Amarelo.`n`nDeseja continuar?"
    if (-not (Confirm-Action $warning "Remove IA do Windows")) { return }
    $cmdFile = $null
    try {
        $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        if (-not (Test-Path $psExe)) { $psExe = "powershell.exe" }
        $cmdFile = Join-Path $env:TEMP ("Elgin_RemoveWindowsAI_" + [guid]::NewGuid().ToString("N") + ".cmd")
        $quote      = [char]34
        $safeUrl    = $pinnedUrl.Replace([string]$quote,"")
        $psCommand  = "Set-ExecutionPolicy Unrestricted -Scope CurrentUser -Force; Set-ExecutionPolicy Unrestricted -Scope Process -Force; & ([scriptblock]::Create((irm '" + $safeUrl + "')))"
        $cmdBody    = "@echo off`r`n" + $quote + $psExe + $quote + " -NoProfile -NoExit -Command " + $quote + $psCommand + $quote + "`r`n"
        Set-Content -Path $cmdFile -Value $cmdBody -Encoding ASCII -Force
        Start-Process -FilePath $cmdFile -ErrorAction Stop
        Write-Log -Message "[AI] Janela do RemoveWindowsAI aberta." -Level "INFO"
    } catch {
        Write-Log -Message ("[AI] Falha ao abrir RemoveWindowsAI: {0}" -f $_.Exception.Message) -Level "ERROR"
        Show-ErrorBox ("Falha ao iniciar o RemoveWindowsAI.`n`n{0}" -f $_.Exception.Message)
    }
}

# ==============================================================================
# IMPRESSORAS DE REDE - consulta o servidor de impressao (spooler) e faz SNMP
# direto no IP de cada impressora para ler nivel de toner/uptime/paginas.
# So funciona com a maquina conectada a rede/VPN da empresa.
# ==============================================================================
function Get-PrinterConfig {
    if (-not (Test-Path $global:PrinterConfigFile)) {
        [PSCustomObject]@{ ServidorPrint = "elgjunprt"; SnmpCommunity = "public"; TempoRefreshMinutos = 5 } |
            ConvertTo-Json | Out-File $global:PrinterConfigFile -Encoding UTF8 -Force
    }
    try {
        $cfg = Get-Content $global:PrinterConfigFile -Raw | ConvertFrom-Json
        if (-not $cfg.PSObject.Properties['TempoRefreshMinutos'] -or -not $cfg.TempoRefreshMinutos) {
            $cfg | Add-Member -NotePropertyName TempoRefreshMinutos -NotePropertyValue 5 -Force
        }
        return $cfg
    } catch { return [PSCustomObject]@{ ServidorPrint = "elgjunprt"; SnmpCommunity = "public"; TempoRefreshMinutos = 5 } }
}

function Save-PrinterConfig {
    param([string]$ServidorPrint, [string]$SnmpCommunity, [int]$TempoRefreshMinutos = 5)
    [PSCustomObject]@{ ServidorPrint = $ServidorPrint; SnmpCommunity = $SnmpCommunity; TempoRefreshMinutos = $TempoRefreshMinutos } |
        ConvertTo-Json | Out-File $global:PrinterConfigFile -Encoding UTF8 -Force
}

$script:ConfigServidorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Configurar Servidor de Impressao" Height="320" Width="440"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="{DynamicResource BrushSurface}">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Nome/IP do servidor de impressao:" Foreground="{DynamicResource BrushTextMuted}" Margin="0,0,0,4"/>
        <TextBox x:Name="TxtServidor" Grid.Row="1" Height="30" Padding="6,4" Background="{DynamicResource BrushInputBg}" Foreground="{DynamicResource BrushText}" BorderBrush="{DynamicResource BrushInputBorder}"/>
        <TextBlock Grid.Row="2" Text="Comunidade SNMP:" Foreground="{DynamicResource BrushTextMuted}" Margin="0,14,0,4"/>
        <TextBox x:Name="TxtComunidade" Grid.Row="3" Height="30" Width="200" HorizontalAlignment="Left" Padding="6,4" Background="{DynamicResource BrushInputBg}" Foreground="{DynamicResource BrushText}" BorderBrush="{DynamicResource BrushInputBorder}"/>
        <TextBlock Grid.Row="4" Text="Atualizar automaticamente a cada (minutos):" Foreground="{DynamicResource BrushTextMuted}" Margin="0,14,0,4"/>
        <TextBox x:Name="TxtRefresh" Grid.Row="5" Height="30" Width="80" HorizontalAlignment="Left" Padding="6,4" Background="{DynamicResource BrushInputBg}" Foreground="{DynamicResource BrushText}" BorderBrush="{DynamicResource BrushInputBorder}"/>
        <StackPanel Grid.Row="7" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnCancelar" Content="Cancelar" Width="100" Height="34" Margin="0,0,10,0" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0"/>
            <Button x:Name="BtnSalvar" Content="Salvar" Width="120" Height="34" Background="{DynamicResource BrushSuccess}" Foreground="White" BorderThickness="0" FontWeight="Bold"/>
        </StackPanel>
    </Grid>
</Window>
'@

function Show-ConfigurarServidorDialog {
    $cfg = Get-PrinterConfig
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:ConfigServidorXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow
    Set-DialogTheme -Dialog $dlg

    $txtServidor   = $dlg.FindName("TxtServidor")
    $txtComunidade = $dlg.FindName("TxtComunidade")
    $txtRefresh    = $dlg.FindName("TxtRefresh")
    $txtServidor.Text   = [string]$cfg.ServidorPrint
    $txtComunidade.Text = [string]$cfg.SnmpCommunity
    $txtRefresh.Text    = [string]$cfg.TempoRefreshMinutos

    $global:ConfigServidorSalvou = $false
    $dlg.FindName("BtnSalvar").Add_Click({
        $mins = 5
        try { if ($txtRefresh.Text) { $mins = [int]$txtRefresh.Text } } catch {}
        if ($mins -lt 1) { $mins = 1 }
        Save-PrinterConfig -ServidorPrint $txtServidor.Text.Trim() -SnmpCommunity $txtComunidade.Text.Trim() -TempoRefreshMinutos $mins
        $global:ConfigServidorSalvou = $true
        $dlg.DialogResult = $true
        $dlg.Close()
    }.GetNewClosure())
    $dlg.FindName("BtnCancelar").Add_Click({ $dlg.DialogResult = $false; $dlg.Close() }.GetNewClosure())
    [void]$dlg.ShowDialog()
    return $global:ConfigServidorSalvou
}

# SNMP puro via UDP (sem dependencias externas) - le toner/uptime/paginas.
function Get-TonerSNMP {
    param([string]$IP, [int]$Qtd = 1, [string]$Community = "public")
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = 1500
        $udp.Connect($IP, 161)

        function Build-SnmpGet {
            param([string]$oid, [string]$community)
            $oidParts = $oid.Split('.') | ForEach-Object { [int]$_ }
            $oidBytes = @(0x2b)
            for ($i = 2; $i -lt $oidParts.Count; $i++) {
                $val = $oidParts[$i]
                if ($val -lt 128) { $oidBytes += [byte]$val }
                else {
                    $buf = @()
                    $buf += [byte]($val -band 0x7F)
                    $val = $val -shr 7
                    while ($val -gt 0) {
                        $buf = @([byte](($val -band 0x7F) -bor 0x80)) + $buf
                        $val = $val -shr 7
                    }
                    $oidBytes += $buf
                }
            }
            $oidTlv    = @(0x06, $oidBytes.Count) + $oidBytes
            $nullTlv   = @(0x05, 0x00)
            $varBind   = @(0x30, ($oidTlv.Count + $nullTlv.Count)) + $oidTlv + $nullTlv
            $varBinds  = @(0x30, $varBind.Count) + $varBind
            $communityBytes = [System.Text.Encoding]::ASCII.GetBytes($community)
            $commTlv   = @(0x04, $communityBytes.Count) + $communityBytes
            $reqId     = @(0x02, 0x04, 0x00, 0x00, 0x00, 0x01)
            $errStat   = @(0x02, 0x01, 0x00)
            $errIdx    = @(0x02, 0x01, 0x00)
            $pdu       = @(0xa0) + @(0x00) + $reqId + $errStat + $errIdx + $varBinds
            $pdu[1]    = $pdu.Count - 2
            $version   = @(0x02, 0x01, 0x00)
            $seq       = @(0x30) + @(0x00) + $version + $commTlv + $pdu
            $seq[1]    = $seq.Count - 2
            return [byte[]]$seq
        }

        function Parse-SnmpInt {
            param([byte[]]$data)
            if ($null -eq $data -or $data.Count -lt 4) { return $null }
            $result = $null
            $i = 0
            while ($i -lt ($data.Count - 2)) {
                if ($data[$i] -eq 0x02) {
                    $len = $data[$i + 1]
                    if ($len -ge 1 -and $len -le 4 -and ($i + 2 + $len) -le $data.Count) {
                        $val = 0
                        for ($j = 0; $j -lt $len; $j++) { $val = ($val -shl 8) -bor $data[$i + 2 + $j] }
                        if ($i -gt 10) { $result = $val }
                    }
                }
                $i++
            }
            return $result
        }

        function Parse-SnmpString {
            param([byte[]]$data)
            if ($null -eq $data -or $data.Count -lt 12) { return "" }
            $result = ""
            $i = 0
            while ($i -lt ($data.Count - 2)) {
                if ($data[$i] -eq 0x04) {
                    $len = $data[$i + 1]
                    if ($len -gt 0 -and ($i + 2 + $len) -le $data.Count -and $i -gt 10) {
                        $result = [System.Text.Encoding]::ASCII.GetString($data[($i + 2)..($i + 1 + $len)]).Trim()
                    }
                }
                $i++
            }
            return $result
        }

        function Parse-SnmpCounter {
            param([byte[]]$data)
            if ($null -eq $data -or $data.Count -lt 4) { return $null }
            $result = $null
            $i = 0
            while ($i -lt ($data.Count - 2)) {
                if ($data[$i] -eq 0x41 -or $data[$i] -eq 0x02) {
                    $len = $data[$i + 1]
                    if ($len -ge 1 -and $len -le 5 -and ($i + 2 + $len) -le $data.Count) {
                        $val = 0
                        for ($j = 0; $j -lt $len; $j++) { $val = ($val -shl 8) -bor $data[$i + 2 + $j] }
                        if ($i -gt 10) { $result = $val }
                    }
                }
                $i++
            }
            return $result
        }

        $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)

        $uptimeStr = "N/A"
        try {
            $pkgUptime = Build-SnmpGet "1.3.6.1.2.1.1.3.0" $Community
            $udp.Send($pkgUptime, $pkgUptime.Count) | Out-Null
            $respUptime = $udp.Receive([ref]$ep)
            $ticks = $null
            for ($i = 0; $i -lt ($respUptime.Count - 2); $i++) {
                if ($respUptime[$i] -eq 0x43) {
                    $len = $respUptime[$i + 1]
                    if ($len -ge 1 -and $len -le 5 -and ($i + 2 + $len) -le $respUptime.Count) {
                        $val = 0
                        for ($j = 0; $j -lt $len; $j++) { $val = ($val -shl 8) -bor $respUptime[$i + 2 + $j] }
                        $ticks = $val; break
                    }
                }
            }
            if ($null -ne $ticks) {
                $sec = $ticks / 100
                $uptimeStr = "$([math]::Floor($sec/86400))d, $([math]::Floor(($sec%86400)/3600))h, $([math]::Floor(($sec%3600)/60))m"
            }
        } catch {}

        $pageCount = $null
        try {
            $pkgPagCount = Build-SnmpGet "1.3.6.1.2.1.43.10.2.1.4.1.1" $Community
            $udp.Send($pkgPagCount, $pkgPagCount.Count) | Out-Null
            $pageCount = Parse-SnmpCounter ($udp.Receive([ref]$ep))
        } catch {}

        $candidatos = @()
        $falhasConsecutivas = 0
        foreach ($indice in 1..20) {
            try {
                $pkgNivel = Build-SnmpGet "1.3.6.1.2.1.43.11.1.1.9.1.$indice" $Community
                $udp.Send($pkgNivel, $pkgNivel.Count) | Out-Null
                $nivel = Parse-SnmpInt ($udp.Receive([ref]$ep))

                $pkgMax = Build-SnmpGet "1.3.6.1.2.1.43.11.1.1.8.1.$indice" $Community
                $udp.Send($pkgMax, $pkgMax.Count) | Out-Null
                $maximo = Parse-SnmpInt ($udp.Receive([ref]$ep))

                if ($null -ne $nivel -and $null -ne $maximo -and $maximo -gt 0) {
                    $falhasConsecutivas = 0
                    $pkgDesc = Build-SnmpGet "1.3.6.1.2.1.43.11.1.1.6.1.$indice" $Community
                    $udp.Send($pkgDesc, $pkgDesc.Count) | Out-Null
                    $desc = Parse-SnmpString ($udp.Receive([ref]$ep))

                    if ($desc -match "(?i)waste|descarte|lixeira|recovery|container|cleaner") { continue }

                    $pct = [math]::Min(100, [math]::Max(0, [math]::Round(($nivel / $maximo) * 100)))

                    $cor = "Preto"
                    if      ($desc -match "(?i)cyan|ciano|azul|\bc\b")       { $cor = "Ciano" }
                    elseif  ($desc -match "(?i)magenta|rosa|\bm\b")           { $cor = "Magenta" }
                    elseif  ($desc -match "(?i)yellow|amarelo|\by\b")         { $cor = "Amarelo" }
                    elseif  ($desc -match "(?i)black|preto|negro|\bk\b")      { $cor = "Preto" }
                    elseif  ($Qtd -gt 1) {
                        switch ($indice % 4) { 1{$cor="Ciano"} 2{$cor="Magenta"} 3{$cor="Amarelo"} 0{$cor="Preto"} }
                    }

                    $candidatos += [PSCustomObject]@{ Indice=$indice; Pct=$pct; CorToner=$cor; Maximo=$maximo }
                } else {
                    $falhasConsecutivas++
                }
            } catch {
                $falhasConsecutivas++
            }
            if ($Qtd -eq 1 -and $candidatos.Count -ge 1) { break }
            if ($Qtd -gt 1 -and $candidatos.Count -ge 8) { break }
            if ($falhasConsecutivas -ge 3) { break }
        }

        $melhores = @()
        if ($candidatos.Count -gt 0) {
            if ($Qtd -gt 1) {
                $pesos = @{ "Ciano"=1; "Magenta"=2; "Amarelo"=3; "Preto"=4 }
                $melhores = $candidatos | Group-Object CorToner | ForEach-Object { $_.Group | Select-Object -First 1 } | Sort-Object { $pesos[$_.CorToner] }
            } else {
                $melhores = $candidatos | Sort-Object Maximo -Descending | Select-Object -First 1
            }
        }

        $udp.Dispose()
        return @{ Toners=$melhores; Uptime=$uptimeStr; PageCount=$pageCount }
    } catch {
        if ($null -ne $udp) { $udp.Dispose() }
        return @{ Toners=$null; Uptime="Erro"; PageCount=$null }
    }
}

function Obter-Modelo {
    param([string]$Driver)
    switch -Regex ($Driver) {
        "P 311"     { "Ricoh P311" }
        "P 502"     { "Ricoh P502" }
        "M3040"     { "Kyocera M3040idn" }
        "P3055"     { "Kyocera P3055dn" }
        "M6530"     { "Kyocera M6530cdn" }
        "Honeywell" { "Honeywell RP4f" }
        "TT042"     { "Elgin TT042" }
        "ELGIN"     { "Elgin TT042 Plus" }
        default     { $Driver -replace '\s+(PCL\d*|PS|KX|XPS|UFR\s*II|Class Driver)\b.*', '' }
    }
}

# Consulta o spooler do servidor de impressao configurado e faz SNMP em paralelo
# (runspace pool) em cada impressora. Em caso de falha, cai para o ultimo
# resultado bom conhecido, salvo em disco.
function Get-ImpressorasRede {
    $cfg = Get-PrinterConfig
    Set-Status ("Consultando spooler em '{0}'..." -f $cfg.ServidorPrint)
    try {
        $ports    = Get-PrinterPort -ComputerName $cfg.ServidorPrint -ErrorAction Stop
        $printers = Get-Printer -ComputerName $cfg.ServidorPrint -ErrorAction Stop
    } catch {
        Write-Log -Message ("[PRINT] Servidor '{0}' inacessivel: {1}" -f $cfg.ServidorPrint,$_.Exception.Message) -Level "ERROR"
        if (Test-Path $global:PrinterCacheFile) {
            try {
                $cache = Get-Content $global:PrinterCacheFile -Raw | ConvertFrom-Json
                return @($cache)
            } catch {}
        }
        return @()
    }

    $portMap = @{}
    foreach ($port in $ports) { if ($port.Name) { $portMap[$port.Name] = [string]$port.PrinterHostAddress } }

    $pool = [runspacefactory]::CreateRunspacePool(1, 30)
    $pool.Open()
    $defGetToner = (Get-Command Get-TonerSNMP).Definition
    $defObterMod = (Get-Command Obter-Modelo).Definition
    $snmpCommunity = [string]$cfg.SnmpCommunity

    $tasks = @()
    foreach ($printer in $printers) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript(@"
param(`$p, `$portMap, `$defGetToner, `$defObterMod, `$snmpCommunity)
Invoke-Expression "function Get-TonerSNMP { `$defGetToner }"
Invoke-Expression "function Obter-Modelo { `$defObterMod }"

`$ip     = if (`$portMap.ContainsKey(`$p.PortName)) { `$portMap[`$p.PortName] } else { `$p.PortName }
`$online = `$false
if (`$ip -match '^\d') {
    try { if ((New-Object System.Net.NetworkInformation.Ping).Send(`$ip, 400).Status -eq 'Success') { `$online = `$true } } catch {}
}
`$modelo = Obter-Modelo `$p.DriverName
`$qtd    = if (`$modelo -match 'color|M6530' -or `$p.Name -match 'color') { 4 } else { 1 }
`$snmp   = @{ Toners = `$null; Uptime = 'N/A'; PageCount = `$null }

if (`$online -and `$modelo -notmatch 'TT042|Honeywell' -and `$p.Name -notmatch 'TT042|Honeywell|Etiqueta|Elgin') {
    `$snmp = Get-TonerSNMP -IP `$ip -Qtd `$qtd -Community `$snmpCommunity
}

return [PSCustomObject]@{
    Nome      = `$p.Name
    IP        = `$ip
    Modelo    = `$modelo
    Status    = if (`$online) { 'Online' } else { 'Offline' }
    Toner     = (@(`$snmp.Toners | ForEach-Object { "{0}:{1}%" -f (`$_.CorToner.Substring(0,1)), `$_.Pct }) -join " ")
    Uptime    = `$snmp.Uptime
    PageCount = `$snmp.PageCount
}
"@)
        [void]$ps.AddArgument($printer)
        [void]$ps.AddArgument($portMap)
        [void]$ps.AddArgument($defGetToner)
        [void]$ps.AddArgument($defObterMod)
        [void]$ps.AddArgument($snmpCommunity)
        $tasks += @{ Pipe = $ps; Handle = $ps.BeginInvoke() }
    }

    $resultado = @()
    $total = $tasks.Count; $done = 0
    foreach ($t in $tasks) {
        $done++
        Set-Status ("Varrendo impressoras... ({0}/{1})" -f $done,$total)
        try {
            $obj = $t.Pipe.EndInvoke($t.Handle) | Select-Object -Last 1
            if ($null -ne $obj) { $resultado += $obj }
        } catch { Write-Log -Message ("[PRINT] Erro ao processar impressora: {0}" -f $_.Exception.Message) -Level "ERROR" }
        $t.Pipe.Dispose()
    }
    $pool.Close(); $pool.Dispose()

    try { $resultado | ConvertTo-Json -Depth 5 | Out-File $global:PrinterCacheFile -Encoding UTF8 -Force } catch {}
    Set-Status ("Varredura concluida: {0} impressora(s)." -f $resultado.Count) "SUCCESS"
    return $resultado
}

function Export-PrintersCsv {
    param([array]$Printers)
    $path = Join-Path $global:ReportsPath ("Impressoras-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $lines = @("Nome,IP,Modelo,Status,Toner,Uptime,PaginasImpressas")
    foreach ($p in $Printers) {
        $lines += ('{0},{1},{2},{3},"{4}",{5},{6}' -f $p.Nome,$p.IP,$p.Modelo,$p.Status,$p.Toner,$p.Uptime,$p.PageCount)
    }
    $lines | Out-File $path -Encoding UTF8 -Force
    return $path
}

# Envia pagina de teste para uma impressora ja instalada localmente (precisa
# de uma fila local correspondente - impressoras so mapeadas no servidor e
# nao conectadas nesta maquina nao suportam pagina de teste local).
function Invoke-PrintTestPage {
    param([string]$Nome)
    $safeNome = $Nome.Replace("'","''")
    try {
        $printerObj = Get-CimInstance -ClassName Win32_Printer -Filter ("Name='{0}'" -f $safeNome) -ErrorAction Stop
        if ($printerObj) {
            Invoke-CimMethod -InputObject $printerObj -MethodName PrintTestPage -ErrorAction Stop | Out-Null
            Show-Info ("Pagina de teste enviada para {0}." -f $Nome)
            Write-Log -Message ("[PRINT] Pagina de teste enviada para {0}." -f $Nome) -Level "SUCCESS"
            return
        }
    } catch {}
    Show-Warning ("'{0}' nao esta instalada como fila local nesta maquina.`n`nMapeie a impressora primeiro (Gerenciar Driver > Mapear via Rede) antes de enviar uma pagina de teste." -f $Nome)
}

# ==============================================================================
# GERENCIAMENTO DE DRIVER (versao simplificada - sem pasta local de drivers,
# incompativel com a distribuicao single-file via Gist). So oferece as duas
# acoes que nao dependem de arquivos empacotados junto do script.
# ==============================================================================
$script:DriverPopupXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Gerenciar Driver" Height="320" Width="460"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="{DynamicResource BrushSurface}">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="TxtNome" Grid.Row="0" Foreground="{DynamicResource BrushText}" FontSize="18" FontWeight="Bold" TextWrapping="Wrap"/>
        <TextBlock x:Name="TxtModelo" Grid.Row="1" Foreground="{DynamicResource BrushTextMuted}" FontSize="13" Margin="0,4,0,16"/>
        <StackPanel Grid.Row="2">
            <Border Background="{DynamicResource BrushSurfaceAlt}" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" CornerRadius="6" Padding="14" Margin="0,0,0,10">
                <StackPanel>
                    <TextBlock Text="Impressora gerenciada pelo servidor de impressao" Foreground="{DynamicResource BrushText}" FontWeight="SemiBold" FontSize="13" TextWrapping="Wrap"/>
                    <TextBlock Text="Abre o assistente nativo do Windows para conectar via \\servidor\impressora." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,4,0,10" TextWrapping="Wrap"/>
                    <Button x:Name="BtnMapear" Content="Mapear via Rede" Height="34" Background="{DynamicResource BrushAccent}" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
                </StackPanel>
            </Border>
            <Border Background="{DynamicResource BrushSurfaceAlt}" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" CornerRadius="6" Padding="14">
                <StackPanel>
                    <TextBlock Text="Driver manual" Foreground="{DynamicResource BrushText}" FontWeight="SemiBold" FontSize="13"/>
                    <TextBlock Text="Selecione um arquivo .inf ou .exe do driver no computador." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,4,0,10" TextWrapping="Wrap"/>
                    <Button x:Name="BtnManual" Content="Selecionar Driver Manual" Height="34" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
                </StackPanel>
            </Border>
        </StackPanel>
        <Button x:Name="BtnFechar" Grid.Row="3" Content="Fechar" Width="100" Height="34" HorizontalAlignment="Right" Margin="0,16,0,0" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0"/>
    </Grid>
</Window>
'@

function Show-DriverPopupSimplificado {
    param([string]$Nome,[string]$Modelo,[string]$IP)
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:DriverPopupXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow
    Set-DialogTheme -Dialog $dlg
    $dlg.FindName("TxtNome").Text   = $Nome
    $dlg.FindName("TxtModelo").Text = ("Modelo: {0}" -f $Modelo)

    $dlg.FindName("BtnMapear").Add_Click({
        try {
            $cfgLocal = Get-PrinterConfig
            $uncPath  = "\\{0}\{1}" -f $cfgLocal.ServidorPrint,$Nome
            $quote    = [char]34
            Start-Process "rundll32.exe" -ArgumentList ("printui.dll,PrintUIEntry /in /n " + $quote + $uncPath + $quote) | Out-Null
            $dlg.Close()
        } catch { Show-ErrorBox ("Falha ao abrir o assistente de conexao.`n`n{0}" -f $_.Exception.Message) }
    }.GetNewClosure())

    $dlg.FindName("BtnManual").Add_Click({
        $ofd = New-Object Microsoft.Win32.OpenFileDialog
        $ofd.Filter = "Pacotes de instalacao (*.inf;*.exe)|*.inf;*.exe"
        $ofd.Title  = "Selecionar driver manual para $Modelo"
        if ($ofd.ShowDialog() -eq $true) {
            $manualPath = $ofd.FileName
            $quote = [char]34
            try {
                if ($manualPath -match "\.exe$") {
                    Start-Process $manualPath -Wait
                    Show-Info "Instalador manual executado."
                } else {
                    $proc = Start-Process "pnputil.exe" -ArgumentList ("/add-driver " + $quote + $manualPath + $quote + " /install") -Wait -PassThru
                    if ($proc.ExitCode -eq 0) { Show-Info "Driver injetado com sucesso." }
                    else { Show-Warning ("O Windows recusou o pacote do driver. Codigo: {0}" -f $proc.ExitCode); return }
                }
                $dlg.Close()
            } catch { Show-ErrorBox ("Falha ao instalar driver manual.`n`n{0}" -f $_.Exception.Message) }
        }
    }.GetNewClosure())

    $dlg.FindName("BtnFechar").Add_Click({ $dlg.Close() }.GetNewClosure())
    [void]$dlg.ShowDialog()
}

# ==============================================================================
# DETALHES DA IMPRESSORA (uptime, paginas, barras de toner)
# ==============================================================================
$script:PrinterDetailsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Detalhes da Impressora" Height="440" Width="420"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="{DynamicResource BrushSurface}">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="TxtNome" Grid.Row="0" Foreground="{DynamicResource BrushText}" FontSize="18" FontWeight="Bold" TextWrapping="Wrap"/>
        <TextBlock x:Name="TxtModelo" Grid.Row="1" Foreground="{DynamicResource BrushTextMuted}" FontSize="13" Margin="0,4,0,15"/>
        <Border Grid.Row="2" Background="{DynamicResource BrushSurfaceAlt}" CornerRadius="6" Padding="14" Margin="0,0,0,15" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="120"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Grid.Column="0" Text="Endereco IP:" Foreground="{DynamicResource BrushTextMuted}" Margin="0,5" FontSize="13"/>
                <TextBlock x:Name="TxtIP" Grid.Row="0" Grid.Column="1" Foreground="{DynamicResource BrushText}" FontWeight="Bold" Margin="0,5" FontSize="13"/>
                <TextBlock Grid.Row="1" Grid.Column="0" Text="Status atual:" Foreground="{DynamicResource BrushTextMuted}" Margin="0,5" FontSize="13"/>
                <TextBlock x:Name="TxtStatus" Grid.Row="1" Grid.Column="1" Foreground="{DynamicResource BrushAccent}" FontWeight="Bold" Margin="0,5" FontSize="13"/>
                <TextBlock Grid.Row="2" Grid.Column="0" Text="Tempo Online:" Foreground="{DynamicResource BrushTextMuted}" Margin="0,5" FontSize="13"/>
                <TextBlock x:Name="TxtUptime" Grid.Row="2" Grid.Column="1" Foreground="{DynamicResource BrushText}" FontWeight="Bold" Margin="0,5" FontSize="13"/>
                <TextBlock Grid.Row="3" Grid.Column="0" Text="Pags. Impressas:" Foreground="{DynamicResource BrushTextMuted}" Margin="0,5" FontSize="13"/>
                <TextBlock x:Name="TxtPaginas" Grid.Row="3" Grid.Column="1" Foreground="{DynamicResource BrushText}" FontWeight="Bold" Margin="0,5" FontSize="13"/>
            </Grid>
        </Border>
        <StackPanel Grid.Row="3">
            <TextBlock Text="NIVEIS DE SUPRIMENTOS" Foreground="{DynamicResource BrushTextMuted}" FontSize="11" FontWeight="Bold" Margin="0,0,0,10"/>
            <StackPanel x:Name="SpToners"/>
        </StackPanel>
        <Button x:Name="BtnFechar" Grid.Row="4" Content="Fechar" Width="100" Height="36" HorizontalAlignment="Right" Margin="0,10,0,0"
                Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" FontWeight="SemiBold" BorderThickness="0"/>
    </Grid>
</Window>
'@

function Show-PrinterDetailsDialog {
    param($Printer)
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:PrinterDetailsXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow
    Set-DialogTheme -Dialog $dlg

    $dlg.FindName("TxtNome").Text    = [string]$Printer.Nome
    $dlg.FindName("TxtModelo").Text  = [string]$Printer.Modelo
    $dlg.FindName("TxtIP").Text      = [string]$Printer.IP
    $dlg.FindName("TxtStatus").Text  = [string]$Printer.Status
    $dlg.FindName("TxtUptime").Text  = [string]$Printer.Uptime
    $dlg.FindName("TxtPaginas").Text = [string]$Printer.PageCount

    $spToners = $dlg.FindName("SpToners")
    $mapaCores = @{ "P"="Preto"; "C"="Ciano"; "M"="Magenta"; "Y"="Amarelo" }
    $mapaHex   = @{ "P"="#9CA3AF"; "C"="#00BCFF"; "M"="#EC4899"; "Y"="#EAB308" }
    $tonerText = [string]$Printer.Toner
    $achou = $false
    if ($tonerText) {
        foreach ($m in [regex]::Matches($tonerText,"([A-Za-z]+):(\d+)%")) {
            $achou = $true
            $sigla = $m.Groups[1].Value
            $pct   = [int]$m.Groups[2].Value
            $label = if ($mapaCores.ContainsKey($sigla)) { $mapaCores[$sigla] } else { $sigla }
            $hex   = if ($mapaHex.ContainsKey($sigla)) { $mapaHex[$sigla] } else { "#219AF9" }

            $row = New-Object System.Windows.Controls.Grid
            $row.Margin = "0,0,0,10"
            $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 90
            $c2 = New-Object System.Windows.Controls.ColumnDefinition
            [void]$row.ColumnDefinitions.Add($c1); [void]$row.ColumnDefinitions.Add($c2)

            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = ("{0} {1}%" -f $label,$pct)
            $lbl.Foreground = Get-Brush $hex
            $lbl.FontSize = 12; $lbl.FontWeight = "Bold"; $lbl.VerticalAlignment = "Center"
            [System.Windows.Controls.Grid]::SetColumn($lbl,0)
            [void]$row.Children.Add($lbl)

            $track = New-Object System.Windows.Controls.Border
            $track.Height = 10; $track.CornerRadius = 5; $track.Background = Get-ThemeBrush "BrushBorder"
            $track.VerticalAlignment = "Center"
            $fillWidth = [double]([math]::Max(2,[math]::Round(($pct/100.0)*200)))
            $fill = New-Object System.Windows.Controls.Border
            $fill.Height = 10; $fill.CornerRadius = 5; $fill.Background = Get-Brush $hex
            $fill.Width = $fillWidth; $fill.HorizontalAlignment = "Left"
            $track.Child = $fill
            [System.Windows.Controls.Grid]::SetColumn($track,1)
            [void]$row.Children.Add($track)

            [void]$spToners.Children.Add($row)
        }
    }
    if (-not $achou) {
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = "Sem leitura de suprimentos disponivel para este equipamento."
        $lbl.Foreground = Get-ThemeBrush "BrushTextMuted"
        $lbl.FontSize = 12; $lbl.TextWrapping = "Wrap"
        [void]$spToners.Children.Add($lbl)
    }

    $dlg.FindName("BtnFechar").Add_Click({ $dlg.Close() }.GetNewClosure())
    [void]$dlg.ShowDialog()
}

# ==============================================================================
# INTERFACE (WPF) - shell novo com tema claro/escuro
# Montado em fragmentos (XamlHead/XamlPanelsA/XamlPanelsB/XamlPanelsC) e
# concatenado em $script:MainWindowXaml logo antes do uso, para manter cada
# bloco de texto administravel.
# ==============================================================================
$script:XamlHead = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Elgin Service Desk Tool" Height="760" Width="1240"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource BrushWindowBg}">
    <Window.Resources>
        <Style x:Key="NavGroupLabel" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{DynamicResource BrushTextFaint}"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Margin" Value="22,18,0,6"/>
        </Style>
        <Style x:Key="SidebarButton" TargetType="Button">
            <Setter Property="Height" Value="42"/>
            <Setter Property="Margin" Value="0,0,0,3"/>
            <Setter Property="Foreground" Value="{DynamicResource BrushTextMuted}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding" Value="22,0,0,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{DynamicResource BrushAccent}" BorderThickness="{TemplateBinding Tag}">
                            <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource BrushHover}"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="CardButton" TargetType="Button">
            <Setter Property="Height" Value="40"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="TopBarButton" TargetType="Button" BasedOn="{StaticResource CardButton}">
            <Setter Property="Height" Value="30"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Padding" Value="10,0"/>
        </Style>
        <Style x:Key="FilterChip" TargetType="Button">
            <Setter Property="Height" Value="30"/>
            <Setter Property="Padding" Value="14,0"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="Foreground" Value="{DynamicResource BrushTextMuted}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BrushBorder}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="15">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="RowActionButton" TargetType="Button">
            <Setter Property="Width" Value="62"/>
            <Setter Property="Height" Value="26"/>
            <Setter Property="Margin" Value="0,0,4,0"/>
            <Setter Property="FontSize" Value="10"/>
            <Setter Property="Background" Value="{DynamicResource BrushSurfaceAlt}"/>
            <Setter Property="Foreground" Value="{DynamicResource BrushText}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BrushBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ShortcutCardButton" TargetType="Button">
            <Setter Property="Height" Value="92"/>
            <Setter Property="Margin" Value="0,0,12,12"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding" Value="18"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Background" Value="{DynamicResource BrushSurface}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BrushBorder}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
                            <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource BrushAccent}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="StatMiniTile" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource BrushSurface}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BrushBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="8"/>
            <Setter Property="Padding" Value="16,12"/>
            <Setter Property="Margin" Value="0,0,12,12"/>
        </Style>
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource BrushSurface}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BrushBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="8"/>
            <Setter Property="Padding" Value="16"/>
            <Setter Property="Margin" Value="0,0,0,10"/>
        </Style>
        <Style x:Key="SearchBox" TargetType="TextBox">
            <Setter Property="Height" Value="36"/>
            <Setter Property="Padding" Value="12,0"/>
            <Setter Property="Background" Value="{DynamicResource BrushInputBg}"/>
            <Setter Property="Foreground" Value="{DynamicResource BrushText}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BrushInputBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="{DynamicResource BrushSurfaceAlt}"/>
            <Setter Property="Foreground" Value="{DynamicResource BrushTextMuted}"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource BrushText}"/>
            <Setter Property="Margin" Value="0,0,0,10"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="230"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Border Grid.Column="0" Background="{DynamicResource BrushSidebarBg}" BorderBrush="{DynamicResource BrushSidebarBrd}" BorderThickness="0,0,1,0">
            <DockPanel>
                <StackPanel DockPanel.Dock="Top" Margin="22,24,0,10">
                    <Image x:Name="LogoElgin" Height="56" Stretch="Uniform" HorizontalAlignment="Left" Margin="0,0,0,10" Visibility="Collapsed"/>
                    <TextBlock Text="Elgin" Foreground="{DynamicResource BrushText}" FontSize="20" FontWeight="Bold"/>
                    <TextBlock Text="Service Desk Tool" Foreground="{DynamicResource BrushTextMuted}" FontSize="12"/>
                    <TextBlock x:Name="TxtVersaoSidebar" Text="" Foreground="{DynamicResource BrushTextFaint}" FontSize="10" Margin="0,4,0,0"/>
                </StackPanel>
                <ScrollViewer DockPanel.Dock="Top" VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="0,4,0,0">
                        <TextBlock Text="INICIO" Style="{StaticResource NavGroupLabel}" Margin="22,4,0,6"/>
                        <Button x:Name="NavInicio" Content="Inicio" Style="{StaticResource SidebarButton}" Background="{DynamicResource BrushActiveNav}" Foreground="{DynamicResource BrushText}" Tag="3,0,0,0"/>
                        <Button x:Name="NavChecklist" Content="Checklist" Style="{StaticResource SidebarButton}" Tag="0"/>
                        <TextBlock Text="APLICATIVOS" Style="{StaticResource NavGroupLabel}"/>
                        <Button x:Name="NavInstalar"  Content="Instalar Aplicativos" Style="{StaticResource SidebarButton}" Tag="0"/>
                        <Button x:Name="NavExtra"     Content="Pacote Extra"        Style="{StaticResource SidebarButton}" Tag="0"/>
                        <TextBlock Text="SISTEMA" Style="{StaticResource NavGroupLabel}"/>
                        <Button x:Name="NavLimpeza"   Content="Limpeza"             Style="{StaticResource SidebarButton}" Tag="0"/>
                        <Button x:Name="NavRede"      Content="Rede"                Style="{StaticResource SidebarButton}" Tag="0"/>
                        <TextBlock Text="IMPRESSAO" Style="{StaticResource NavGroupLabel}"/>
                        <Button x:Name="NavImpressao" Content="Impressao"           Style="{StaticResource SidebarButton}" Tag="0"/>
                        <TextBlock Text="AVANCADO" Style="{StaticResource NavGroupLabel}"/>
                        <Button x:Name="NavFerramentas" Content="Ferramentas"       Style="{StaticResource SidebarButton}" Tag="0"/>
                        <TextBlock Text="DIAGNOSTICO" Style="{StaticResource NavGroupLabel}"/>
                        <Button x:Name="NavLogs"      Content="Logs"                Style="{StaticResource SidebarButton}" Tag="0"/>
                    </StackPanel>
                </ScrollViewer>
            </DockPanel>
        </Border>

        <Grid Grid.Column="1">
            <Grid.RowDefinitions>
                <RowDefinition Height="58"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="30"/>
            </Grid.RowDefinitions>

            <Border Grid.Row="0" Background="{DynamicResource BrushTopBarBg}" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="0,0,0,1">
                <Grid Margin="24,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="TxtTituloSecao" Grid.Column="0" Text="Instalar Aplicativos" Foreground="{DynamicResource BrushText}" FontSize="17" FontWeight="Bold" VerticalAlignment="Center"/>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <Border x:Name="BorderAdminBadge" CornerRadius="12" Padding="10,4" Margin="0,0,8,0" Background="{DynamicResource BrushWarning}">
                            <TextBlock x:Name="TxtAdminBadge" Text="Sem privilegios" FontSize="11" FontWeight="SemiBold" Foreground="White"/>
                        </Border>
                        <Border CornerRadius="12" Padding="10,4" Margin="0,0,6,0" Background="{DynamicResource BrushSurfaceAlt}">
                            <TextBlock x:Name="TbCpu" FontSize="11" Foreground="{DynamicResource BrushTextMuted}"/>
                        </Border>
                        <Border CornerRadius="12" Padding="10,4" Margin="0,0,6,0" Background="{DynamicResource BrushSurfaceAlt}">
                            <TextBlock x:Name="TbRam" FontSize="11" Foreground="{DynamicResource BrushTextMuted}"/>
                        </Border>
                        <Border CornerRadius="12" Padding="10,4" Margin="0,0,10,0" Background="{DynamicResource BrushSurfaceAlt}">
                            <TextBlock x:Name="TbDisk" FontSize="11" Foreground="{DynamicResource BrushTextMuted}"/>
                        </Border>
                        <Button x:Name="BtnTemaToggle" Content="Tema: Escuro" Style="{StaticResource TopBarButton}" Background="{DynamicResource BrushSurfaceAlt}" Foreground="{DynamicResource BrushText}" Width="100" Margin="0,0,8,0"/>
                        <Button x:Name="BtnSino" Style="{StaticResource TopBarButton}" Background="{DynamicResource BrushSurfaceAlt}" Width="36">
                            <Grid>
                                <TextBlock Text="Logs" FontSize="11" Foreground="{DynamicResource BrushText}"/>
                                <Border x:Name="BorderBadgeErros" Background="{DynamicResource BrushDanger}" CornerRadius="7" Width="14" Height="14" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-10,-10,0" Visibility="Collapsed">
                                    <TextBlock x:Name="TxtBadgeErros" Text="0" FontSize="9" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                            </Grid>
                        </Button>
                    </StackPanel>
                </Grid>
            </Border>

            <Grid Grid.Row="1" Margin="24">
'@

$script:XamlPanelsA = @'
                <!-- Inicio -->
                <Grid x:Name="PanelInicio">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" x:Name="TxtBemVindo" Text="Bem-vindo" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,2"/>
                    <TextBlock Grid.Row="1" x:Name="TxtSubtituloInicio" Text="" Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,18"/>

                    <WrapPanel Grid.Row="2" Margin="0,0,0,4">
                        <Border Style="{StaticResource StatMiniTile}" Width="180">
                            <StackPanel>
                                <TextBlock Text="ADMINISTRADOR" Foreground="{DynamicResource BrushTextFaint}" FontSize="10" FontWeight="Bold"/>
                                <TextBlock x:Name="TxtHomeAdmin" Text="Verificando..." Foreground="{DynamicResource BrushText}" FontSize="14" FontWeight="SemiBold" Margin="0,4,0,0"/>
                            </StackPanel>
                        </Border>
                        <Border Style="{StaticResource StatMiniTile}" Width="180">
                            <StackPanel>
                                <TextBlock Text="INTERNET" Foreground="{DynamicResource BrushTextFaint}" FontSize="10" FontWeight="Bold"/>
                                <TextBlock x:Name="TxtHomeInternet" Text="Verificando..." Foreground="{DynamicResource BrushText}" FontSize="14" FontWeight="SemiBold" Margin="0,4,0,0"/>
                            </StackPanel>
                        </Border>
                        <Border Style="{StaticResource StatMiniTile}" Width="180">
                            <StackPanel>
                                <TextBlock Text="WINGET" Foreground="{DynamicResource BrushTextFaint}" FontSize="10" FontWeight="Bold"/>
                                <TextBlock x:Name="TxtHomeWinget" Text="Verificando..." Foreground="{DynamicResource BrushText}" FontSize="14" FontWeight="SemiBold" Margin="0,4,0,0"/>
                            </StackPanel>
                        </Border>
                        <Border Style="{StaticResource StatMiniTile}" Width="180">
                            <StackPanel>
                                <TextBlock Text="CHOCOLATEY" Foreground="{DynamicResource BrushTextFaint}" FontSize="10" FontWeight="Bold"/>
                                <TextBlock x:Name="TxtHomeChoco" Text="Verificando..." Foreground="{DynamicResource BrushText}" FontSize="14" FontWeight="SemiBold" Margin="0,4,0,0"/>
                            </StackPanel>
                        </Border>
                    </WrapPanel>

                    <TextBlock Grid.Row="3" Text="ATALHOS" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold" Margin="0,10,0,10"/>

                    <ScrollViewer Grid.Row="4">
                        <UniformGrid x:Name="GridAtalhos" Columns="3"/>
                    </ScrollViewer>
                </Grid>

                <!-- Checklist -->
                <Grid x:Name="PanelChecklist" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Checklist" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,4"/>
                    <TextBlock Grid.Row="1" Text="Formatacao / Configuracao - marque cada etapa conforme for concluindo. Progresso salvo automaticamente." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,14" TextWrapping="Wrap"/>
                    <Grid Grid.Row="2" Margin="0,0,0,14">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" x:Name="TxtChecklistProgresso" Text="0 de 22 concluidos" Foreground="{DynamicResource BrushAccent}" FontSize="14" FontWeight="Bold" VerticalAlignment="Center"/>
                        <Button Grid.Column="1" x:Name="BtnResetarChecklist" Content="Resetar Checklist" Width="160" Height="34" Style="{StaticResource CardButton}" Background="{DynamicResource BrushDanger}"/>
                    </Grid>
                    <ScrollViewer Grid.Row="3">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,0" VerticalAlignment="Top">
                                <StackPanel x:Name="SpChecklistLeft"/>
                            </Border>
                            <Border Grid.Column="1" Style="{StaticResource Card}" Margin="5,0,0,0" VerticalAlignment="Top">
                                <StackPanel x:Name="SpChecklistRight"/>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                </Grid>

                <!-- Instalar Aplicativos -->
                <Grid x:Name="PanelInstalar">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Instalar Aplicativos" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,14"/>

                    <Border Grid.Row="1" Style="{StaticResource Card}">
                        <StackPanel>
                            <TextBlock Text="GERENCIADORES DE PACOTE" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold" Margin="0,0,0,10"/>
                            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                <TextBlock x:Name="TxtWingetStatus" Text="Winget: verificando..." Foreground="{DynamicResource BrushText}" FontSize="13" VerticalAlignment="Center" Width="260"/>
                                <Button x:Name="BtnInstalarWinget" Content="Instalar Winget" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Width="150" Height="30" Margin="0,0,8,0"/>
                                <Button x:Name="BtnRepararWinget" Content="Reparar Winget" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" Width="150" Height="30"/>
                            </StackPanel>
                            <StackPanel Orientation="Horizontal">
                                <TextBlock x:Name="TxtChocoStatus" Text="Chocolatey: verificando..." Foreground="{DynamicResource BrushText}" FontSize="13" VerticalAlignment="Center" Width="260"/>
                                <Button x:Name="BtnInstalarChoco" Content="Instalar Chocolatey" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Width="150" Height="30"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>

                    <Border Grid.Row="2" Style="{StaticResource Card}">
                        <StackPanel>
                            <TextBlock Text="BUSCAR OUTRO SOFTWARE (WINGET / CHOCOLATEY)" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold" Margin="0,0,0,10"/>
                            <StackPanel Orientation="Horizontal">
                                <TextBox x:Name="TxtBuscaOnline" Style="{StaticResource SearchBox}" Width="360" Margin="0,0,10,0"/>
                                <Button x:Name="BtnBuscarOnline" Content="Buscar" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Width="110" Height="36"/>
                            </StackPanel>
                            <StackPanel x:Name="SpBuscaResultados" Margin="0,10,0,0"/>
                            <Button x:Name="BtnInstalarBusca" Content="Instalar Selecionados da Busca" Style="{StaticResource CardButton}" Background="{DynamicResource BrushSuccess}" Width="240" HorizontalAlignment="Left" Margin="0,10,0,0" Visibility="Collapsed"/>
                        </StackPanel>
                    </Border>

                    <TextBox Grid.Row="3" x:Name="TxtFiltroApps" Style="{StaticResource SearchBox}" Text="Pesquisar na lista padrao..." Foreground="{DynamicResource BrushTextMuted}" Margin="0,0,0,10"/>

                    <ScrollViewer Grid.Row="4"><StackPanel x:Name="SpAppsList"/></ScrollViewer>
                    <Button Grid.Row="5" x:Name="BtnInstalarSelecionados" Content="Instalar Selecionados" Width="220" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Margin="0,14,0,0"/>
                </Grid>

                <!-- Pacote Extra -->
                <Grid x:Name="PanelExtra" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Pacote Extra" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,14"/>
                    <ScrollViewer Grid.Row="1"><StackPanel x:Name="SpExtraList"/></ScrollViewer>
                    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,14,0,0">
                        <Button x:Name="BtnAdicionarExtra" Content="Adicionar" Width="140" Style="{StaticResource CardButton}" Background="{DynamicResource BrushSuccess}" Margin="0,0,10,0"/>
                        <Button x:Name="BtnInstalarExtra" Content="Instalar Selecionados" Width="220" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                    </StackPanel>
                </Grid>
'@

$script:XamlPanelsB = @'
                <!-- Limpeza -->
                <StackPanel x:Name="PanelLimpeza" Visibility="Collapsed">
                    <TextBlock Text="Limpeza" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,14"/>
                    <Border Style="{StaticResource Card}">
                        <StackPanel>
                            <TextBlock Text="Arquivos temporarios" Foreground="{DynamicResource BrushText}" FontWeight="SemiBold" Margin="0,0,0,4"/>
                            <TextBlock Text="Limpa a pasta TEMP do usuario e, se administrador, a pasta TEMP do Windows." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,10" TextWrapping="Wrap"/>
                            <Button x:Name="BtnLimparTemp" Content="Limpar Arquivos Temporarios" Width="280" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                        </StackPanel>
                    </Border>
                    <Border Style="{StaticResource Card}">
                        <StackPanel>
                            <TextBlock Text="Cache do Windows Update" Foreground="{DynamicResource BrushText}" FontWeight="SemiBold" Margin="0,0,0,4"/>
                            <TextBlock Text="Para wuauserv/bits, limpa SoftwareDistribution\Download e reinicia os servicos. Requer Administrador." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,10" TextWrapping="Wrap"/>
                            <Button x:Name="BtnLimparWU" Content="Limpar Cache do Windows Update" Width="280" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                        </StackPanel>
                    </Border>
                    <Border Style="{StaticResource Card}">
                        <StackPanel>
                            <TextBlock Text="Cache de geolocalizacao" Foreground="{DynamicResource BrushText}" FontWeight="SemiBold" Margin="0,0,0,4"/>
                            <TextBlock Text="Limpa o cache de localizacao do Windows e reinicia o servico lfsvc. Requer Administrador." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,10" TextWrapping="Wrap"/>
                            <Button x:Name="BtnLimparGeo" Content="Limpar Cache de Geolocalizacao" Width="280" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                        </StackPanel>
                    </Border>
                </StackPanel>

                <!-- Rede -->
                <StackPanel x:Name="PanelRede" Visibility="Collapsed">
                    <TextBlock Text="Ferramentas de Rede" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,14"/>
                    <Border Style="{StaticResource Card}">
                        <StackPanel>
                            <TextBlock Text="Flush DNS" Foreground="{DynamicResource BrushText}" FontWeight="SemiBold" Margin="0,0,0,4"/>
                            <TextBlock Text="Limpa o cache de resolucao DNS local." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,10"/>
                            <Button x:Name="BtnFlushDns" Content="Flush DNS" Width="220" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                        </StackPanel>
                    </Border>
                    <Border Style="{StaticResource Card}">
                        <StackPanel>
                            <TextBlock Text="Renovar IP" Foreground="{DynamicResource BrushText}" FontWeight="SemiBold" Margin="0,0,0,4"/>
                            <TextBlock Text="Libera e renova o endereco IP da conexao ativa. Requer Administrador." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,10"/>
                            <Button x:Name="BtnRenewIp" Content="Renew IP" Width="220" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                        </StackPanel>
                    </Border>
                    <Border Style="{StaticResource Card}">
                        <StackPanel>
                            <TextBlock Text="Reset Winsock" Foreground="{DynamicResource BrushText}" FontWeight="SemiBold" Margin="0,0,0,4"/>
                            <TextBlock Text="Reinicia o catalogo Winsock. Requer reiniciar o computador depois. Requer Administrador." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,10"/>
                            <Button x:Name="BtnWinsock" Content="Reset Winsock" Width="220" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushDanger}"/>
                        </StackPanel>
                    </Border>
                    <Border Style="{StaticResource Card}">
                        <StackPanel>
                            <TextBlock Text="Ping Google" Foreground="{DynamicResource BrushText}" FontWeight="SemiBold" Margin="0,0,0,4"/>
                            <TextBlock Text="Testa conectividade externa (8.8.8.8)." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,10"/>
                            <Button x:Name="BtnPingGoogle" Content="Ping Google" Width="220" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                        </StackPanel>
                    </Border>
                    <Border Style="{StaticResource Card}">
                        <StackPanel>
                            <TextBlock Text="Teste DNS" Foreground="{DynamicResource BrushText}" FontWeight="SemiBold" Margin="0,0,0,4"/>
                            <TextBlock Text="Resolve google.com para checar o DNS configurado." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,10"/>
                            <Button x:Name="BtnTesteDns" Content="Teste DNS" Width="220" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                        </StackPanel>
                    </Border>
                </StackPanel>

                <!-- Impressao -->
                <Grid x:Name="PanelImpressao" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Impressao" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,14"/>

                    <Border Grid.Row="1" Style="{StaticResource Card}">
                        <StackPanel>
                            <TextBlock Text="Spooler de impressao" Foreground="{DynamicResource BrushText}" FontWeight="SemiBold" Margin="0,0,0,4"/>
                            <TextBlock Text="Reinicia o servico de spooler e limpa a fila de impressao travada. Requer Administrador." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,10"/>
                            <Button x:Name="BtnSpooler" Content="Reiniciar Spooler de Impressao" Width="260" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushDanger}"/>
                        </StackPanel>
                    </Border>

                    <Grid Grid.Row="2" Margin="0,0,0,14">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Margin="0,0,5,0" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock Text="TOTAL" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold"/>
                                <TextBlock x:Name="TxtStatTotal" Text="0" Foreground="{DynamicResource BrushText}" FontSize="32" FontWeight="Bold" Margin="0,4,0,0"/>
                            </StackPanel>
                        </Border>
                        <Border Grid.Column="1" Margin="5,0" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock Text="ONLINE" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold"/>
                                <TextBlock x:Name="TxtStatOnline" Text="0" Foreground="{DynamicResource BrushAccent}" FontSize="32" FontWeight="Bold" Margin="0,4,0,0"/>
                            </StackPanel>
                        </Border>
                        <Border Grid.Column="2" Margin="5,0,0,0" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock Text="OFFLINE" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold"/>
                                <TextBlock x:Name="TxtStatOffline" Text="0" Foreground="{DynamicResource BrushDanger}" FontSize="32" FontWeight="Bold" Margin="0,4,0,0"/>
                            </StackPanel>
                        </Border>
                    </Grid>

                    <Grid Grid.Row="3" Margin="0,0,0,14">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBox Grid.Column="0" x:Name="TxtPesquisaImpressoras" Style="{StaticResource SearchBox}" Text="Pesquisar impressora..." Foreground="{DynamicResource BrushTextMuted}" Width="220" Margin="0,0,10,0"/>
                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                            <Button x:Name="BtnFiltroTodos"   Content="Todos"   Style="{StaticResource FilterChip}"/>
                            <Button x:Name="BtnFiltroOnline"  Content="Online"  Style="{StaticResource FilterChip}"/>
                            <Button x:Name="BtnFiltroOffline" Content="Offline" Style="{StaticResource FilterChip}"/>
                        </StackPanel>
                        <TextBlock Grid.Column="2" x:Name="TxtUltimaAtualizacao" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="0,0,14,0"/>
                        <StackPanel Grid.Column="3" Orientation="Horizontal">
                            <Button x:Name="BtnConfigServidor" Content="Configurar Servidor" Width="150" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" Margin="0,0,8,0"/>
                            <Button x:Name="BtnEscanear"       Content="Escanear Rede"       Width="130" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Margin="0,0,8,0"/>
                            <Button x:Name="BtnExportarCsv"    Content="Exportar CSV"        Width="120" Style="{StaticResource CardButton}" Background="{DynamicResource BrushSuccess}"/>
                        </StackPanel>
                    </Grid>

                    <DataGrid Grid.Row="4" x:Name="DgImpressoras" AutoGenerateColumns="False" IsReadOnly="True"
                              Background="{DynamicResource BrushSurface}" Foreground="{DynamicResource BrushText}" BorderThickness="1" BorderBrush="{DynamicResource BrushBorder}" HeadersVisibility="Column"
                              RowBackground="{DynamicResource BrushSurface}" AlternatingRowBackground="{DynamicResource BrushSurfaceAlt}" GridLinesVisibility="None" RowHeight="42">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="NOME" Binding="{Binding Nome}" Width="2*"/>
                            <DataGridTextColumn Header="IP" Binding="{Binding IP}" Width="1*"/>
                            <DataGridTextColumn Header="MODELO" Binding="{Binding Modelo}" Width="2*"/>
                            <DataGridTextColumn Header="TONER" Binding="{Binding Toner}" Width="1.3*"/>
                            <DataGridTextColumn Header="STATUS" Binding="{Binding Status}" Width="1*"/>
                            <DataGridTextColumn Header="PAGINAS" Binding="{Binding PageCount}" Width="1*"/>
                            <DataGridTextColumn Header="UPTIME" Binding="{Binding Uptime}" Width="1.3*"/>
                            <DataGridTemplateColumn Header="ACOES" Width="270">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="4,0">
                                            <Button Content="Detalhes" Tag="Detalhes" Style="{StaticResource RowActionButton}" ToolTip="Ver detalhes do equipamento"/>
                                            <Button Content="Web" Tag="Web" Style="{StaticResource RowActionButton}" ToolTip="Abrir pagina web da impressora"/>
                                            <Button Content="Teste" Tag="Teste" Style="{StaticResource RowActionButton}" ToolTip="Enviar pagina de teste"/>
                                            <Button Content="Driver" Tag="Driver" Style="{StaticResource RowActionButton}" ToolTip="Gerenciar driver"/>
                                        </StackPanel>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                            </DataGridTemplateColumn>
                        </DataGrid.Columns>
                    </DataGrid>
                </Grid>
'@

$script:XamlPanelsC = @'
                <!-- Logs -->
                <Grid x:Name="PanelLogs" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Logs" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,14"/>
                    <Border Grid.Row="1" Background="{DynamicResource BrushSurfaceAlt}" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" CornerRadius="8">
                        <TextBox x:Name="TxtLogs" Background="Transparent" Foreground="{DynamicResource BrushText}" FontFamily="Consolas" FontSize="12" Padding="10"
                                 BorderThickness="0" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
                    </Border>
                </Grid>
            </Grid>

            <Border Grid.Row="2" Background="{DynamicResource BrushStatusBarBg}" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="0,1,0,0">
                <TextBlock x:Name="TxtStatus" Text="Pronto." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" VerticalAlignment="Center" Margin="16,0"/>
            </Border>
        </Grid>
    </Grid>
</Window>
'@

$script:LoadingOverlayXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Escaneando" Height="140" Width="380"
        WindowStartupLocation="CenterOwner" WindowStyle="None" ResizeMode="NoResize"
        Background="{DynamicResource BrushSurface}">
    <Border BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" CornerRadius="10">
        <StackPanel Margin="20" VerticalAlignment="Center">
            <TextBlock x:Name="TxtLoadingStatus" Text="Escaneando impressoras..." Foreground="{DynamicResource BrushText}" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,12"/>
            <ProgressBar IsIndeterminate="True" Height="4" Background="{DynamicResource BrushSurfaceAlt}" Foreground="{DynamicResource BrushAccent}" BorderThickness="0"/>
        </StackPanel>
    </Border>
</Window>
'@

# ==============================================================================
# FERRAMENTAS - reparos do Windows, desinstalador seguro, cache de
# navegadores, limpeza avancada do sistema e rede avancada. Backend novo
# usado pela secao "Ferramentas" da UI.
# ==============================================================================

# ---- LIMPEZA (item novo: lixeira) ----
function Clear-RecycleBinContents {
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Log -Message "[CLEANUP] Lixeira esvaziada." -Level "SUCCESS"
    } catch { Write-Log -Message ("[CLEANUP] Falha ao esvaziar lixeira: {0}" -f $_.Exception.Message) -Level "WARN" }
}

# ---- REPAROS ----
function Invoke-SfcScan {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    Set-Status "Executando SFC /scannow - isso pode levar varios minutos..."
    $r = Invoke-ConsoleCommand "sfc /scannow" "[REPAIR] SFC /scannow" 1800
    Show-TextResultDialog -Title "Resultado - SFC /scannow" -Text $r.Output
}

function Invoke-DismRestoreHealth {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    Set-Status "Executando DISM RestoreHealth - isso pode levar varios minutos..."
    $r = Invoke-ConsoleCommand "DISM /Online /Cleanup-Image /RestoreHealth" "[REPAIR] DISM RestoreHealth" 1800
    Show-TextResultDialog -Title "Resultado - DISM RestoreHealth" -Text $r.Output
}

function Update-WingetApps {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    Update-Prerequisites
    if (-not $global:HasWinget) { Show-Warning "Winget nao esta instalado."; return }
    Set-Status "Atualizando aplicativos via winget..."
    $winget = Get-CommandPathSafe -Name "winget"
    $r = Invoke-ManagedProcess -FilePath $winget -Arguments @("upgrade","--all","--silent","--accept-package-agreements","--accept-source-agreements","--disable-interactivity") -Description "[REPAIR] winget upgrade --all" -TimeoutSeconds 1800
    Show-TextResultDialog -Title "Resultado - Atualizar Apps Winget" -Text $r.Output
}

# Ativa o plano de energia "Desempenho Maximo" (Ultimate Performance, oculto
# por padrao no Windows). Se a duplicacao falhar, cai para "Alto Desempenho"
# (plano padrao do Windows, sempre disponivel).
function Enable-MaxPerformancePowerPlan {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    $ultimateSourceGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
    $highPerfGuid       = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    try {
        $list = Invoke-ConsoleCommand "powercfg /list" "[REPAIR] powercfg /list" 20
        $existing = $null
        if ($list.Output -match "([0-9a-fA-F-]{36})\s+\(.*Desempenho M.ximo.*\)" -or $list.Output -match "([0-9a-fA-F-]{36})\s+\(.*Ultimate Performance.*\)") {
            $existing = $matches[1]
        }
        if (-not $existing) {
            $dup = Invoke-ConsoleCommand ("powercfg /duplicatescheme {0}" -f $ultimateSourceGuid) "[REPAIR] powercfg /duplicatescheme" 20
            if ($dup.Output -match "([0-9a-fA-F-]{36})") { $existing = $matches[1] }
        }
        $targetGuid = if ($existing) { $existing } else { $highPerfGuid }
        Invoke-ConsoleCommand ("powercfg /setactive {0}" -f $targetGuid) "[REPAIR] powercfg /setactive" 20 | Out-Null
        Write-Log -Message ("[REPAIR] Plano de energia ativado: {0}" -f $targetGuid) -Level "SUCCESS"
        Show-Info "Plano de energia de maximo desempenho ativado."
    } catch { Show-ErrorBox ("Falha ao ativar plano de energia.`n`n{0}" -f $_.Exception.Message) }
}

# ---- DESINSTALADOR SEGURO ----
# Le as chaves de Uninstall do registro (64-bit, 32-bit em SysWOW64 e por
# usuario) - o mesmo lugar de onde o Painel de Controle/Configuracoes tira a
# lista "Aplicativos e recursos".
function Get-InstalledProgramsList {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $result = New-Object System.Collections.ArrayList
    foreach ($p in $paths) {
        try {
            Get-ItemProperty -Path $p -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.DisplayName -and -not $_.SystemComponent -and ($_.UninstallString -or $_.QuietUninstallString)) {
                    [void]$result.Add([PSCustomObject]@{
                        Name        = [string]$_.DisplayName
                        Publisher   = [string]$_.Publisher
                        Version     = [string]$_.DisplayVersion
                        UninstallCmd = if ($_.QuietUninstallString) { [string]$_.QuietUninstallString } else { [string]$_.UninstallString }
                    })
                }
            }
        } catch {}
    }
    return @($result | Sort-Object Name -Unique)
}

function Invoke-SafeUninstall {
    param([Parameter(Mandatory=$true)]$Program)
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return $false }
    if (-not (Confirm-Action ("Desinstalar '{0}'?`n`nEssa acao abre o desinstalador oficial do programa e nao pode ser desfeita." -f $Program.Name) "Desinstalador Seguro")) { return $false }
    try {
        Set-Status ("Desinstalando {0}..." -f $Program.Name)
        Write-Log -Message ("[UNINSTALL] {0}: {1}" -f $Program.Name,$Program.UninstallCmd) -Level "INFO"
        $r = Invoke-ConsoleCommand $Program.UninstallCmd ("[UNINSTALL] {0}" -f $Program.Name) 600
        Write-Log -Message ("[UNINSTALL] {0} finalizado. ExitCode {1}" -f $Program.Name,$r.ExitCode) -Level "SUCCESS"
        Show-Info ("Desinstalacao de '{0}' finalizada. Se o desinstalador abriu uma janela propria, siga as instrucoes nela." -f $Program.Name)
        return $true
    } catch { Show-ErrorBox ("Falha ao desinstalar.`n`n{0}" -f $_.Exception.Message); return $false }
}

# ---- CONFIGURACOES DA FERRAMENTA ----
function Open-ToolDataFolder {
    try { Start-Process explorer.exe -ArgumentList $global:BasePath } catch { Show-Warning "Nao foi possivel abrir a pasta." }
}

function Open-PrintersFolder {
    try { Start-Process "control.exe" -ArgumentList "printers" } catch { Show-Warning "Nao foi possivel abrir a pasta de impressoras." }
}

# ---- CACHE DE NAVEGADORES ----
function Clear-BrowserCaches {
    param([string[]]$Browsers)
    $limpos = @()
    if ($Browsers -contains "Chrome") {
        $p = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data\Default\Cache"
        if (Test-Path $p) { Get-ChildItem $p -Force -Recurse -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue; $limpos += "Chrome" }
    }
    if ($Browsers -contains "Edge") {
        $p = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data\Default\Cache"
        if (Test-Path $p) { Get-ChildItem $p -Force -Recurse -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue; $limpos += "Edge" }
    }
    if ($Browsers -contains "Firefox") {
        $root = Join-Path $env:LOCALAPPDATA "Mozilla\Firefox\Profiles"
        if (Test-Path $root) {
            Get-ChildItem $root -Directory -Filter "*.default*" -EA SilentlyContinue | ForEach-Object {
                $cache2 = Join-Path $_.FullName "cache2"
                if (Test-Path $cache2) { Get-ChildItem $cache2 -Force -Recurse -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue }
            }
            $limpos += "Firefox"
        }
    }
    Write-Log -Message ("[CLEANUP] Cache de navegadores limpo: {0}" -f ($limpos -join ", ")) -Level "SUCCESS"
    Show-Info ("Cache limpo para: {0}.`n`nFeche o navegador antes de limpar para melhores resultados (arquivos em uso sao ignorados)." -f ($(if($limpos.Count -gt 0){$limpos -join ", "}else{"nenhum navegador encontrado"})))
}

# ---- LIMPEZA DO SISTEMA (avancada) ----
function Clear-PrefetchCache {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    $p = Join-Path $env:WINDIR "Prefetch"
    if (Test-Path $p) { Get-ChildItem $p -Force -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue }
    Write-Log -Message "[CLEANUP] Cache de Prefetch limpo." -Level "SUCCESS"
    Show-Info "Cache de Prefetch limpo."
}

function Clear-FontCacheData {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    try {
        Stop-Service -Name "FontCache" -Force -EA SilentlyContinue
        Start-Sleep -Seconds 1
        $p1 = Join-Path $env:WINDIR "ServiceProfiles\LocalService\AppData\Local\FontCache"
        if (Test-Path $p1) { Get-ChildItem $p1 -Force -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue }
        $p2 = Join-Path $env:WINDIR "System32\FNTCACHE.DAT"
        if (Test-Path $p2) { Remove-Item $p2 -Force -EA SilentlyContinue }
        Start-Service -Name "FontCache" -EA SilentlyContinue
        Write-Log -Message "[CLEANUP] Cache de fontes limpo e servico reiniciado." -Level "SUCCESS"
        Show-Info "Cache de fontes limpo."
    } catch { Show-ErrorBox ("Falha ao limpar cache de fontes.`n`n{0}" -f $_.Exception.Message) }
}

function Get-ShadowCopiesInfo {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return "" }
    $r = Invoke-ConsoleCommand "vssadmin list shadows" "[REPAIR] vssadmin list shadows" 30
    return $r.Output
}

function Invoke-DismComponentCleanup {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    Set-Status "Executando limpeza de componentes WinSxS - isso pode levar varios minutos..."
    $r = Invoke-ConsoleCommand "DISM /Online /Cleanup-Image /StartComponentCleanup" "[REPAIR] DISM StartComponentCleanup" 1800
    Show-TextResultDialog -Title "Resultado - WinSxS / DISM Cleanup" -Text $r.Output
}

# ---- REDE AVANCADA ----
function Get-WifiProfilesInfo {
    $r = Invoke-ConsoleCommand "netsh wlan show profiles" "[NETWORK] Perfis Wi-Fi" 20
    return $r.Output
}

function Get-NetworkConnectionsInfo {
    $r = Invoke-ConsoleCommand "netstat -ano" "[NETWORK] Conexoes/Portas" 30
    return $r.Output
}

function Get-MappedDrivesInfo {
    $r = Invoke-ConsoleCommand "net use" "[NETWORK] Unidades mapeadas" 20
    return $r.Output
}

function Add-MappedNetworkDrive {
    param([string]$Letra,[string]$Caminho,[bool]$Persistente)
    if ([string]::IsNullOrWhiteSpace($Letra) -or [string]::IsNullOrWhiteSpace($Caminho)) {
        Show-Warning "Informe a letra da unidade e o caminho de rede."; return $false
    }
    $letraLimpa = ($Letra.Trim().TrimEnd(':') + ":")
    $persistFlag = if ($Persistente) { "yes" } else { "no" }
    $cmd = "net use $letraLimpa `"$Caminho`" /persistent:$persistFlag"
    $r = Invoke-ConsoleCommand $cmd "[NETWORK] Mapear unidade de rede" 30
    if ($r.ExitCode -eq 0) {
        Write-Log -Message ("[NETWORK] Unidade {0} mapeada para {1}." -f $letraLimpa,$Caminho) -Level "SUCCESS"
        Show-Info ("Unidade {0} mapeada com sucesso para {1}." -f $letraLimpa,$Caminho)
        return $true
    } else {
        Show-Warning ("Falha ao mapear unidade.`n`n{0}" -f $r.Output)
        return $false
    }
}

# ==============================================================================
# DIALOGOS DE APOIO - resultado de texto (SFC/DISM/netstat/etc.), desinstalador
# seguro e mapeamento de unidade de rede. Sao janelas separadas (proprio
# XamlReader.Load), entao NAO enxergam os Styles de Window.Resources da janela
# principal - por isso os botoes aqui usam atributos diretos (Background/
# Foreground via DynamicResource) em vez de StaticResource.
# ==============================================================================
$script:TextResultDialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Resultado" Height="480" Width="680"
        WindowStartupLocation="CenterOwner"
        Background="{DynamicResource BrushSurface}">
    <Grid Margin="20">
        <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Border Grid.Row="0" Background="{DynamicResource BrushSurfaceAlt}" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" CornerRadius="6">
            <TextBox x:Name="TxtResultado" Background="Transparent" Foreground="{DynamicResource BrushText}" FontFamily="Consolas" FontSize="12" Padding="10"
                     BorderThickness="0" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
        </Border>
        <Button Grid.Row="1" x:Name="BtnFecharResultado" Content="Fechar" Width="100" Height="34" HorizontalAlignment="Right" Margin="0,14,0,0"
                Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0"/>
    </Grid>
</Window>
'@

function Show-TextResultDialog {
    param([string]$Title="Resultado",[string]$Text="")
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:TextResultDialogXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Title = $Title
    $dlg.Owner = $global:MainWindow
    Set-DialogTheme -Dialog $dlg
    $dlg.FindName("TxtResultado").Text = if ([string]::IsNullOrWhiteSpace($Text)) { "(sem saida)" } else { $Text }
    $dlg.FindName("BtnFecharResultado").Add_Click({ $dlg.Close() }.GetNewClosure())
    [void]$dlg.ShowDialog()
}

$script:UninstallerDialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Desinstalador Seguro" Height="560" Width="680"
        WindowStartupLocation="CenterOwner"
        Background="{DynamicResource BrushSurface}">
    <Window.Resources>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="{DynamicResource BrushSurfaceAlt}"/>
            <Setter Property="Foreground" Value="{DynamicResource BrushTextMuted}"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>
    </Window.Resources>
    <Grid Margin="20">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <TextBox Grid.Row="0" x:Name="TxtFiltroPrograma" Height="34" Padding="10,0" Margin="0,0,0,10"
                 Background="{DynamicResource BrushInputBg}" Foreground="{DynamicResource BrushTextMuted}" BorderBrush="{DynamicResource BrushInputBorder}"
                 Text="Pesquisar programa instalado..." VerticalContentAlignment="Center"/>
        <DataGrid Grid.Row="1" x:Name="DgProgramas" AutoGenerateColumns="False" IsReadOnly="True"
                  Background="{DynamicResource BrushSurface}" Foreground="{DynamicResource BrushText}" BorderThickness="1" BorderBrush="{DynamicResource BrushBorder}"
                  HeadersVisibility="Column" RowBackground="{DynamicResource BrushSurface}" AlternatingRowBackground="{DynamicResource BrushSurfaceAlt}"
                  GridLinesVisibility="None" RowHeight="38">
            <DataGrid.Columns>
                <DataGridTextColumn Header="NOME" Binding="{Binding Name}" Width="2.4*"/>
                <DataGridTextColumn Header="EDITOR" Binding="{Binding Publisher}" Width="1.6*"/>
                <DataGridTextColumn Header="VERSAO" Binding="{Binding Version}" Width="1*"/>
                <DataGridTemplateColumn Header="ACAO" Width="110">
                    <DataGridTemplateColumn.CellTemplate>
                        <DataTemplate>
                            <Button Content="Desinstalar" Tag="Desinstalar" Width="94" Height="26" FontSize="11"
                                    Background="{DynamicResource BrushDanger}" Foreground="White" BorderThickness="0" Cursor="Hand"/>
                        </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
            </DataGrid.Columns>
        </DataGrid>
        <Button Grid.Row="2" x:Name="BtnFecharUninstaller" Content="Fechar" Width="100" Height="34" HorizontalAlignment="Right" Margin="0,14,0,0"
                Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0"/>
    </Grid>
</Window>
'@

function Show-UninstallerDialog {
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:UninstallerDialogXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow
    Set-DialogTheme -Dialog $dlg

    Set-Status "Lendo programas instalados..."
    $todosOsProgramas = @(Get-InstalledProgramsList)
    Set-Status ("{0} programa(s) encontrado(s)." -f $todosOsProgramas.Count) "SUCCESS"

    $dg = $dlg.FindName("DgProgramas")
    $dg.ItemsSource = $todosOsProgramas

    $txtFiltro = $dlg.FindName("TxtFiltroPrograma")
    $txtFiltro.Add_GotFocus({ if ($txtFiltro.Text -eq "Pesquisar programa instalado...") { $txtFiltro.Text = "" } }.GetNewClosure())
    $txtFiltro.Add_LostFocus({ if ([string]::IsNullOrWhiteSpace($txtFiltro.Text)) { $txtFiltro.Text = "Pesquisar programa instalado..." } }.GetNewClosure())
    $txtFiltro.Add_TextChanged({
        $texto = $txtFiltro.Text.Trim()
        if ($texto -eq "Pesquisar programa instalado...") { $texto = "" }
        if ($texto -eq "") { $dg.ItemsSource = $todosOsProgramas; return }
        $dg.ItemsSource = @($todosOsProgramas | Where-Object { $_.Name -match [regex]::Escape($texto) })
    }.GetNewClosure())

    $dg.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($senderObj,$e)
        $btn = $e.OriginalSource
        if ($btn -isnot [System.Windows.Controls.Button]) { return }
        $programa = $btn.DataContext
        if ($null -eq $programa) { return }
        $ok = Invoke-SafeUninstall -Program $programa
        if ($ok) {
            $todosOsProgramas = @(Get-InstalledProgramsList)
            $dg.ItemsSource = $todosOsProgramas
        }
    }.GetNewClosure())

    $dlg.FindName("BtnFecharUninstaller").Add_Click({ $dlg.Close() }.GetNewClosure())
    [void]$dlg.ShowDialog()
}

$script:MapDriveDialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Mapear Unidade de Rede" Height="320" Width="440"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="{DynamicResource BrushSurface}">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Letra da unidade (ex: Z):" Foreground="{DynamicResource BrushTextMuted}" Margin="0,0,0,4"/>
        <TextBox Grid.Row="1" x:Name="TxtLetraUnidade" Height="30" Width="80" HorizontalAlignment="Left" Padding="6,4"
                 Background="{DynamicResource BrushInputBg}" Foreground="{DynamicResource BrushText}" BorderBrush="{DynamicResource BrushInputBorder}"/>
        <TextBlock Grid.Row="2" Text="Caminho de rede (ex: \\servidor\pasta):" Foreground="{DynamicResource BrushTextMuted}" Margin="0,14,0,4"/>
        <TextBox Grid.Row="3" x:Name="TxtCaminhoRede" Height="30" Padding="6,4"
                 Background="{DynamicResource BrushInputBg}" Foreground="{DynamicResource BrushText}" BorderBrush="{DynamicResource BrushInputBorder}"/>
        <CheckBox Grid.Row="4" x:Name="ChkPersistente" Content="Reconectar automaticamente no login" Foreground="{DynamicResource BrushText}" IsChecked="True" Margin="0,14,0,0"/>
        <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnCancelarMapa" Content="Cancelar" Width="100" Height="34" Margin="0,0,10,0" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0"/>
            <Button x:Name="BtnConectarMapa" Content="Conectar" Width="120" Height="34" Background="{DynamicResource BrushSuccess}" Foreground="White" BorderThickness="0" FontWeight="Bold"/>
        </StackPanel>
    </Grid>
</Window>
'@

function Show-MapNetworkDriveDialog {
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:MapDriveDialogXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow
    Set-DialogTheme -Dialog $dlg

    $txtLetra    = $dlg.FindName("TxtLetraUnidade")
    $txtCaminho  = $dlg.FindName("TxtCaminhoRede")
    $chkPersist  = $dlg.FindName("ChkPersistente")

    $dlg.FindName("BtnConectarMapa").Add_Click({
        $ok = Add-MappedNetworkDrive -Letra $txtLetra.Text -Caminho $txtCaminho.Text -Persistente $chkPersist.IsChecked
        if ($ok) { $dlg.Close() }
    }.GetNewClosure())
    $dlg.FindName("BtnCancelarMapa").Add_Click({ $dlg.Close() }.GetNewClosure())
    [void]$dlg.ShowDialog()
}

$script:XamlPanelsD = @'
                <!-- Ferramentas -->
                <Grid x:Name="PanelFerramentas" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Ferramentas" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,4"/>
                    <TextBlock Grid.Row="1" Text="Limpeza, reparos, rede, impressao e configuracoes da ferramenta." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,14"/>
                    <ScrollViewer Grid.Row="2">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <!-- LIMPEZA -->
                            <Border Grid.Row="0" Grid.Column="0" Margin="0,0,5,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="LIMPEZA" Foreground="{DynamicResource BrushAccent}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <CheckBox x:Name="ChkLimpTemp" Content="Temporarios do usuario" IsChecked="True"/>
                                    <CheckBox x:Name="ChkLimpWinTemp" Content="C:\Windows\Temp"/>
                                    <CheckBox x:Name="ChkLimpLixeira" Content="Esvaziar Lixeira"/>
                                    <CheckBox x:Name="ChkLimpWU" Content="Cache do Windows Update"/>
                                    <CheckBox x:Name="ChkLimpGeo" Content="Cache de geolocalizacao + lfsvc"/>
                                    <Button x:Name="BtnExecutarLimpeza" Content="Executar Limpeza" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Margin="0,10,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- REPAROS -->
                            <Border Grid.Row="0" Grid.Column="1" Margin="5,0,0,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="REPAROS" Foreground="{DynamicResource BrushWarning}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <UniformGrid Columns="2">
                                        <Button x:Name="BtnSfcScan" Content="SFC /scannow" Height="38" Margin="0,0,6,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnDismRestore" Content="DISM RestoreHealth" Height="38" Margin="6,0,0,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnWingetUpgrade" Content="Atualizar Apps Winget" Height="38" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushSuccess}"/>
                                        <Button x:Name="BtnUninstaller" Content="Desinstalador Seguro" Height="38" Margin="6,0,0,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushDanger}"/>
                                    </UniformGrid>
                                    <Button x:Name="BtnMaxPerformance" Content="Habilitar Maximo Desempenho" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Margin="0,8,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- REDE -->
                            <Border Grid.Row="1" Grid.Column="0" Margin="0,0,5,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="REDE" Foreground="{DynamicResource BrushAccent}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <UniformGrid Columns="3">
                                        <Button x:Name="BtnFerrFlushDns" Content="Flush DNS" Height="36" Margin="0,0,6,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnFerrRenewIp" Content="Renew IP" Height="36" Margin="0,0,6,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnFerrWinsock" Content="Reset Winsock" Height="36" Margin="0,0,0,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnFerrPing" Content="Ping Google" Height="36" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnFerrDns" Content="Teste DNS" Height="36" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                    </UniformGrid>
                                </StackPanel>
                            </Border>

                            <!-- IMPRESSAO -->
                            <Border Grid.Row="1" Grid.Column="1" Margin="5,0,0,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="IMPRESSAO" Foreground="{DynamicResource BrushAccent}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnFerrSpooler" Content="Reiniciar Spooler e Limpar Fila" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Margin="0,0,0,8"/>
                                    <Button x:Name="BtnAbrirImpressoras" Content="Abrir Impressoras" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                </StackPanel>
                            </Border>

                            <!-- CONFIGURACOES -->
                            <Border Grid.Row="2" Grid.Column="0" Margin="0,0,5,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="CONFIGURACOES" Foreground="{DynamicResource BrushTextMuted}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnResetAppsJson" Content="Apagar JSON e Recriar Lista Padrao" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushDanger}" Margin="0,0,0,8"/>
                                    <Button x:Name="BtnAbrirPastaFerramenta" Content="Abrir Pasta da Ferramenta" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                </StackPanel>
                            </Border>

                            <!-- IA DO WINDOWS -->
                            <Border Grid.Row="2" Grid.Column="1" Margin="5,0,0,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="IA DO WINDOWS" Foreground="{DynamicResource BrushWarning}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnFerrRemoveAI" Content="Remove IA do Windows" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushWarning}" Margin="0,0,0,10"/>
                                    <TextBlock Text="Libera memoria RAM!" Foreground="{DynamicResource BrushSuccess}" FontSize="11" FontWeight="SemiBold"/>
                                    <TextBlock Text="NAO selecione as opcoes com Triangulo Amarelo!" Foreground="{DynamicResource BrushDanger}" FontSize="11" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- CACHE DE NAVEGADORES -->
                            <Border Grid.Row="3" Grid.Column="0" Margin="0,0,5,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="CACHE DE NAVEGADORES" Foreground="{DynamicResource BrushSuccess}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <CheckBox x:Name="ChkCacheChrome" Content="Google Chrome" IsChecked="True"/>
                                    <CheckBox x:Name="ChkCacheEdge" Content="Microsoft Edge" IsChecked="True"/>
                                    <CheckBox x:Name="ChkCacheFirefox" Content="Mozilla Firefox" IsChecked="True"/>
                                    <Button x:Name="BtnLimparCacheNavegadores" Content="Limpar Cache dos Navegadores" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Margin="0,10,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- LIMPEZA DO SISTEMA -->
                            <Border Grid.Row="3" Grid.Column="1" Margin="5,0,0,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="LIMPEZA DO SISTEMA" Foreground="{DynamicResource BrushAccent}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <UniformGrid Columns="2">
                                        <Button x:Name="BtnLimparPrefetch" Content="Limpar Prefetch" Height="36" Margin="0,0,6,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnLimparFontCache" Content="Limpar Cache de Fontes" Height="36" Margin="6,0,0,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnVerShadowCopies" Content="Ver Shadow Copies" Height="36" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnWinSxSCleanup" Content="WinSxS / DISM Cleanup" Height="36" Margin="6,0,0,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushWarning}"/>
                                    </UniformGrid>
                                    <Button x:Name="BtnLimparCacheDns" Content="Limpar Cache DNS" Height="36" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" Margin="0,8,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- REDE AVANCADA -->
                            <Border Grid.Row="4" Grid.Column="0" Grid.ColumnSpan="2" Margin="0,0,0,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="REDE AVANCADA" Foreground="{DynamicResource BrushAccent}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <UniformGrid Columns="4">
                                        <Button x:Name="BtnWifiPerfis" Content="Perfis Wi-Fi" Height="38" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                                        <Button x:Name="BtnConexoesPortas" Content="Conexoes / Portas" Height="38" Margin="6,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                                        <Button x:Name="BtnMapearUnidade" Content="Mapear Unidade de Rede" Height="38" Margin="6,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushSuccess}"/>
                                        <Button x:Name="BtnVerUnidadesMapeadas" Content="Ver Unidades Mapeadas" Height="38" Margin="6,0,0,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                    </UniformGrid>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                </Grid>
'@

function Show-MainWindow {
    $script:MainWindowXaml = $script:XamlHead + $script:XamlPanelsA + $script:XamlPanelsB + $script:XamlPanelsD + $script:XamlPanelsC
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:MainWindowXaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    $global:MainWindow = $window
    $window.Title = "{0} v{1}" -f $global:AppName,$global:AppVersion

    $prefs = Get-UiPrefs
    Set-AppTheme -Theme $prefs.Theme

    if (Test-Path $global:IconFile) {
        try { $window.Icon = New-Object System.Windows.Media.Imaging.BitmapImage([uri]$global:IconFile) } catch {}
    }
    if (Test-Path $global:LogoFile) {
        try {
            $imgLogo = $window.FindName("LogoElgin")
            $imgLogo.Source = New-Object System.Windows.Media.Imaging.BitmapImage([uri]$global:LogoFile)
            $imgLogo.Visibility = "Visible"
        } catch {}
    }

    $window.FindName("TxtVersaoSidebar").Text = "v{0}" -f $global:AppVersion
    $global:StatusLabel     = $window.FindName("TxtStatus")
    $global:LogTextBox      = $window.FindName("TxtLogs")
    $global:BellBadgeLabel  = $window.FindName("TxtBadgeErros")
    $global:BellBadgeBorder = $window.FindName("BorderBadgeErros")
    $txtTitulo = $window.FindName("TxtTituloSecao")

    $panels = @{
        Inicio    = $window.FindName("PanelInicio")
        Checklist = $window.FindName("PanelChecklist")
        Instalar  = $window.FindName("PanelInstalar")
        Extra     = $window.FindName("PanelExtra")
        Limpeza   = $window.FindName("PanelLimpeza")
        Rede      = $window.FindName("PanelRede")
        Impressao = $window.FindName("PanelImpressao")
        Ferramentas = $window.FindName("PanelFerramentas")
        Logs      = $window.FindName("PanelLogs")
    }
    $navButtons = @{
        Inicio    = $window.FindName("NavInicio")
        Checklist = $window.FindName("NavChecklist")
        Instalar  = $window.FindName("NavInstalar")
        Extra     = $window.FindName("NavExtra")
        Limpeza   = $window.FindName("NavLimpeza")
        Rede      = $window.FindName("NavRede")
        Impressao = $window.FindName("NavImpressao")
        Ferramentas = $window.FindName("NavFerramentas")
        Logs      = $window.FindName("NavLogs")
    }
    $panelTitles = @{
        Inicio="Inicio"; Checklist="Checklist"; Instalar="Instalar Aplicativos"; Extra="Pacote Extra"; Limpeza="Limpeza"
        Rede="Ferramentas de Rede"; Impressao="Impressao"; Ferramentas="Ferramentas"; Logs="Logs"
    }
    # Scriptblock (nao function aninhada) - funcoes definidas dentro de outra
    # funcao nao ficam visiveis de dentro de closures de eventos WPF (Add_Click),
    # mas um scriptblock capturado via GetNewClosure() funciona corretamente.
    $ShowSection = {
        param([string]$Key)
        foreach ($k in $panels.Keys) {
            $panels[$k].Visibility = if ($k -eq $Key) { "Visible" } else { "Collapsed" }
            $navButtons[$k].Background = if ($k -eq $Key) { Get-ThemeBrush "BrushActiveNav" } else { Get-Brush "Transparent" }
            $navButtons[$k].Foreground = if ($k -eq $Key) { Get-ThemeBrush "BrushText" } else { Get-ThemeBrush "BrushTextMuted" }
            $navButtons[$k].Tag = if ($k -eq $Key) { "3,0,0,0" } else { "0" }
        }
        $global:CurrentSection = $Key
        $txtTitulo.Text = $panelTitles[$Key]
    }.GetNewClosure()
    $global:ShowSectionRef = $ShowSection

    foreach ($key in $navButtons.Keys) {
        $navButtons[$key].Add_Click({ & $ShowSection -Key $key }.GetNewClosure())
    }

    # ---- Inicio (dashboard com atalhos) ----
    $window.FindName("TxtBemVindo").Text = "Ola, {0}" -f $env:USERNAME
    $window.FindName("TxtSubtituloInicio").Text = "Maquina: {0}" -f $env:COMPUTERNAME
    $txtHomeAdmin   = $window.FindName("TxtHomeAdmin")
    $txtHomeInternet = $window.FindName("TxtHomeInternet")
    $txtHomeWinget  = $window.FindName("TxtHomeWinget")
    $txtHomeChoco   = $window.FindName("TxtHomeChoco")

    $gridAtalhos = $window.FindName("GridAtalhos")
    $homeShortcuts = @(
        @{ Key="Checklist"; Title="Checklist";             Desc="Formatacao e configuracao passo a passo" }
        @{ Key="Instalar";  Title="Instalar Aplicativos";  Desc="Lista padrao via winget/choco + busca de software" }
        @{ Key="Extra";     Title="Pacote Extra";          Desc="Instaladores diretos (Bitdefender, FortiClient, etc.)" }
        @{ Key="Limpeza";   Title="Limpeza";                Desc="Temporarios, Windows Update, geolocalizacao, IA do Windows" }
        @{ Key="Rede";      Title="Rede";                   Desc="Flush DNS, renovar IP, reset winsock, testes de conectividade" }
        @{ Key="Impressao"; Title="Impressao";              Desc="Spooler, monitor SNMP e gerenciamento de impressoras" }
        @{ Key="Ferramentas"; Title="Ferramentas";          Desc="Reparos, desinstalador seguro, cache e rede avancada" }
        @{ Key="Logs";      Title="Logs";                   Desc="Historico de acoes e erros da ferramenta" }
    )
    foreach ($shortcut in $homeShortcuts) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $window.FindResource("ShortcutCardButton")
        $sp = New-Object System.Windows.Controls.StackPanel
        $tTitle = New-Object System.Windows.Controls.TextBlock
        $tTitle.Text = $shortcut.Title
        $tTitle.FontSize = 15; $tTitle.FontWeight = "Bold"
        $tTitle.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "BrushText")
        $tDesc = New-Object System.Windows.Controls.TextBlock
        $tDesc.Text = $shortcut.Desc
        $tDesc.FontSize = 11
        $tDesc.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "BrushTextMuted")
        $tDesc.TextWrapping = "Wrap"; $tDesc.Margin = "0,4,0,0"
        [void]$sp.Children.Add($tTitle)
        [void]$sp.Children.Add($tDesc)
        $btn.Content = $sp
        $key = $shortcut.Key
        $btn.Add_Click({ & $ShowSection -Key $key }.GetNewClosure())
        [void]$gridAtalhos.Children.Add($btn)
    }

    # ---- Barra superior: badge admin, CPU/RAM/Disco, tema, sino de logs ----
    $borderAdminBadge = $window.FindName("BorderAdminBadge")
    $txtAdminBadge    = $window.FindName("TxtAdminBadge")
    $tbCpu  = $window.FindName("TbCpu")
    $tbRam  = $window.FindName("TbRam")
    $tbDisk = $window.FindName("TbDisk")

    $global:BtnTemaToggle = $window.FindName("BtnTemaToggle")
    $global:BtnTemaToggle.Content = if ($global:CurrentTheme -eq "Dark") { "Tema: Escuro" } else { "Tema: Claro" }
    $global:BtnTemaToggle.Add_Click({
        $novoTema = if ($global:CurrentTheme -eq "Dark") { "Light" } else { "Dark" }
        Set-AppTheme -Theme $novoTema
    }.GetNewClosure())

    $window.FindName("BtnSino").Add_Click({ & $ShowSection -Key "Logs" }.GetNewClosure())

    $statsTimer = New-Object System.Windows.Threading.DispatcherTimer
    $statsTimer.Interval = [TimeSpan]::FromSeconds(4)
    $statsTimer.Add_Tick({
        $snap = Get-SystemStatsSnapshot
        $tbCpu.Text  = "CPU " + $snap.Cpu
        $tbRam.Text  = "RAM " + $snap.Ram
        $tbDisk.Text = $snap.Disk
    }.GetNewClosure())

    # ---- Checklist (Formatacao/Configuracao) ----
    $spChecklistLeft       = $window.FindName("SpChecklistLeft")
    $spChecklistRight      = $window.FindName("SpChecklistRight")
    $txtChecklistProgresso = $window.FindName("TxtChecklistProgresso")
    $global:ChecklistState = Get-ChecklistState
    $global:ChecklistCheckboxes = @()

    $UpdateChecklistProgress = {
        $total = $global:ChecklistCheckboxes.Count
        $done  = @($global:ChecklistCheckboxes | Where-Object { $_.IsChecked }).Count
        $txtChecklistProgresso.Text = "{0} de {1} concluidos" -f $done,$total
    }.GetNewClosure()

    # So 2 niveis (item + sub-itens) - construido com dois loops simples em vez
    # de recursao, pra evitar o problema classico de scriptblock recursivo com
    # GetNewClosure() (a closure capturaria a propria variavel antes dela
    # existir).
    $BuildChecklistColumn = {
        param($Parent,[object[]]$Items)
        foreach ($item in $Items) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $item.Text
            $cb.Tag = [string]$item.Id
            $cb.Margin = "0,0,0,8"
            $temChildren = (@($item.Children).Count -gt 0)
            if ($temChildren) { $cb.FontWeight = "Bold"; $cb.Foreground = Get-ThemeBrush "BrushAccent" }
            if ($global:ChecklistState.ContainsKey([string]$item.Id)) { $cb.IsChecked = [bool]$global:ChecklistState[[string]$item.Id] }
            $cb.Add_Click({
                $global:ChecklistState[[string]$cb.Tag] = [bool]$cb.IsChecked
                Save-ChecklistState -State $global:ChecklistState
                & $UpdateChecklistProgress
            }.GetNewClosure())
            [void]$Parent.Children.Add($cb)
            $global:ChecklistCheckboxes += $cb
            foreach ($child in @($item.Children)) {
                $ccb = New-Object System.Windows.Controls.CheckBox
                $ccb.Content = $child.Text
                $ccb.Tag = [string]$child.Id
                $ccb.Margin = "26,0,0,8"
                if ($global:ChecklistState.ContainsKey([string]$child.Id)) { $ccb.IsChecked = [bool]$global:ChecklistState[[string]$child.Id] }
                $ccb.Add_Click({
                    $global:ChecklistState[[string]$ccb.Tag] = [bool]$ccb.IsChecked
                    Save-ChecklistState -State $global:ChecklistState
                    & $UpdateChecklistProgress
                }.GetNewClosure())
                [void]$Parent.Children.Add($ccb)
                $global:ChecklistCheckboxes += $ccb
            }
        }
    }.GetNewClosure()

    $checklistDef = @(Get-ChecklistDefinition)
    & $BuildChecklistColumn -Parent $spChecklistLeft  -Items @($checklistDef[0..5])
    & $BuildChecklistColumn -Parent $spChecklistRight -Items @($checklistDef[6..7])
    & $UpdateChecklistProgress

    $window.FindName("BtnResetarChecklist").Add_Click({
        if (-not (Confirm-Action "Isso vai desmarcar todos os itens do checklist. Deseja continuar?" "Resetar Checklist")) { return }
        $global:ChecklistState = @{}
        Save-ChecklistState -State $global:ChecklistState
        foreach ($cb in $global:ChecklistCheckboxes) { $cb.IsChecked = $false }
        & $UpdateChecklistProgress
    }.GetNewClosure())

    # ---- Instalar Aplicativos ----
    $txtWingetStatus   = $window.FindName("TxtWingetStatus")
    $txtChocoStatus    = $window.FindName("TxtChocoStatus")
    $RefreshPkgMgrStatus = {
        Update-Prerequisites
        if ($global:HasWinget) {
            $ver = Get-WingetVersion
            $txtWingetStatus.Text = if ($ver) { "Winget: instalado ($ver)" } else { "Winget: instalado" }
        } else { $txtWingetStatus.Text = "Winget: nao instalado" }
        $txtChocoStatus.Text = if ($global:HasChoco) { "Chocolatey: instalado" } else { "Chocolatey: nao instalado" }
    }.GetNewClosure()
    $window.FindName("BtnInstalarWinget").Add_Click({ Install-WingetPackageManager; & $RefreshPkgMgrStatus }.GetNewClosure())
    $window.FindName("BtnRepararWinget").Add_Click({
        $r = Repair-Winget
        if ($r.Missing) { Show-Warning "Winget nao esta instalado. Use 'Instalar Winget' primeiro." }
        elseif ($r.Ok) { Show-Info "Winget reparado com sucesso." }
        else { Show-Warning "Nao foi possivel reparar o winget automaticamente. Verifique os Logs." }
        & $RefreshPkgMgrStatus
    }.GetNewClosure())
    $window.FindName("BtnInstalarChoco").Add_Click({ Install-ChocolateyPackageManager; & $RefreshPkgMgrStatus }.GetNewClosure())

    $spApps = $window.FindName("SpAppsList")
    $appCheckboxes = @()
    foreach ($app in $global:AppsList) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $app.Name
        $cb.Tag = $app
        [void]$spApps.Children.Add($cb)
        $appCheckboxes += $cb
    }
    $txtFiltroApps = $window.FindName("TxtFiltroApps")
    $txtFiltroApps.Add_GotFocus({ if ($txtFiltroApps.Text -eq "Pesquisar na lista padrao...") { $txtFiltroApps.Text = "" } }.GetNewClosure())
    $txtFiltroApps.Add_LostFocus({ if ([string]::IsNullOrWhiteSpace($txtFiltroApps.Text)) { $txtFiltroApps.Text = "Pesquisar na lista padrao..." } }.GetNewClosure())
    $txtFiltroApps.Add_TextChanged({
        $texto = $txtFiltroApps.Text.Trim()
        if ($texto -eq "Pesquisar na lista padrao...") { $texto = "" }
        foreach ($cb in $appCheckboxes) {
            $cb.Visibility = if ($texto -eq "" -or $cb.Content -match [regex]::Escape($texto)) { "Visible" } else { "Collapsed" }
        }
    }.GetNewClosure())

    $window.FindName("BtnInstalarSelecionados").Add_Click({
        if (-not $global:IsAdmin) { Show-Warning "Instalacao requer Administrador. Reabra a ferramenta como Admin."; return }
        $selecionados = @($appCheckboxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if ($selecionados.Count -eq 0) { Show-Warning "Selecione ao menos um aplicativo."; return }
        $results = @{}
        foreach ($app in $selecionados) { $results[$app.Name] = Install-OnlineApp -App $app }
        $path = Export-InstallReport -Results $results -Section "Instalacao"
        Show-Info ("Instalacao concluida. Relatorio salvo em:`n{0}" -f $path)
    }.GetNewClosure())

    $txtBuscaOnline    = $window.FindName("TxtBuscaOnline")
    $spBuscaResultados = $window.FindName("SpBuscaResultados")
    $btnInstalarBusca  = $window.FindName("BtnInstalarBusca")
    $global:BuscaCheckboxes = @()
    $window.FindName("BtnBuscarOnline").Add_Click({
        $q = $txtBuscaOnline.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($q)) { Show-Warning "Digite um termo de busca."; return }
        Set-Status ("Buscando '{0}'..." -f $q)
        $rows = Search-SoftwarePackages -Query $q
        $spBuscaResultados.Children.Clear()
        $global:BuscaCheckboxes = @()
        if (@($rows).Count -eq 0) {
            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = "Nenhum resultado encontrado."
            $lbl.Foreground = Get-ThemeBrush "BrushTextMuted"
            [void]$spBuscaResultados.Children.Add($lbl)
            $btnInstalarBusca.Visibility = "Collapsed"
        } else {
            foreach ($row in $rows) {
                $cb = New-Object System.Windows.Controls.CheckBox
                $cb.Content = ("{0}  [{1}: {2}]" -f $row.Name,$row.Source,$row.Id)
                $cb.Tag = $row
                [void]$spBuscaResultados.Children.Add($cb)
                $global:BuscaCheckboxes += $cb
            }
            $btnInstalarBusca.Visibility = "Visible"
        }
        Set-Status ("Busca concluida: {0} resultado(s)." -f @($rows).Count) "SUCCESS"
    }.GetNewClosure())
    $btnInstalarBusca.Add_Click({
        if (-not $global:IsAdmin) { Show-Warning "Instalacao requer Administrador."; return }
        $selecionados = @($global:BuscaCheckboxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if ($selecionados.Count -eq 0) { Show-Warning "Selecione ao menos um item da busca."; return }
        $results = @{}
        foreach ($row in $selecionados) {
            $appObj = [PSCustomObject]@{
                Name = $row.Name
                Winget = if ($row.Source -eq "Winget") { $row.Id } else { "" }
                Choco = if ($row.Source -eq "Chocolatey") { $row.Id } else { "" }
                Scope = ""; TimeoutSeconds = 1800
            }
            $results[$row.Name] = Install-OnlineApp -App $appObj
        }
        $path = Export-InstallReport -Results $results -Section "BuscaOnline"
        Show-Info ("Instalacao concluida. Relatorio salvo em:`n{0}" -f $path)
    }.GetNewClosure())

    # ---- Pacote Extra ----
    $spExtra = $window.FindName("SpExtraList")
    $global:ExtraCheckboxes = @()
    $RefreshExtraList = {
        $spExtra.Children.Clear()
        $global:ExtraCheckboxes = @()
        foreach ($app in $global:ExtraAppsList) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $app.Name
            $cb.Tag = $app
            [void]$spExtra.Children.Add($cb)
            $global:ExtraCheckboxes += $cb
        }
    }.GetNewClosure()
    & $RefreshExtraList
    $window.FindName("BtnAdicionarExtra").Add_Click({
        $novo = Show-AddExtraAppDialog
        if ($novo) { [void]$global:ExtraAppsList.Add($novo); Export-ExtraDatabase | Out-Null; & $RefreshExtraList }
    }.GetNewClosure())
    $window.FindName("BtnInstalarExtra").Add_Click({
        if (-not $global:IsAdmin) { Show-Warning "Instalacao requer Administrador. Reabra a ferramenta como Admin."; return }
        $selecionados = @($global:ExtraCheckboxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if ($selecionados.Count -eq 0) { Show-Warning "Selecione ao menos um item."; return }
        $results = @{}
        foreach ($app in $selecionados) { $results[$app.Name] = Install-DirectApp -App $app }
        $path = Export-InstallReport -Results $results -Section "PacoteExtra"
        Show-Info ("Instalacao concluida. Relatorio salvo em:`n{0}" -f $path)
    }.GetNewClosure())

    # ---- Limpeza ----
    $window.FindName("BtnLimparTemp").Add_Click({ Invoke-CleanupOperation -IncludeWindowsTemp; Show-Info "Temporarios limpos." }.GetNewClosure())
    $window.FindName("BtnLimparWU").Add_Click({ Clear-WindowsUpdateCache }.GetNewClosure())
    $window.FindName("BtnLimparGeo").Add_Click({ Clear-GeolocationCache }.GetNewClosure())

    # ---- Rede ----
    $window.FindName("BtnFlushDns").Add_Click({ Invoke-NetworkTool -Action "Flush DNS" }.GetNewClosure())
    $window.FindName("BtnRenewIp").Add_Click({ Invoke-NetworkTool -Action "Renew IP" }.GetNewClosure())
    $window.FindName("BtnWinsock").Add_Click({ Invoke-NetworkTool -Action "Reset Winsock" }.GetNewClosure())
    $window.FindName("BtnPingGoogle").Add_Click({ Invoke-NetworkTool -Action "Ping Google" }.GetNewClosure())
    $window.FindName("BtnTesteDns").Add_Click({ Invoke-NetworkTool -Action "Teste DNS" }.GetNewClosure())

    # ---- Impressao ----
    $window.FindName("BtnSpooler").Add_Click({ Reset-PrintSpooler }.GetNewClosure())
    $dgImpressoras = $window.FindName("DgImpressoras")
    $txtPesquisaImpressoras = $window.FindName("TxtPesquisaImpressoras")
    $btnFiltroTodos   = $window.FindName("BtnFiltroTodos")
    $btnFiltroOnline  = $window.FindName("BtnFiltroOnline")
    $btnFiltroOffline = $window.FindName("BtnFiltroOffline")
    $txtStatTotal   = $window.FindName("TxtStatTotal")
    $txtStatOnline  = $window.FindName("TxtStatOnline")
    $txtStatOffline = $window.FindName("TxtStatOffline")
    $txtUltimaAtualizacao = $window.FindName("TxtUltimaAtualizacao")

    $global:PrinterFiltroStatus = "Todos"

    $UpdatePrinterStats = {
        $lista = @($global:PrintersList)
        $txtStatTotal.Text   = [string]$lista.Count
        $txtStatOnline.Text  = [string]@($lista | Where-Object { $_.Status -eq "Online" }).Count
        $txtStatOffline.Text = [string]@($lista | Where-Object { $_.Status -eq "Offline" }).Count
        $txtUltimaAtualizacao.Text = "Atualizado em " + (Get-Date -Format "HH:mm:ss")
    }.GetNewClosure()

    $ApplyPrinterFilter = {
        $texto = $txtPesquisaImpressoras.Text.Trim()
        if ($texto -eq "Pesquisar impressora...") { $texto = "" }
        $filtro = $global:PrinterFiltroStatus
        $resultado = @($global:PrintersList) | Where-Object {
            ($filtro -eq "Todos" -or $_.Status -eq $filtro) -and
            ($texto -eq "" -or $_.Nome -match [regex]::Escape($texto) -or $_.IP -match [regex]::Escape($texto) -or $_.Modelo -match [regex]::Escape($texto))
        }
        $dgImpressoras.ItemsSource = @($resultado)
    }.GetNewClosure()

    $UpdatePrinterFilterUI = {
        param([string]$Filtro)
        $global:PrinterFiltroStatus = $Filtro
        foreach ($pair in @(@{Btn=$btnFiltroTodos;Val="Todos"},@{Btn=$btnFiltroOnline;Val="Online"},@{Btn=$btnFiltroOffline;Val="Offline"})) {
            $ativo = ($pair.Val -eq $Filtro)
            $pair.Btn.Background = if ($ativo) { Get-ThemeBrush "BrushActiveNav" } else { Get-Brush "Transparent" }
            $pair.Btn.Foreground = if ($ativo) { Get-ThemeBrush "BrushAccent" } else { Get-ThemeBrush "BrushTextMuted" }
        }
        & $ApplyPrinterFilter
    }.GetNewClosure()

    $btnFiltroTodos.Add_Click({ & $UpdatePrinterFilterUI -Filtro "Todos" }.GetNewClosure())
    $btnFiltroOnline.Add_Click({ & $UpdatePrinterFilterUI -Filtro "Online" }.GetNewClosure())
    $btnFiltroOffline.Add_Click({ & $UpdatePrinterFilterUI -Filtro "Offline" }.GetNewClosure())
    $txtPesquisaImpressoras.Add_GotFocus({ if ($txtPesquisaImpressoras.Text -eq "Pesquisar impressora...") { $txtPesquisaImpressoras.Text = "" } }.GetNewClosure())
    $txtPesquisaImpressoras.Add_LostFocus({ if ([string]::IsNullOrWhiteSpace($txtPesquisaImpressoras.Text)) { $txtPesquisaImpressoras.Text = "Pesquisar impressora..." } }.GetNewClosure())
    $txtPesquisaImpressoras.Add_TextChanged({ & $ApplyPrinterFilter }.GetNewClosure())

    # Um unico handler no DataGrid capta o clique de qualquer botao de acao
    # dentro do DataTemplate de cada linha (eles nao existem no momento em que
    # o codigo roda - so sao criados pelo WPF quando a linha e desenhada -
    # entao precisam ser capturados via bubbling do evento Click, nao via
    # Add_Click direto).
    $printerActionHandler = {
        param($senderObj,$e)
        $btn = $e.OriginalSource
        if ($btn -isnot [System.Windows.Controls.Button]) { return }
        $printer = $btn.DataContext
        if ($null -eq $printer) { return }
        switch ([string]$btn.Tag) {
            "Detalhes" { Show-PrinterDetailsDialog -Printer $printer }
            "Web" {
                if ([string]$printer.IP -match '^\d+\.\d+\.\d+\.\d+$') {
                    try { Start-Process ("http://{0}" -f $printer.IP) } catch { Show-Warning "Nao foi possivel abrir o IP no navegador." }
                } else { Show-Warning "Esta impressora nao tem um IP valido conhecido." }
            }
            "Teste"  { Invoke-PrintTestPage -Nome ([string]$printer.Nome) }
            "Driver" { Show-DriverPopupSimplificado -Nome ([string]$printer.Nome) -Modelo ([string]$printer.Modelo) -IP ([string]$printer.IP) }
        }
    }.GetNewClosure()
    $dgImpressoras.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]$printerActionHandler)

    $ExecutarScan = {
        param([bool]$Silencioso)
        $overlay = $null
        if (-not $Silencioso) {
            $btnEscanearRef = $window.FindName("BtnEscanear")
            $btnEscanearRef.IsEnabled = $false
            $overlayReader = [System.Xml.XmlNodeReader]::new([xml]$script:LoadingOverlayXaml)
            $overlay = [System.Windows.Markup.XamlReader]::Load($overlayReader)
            $overlay.Owner = $global:MainWindow
            Set-DialogTheme -Dialog $overlay
            $overlay.Show()
            $overlay.Dispatcher.Invoke([System.Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        }
        try {
            $resultado = Get-ImpressorasRede
            $global:PrintersList.Clear()
            foreach ($r in $resultado) { [void]$global:PrintersList.Add($r) }
            & $ApplyPrinterFilter
            & $UpdatePrinterStats
        } finally {
            if ($overlay -ne $null) { $overlay.Close() }
            if (-not $Silencioso) { $window.FindName("BtnEscanear").IsEnabled = $true }
        }
    }.GetNewClosure()

    $window.FindName("BtnEscanear").Add_Click({ & $ExecutarScan -Silencioso $false }.GetNewClosure())
    $window.FindName("BtnConfigServidor").Add_Click({
        $salvou = Show-ConfigurarServidorDialog
        if ($salvou -and $global:PrinterRefreshTimer -ne $null) {
            $cfgNovo = Get-PrinterConfig
            $global:PrinterRefreshTimer.Interval = [TimeSpan]::FromMinutes([double]$cfgNovo.TempoRefreshMinutos)
        }
    }.GetNewClosure())
    $window.FindName("BtnExportarCsv").Add_Click({
        if ($global:PrintersList.Count -eq 0) { Show-Warning "Nenhuma impressora para exportar. Clique em 'Escanear Rede' primeiro."; return }
        $path = Export-PrintersCsv -Printers @($global:PrintersList)
        Show-Info ("CSV exportado em:`n{0}" -f $path)
    }.GetNewClosure())

    # ---- Ferramentas ----
    $chkLimpTemp    = $window.FindName("ChkLimpTemp")
    $chkLimpWinTemp = $window.FindName("ChkLimpWinTemp")
    $chkLimpLixeira = $window.FindName("ChkLimpLixeira")
    $chkLimpWU      = $window.FindName("ChkLimpWU")
    $chkLimpGeo     = $window.FindName("ChkLimpGeo")
    $window.FindName("BtnExecutarLimpeza").Add_Click({
        if ($chkLimpTemp.IsChecked)    { Invoke-CleanupOperation }
        if ($chkLimpWinTemp.IsChecked) { Invoke-CleanupOperation -IncludeWindowsTemp }
        if ($chkLimpLixeira.IsChecked) { Clear-RecycleBinContents }
        if ($chkLimpWU.IsChecked)      { Clear-WindowsUpdateCache }
        if ($chkLimpGeo.IsChecked)     { Clear-GeolocationCache }
        Show-Info "Limpeza concluida."
    }.GetNewClosure())

    $window.FindName("BtnSfcScan").Add_Click({ Invoke-SfcScan }.GetNewClosure())
    $window.FindName("BtnDismRestore").Add_Click({ Invoke-DismRestoreHealth }.GetNewClosure())
    $window.FindName("BtnWingetUpgrade").Add_Click({ Update-WingetApps }.GetNewClosure())
    $window.FindName("BtnUninstaller").Add_Click({
        if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
        Show-UninstallerDialog
    }.GetNewClosure())
    $window.FindName("BtnMaxPerformance").Add_Click({ Enable-MaxPerformancePowerPlan }.GetNewClosure())

    $window.FindName("BtnFerrFlushDns").Add_Click({ Invoke-NetworkTool -Action "Flush DNS" }.GetNewClosure())
    $window.FindName("BtnFerrRenewIp").Add_Click({ Invoke-NetworkTool -Action "Renew IP" }.GetNewClosure())
    $window.FindName("BtnFerrWinsock").Add_Click({ Invoke-NetworkTool -Action "Reset Winsock" }.GetNewClosure())
    $window.FindName("BtnFerrPing").Add_Click({ Invoke-NetworkTool -Action "Ping Google" }.GetNewClosure())
    $window.FindName("BtnFerrDns").Add_Click({ Invoke-NetworkTool -Action "Teste DNS" }.GetNewClosure())

    $window.FindName("BtnFerrSpooler").Add_Click({ Reset-PrintSpooler }.GetNewClosure())
    $window.FindName("BtnAbrirImpressoras").Add_Click({ Open-PrintersFolder }.GetNewClosure())

    $window.FindName("BtnResetAppsJson").Add_Click({
        if (-not (Confirm-Action "Isso vai apagar suas customizacoes em apps.json e recriar a lista padrao. Continuar?" "Recriar Lista Padrao")) { return }
        if (Reset-AppDatabaseToDefault) { Show-Info "Lista padrao recriada. Reabra a ferramenta para atualizar a tela de Instalar Aplicativos." }
    }.GetNewClosure())
    $window.FindName("BtnAbrirPastaFerramenta").Add_Click({ Open-ToolDataFolder }.GetNewClosure())

    $window.FindName("BtnFerrRemoveAI").Add_Click({ Invoke-RemoveWindowsAI }.GetNewClosure())

    $chkCacheChrome  = $window.FindName("ChkCacheChrome")
    $chkCacheEdge    = $window.FindName("ChkCacheEdge")
    $chkCacheFirefox = $window.FindName("ChkCacheFirefox")
    $window.FindName("BtnLimparCacheNavegadores").Add_Click({
        $navegadores = @()
        if ($chkCacheChrome.IsChecked)  { $navegadores += "Chrome" }
        if ($chkCacheEdge.IsChecked)    { $navegadores += "Edge" }
        if ($chkCacheFirefox.IsChecked) { $navegadores += "Firefox" }
        if ($navegadores.Count -eq 0) { Show-Warning "Selecione ao menos um navegador."; return }
        Clear-BrowserCaches -Browsers $navegadores
    }.GetNewClosure())

    $window.FindName("BtnLimparPrefetch").Add_Click({ Clear-PrefetchCache }.GetNewClosure())
    $window.FindName("BtnLimparFontCache").Add_Click({ Clear-FontCacheData }.GetNewClosure())
    $window.FindName("BtnVerShadowCopies").Add_Click({ Show-TextResultDialog -Title "Shadow Copies" -Text (Get-ShadowCopiesInfo) }.GetNewClosure())
    $window.FindName("BtnWinSxSCleanup").Add_Click({ Invoke-DismComponentCleanup }.GetNewClosure())
    $window.FindName("BtnLimparCacheDns").Add_Click({ Invoke-NetworkTool -Action "Flush DNS" }.GetNewClosure())

    $window.FindName("BtnWifiPerfis").Add_Click({ Show-TextResultDialog -Title "Perfis Wi-Fi" -Text (Get-WifiProfilesInfo) }.GetNewClosure())
    $window.FindName("BtnConexoesPortas").Add_Click({ Show-TextResultDialog -Title "Conexoes / Portas" -Text (Get-NetworkConnectionsInfo) }.GetNewClosure())
    $window.FindName("BtnMapearUnidade").Add_Click({ Show-MapNetworkDriveDialog }.GetNewClosure())
    $window.FindName("BtnVerUnidadesMapeadas").Add_Click({ Show-TextResultDialog -Title "Unidades Mapeadas" -Text (Get-MappedDrivesInfo) }.GetNewClosure())

    $global:PrinterRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
    $global:PrinterRefreshTimer.Add_Tick({
        try { & $ExecutarScan -Silencioso $true; Write-Log -Message "[PRINT] Atualizacao automatica concluida." -Level "INFO" }
        catch { Write-Log -Message ("[PRINT] Falha na atualizacao automatica: {0}" -f $_.Exception.Message) -Level "WARN" }
    }.GetNewClosure())

    & $UpdatePrinterFilterUI -Filtro "Todos"
    & $ShowSection -Key "Inicio"

    $window.Add_ContentRendered({
        Update-Prerequisites
        & $RefreshPkgMgrStatus
        if ($global:IsAdmin) {
            $borderAdminBadge.Background = Get-ThemeBrush "BrushSuccess"
            $txtAdminBadge.Text = "Administrador"
            $txtHomeAdmin.Text = "Sim"
            Set-Status "Pronto."
        } else {
            $borderAdminBadge.Background = Get-ThemeBrush "BrushWarning"
            $txtAdminBadge.Text = "Sem privilegios"
            $txtHomeAdmin.Text = "Nao"
            Set-Status "Rodando sem privilegios de administrador - algumas acoes ficarao bloqueadas." "WARN"
        }
        $txtHomeInternet.Text = if ($global:HasInternet) { "Conectado" } else { "Sem conexao" }
        $txtHomeWinget.Text   = if ($global:HasWinget)   { "Instalado" } else { "Nao instalado" }
        $txtHomeChoco.Text    = if ($global:HasChoco)    { "Instalado" } else { "Nao instalado" }
        $tbCpu.Text = "CPU N/A"; $tbRam.Text = "RAM N/A"; $tbDisk.Text = "Disco N/A"
        $statsTimer.Start()
        $cfgInicial = Get-PrinterConfig
        $global:PrinterRefreshTimer.Interval = [TimeSpan]::FromMinutes([double]$cfgInicial.TempoRefreshMinutos)
        $global:PrinterRefreshTimer.Start()
    }.GetNewClosure())

    $window.Add_Closed({
        try { $statsTimer.Stop() } catch {}
        try { $global:PrinterRefreshTimer.Stop() } catch {}
    }.GetNewClosure())

    [void]$window.ShowDialog()
}

# ==============================================================================
# ENTRADA
# ==============================================================================
Initialize-BrandingAssets
Initialize-AppDatabase
Update-LegacyDefaultListIfNeeded
Import-AppDatabase
Initialize-ExtraDatabase
Import-ExtraDatabase
Update-Prerequisites
Show-MainWindow
