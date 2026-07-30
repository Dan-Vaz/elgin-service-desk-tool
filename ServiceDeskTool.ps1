# ==============================================================================
# Elgin Service Desk Tool
# Ferramenta online de instalacao, limpeza, diagnostico e suporte para Windows
# Interface em WPF/XAML — tema escuro moderno.
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
$global:AppVersion    = "2.0"
$global:BasePath      = Join-Path $env:ProgramData "ElginServiceDesk"
$global:ConfigPath    = Join-Path $global:BasePath  "Config"
$global:ReportsPath   = Join-Path $global:BasePath  "Relatorios"
$global:ConfigFile    = Join-Path $global:ConfigPath "apps.json"
$global:ExtraConfigFile   = Join-Path $global:ConfigPath "extra_apps.json"
$global:PrinterConfigFile = Join-Path $global:ConfigPath "printers_config.json"
$global:PrinterCacheFile  = Join-Path $global:BasePath   "printers_cache.json"
$global:LogFile       = Join-Path $global:BasePath   "servicedesk.log"

$global:IsAdmin       = $false
$global:HasWinget     = $false
$global:HasChoco      = $false
$global:HasInternet   = $false
$global:WingetPath    = $null
$global:ChocoPath     = $null
$global:AppsList        = New-Object System.Collections.ArrayList
$global:ExtraAppsList   = New-Object System.Collections.ArrayList
$global:PrintersList     = New-Object System.Collections.ArrayList

$global:StatusLabel  = $null
$global:LogTextBox   = $null
$global:MainWindow   = $null

function Get-Brush { param([string]$Hex) [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex) }

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

# Substitui Application.DoEvents() (que nao existe em WPF): processa a fila de
# mensagens pendentes da UI para manter a janela responsiva durante operacoes longas.
function Invoke-UiPump {
    if ($null -eq [System.Windows.Threading.Dispatcher]::CurrentDispatcher) { return }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
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
        if ($global:LogTextBox -ne $null) {
            $global:LogTextBox.AppendText($line + [Environment]::NewLine)
            $global:LogTextBox.ScrollToEnd()
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
        Write-Log -Message "[ELEVATE] SourceUrl vazia — nao e possivel montar o comando de elevacao." -Level "ERROR"
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
    Invoke-UiPump
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
            Invoke-UiPump
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
            Invoke-UiPump; Start-Sleep -Milliseconds 150
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
        Title="Adicionar ao Pacote Extra" Height="300" Width="480"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="#18181B">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Nome do software:" Foreground="#9CA3AF" Margin="0,0,0,4"/>
        <TextBox x:Name="TxtNome" Grid.Row="1" Height="28" Background="#27272A" Foreground="White" BorderBrush="#3F3F46"/>
        <TextBlock Grid.Row="2" Text="URL de download direto (.exe/.msi):" Foreground="#9CA3AF" Margin="0,14,0,4"/>
        <TextBox x:Name="TxtUrl" Grid.Row="3" Height="28" Background="#27272A" Foreground="White" BorderBrush="#3F3F46"/>
        <CheckBox x:Name="ChkMsi" Grid.Row="4" Content="Arquivo .msi (usa msiexec automaticamente)" Foreground="#E4E4E7" Margin="0,14,0,0"/>
        <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="BtnCancelar" Content="Cancelar" Width="100" Height="34" Margin="0,0,10,0" Background="#3F3F46" Foreground="White" BorderThickness="0"/>
            <Button x:Name="BtnSalvar" Content="Salvar" Width="120" Height="34" Background="#16A34A" Foreground="White" BorderThickness="0" FontWeight="Bold"/>
        </StackPanel>
    </Grid>
</Window>
'@

function Show-AddExtraAppDialog {
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:AddExtraDialogXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow

    $txtNome = $dlg.FindName("TxtNome")
    $txtUrl  = $dlg.FindName("TxtUrl")
    $chkMsi  = $dlg.FindName("ChkMsi")
    $btnSalvar   = $dlg.FindName("BtnSalvar")
    $btnCancelar = $dlg.FindName("BtnCancelar")

    $script:extraDialogResult = $null
    $btnSalvar.Add_Click({
        $n = $txtNome.Text.Trim(); $u = $txtUrl.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($n)) { Show-Warning "Informe o nome."; return }
        if ([string]::IsNullOrWhiteSpace($u) -or $u -notmatch "^https?://") { Show-Warning "Informe uma URL valida (https://)."; return }
        $isMsi = $chkMsi.IsChecked
        $ext   = if ($isMsi) { ".msi" } else { [System.IO.Path]::GetExtension($u) }
        $script:extraDialogResult = [PSCustomObject]@{
            Name=$n; Url=$u; SilentArgs=if($isMsi){@("/qn","/norestart")}else{@()}
            Ext=$ext; IsMSI=$isMsi; TimeoutSeconds=1800; Enabled=$true
        }
        $dlg.DialogResult = $true
        $dlg.Close()
    })
    $btnCancelar.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })
    [void]$dlg.ShowDialog()
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
            Invoke-UiPump
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
# So funciona com a maquina conectada a rede/VPN da empresa.
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

