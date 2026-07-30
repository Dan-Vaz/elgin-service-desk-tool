# ==============================================================================
# Elgin Service Desk Tool
# Ferramenta portatil de instalacao, limpeza, diagnostico e suporte para Windows.
#
# Distribuicao: executavel unico (.exe), compilado com PS2EXE a partir deste
# script (ver Build-Exe.ps1). Sem dependencia de Gist/irm/iex — basta baixar
# o .exe de um link fixo (GitHub Releases) e executar em qualquer computador.
# ==============================================================================

#requires -Version 5.1

param(
    [switch]$Silent,
    [switch]$NoElevatePrompt,
    [switch]$NoUpdateCheck
)

$ErrorActionPreference = "Stop"

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing       -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()
} catch {
    Write-Host "Nao foi possivel carregar Windows Forms/System.Drawing. Execute em Windows com interface grafica." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# ==============================================================================
# CONFIGURACAO GLOBAL
# ==============================================================================
$global:AppName       = "Elgin Service Desk Tool"
$global:AppVersion    = "1.0.0"
$global:BasePath      = Join-Path $env:ProgramData "ElginServiceDesk"
$global:ConfigPath    = Join-Path $global:BasePath  "Config"
$global:ReportsPath   = Join-Path $global:BasePath  "Relatorios"
$global:ConfigFile    = Join-Path $global:ConfigPath "apps.json"
$global:ExtraConfigFile = Join-Path $global:ConfigPath "extra_apps.json"
$global:PrinterConfigFile = Join-Path $global:ConfigPath "printers_config.json"
$global:PrinterCacheFile  = Join-Path $global:BasePath   "printers_cache.json"
$global:LogFile       = Join-Path $global:BasePath   "servicedesk.log"

# URL fixa (GitHub Releases) para checagem de nova versao.
$global:UpdateVersionUrl = "https://raw.githubusercontent.com/Dan-Vaz/elgin-service-desk-tool/main/version.json"
$global:UpdateReleaseUrl = "https://github.com/Dan-Vaz/elgin-service-desk-tool/releases/latest"

$global:IsAdmin       = $false
$global:HasWinget     = $false
$global:HasChoco      = $false
$global:HasInternet   = $false
$global:WingetPath    = $null
$global:ChocoPath     = $null
$global:AppsList        = New-Object System.Collections.ArrayList
$global:ExtraAppsList   = New-Object System.Collections.ArrayList
$global:PrintersList    = New-Object System.Collections.ArrayList
$global:StatusLabel   = $null
$global:LogTextBox    = $null

$global:Theme = [PSCustomObject]@{
    Background = [System.Drawing.Color]::FromArgb(245,245,245)
    Surface    = [System.Drawing.Color]::White
    Sidebar    = [System.Drawing.Color]::FromArgb(20,30,40)
    Primary    = [System.Drawing.Color]::FromArgb(0,120,215)
    Success    = [System.Drawing.Color]::FromArgb(34,139,34)
    Danger     = [System.Drawing.Color]::FromArgb(178,34,34)
    Warning    = [System.Drawing.Color]::FromArgb(220,140,0)
    Neutral    = [System.Drawing.Color]::FromArgb(80,80,80)
    Text       = [System.Drawing.Color]::FromArgb(35,35,35)
    Muted      = [System.Drawing.Color]::Gray
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

function Show-Info    { param([string]$Message,[string]$Title=$global:AppName) [System.Windows.Forms.MessageBox]::Show($Message,$Title,[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null }
function Show-Warning { param([string]$Message,[string]$Title=$global:AppName) [System.Windows.Forms.MessageBox]::Show($Message,$Title,[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null }
function Show-ErrorBox{ param([string]$Message,[string]$Title=$global:AppName) [System.Windows.Forms.MessageBox]::Show($Message,$Title,[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null }
function Confirm-Action {
    param([string]$Message,[string]$Title="Confirmacao")
    return ([System.Windows.Forms.MessageBox]::Show($Message,$Title,[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -eq [System.Windows.Forms.DialogResult]::Yes)
}

# Caminho do proprio executavel (funciona tanto rodando como .ps1 quanto compilado via PS2EXE).
function Get-SelfExecutablePath {
    try {
        $proc = [System.Diagnostics.Process]::GetCurrentProcess()
        if ($proc.MainModule.FileName -match 'powershell(_ise)?\.exe$|pwsh\.exe$') {
            # Rodando como script (.ps1) via powershell.exe — nao ha exe proprio.
            return $null
        }
        return $proc.MainModule.FileName
    } catch { return $null }
}

# Reabre a propria ferramenta como Administrador (via UAC). Quando compilado
# com PS2EXE, isso relanca o proprio .exe; quando rodando como .ps1 (dev),
# relanca via powershell.exe -File.
function Request-AdminElevation {
    param([switch]$SilentMode)
    if (Test-IsAdmin) { return $true }
    $message = "Para instalar aplicativos, limpar componentes do Windows e usar as ferramentas de rede, a ferramenta precisa de permissao administrativa.`n`nO Windows exibira a janela oficial do UAC. A ferramenta nao coleta, nao armazena e nao visualiza credenciais.`n`nDeseja reabrir agora como Administrador?"
    $shouldElevate = $true
    if (-not $SilentMode) { $shouldElevate = Confirm-Action $message "Permissao administrativa necessaria" }
    if (-not $shouldElevate) { return $false }
    try {
        $selfExe = Get-SelfExecutablePath
        if ($selfExe) {
            Start-Process -FilePath $selfExe -Verb RunAs | Out-Null
        } else {
            Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-STA","-File","`"$PSCommandPath`"") -Verb RunAs | Out-Null
        }
        return $true
    } catch { Show-ErrorBox ("Nao foi possivel solicitar elevacao administrativa.`n`n{0}" -f $_.Exception.Message); return $false }
}

if (-not $NoElevatePrompt -and -not (Test-IsAdmin)) {
    $elevated = Request-AdminElevation -SilentMode:$Silent
    if ($elevated) { exit 0 }
}

function Initialize-Folders {
    foreach ($path in @($global:BasePath,$global:ConfigPath,$global:ReportsPath)) {
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
        if ($global:LogTextBox -ne $null -and -not $global:LogTextBox.IsDisposed) {
            $global:LogTextBox.AppendText($line + [Environment]::NewLine)
            $global:LogTextBox.SelectionStart = $global:LogTextBox.Text.Length
            $global:LogTextBox.ScrollToCaret()
        }
    } catch {}
}

function Set-Status {
    param([string]$Text,[ValidateSet("INFO","WARN","ERROR","SUCCESS")][string]$Level="INFO")
    if ($global:StatusLabel -ne $null) { $global:StatusLabel.Text = $Text }
    Write-Log -Message $Text -Level $Level
    [System.Windows.Forms.Application]::DoEvents()
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

function Invoke-ManagedProcess {
    param([Parameter(Mandatory=$true)][string]$FilePath,[string[]]$Arguments=@(),[string]$Description="Processo",[int]$TimeoutSeconds=0)
    $argLine = ConvertTo-ProcessArgumentString -Arguments $Arguments
    Write-Log -Message ("{0}: {1} {2}" -f $Description,$FilePath,$argLine)
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $FilePath
        $psi.Arguments              = $argLine
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $psi.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
            if ($TimeoutSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                try{$proc.Kill()}catch{}
                $sw.Stop()
                return [PSCustomObject]@{ExitCode=-999;Output="";Error=("Timeout apos {0}s" -f $TimeoutSeconds)}
            }
        }
        try { $proc.WaitForExit(5000) | Out-Null } catch {}
        $sw.Stop()

        $output    = try { $outTask.Result } catch { "" }
        $errorText = try { $errTask.Result } catch { "" }
        $exit      = try { $proc.ExitCode } catch { -1 }
        if ($output    -and $output.Trim())    { Write-Log -Message $output.Trim() }
        if ($errorText -and $errorText.Trim()) { Write-Log -Message $errorText.Trim() -Level "WARN" }
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
        $psi.Arguments              = "/d /s /c "+$quote+$CommandLine+$quote
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $psi.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $outTask=$proc.StandardOutput.ReadToEndAsync()
        $errTask=$proc.StandardError.ReadToEndAsync()
        $sw=[System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited) {
            [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 150
            if ($TimeoutSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                try{$proc.Kill()}catch{}
                $pOut=try{$outTask.Result}catch{""}; $pErr=try{$errTask.Result}catch{""}
                return [PSCustomObject]@{ExitCode=-999;Output=$pOut;Error=("Timeout apos {0}s`r`n{1}" -f $TimeoutSeconds,$pErr)}
            }
        }
        try { $proc.WaitForExit(5000) | Out-Null } catch {}
        $output=try{$outTask.Result}catch{""}; $errorText=try{$errTask.Result}catch{""}
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
# CHECAGEM DE ATUALIZACAO (sem auto-substituir o exe em execucao — so avisa)
# ==============================================================================
function Test-NewVersionAvailable {
    if ($NoUpdateCheck) { return $null }
    try {
        $resp = Invoke-RestMethod -Uri $global:UpdateVersionUrl -TimeoutSec 5 -ErrorAction Stop
        if ($resp.Version -and ([version]$resp.Version -gt [version]$global:AppVersion)) { return $resp.Version }
    } catch { Write-Log -Message ("Checagem de atualizacao falhou (normal se offline): {0}" -f $_.Exception.Message) -Level "WARN" }
    return $null
}

# ==============================================================================
# BANCO DE APLICATIVOS (Lista Padrao — Winget / Chocolatey)
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
        [PSCustomObject]@{Apps=@(Get-DefaultAppList)} | ConvertTo-Json -Depth 5 | Out-File $global:ConfigFile -Encoding UTF8 -Force
    }
}

function Import-AppDatabase {
    $global:AppsList.Clear()
    try {
        $json = Get-Content $global:ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($item in @($json.Apps)) { [void]$global:AppsList.Add($item) }
    } catch {
        Write-Log -Message ("Falha ao carregar banco de apps: {0}. Usando lista padrao." -f $_.Exception.Message) -Level "ERROR"
        foreach ($app in Get-DefaultAppList) { [void]$global:AppsList.Add($app) }
    }
}

# ==============================================================================
# PACOTE EXTRA — instaladores hospedados onde a empresa preferir (ex.: GitHub
# Releases). NAO ha URLs pre-cadastradas aqui: use "Adicionar" na aba Pacote
# Extra para cadastrar os instaladores da sua empresa (ex.: antivirus, VPN,
# agente de inventario). Fica salvo em extra_apps.json e some com voce.
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

function Show-AddExtraAppDialog {
    $df = New-Object System.Windows.Forms.Form
    $df.Text          = "Adicionar ao Pacote Extra"
    $df.Size          = New-Object System.Drawing.Size(520, 260)
    $df.StartPosition = "CenterParent"
    $df.FormBorderStyle = "FixedDialog"
    $df.MaximizeBox   = $false; $df.MinimizeBox = $false
    $df.BackColor     = $global:Theme.Background

    $lblN = New-Object System.Windows.Forms.Label
    $lblN.Text="Nome do software:"; $lblN.Location=New-Object System.Drawing.Point(20,20); $lblN.AutoSize=$true
    $df.Controls.Add($lblN)
    $txtN = New-Object System.Windows.Forms.TextBox
    $txtN.Location = New-Object System.Drawing.Point(20, 40); $txtN.Size = New-Object System.Drawing.Size(460, 22)
    $df.Controls.Add($txtN)

    $lblU = New-Object System.Windows.Forms.Label
    $lblU.Text="URL de download direto (.exe/.msi):"; $lblU.Location=New-Object System.Drawing.Point(20,72); $lblU.AutoSize=$true
    $df.Controls.Add($lblU)
    $txtU = New-Object System.Windows.Forms.TextBox
    $txtU.Location = New-Object System.Drawing.Point(20, 92); $txtU.Size = New-Object System.Drawing.Size(460, 22)
    $df.Controls.Add($txtU)

    $cbMsi = New-Object System.Windows.Forms.CheckBox
    $cbMsi.Text = "Arquivo .msi (usa msiexec automaticamente)"
    $cbMsi.Location = New-Object System.Drawing.Point(20, 124); $cbMsi.AutoSize = $true
    $df.Controls.Add($cbMsi)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text="Salvar"; $btnSave.Location=New-Object System.Drawing.Point(20,162); $btnSave.Size=New-Object System.Drawing.Size(140,34)
    $btnSave.BackColor=$global:Theme.Success; $btnSave.ForeColor=[System.Drawing.Color]::White; $btnSave.FlatStyle="Flat"
    $btnCncl = New-Object System.Windows.Forms.Button
    $btnCncl.Text="Cancelar"; $btnCncl.Location=New-Object System.Drawing.Point(170,162); $btnCncl.Size=New-Object System.Drawing.Size(100,34)
    $btnCncl.BackColor=$global:Theme.Neutral; $btnCncl.ForeColor=[System.Drawing.Color]::White; $btnCncl.FlatStyle="Flat"
    $df.Controls.AddRange(@($btnSave,$btnCncl))

    $script:extraDialogResult = $null
    $btnSave.Add_Click({
        $n = $txtN.Text.Trim(); $u = $txtU.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($n)) { Show-Warning "Informe o nome."; return }
        if ([string]::IsNullOrWhiteSpace($u) -or $u -notmatch "^https?://") { Show-Warning "Informe uma URL valida (https://)."; return }
        $isMsi = $cbMsi.Checked
        $ext   = if ($isMsi) { ".msi" } else { [System.IO.Path]::GetExtension($u) }
        $script:extraDialogResult = [PSCustomObject]@{
            Name=$n; Url=$u; SilentArgs=if($isMsi){@("/qn","/norestart")}else{@()}
            Ext=$ext; IsMSI=$isMsi; TimeoutSeconds=1800; Enabled=$true
        }
        $df.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $df.Close()
    })
    $btnCncl.Add_Click({ $df.DialogResult=[System.Windows.Forms.DialogResult]::Cancel; $df.Close() })
    [void]$df.ShowDialog()
    return $script:extraDialogResult
}

# Baixa o instalador, executa silenciosamente e remove o arquivo temporario.
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
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

        $downloadOk = $false; $lastError = ""

        $curlExe = "$env:SystemRoot\System32\curl.exe"
        if (-not (Test-Path $curlExe)) { $curlExe = "$env:SystemRoot\SysWOW64\curl.exe" }
        if (Test-Path $curlExe) {
            try {
                $curlArgs = @("-L","--fail","--silent","--show-error","-A","Mozilla/5.0 (Windows NT 10.0; Win64; x64)","-o",$tempFile,$url)
                $curlRes = Invoke-ManagedProcess -FilePath $curlExe -Arguments $curlArgs -Description "[EXTRA] Download curl" -TimeoutSeconds $timeout
                if ($curlRes.ExitCode -eq 0 -and (Test-Path $tempFile)) { $downloadOk = $true }
                else { $lastError = ("curl exit {0}" -f $curlRes.ExitCode) }
            } catch { $lastError = $_.Exception.Message }
        }

        if (-not $downloadOk) {
            try {
                $prev = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
                Invoke-WebRequest -Uri $url -OutFile $tempFile -UseBasicParsing -Headers @{"User-Agent"="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"} -ErrorAction Stop
                $ProgressPreference = $prev; $downloadOk = $true
            } catch { $ProgressPreference = $prev; $lastError = $_.Exception.Message }
        }

        if (-not $downloadOk) {
            Write-Log -Message ("[EXTRA] Download falhou para '{0}'. Ultimo erro: {1}" -f $appName,$lastError) -Level "ERROR"
            Show-Warning ("Falha ao baixar '{0}'.`n`nUltimo erro:`n{1}" -f $appName,$lastError)
            return $false
        }

        $fileSize = (Get-Item $tempFile).Length
        if ($fileSize -lt 10240) {
            Write-Log -Message ("[EXTRA] Arquivo suspeito ({0:N0} bytes) para '{1}'." -f $fileSize,$appName) -Level "ERROR"
            Show-Warning ("O arquivo baixado para '{0}' tem apenas {1:N0} bytes. Verifique a URL configurada." -f $appName,$fileSize)
            return $false
        }

        Set-Status ("Aguardando instalacao de {0}..." -f $appName)
        if ($isMSI) {
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$tempFile`" /qn /norestart" -PassThru -ErrorAction Stop
        } else {
            $proc = Start-Process -FilePath $tempFile -PassThru -ErrorAction Stop
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($proc -and -not $proc.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 400
            if ($sw.Elapsed.TotalSeconds -gt $timeout) { try{$proc.Kill()}catch{}; Write-Log -Message ("[EXTRA] Timeout em {0}" -f $appName) -Level "ERROR"; return $false }
        }
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
# GERENCIADORES DE PACOTES E INSTALACAO (Lista Padrao)
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

# ==============================================================================
# IMPRESSORAS DE REDE — consulta o servidor de impressao (spooler) e faz SNMP
# direto no IP de cada impressora para ler nivel de toner/uptime/paginas.
# So funciona com a maquina conectada a rede/VPN da empresa (mesma exigencia
# do app antigo de impressoras).
# ==============================================================================
function Get-PrinterConfig {
    if (-not (Test-Path $global:PrinterConfigFile)) {
        [PSCustomObject]@{ ServidorPrint = "elgjunprt"; SnmpCommunity = "public" } |
            ConvertTo-Json | Out-File $global:PrinterConfigFile -Encoding UTF8 -Force
    }
    try { return (Get-Content $global:PrinterConfigFile -Raw | ConvertFrom-Json) }
    catch { return [PSCustomObject]@{ ServidorPrint = "elgjunprt"; SnmpCommunity = "public" } }
}

function Save-PrinterConfig {
    param([string]$ServidorPrint, [string]$SnmpCommunity)
    [PSCustomObject]@{ ServidorPrint = $ServidorPrint; SnmpCommunity = $SnmpCommunity } |
        ConvertTo-Json | Out-File $global:PrinterConfigFile -Encoding UTF8 -Force
}

function Show-ConfigurarServidorDialog {
    $cfg = Get-PrinterConfig
    $df = New-Object System.Windows.Forms.Form
    $df.Text = "Configurar Servidor de Impressao"
    $df.Size = New-Object System.Drawing.Size(440,220)
    $df.StartPosition = "CenterParent"; $df.FormBorderStyle = "FixedDialog"
    $df.MaximizeBox = $false; $df.MinimizeBox = $false
    $df.BackColor = $global:Theme.Background

    $lbl1 = New-Object System.Windows.Forms.Label
    $lbl1.Text = "Nome/IP do servidor de impressao:"; $lbl1.Location = New-Object System.Drawing.Point(20,20); $lbl1.AutoSize = $true
    $df.Controls.Add($lbl1)
    $txt1 = New-Object System.Windows.Forms.TextBox
    $txt1.Text = [string]$cfg.ServidorPrint
    $txt1.Location = New-Object System.Drawing.Point(20,42); $txt1.Size = New-Object System.Drawing.Size(380,22)
    $df.Controls.Add($txt1)

    $lbl2 = New-Object System.Windows.Forms.Label
    $lbl2.Text = "Comunidade SNMP:"; $lbl2.Location = New-Object System.Drawing.Point(20,78); $lbl2.AutoSize = $true
    $df.Controls.Add($lbl2)
    $txt2 = New-Object System.Windows.Forms.TextBox
    $txt2.Text = [string]$cfg.SnmpCommunity
    $txt2.Location = New-Object System.Drawing.Point(20,100); $txt2.Size = New-Object System.Drawing.Size(200,22)
    $df.Controls.Add($txt2)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Salvar"; $btnSave.Location = New-Object System.Drawing.Point(20,140)
    $btnSave.Size = New-Object System.Drawing.Size(140,34); $btnSave.BackColor = $global:Theme.Success
    $btnSave.ForeColor = [System.Drawing.Color]::White; $btnSave.FlatStyle = "Flat"
    $btnSave.Add_Click({
        Save-PrinterConfig -ServidorPrint $txt1.Text.Trim() -SnmpCommunity $txt2.Text.Trim()
        $df.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $df.Close()
    })
    $btnCncl = New-Object System.Windows.Forms.Button
    $btnCncl.Text = "Cancelar"; $btnCncl.Location = New-Object System.Drawing.Point(170,140)
    $btnCncl.Size = New-Object System.Drawing.Size(100,34); $btnCncl.BackColor = $global:Theme.Neutral
    $btnCncl.ForeColor = [System.Drawing.Color]::White; $btnCncl.FlatStyle = "Flat"
    $btnCncl.Add_Click({ $df.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $df.Close() })
    $df.Controls.AddRange(@($btnSave,$btnCncl))
    [void]$df.ShowDialog()
}

# SNMP puro via UDP (sem dependencias externas) — le toner/uptime/paginas.
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
                    if      ($desc -match "(?i)cyan|ciano|azul|\bc\b")   { $cor = "Ciano" }
                    elseif  ($desc -match "(?i)magenta|rosa|\bm\b")       { $cor = "Magenta" }
                    elseif  ($desc -match "(?i)yellow|amarelo|\by\b")     { $cor = "Amarelo" }
                    elseif  ($desc -match "(?i)black|preto|negro|\bk\b")  { $cor = "Preto" }
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
        return @{ Toners = $melhores; Uptime = $uptimeStr; PageCount = $pageCount }
    } catch {
        if ($null -ne $udp) { $udp.Dispose() }
        return @{ Toners = $null; Uptime = "Erro"; PageCount = $null }
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
# (runspace pool) em cada impressora. Em caso de falha (servidor fora da rede/VPN),
# cai para o ultimo resultado bom conhecido, salvo em disco.
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
                Show-Warning ("Nao foi possivel acessar o servidor de impressao '{0}'.`n`nMostrando o ultimo resultado conhecido (pode estar desatualizado). Confirme se voce esta conectado a rede/VPN da empresa." -f $cfg.ServidorPrint)
                return @($cache)
            } catch {}
        }
        Show-Warning ("Nao foi possivel acessar o servidor de impressao '{0}'.`n`nConfirme se voce esta conectado a rede/VPN da empresa (aba Configurar Servidor)." -f $cfg.ServidorPrint)
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
    Toners    = @(`$snmp.Toners | ForEach-Object { "{0}:{1}%" -f (`$_.CorToner.Substring(0,1)), `$_.Pct })
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
        [System.Windows.Forms.Application]::DoEvents()
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
        $toner = ($p.Toners -join " ")
        $lines += ('{0},{1},{2},{3},"{4}",{5},{6}' -f $p.Nome,$p.IP,$p.Modelo,$p.Status,$toner,$p.Uptime,$p.PageCount)
    }
    $lines | Out-File $path -Encoding UTF8 -Force
    return $path
}

# ==============================================================================
# INTERFACE (WinForms)
# ==============================================================================
function New-SidebarButton {
    param([string]$Text,[int]$Y)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Location = New-Object System.Drawing.Point(0,$Y); $b.Size = New-Object System.Drawing.Size(220,40)
    $b.FlatStyle = "Flat"; $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $global:Theme.Sidebar; $b.ForeColor = [System.Drawing.Color]::White
    $b.TextAlign = "MiddleLeft"; $b.Padding = New-Object System.Windows.Forms.Padding(16,0,0,0)
    $b.Font = New-Object System.Drawing.Font("Segoe UI",10)
    $b.Cursor = "Hand"
    return $b
}

function Show-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$($global:AppName) v$($global:AppVersion)"
    $form.Size = New-Object System.Drawing.Size(980,640)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = $global:Theme.Background
    $form.MinimumSize = New-Object System.Drawing.Size(900,600)

    $sidebar = New-Object System.Windows.Forms.Panel
    $sidebar.Size = New-Object System.Drawing.Size(220,0)
    $sidebar.Dock = "Left"
    $sidebar.BackColor = $global:Theme.Sidebar
    $form.Controls.Add($sidebar)

    $content = New-Object System.Windows.Forms.Panel
    $content.Dock = "Fill"
    $content.BackColor = $global:Theme.Background
    $content.Padding = New-Object System.Windows.Forms.Padding(20)
    $form.Controls.Add($content)
    $content.BringToFront()

    $statusBar = New-Object System.Windows.Forms.Panel
    $statusBar.Dock = "Bottom"; $statusBar.Height = 30; $statusBar.BackColor = $global:Theme.Sidebar
    $global:StatusLabel = New-Object System.Windows.Forms.Label
    $global:StatusLabel.Text = "Pronto."; $global:StatusLabel.ForeColor = [System.Drawing.Color]::White
    $global:StatusLabel.Dock = "Fill"; $global:StatusLabel.TextAlign = "MiddleLeft"
    $global:StatusLabel.Padding = New-Object System.Windows.Forms.Padding(10,0,0,0)
    $statusBar.Controls.Add($global:StatusLabel)
    $form.Controls.Add($statusBar)

    $panels = @{}
    function New-Section {
        param([string]$Key)
        $p = New-Object System.Windows.Forms.Panel
        $p.Dock = "Fill"; $p.Visible = $false; $p.AutoScroll = $true
        $content.Controls.Add($p)
        $panels[$Key] = $p
        return $p
    }
    function Show-Section {
        param([string]$Key)
        foreach ($k in $panels.Keys) { $panels[$k].Visible = ($k -eq $Key) }
    }

    # ---- Secao: Instalar Aplicativos ----
    $pInstall = New-Section "Instalar"
    $lblInstall = New-Object System.Windows.Forms.Label
    $lblInstall.Text = "Instalar Aplicativos"; $lblInstall.Font = New-Object System.Drawing.Font("Segoe UI",14,[System.Drawing.FontStyle]::Bold)
    $lblInstall.Location = New-Object System.Drawing.Point(0,0); $lblInstall.AutoSize = $true
    $pInstall.Controls.Add($lblInstall)

    $clbApps = New-Object System.Windows.Forms.CheckedListBox
    $clbApps.Location = New-Object System.Drawing.Point(0,40); $clbApps.Size = New-Object System.Drawing.Size(500,300)
    $clbApps.CheckOnClick = $true
    foreach ($app in $global:AppsList) { [void]$clbApps.Items.Add($app.Name, $false) }
    $pInstall.Controls.Add($clbApps)

    $btnInstallSelected = New-Object System.Windows.Forms.Button
    $btnInstallSelected.Text = "Instalar Selecionados"; $btnInstallSelected.Location = New-Object System.Drawing.Point(0,350)
    $btnInstallSelected.Size = New-Object System.Drawing.Size(200,36); $btnInstallSelected.BackColor = $global:Theme.Primary
    $btnInstallSelected.ForeColor = [System.Drawing.Color]::White; $btnInstallSelected.FlatStyle = "Flat"
    $btnInstallSelected.Add_Click({
        if (-not $global:IsAdmin) { Show-Warning "Instalacao requer Administrador. Reabra a ferramenta como Admin."; return }
        $selecionados = @()
        for ($i=0; $i -lt $clbApps.Items.Count; $i++) { if ($clbApps.GetItemChecked($i)) { $selecionados += $global:AppsList[$i] } }
        if ($selecionados.Count -eq 0) { Show-Warning "Selecione ao menos um aplicativo."; return }
        $results = @{}
        foreach ($app in $selecionados) { $results[$app.Name] = Install-OnlineApp -App $app }
        $path = Export-InstallReport -Results $results -Section "Instalacao"
        Show-Info ("Instalacao concluida. Relatorio salvo em:`n{0}" -f $path)
    })
    $pInstall.Controls.Add($btnInstallSelected)

    # ---- Secao: Pacote Extra ----
    $pExtra = New-Section "Extra"
    $lblExtra = New-Object System.Windows.Forms.Label
    $lblExtra.Text = "Pacote Extra"; $lblExtra.Font = New-Object System.Drawing.Font("Segoe UI",14,[System.Drawing.FontStyle]::Bold)
    $lblExtra.Location = New-Object System.Drawing.Point(0,0); $lblExtra.AutoSize = $true
    $pExtra.Controls.Add($lblExtra)

    $clbExtra = New-Object System.Windows.Forms.CheckedListBox
    $clbExtra.Location = New-Object System.Drawing.Point(0,40); $clbExtra.Size = New-Object System.Drawing.Size(500,260)
    $clbExtra.CheckOnClick = $true
    $pExtra.Controls.Add($clbExtra)
    function Refresh-ExtraList {
        $clbExtra.Items.Clear()
        foreach ($app in $global:ExtraAppsList) { [void]$clbExtra.Items.Add($app.Name, $false) }
    }
    Refresh-ExtraList

    $btnAddExtra = New-Object System.Windows.Forms.Button
    $btnAddExtra.Text = "Adicionar"; $btnAddExtra.Location = New-Object System.Drawing.Point(0,310)
    $btnAddExtra.Size = New-Object System.Drawing.Size(140,34); $btnAddExtra.BackColor = $global:Theme.Success
    $btnAddExtra.ForeColor = [System.Drawing.Color]::White; $btnAddExtra.FlatStyle = "Flat"
    $btnAddExtra.Add_Click({
        $novo = Show-AddExtraAppDialog
        if ($novo) { [void]$global:ExtraAppsList.Add($novo); Export-ExtraDatabase | Out-Null; Refresh-ExtraList }
    })
    $pExtra.Controls.Add($btnAddExtra)

    $btnInstallExtra = New-Object System.Windows.Forms.Button
    $btnInstallExtra.Text = "Instalar Selecionados"; $btnInstallExtra.Location = New-Object System.Drawing.Point(150,310)
    $btnInstallExtra.Size = New-Object System.Drawing.Size(200,34); $btnInstallExtra.BackColor = $global:Theme.Primary
    $btnInstallExtra.ForeColor = [System.Drawing.Color]::White; $btnInstallExtra.FlatStyle = "Flat"
    $btnInstallExtra.Add_Click({
        if (-not $global:IsAdmin) { Show-Warning "Instalacao requer Administrador. Reabra a ferramenta como Admin."; return }
        $selecionados = @()
        for ($i=0; $i -lt $clbExtra.Items.Count; $i++) { if ($clbExtra.GetItemChecked($i)) { $selecionados += $global:ExtraAppsList[$i] } }
        if ($selecionados.Count -eq 0) { Show-Warning "Selecione ao menos um item."; return }
        $results = @{}
        foreach ($app in $selecionados) { $results[$app.Name] = Install-DirectApp -App $app }
        $path = Export-InstallReport -Results $results -Section "PacoteExtra"
        Show-Info ("Instalacao concluida. Relatorio salvo em:`n{0}" -f $path)
    })
    $pExtra.Controls.Add($btnInstallExtra)

    # ---- Secao: Limpeza ----
    $pClean = New-Section "Limpeza"
    $lblClean = New-Object System.Windows.Forms.Label
    $lblClean.Text = "Limpeza"; $lblClean.Font = New-Object System.Drawing.Font("Segoe UI",14,[System.Drawing.FontStyle]::Bold)
    $lblClean.Location = New-Object System.Drawing.Point(0,0); $lblClean.AutoSize = $true
    $pClean.Controls.Add($lblClean)

    $y = 50
    foreach ($item in @(
        @{Text="Limpar Arquivos Temporarios"; Action={ Invoke-CleanupOperation -IncludeWindowsTemp; Show-Info "Temporarios limpos." }},
        @{Text="Limpar Cache do Windows Update"; Action={ Clear-WindowsUpdateCache }},
        @{Text="Limpar Cache de Geolocalizacao"; Action={ Clear-GeolocationCache }}
    )) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $item.Text; $btn.Location = New-Object System.Drawing.Point(0,$y); $btn.Size = New-Object System.Drawing.Size(280,36)
        $btn.BackColor = $global:Theme.Primary; $btn.ForeColor = [System.Drawing.Color]::White; $btn.FlatStyle = "Flat"
        $btn.Add_Click($item.Action.GetNewClosure())
        $pClean.Controls.Add($btn)
        $y += 46
    }

    # ---- Secao: Rede ----
    $pNet = New-Section "Rede"
    $lblNet = New-Object System.Windows.Forms.Label
    $lblNet.Text = "Ferramentas de Rede"; $lblNet.Font = New-Object System.Drawing.Font("Segoe UI",14,[System.Drawing.FontStyle]::Bold)
    $lblNet.Location = New-Object System.Drawing.Point(0,0); $lblNet.AutoSize = $true
    $pNet.Controls.Add($lblNet)

    $y = 50
    foreach ($acao in @("Flush DNS","Renew IP","Reset Winsock","Ping Google","Teste DNS")) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $acao; $btn.Location = New-Object System.Drawing.Point(0,$y); $btn.Size = New-Object System.Drawing.Size(280,36)
        $btn.BackColor = $global:Theme.Primary; $btn.ForeColor = [System.Drawing.Color]::White; $btn.FlatStyle = "Flat"
        $btn.Tag = $acao
        $btn.Add_Click({ Invoke-NetworkTool -Action $this.Tag }.GetNewClosure())
        $pNet.Controls.Add($btn)
        $y += 46
    }

    # ---- Secao: Impressao ----
    $pPrint = New-Section "Impressao"
    $lblPrint = New-Object System.Windows.Forms.Label
    $lblPrint.Text = "Impressao"; $lblPrint.Font = New-Object System.Drawing.Font("Segoe UI",14,[System.Drawing.FontStyle]::Bold)
    $lblPrint.Location = New-Object System.Drawing.Point(0,0); $lblPrint.AutoSize = $true
    $pPrint.Controls.Add($lblPrint)

    $btnSpooler = New-Object System.Windows.Forms.Button
    $btnSpooler.Text = "Reiniciar Spooler de Impressao"; $btnSpooler.Location = New-Object System.Drawing.Point(0,50)
    $btnSpooler.Size = New-Object System.Drawing.Size(220,36); $btnSpooler.BackColor = $global:Theme.Danger
    $btnSpooler.ForeColor = [System.Drawing.Color]::White; $btnSpooler.FlatStyle = "Flat"
    $btnSpooler.Add_Click({ Reset-PrintSpooler })
    $pPrint.Controls.Add($btnSpooler)

    $lblImpressoras = New-Object System.Windows.Forms.Label
    $lblImpressoras.Text = "Impressoras da Rede"; $lblImpressoras.Font = New-Object System.Drawing.Font("Segoe UI",12,[System.Drawing.FontStyle]::Bold)
    $lblImpressoras.Location = New-Object System.Drawing.Point(0,105); $lblImpressoras.AutoSize = $true
    $pPrint.Controls.Add($lblImpressoras)

    $btnConfigServidor = New-Object System.Windows.Forms.Button
    $btnConfigServidor.Text = "Configurar Servidor"; $btnConfigServidor.Location = New-Object System.Drawing.Point(0,135)
    $btnConfigServidor.Size = New-Object System.Drawing.Size(160,32); $btnConfigServidor.BackColor = $global:Theme.Neutral
    $btnConfigServidor.ForeColor = [System.Drawing.Color]::White; $btnConfigServidor.FlatStyle = "Flat"
    $btnConfigServidor.Add_Click({ Show-ConfigurarServidorDialog })
    $pPrint.Controls.Add($btnConfigServidor)

    $btnEscanear = New-Object System.Windows.Forms.Button
    $btnEscanear.Text = "Escanear Rede"; $btnEscanear.Location = New-Object System.Drawing.Point(170,135)
    $btnEscanear.Size = New-Object System.Drawing.Size(140,32); $btnEscanear.BackColor = $global:Theme.Primary
    $btnEscanear.ForeColor = [System.Drawing.Color]::White; $btnEscanear.FlatStyle = "Flat"
    $pPrint.Controls.Add($btnEscanear)

    $btnExportarImpressoras = New-Object System.Windows.Forms.Button
    $btnExportarImpressoras.Text = "Exportar CSV"; $btnExportarImpressoras.Location = New-Object System.Drawing.Point(320,135)
    $btnExportarImpressoras.Size = New-Object System.Drawing.Size(120,32); $btnExportarImpressoras.BackColor = $global:Theme.Success
    $btnExportarImpressoras.ForeColor = [System.Drawing.Color]::White; $btnExportarImpressoras.FlatStyle = "Flat"
    $btnExportarImpressoras.Add_Click({
        if ($global:PrintersList.Count -eq 0) { Show-Warning "Nenhuma impressora para exportar. Clique em 'Escanear Rede' primeiro."; return }
        $path = Export-PrintersCsv -Printers @($global:PrintersList)
        Show-Info ("CSV exportado em:`n{0}" -f $path)
    })
    $pPrint.Controls.Add($btnExportarImpressoras)

    $lvImpressoras = New-Object System.Windows.Forms.ListView
    $lvImpressoras.View = "Details"; $lvImpressoras.FullRowSelect = $true; $lvImpressoras.GridLines = $true
    $lvImpressoras.Location = New-Object System.Drawing.Point(0,175); $lvImpressoras.Size = New-Object System.Drawing.Size(760,360)
    [void]$lvImpressoras.Columns.Add("Nome",180)
    [void]$lvImpressoras.Columns.Add("IP",100)
    [void]$lvImpressoras.Columns.Add("Modelo",150)
    [void]$lvImpressoras.Columns.Add("Toner",100)
    [void]$lvImpressoras.Columns.Add("Status",70)
    [void]$lvImpressoras.Columns.Add("Paginas",80)
    [void]$lvImpressoras.Columns.Add("Uptime",100)
    $pPrint.Controls.Add($lvImpressoras)

    $btnEscanear.Add_Click({
        $lvImpressoras.Items.Clear()
        $resultado = Get-ImpressorasRede
        $global:PrintersList.Clear()
        foreach ($r in $resultado) { [void]$global:PrintersList.Add($r) }
        foreach ($p in $resultado) {
            $item = New-Object System.Windows.Forms.ListViewItem($p.Nome)
            [void]$item.SubItems.Add([string]$p.IP)
            [void]$item.SubItems.Add([string]$p.Modelo)
            [void]$item.SubItems.Add(($p.Toners -join " "))
            [void]$item.SubItems.Add([string]$p.Status)
            [void]$item.SubItems.Add($(if ($p.PageCount) { [string]$p.PageCount } else { "-" }))
            [void]$item.SubItems.Add([string]$p.Uptime)
            if ($p.Status -eq "Online") { $item.ForeColor = [System.Drawing.Color]::FromArgb(0,120,0) }
            else { $item.ForeColor = $global:Theme.Danger }
            [void]$lvImpressoras.Items.Add($item)
        }
    }.GetNewClosure())

    # ---- Secao: Logs ----
    $pLogs = New-Section "Logs"
    $lblLogs = New-Object System.Windows.Forms.Label
    $lblLogs.Text = "Logs"; $lblLogs.Font = New-Object System.Drawing.Font("Segoe UI",14,[System.Drawing.FontStyle]::Bold)
    $lblLogs.Location = New-Object System.Drawing.Point(0,0); $lblLogs.AutoSize = $true
    $pLogs.Controls.Add($lblLogs)

    $global:LogTextBox = New-Object System.Windows.Forms.TextBox
    $global:LogTextBox.Multiline = $true; $global:LogTextBox.ScrollBars = "Vertical"; $global:LogTextBox.ReadOnly = $true
    $global:LogTextBox.Location = New-Object System.Drawing.Point(0,40); $global:LogTextBox.Size = New-Object System.Drawing.Size(700,450)
    $global:LogTextBox.Font = New-Object System.Drawing.Font("Consolas",9)
    $pLogs.Controls.Add($global:LogTextBox)

    # ---- Sidebar: botoes de navegacao ----
    $secoes = @(
        @{Key="Instalar";  Text="Instalar Aplicativos"}
        @{Key="Extra";     Text="Pacote Extra"}
        @{Key="Limpeza";   Text="Limpeza"}
        @{Key="Rede";      Text="Rede"}
        @{Key="Impressao"; Text="Impressao"}
        @{Key="Logs";      Text="Logs"}
    )
    $y = 20
    foreach ($sec in $secoes) {
        $btn = New-SidebarButton -Text $sec.Text -Y $y
        $btn.Tag = $sec.Key
        $btn.Add_Click({ Show-Section -Key $this.Tag }.GetNewClosure())
        $sidebar.Controls.Add($btn)
        $y += 42
    }

    Show-Section -Key "Instalar"

    $form.Add_Shown({
        Update-Prerequisites
        if (-not $global:IsAdmin) { Set-Status "Rodando sem privilegios de administrador — algumas acoes ficarao bloqueadas." "WARN" }
        else { Set-Status "Pronto." }
        $novaVersao = Test-NewVersionAvailable
        if ($novaVersao) {
            if (Confirm-Action ("Uma nova versao (v{0}) esta disponivel. Deseja abrir a pagina de download?" -f $novaVersao) "Atualizacao disponivel") {
                Start-Process $global:UpdateReleaseUrl
            }
        }
    })

    [void]$form.ShowDialog()
}

# ==============================================================================
# ENTRADA
# ==============================================================================
Initialize-Folders
Initialize-AppDatabase
Initialize-ExtraDatabase
Import-AppDatabase
Import-ExtraDatabase
Update-Prerequisites
Show-MainForm