$script:ConfigServidorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Configurar Servidor de Impressao" Height="260" Width="440"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="#18181B">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Nome/IP do servidor de impressao:" Foreground="#9CA3AF" Margin="0,0,0,4"/>
        <TextBox x:Name="TxtServidor" Grid.Row="1" Height="28" Background="#27272A" Foreground="White" BorderBrush="#3F3F46"/>
        <TextBlock Grid.Row="2" Text="Comunidade SNMP:" Foreground="#9CA3AF" Margin="0,14,0,4"/>
        <TextBox x:Name="TxtComunidade" Grid.Row="3" Height="28" Width="200" HorizontalAlignment="Left" Background="#27272A" Foreground="White" BorderBrush="#3F3F46"/>
        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnCancelar" Content="Cancelar" Width="100" Height="34" Margin="0,0,10,0" Background="#3F3F46" Foreground="White" BorderThickness="0"/>
            <Button x:Name="BtnSalvar" Content="Salvar" Width="120" Height="34" Background="#16A34A" Foreground="White" BorderThickness="0" FontWeight="Bold"/>
        </StackPanel>
    </Grid>
</Window>
'@

function Show-ConfigurarServidorDialog {
    $cfg = Get-PrinterConfig
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:ConfigServidorXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow

    $txtServidor   = $dlg.FindName("TxtServidor")
    $txtComunidade = $dlg.FindName("TxtComunidade")
    $txtServidor.Text   = [string]$cfg.ServidorPrint
    $txtComunidade.Text = [string]$cfg.SnmpCommunity

    $dlg.FindName("BtnSalvar").Add_Click({
        Save-PrinterConfig -ServidorPrint $txtServidor.Text.Trim() -SnmpCommunity $txtComunidade.Text.Trim()
        $dlg.DialogResult = $true
        $dlg.Close()
    })
    $dlg.FindName("BtnCancelar").Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })
    [void]$dlg.ShowDialog()
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
                Show-Warning ("Nao foi possivel acessar o servidor de impressao '{0}'.`n`nMostrando o ultimo resultado conhecido (pode estar desatualizado). Confirme se voce esta conectado a rede/VPN da empresa." -f $cfg.ServidorPrint)
                return @($cache)
            } catch {}
        }
        Show-Warning ("Nao foi possivel acessar o servidor de impressao '{0}'.`n`nConfirme se voce esta conectado a rede/VPN da empresa (Configurar Servidor)." -f $cfg.ServidorPrint)
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
        Invoke-UiPump
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

# ==============================================================================
# INTERFACE (WPF) — tema escuro moderno
# ==============================================================================
$script:MainWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Elgin Service Desk Tool" Height="720" Width="1180"
        WindowStartupLocation="CenterScreen" Background="#18181B">
    <Window.Resources>
        <Style x:Key="SidebarButton" TargetType="Button">
            <Setter Property="Height" Value="44"/>
            <Setter Property="Margin" Value="0,0,0,4"/>
            <Setter Property="Foreground" Value="#9CA3AF"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding" Value="22,0,0,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="#219AF9" BorderThickness="{TemplateBinding Tag}">
                            <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#232326"/></Trigger>
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

        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#1E1E1E"/>
            <Setter Property="Foreground" Value="#9CA3AF"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#E4E4E7"/>
            <Setter Property="Margin" Value="0,0,0,10"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="220"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Border Grid.Column="0" Background="#1c1c1e" BorderBrush="#2A2A2A" BorderThickness="0,0,1,0">
            <DockPanel>
                <StackPanel DockPanel.Dock="Top" Margin="22,26,0,20">
                    <TextBlock Text="Elgin" Foreground="White" FontSize="20" FontWeight="Bold"/>
                    <TextBlock Text="Service Desk Tool" Foreground="#6B7280" FontSize="12"/>
                </StackPanel>
                <StackPanel DockPanel.Dock="Top" Margin="0,10,0,0">
                    <Button x:Name="NavInstalar"  Content="Instalar Aplicativos" Style="{StaticResource SidebarButton}" Background="#232326" Foreground="White" Tag="3,0,0,0"/>
                    <Button x:Name="NavExtra"     Content="Pacote Extra"        Style="{StaticResource SidebarButton}" Tag="0"/>
                    <Button x:Name="NavLimpeza"   Content="Limpeza"             Style="{StaticResource SidebarButton}" Tag="0"/>
                    <Button x:Name="NavRede"      Content="Rede"                Style="{StaticResource SidebarButton}" Tag="0"/>
                    <Button x:Name="NavImpressao" Content="Impressao"           Style="{StaticResource SidebarButton}" Tag="0"/>
                    <Button x:Name="NavLogs"      Content="Logs"                Style="{StaticResource SidebarButton}" Tag="0"/>
                </StackPanel>
            </DockPanel>
        </Border>

        <Grid Grid.Column="1">
            <Grid.RowDefinitions>
                <RowDefinition Height="*"/>
                <RowDefinition Height="34"/>
            </Grid.RowDefinitions>

            <Grid Grid.Row="0" Margin="30">
                <!-- Instalar Aplicativos -->
                <Grid x:Name="PanelInstalar">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Instalar Aplicativos" Foreground="White" FontSize="22" FontWeight="Bold" Margin="0,0,0,16"/>
                    <ScrollViewer Grid.Row="1"><StackPanel x:Name="SpAppsList"/></ScrollViewer>
                    <Button Grid.Row="2" x:Name="BtnInstalarSelecionados" Content="Instalar Selecionados" Width="220" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="#219AF9" Margin="0,16,0,0"/>
                </Grid>

                <!-- Pacote Extra -->
                <Grid x:Name="PanelExtra" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Pacote Extra" Foreground="White" FontSize="22" FontWeight="Bold" Margin="0,0,0,16"/>
                    <ScrollViewer Grid.Row="1"><StackPanel x:Name="SpExtraList"/></ScrollViewer>
                    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,16,0,0">
                        <Button x:Name="BtnAdicionarExtra" Content="Adicionar" Width="140" Style="{StaticResource CardButton}" Background="#16A34A" Margin="0,0,10,0"/>
                        <Button x:Name="BtnInstalarExtra" Content="Instalar Selecionados" Width="220" Style="{StaticResource CardButton}" Background="#219AF9"/>
                    </StackPanel>
                </Grid>

                <!-- Limpeza -->
                <StackPanel x:Name="PanelLimpeza" Visibility="Collapsed">
                    <TextBlock Text="Limpeza" Foreground="White" FontSize="22" FontWeight="Bold" Margin="0,0,0,16"/>
                    <Button x:Name="BtnLimparTemp"    Content="Limpar Arquivos Temporarios"  Width="300" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="#219AF9" Margin="0,0,0,10"/>
                    <Button x:Name="BtnLimparWU"      Content="Limpar Cache do Windows Update" Width="300" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="#219AF9" Margin="0,0,0,10"/>
                    <Button x:Name="BtnLimparGeo"     Content="Limpar Cache de Geolocalizacao" Width="300" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="#219AF9"/>
                </StackPanel>

                <!-- Rede -->
                <StackPanel x:Name="PanelRede" Visibility="Collapsed">
                    <TextBlock Text="Ferramentas de Rede" Foreground="White" FontSize="22" FontWeight="Bold" Margin="0,0,0,16"/>
                    <Button x:Name="BtnFlushDns"  Content="Flush DNS"     Width="300" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="#219AF9" Margin="0,0,0,10"/>
                    <Button x:Name="BtnRenewIp"   Content="Renew IP"      Width="300" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="#219AF9" Margin="0,0,0,10"/>
                    <Button x:Name="BtnWinsock"   Content="Reset Winsock" Width="300" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="#219AF9" Margin="0,0,0,10"/>
                    <Button x:Name="BtnPingGoogle" Content="Ping Google"  Width="300" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="#219AF9" Margin="0,0,0,10"/>
                    <Button x:Name="BtnTesteDns"  Content="Teste DNS"     Width="300" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="#219AF9"/>
                </StackPanel>

                <!-- Impressao -->
                <Grid x:Name="PanelImpressao" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Impressao" Foreground="White" FontSize="22" FontWeight="Bold" Margin="0,0,0,16"/>
                    <Button Grid.Row="1" x:Name="BtnSpooler" Content="Reiniciar Spooler de Impressao" Width="260" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="#EF4444" Margin="0,0,0,20"/>
                    <TextBlock Grid.Row="2" Text="Impressoras da Rede" Foreground="White" FontSize="16" FontWeight="Bold" Margin="0,0,0,10"/>
                    <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,0,0,14">
                        <Button x:Name="BtnConfigServidor" Content="Configurar Servidor" Width="160" Style="{StaticResource CardButton}" Background="#3F3F46" Margin="0,0,10,0"/>
                        <Button x:Name="BtnEscanear"       Content="Escanear Rede"       Width="140" Style="{StaticResource CardButton}" Background="#219AF9" Margin="0,0,10,0"/>
                        <Button x:Name="BtnExportarCsv"    Content="Exportar CSV"        Width="130" Style="{StaticResource CardButton}" Background="#16A34A"/>
                    </StackPanel>
                    <DataGrid Grid.Row="4" x:Name="DgImpressoras" AutoGenerateColumns="False" IsReadOnly="True"
                              Background="#2A2A2A" Foreground="White" BorderThickness="0" HeadersVisibility="Column"
                              RowBackground="#2A2A2A" AlternatingRowBackground="#252525" GridLinesVisibility="None" RowHeight="36">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="NOME" Binding="{Binding Nome}" Width="2*"/>
                            <DataGridTextColumn Header="IP" Binding="{Binding IP}" Width="1*"/>
                            <DataGridTextColumn Header="MODELO" Binding="{Binding Modelo}" Width="2*"/>
                            <DataGridTextColumn Header="TONER" Binding="{Binding Toner}" Width="1*"/>
                            <DataGridTextColumn Header="STATUS" Binding="{Binding Status}" Width="1*"/>
                            <DataGridTextColumn Header="PAGINAS" Binding="{Binding PageCount}" Width="1*"/>
                            <DataGridTextColumn Header="UPTIME" Binding="{Binding Uptime}" Width="1.3*"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </Grid>

                <!-- Logs -->
                <Grid x:Name="PanelLogs" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Logs" Foreground="White" FontSize="22" FontWeight="Bold" Margin="0,0,0,16"/>
                    <TextBox Grid.Row="1" x:Name="TxtLogs" Background="#1E1E1E" Foreground="#E4E4E7" FontFamily="Consolas" FontSize="12"
                             IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
                </Grid>
            </Grid>

            <Border Grid.Row="1" Background="#1c1c1e">
                <TextBlock x:Name="TxtStatus" Text="Pronto." Foreground="#9CA3AF" FontSize="12" VerticalAlignment="Center" Margin="16,0"/>
            </Border>
        </Grid>
    </Grid>
</Window>
'@

function Show-MainWindow {
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:MainWindowXaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    $global:MainWindow = $window
    $global:StatusLabel = $window.FindName("TxtStatus")
    $global:LogTextBox  = $window.FindName("TxtLogs")

    $panels = @{
        Instalar  = $window.FindName("PanelInstalar")
        Extra     = $window.FindName("PanelExtra")
        Limpeza   = $window.FindName("PanelLimpeza")
        Rede      = $window.FindName("PanelRede")
        Impressao = $window.FindName("PanelImpressao")
        Logs      = $window.FindName("PanelLogs")
    }
    $navButtons = @{
        Instalar  = $window.FindName("NavInstalar")
        Extra     = $window.FindName("NavExtra")
        Limpeza   = $window.FindName("NavLimpeza")
        Rede      = $window.FindName("NavRede")
        Impressao = $window.FindName("NavImpressao")
        Logs      = $window.FindName("NavLogs")
    }
    function Show-Section {
        param([string]$Key)
        foreach ($k in $panels.Keys) {
            $panels[$k].Visibility = if ($k -eq $Key) { "Visible" } else { "Collapsed" }
            $navButtons[$k].Background = if ($k -eq $Key) { Get-Brush "#232326" } else { Get-Brush "Transparent" }
            $navButtons[$k].Foreground = if ($k -eq $Key) { Get-Brush "White" } else { Get-Brush "#9CA3AF" }
            $navButtons[$k].Tag = if ($k -eq $Key) { "3,0,0,0" } else { "0" }
        }
    }
    foreach ($key in $navButtons.Keys) {
        $navButtons[$key].Add_Click({ Show-Section -Key $this.Content }.GetNewClosure())
    }
    # Corrige o Tag usado no clique (usa o texto do botao como chave amigavel -> mapeia para a chave real)
    $navKeyByContent = @{
        "Instalar Aplicativos"="Instalar"; "Pacote Extra"="Extra"; "Limpeza"="Limpeza"
        "Rede"="Rede"; "Impressao"="Impressao"; "Logs"="Logs"
    }
    foreach ($key in $navButtons.Keys) {
        $navButtons[$key].Add_Click({ Show-Section -Key $navKeyByContent[$this.Content] }.GetNewClosure()) 2>$null
    }

    # ---- Instalar Aplicativos: lista dinamica de checkboxes ----
    $spApps = $window.FindName("SpAppsList")
    $appCheckboxes = @()
    foreach ($app in $global:AppsList) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $app.Name
        $cb.Tag = $app
        [void]$spApps.Children.Add($cb)
        $appCheckboxes += $cb
    }
    $window.FindName("BtnInstalarSelecionados").Add_Click({
        if (-not $global:IsAdmin) { Show-Warning "Instalacao requer Administrador. Reabra a ferramenta como Admin."; return }
        $selecionados = @($appCheckboxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if ($selecionados.Count -eq 0) { Show-Warning "Selecione ao menos um aplicativo."; return }
        $results = @{}
        foreach ($app in $selecionados) { $results[$app.Name] = Install-OnlineApp -App $app }
        $path = Export-InstallReport -Results $results -Section "Instalacao"
        Show-Info ("Instalacao concluida. Relatorio salvo em:`n{0}" -f $path)
    }.GetNewClosure())

    # ---- Pacote Extra ----
    $spExtra = $window.FindName("SpExtraList")
    $script:extraCheckboxes = @()
    function Refresh-ExtraList {
        $spExtra.Children.Clear()
        $script:extraCheckboxes = @()
        foreach ($app in $global:ExtraAppsList) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $app.Name
            $cb.Tag = $app
            [void]$spExtra.Children.Add($cb)
            $script:extraCheckboxes += $cb
        }
    }
    Refresh-ExtraList
    $window.FindName("BtnAdicionarExtra").Add_Click({
        $novo = Show-AddExtraAppDialog
        if ($novo) { [void]$global:ExtraAppsList.Add($novo); Export-ExtraDatabase | Out-Null; Refresh-ExtraList }
    })
    $window.FindName("BtnInstalarExtra").Add_Click({
        if (-not $global:IsAdmin) { Show-Warning "Instalacao requer Administrador. Reabra a ferramenta como Admin."; return }
        $selecionados = @($script:extraCheckboxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if ($selecionados.Count -eq 0) { Show-Warning "Selecione ao menos um item."; return }
        $results = @{}
        foreach ($app in $selecionados) { $results[$app.Name] = Install-DirectApp -App $app }
        $path = Export-InstallReport -Results $results -Section "PacoteExtra"
        Show-Info ("Instalacao concluida. Relatorio salvo em:`n{0}" -f $path)
    })

    # ---- Limpeza ----
    $window.FindName("BtnLimparTemp").Add_Click({ Invoke-CleanupOperation -IncludeWindowsTemp; Show-Info "Temporarios limpos." })
    $window.FindName("BtnLimparWU").Add_Click({ Clear-WindowsUpdateCache })
    $window.FindName("BtnLimparGeo").Add_Click({ Clear-GeolocationCache })

    # ---- Rede ----
    $window.FindName("BtnFlushDns").Add_Click({ Invoke-NetworkTool -Action "Flush DNS" })
    $window.FindName("BtnRenewIp").Add_Click({ Invoke-NetworkTool -Action "Renew IP" })
    $window.FindName("BtnWinsock").Add_Click({ Invoke-NetworkTool -Action "Reset Winsock" })
    $window.FindName("BtnPingGoogle").Add_Click({ Invoke-NetworkTool -Action "Ping Google" })
    $window.FindName("BtnTesteDns").Add_Click({ Invoke-NetworkTool -Action "Teste DNS" })

    # ---- Impressao ----
    $window.FindName("BtnSpooler").Add_Click({ Reset-PrintSpooler })
    $window.FindName("BtnConfigServidor").Add_Click({ Show-ConfigurarServidorDialog })
    $dgImpressoras = $window.FindName("DgImpressoras")
    $window.FindName("BtnEscanear").Add_Click({
        $resultado = Get-ImpressorasRede
        $global:PrintersList.Clear()
        foreach ($r in $resultado) { [void]$global:PrintersList.Add($r) }
        $dgImpressoras.ItemsSource = @($resultado)
    }.GetNewClosure())
    $window.FindName("BtnExportarCsv").Add_Click({
        if ($global:PrintersList.Count -eq 0) { Show-Warning "Nenhuma impressora para exportar. Clique em 'Escanear Rede' primeiro."; return }
        $path = Export-PrintersCsv -Printers @($global:PrintersList)
        Show-Info ("CSV exportado em:`n{0}" -f $path)
    })

    Show-Section -Key "Instalar"

    $window.Add_ContentRendered({
        Update-Prerequisites
        if (-not $global:IsAdmin) { Set-Status "Rodando sem privilegios de administrador — algumas acoes ficarao bloqueadas." "WARN" }
        else { Set-Status "Pronto." }
    })

    [void]$window.ShowDialog()
}

# ==============================================================================
# ENTRADA
# ==============================================================================
Initialize-AppDatabase
Initialize-ExtraDatabase
Import-AppDatabase
Import-ExtraDatabase
Update-Prerequisites
Show-MainWindow
