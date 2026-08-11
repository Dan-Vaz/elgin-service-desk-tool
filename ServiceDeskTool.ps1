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
# Evita que qualquer cmdlet (Remove-Item em pasta com filhos, etc.) pare
# esperando confirmacao interativa no console - a app e single-thread e
# uma confirmacao pendente trava a janela WPF inteira sem aviso visivel.
$ConfirmPreference     = "None"

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
$global:AppVersion    = "3.19"
$global:SchemaVersion = 5
$global:ExtraSchemaVersion = 6
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

# O pacote "AnyDesk.AnyDesk" do winget falha com frequencia com "Installer
# hash does not match" - o instalador oficial (download.anydesk.com/AnyDesk.exe)
# e auto-atualizavel e o hash muda antes do manifesto do winget-pkgs ser
# atualizado. Por isso o AnyDesk usa download direto (mesmo padrao do Chrome),
# nao winget/choco. A senha de acesso nao supervisionado e definida via
# "AnyDesk.exe --set-password" com a senha passada por STDIN (nunca como
# argumento de linha de comando - e assim que a AnyDesk documenta, evita a
# senha aparecer em texto puro no Gerenciador de Tarefas/Process Explorer).
$global:AnyDeskDownloadUrl        = "https://download.anydesk.com/AnyDesk.exe"
$global:AnyDeskUnattendedPassword = '$uP0rt&__22'

# Desinstalador oficial do Bitdefender GravityZone (BEST Uninstall Tool).
$global:BitdefenderUninstallUrl  = "https://github.com/Dan-Vaz/elgin-service-desk-tool/releases/download/v1.0.0/BEST_uninstallTool.exe"
$global:BitdefenderUninstallArgs = @("/bdparams","/passbase64=RnI2OFMmcjhURiZQUWpieQ==","/noWait")

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

# Deploy Remoto - credencial fica so em memoria (PSCredential), nunca gravada
# em disco. Alvos ficam numa lista em memoria tambem (nao persistida - lista
# de maquinas muda a cada visita, nao faz sentido guardar entre sessoes).
$global:DeployCredential = $null
$global:DeployTargets    = New-Object System.Collections.ArrayList

# Aba protegida por senha - so guarda o HASH (SHA256), nunca a senha em
# texto puro (o repositorio deste script e publico no GitHub, entao a senha
# em claro no codigo-fonte nao protegeria nada de verdade contra alguem
# tecnico o suficiente pra ler o .ps1 - isto e so pra afastar acesso casual
# de quem nao deveria estar mexendo nessa aba, nao e seguranca forte).
# $global:DeployUnlocked comeca falso a cada abertura da ferramenta - pede a
# senha de novo toda vez, nao fica destravado entre sessoes.
$global:DeployPasswordHash = "a786954532024fa57cebf6ebd6f8cfeeac00d40167bba4f7a34941fb71c1a3cd"
$global:DeployUnlocked     = $false

# Apps personalizados do Deploy Remoto (Nome/Url/Params digitados pelo
# tecnico) - substituem a dependencia do Pacote Extra nesta aba. Persistidos
# em deploy_apps.json (arquivo local, nao vai no git/gist).
$global:DeployCustomAppsFile = Join-Path $global:ConfigPath "deploy_apps.json"
$global:DeployCustomApps     = New-Object System.Collections.ArrayList

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
    param([Parameter(Mandatory=$true)][string]$FilePath,[string[]]$Arguments=@(),[string]$Description="Processo",[int]$TimeoutSeconds=0,[string]$BusyText="")
    $argLine = ConvertTo-ProcessArgumentString -Arguments $Arguments
    Write-Log -Message ("{0}: {1} {2}" -f $Description,$FilePath,$argLine)
    $proc = $null
    $sub  = $null
    try {
        $quote=[char]34
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $env:ComSpec
        # Roda atraves do cmd.exe com 2>&1 para mesclar stderr em stdout num
        # unico pipe - evita o deadlock classico de redirecionamento (ler um
        # stream ate o fim enquanto o outro, ainda nao lido, enche o buffer e
        # trava o processo filho).
        $psi.Arguments              = "/d /s /c "+$quote+$quote+$FilePath+$quote+" "+$argLine+" 2>&1"+$quote
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $false
        $psi.CreateNoWindow         = $true
        $psi.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        # Leitura ASSINCRONA (BeginOutputReadLine + evento), nao mais
        # ReadToEnd() sincrono - isso e o que permite esperar o processo via
        # Wait-ProcessResponsive (ShowDialog + DispatcherTimer) sem travar a
        # UI. -MessageData passa o StringBuilder pro handler do evento de
        # forma confiavel (testado: capturei corretamente saida incremental
        # de um processo real dentro do wait responsivo antes de aplicar
        # aqui). CreateNoWindow=true ja evita qualquer risco de deadlock por
        # buffer cheio, mas a leitura assincrona e mais correta de qualquer
        # forma.
        $sb = New-Object System.Text.StringBuilder
        $onData = { if ($EventArgs.Data -ne $null) { [void]$Event.MessageData.AppendLine($EventArgs.Data) } }
        [void]$proc.Start()
        $sub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $onData -MessageData $sb
        $proc.BeginOutputReadLine()

        $busyTxt = if ($BusyText) { $BusyText } else { $Description }
        $timedOut = Wait-ProcessResponsive -Process $proc -TimeoutSeconds $TimeoutSeconds -BusyText $busyTxt

        if ($timedOut) {
            try{$proc.Kill()}catch{}
            return [PSCustomObject]@{ExitCode=-999;Output=$sb.ToString();Error=("Timeout apos {0}s" -f $TimeoutSeconds)}
        }

        $exit   = try { $proc.ExitCode } catch { -1 }
        $output = $sb.ToString()
        if ($output -and $output.Trim()) { Write-Log -Message $output.Trim() }
        return [PSCustomObject]@{ExitCode=$exit;Output=$output;Error=""}
    } catch {
        Write-Log -Message ("Falha em {0}: {1}" -f $Description,$_.Exception.Message) -Level "ERROR"
        return [PSCustomObject]@{ExitCode=-1;Output="";Error=$_.Exception.Message}
    } finally {
        if ($sub -ne $null) { try { Unregister-Event -SourceIdentifier $sub.Name -ErrorAction SilentlyContinue; Remove-Job -Id $sub.Id -Force -ErrorAction SilentlyContinue } catch {} }
        if ($proc -ne $null) { try { $proc.Dispose() } catch {} }
    }
}

# Espera um processo terminar SEM travar a janela principal e sem precisar
# de runspace/thread separada (ver notas do projeto: uma chamada nativa
# bloqueante presa numa runspace nao pode ser interrompida de forma
# confiavel, so um processo filho de verdade pode - aqui so esperamos ele).
# Mostra o overlay de "carregando" via ShowDialog (nao Show): um dialogo
# modal com Owner definido automaticamente desabilita a janela principal
# e bombeia a fila de mensagens da UI sozinho enquanto espera, entao a
# janela nao fica "Nao Responde" e nao precisa de pump manual.
# $state e um Hashtable (nao uma variavel escalar) de proposito: dentro do
# Add_Tick (.GetNewClosure()) reatribuir uma variavel local nao propaga de
# volta pro escopo de fora (mesma armadilha documentada de variaveis locais
# dentro de closures), mas MUTAR uma propriedade de um objeto capturado
# funciona porque a referencia ao objeto e a mesma.
function Wait-ProcessResponsive {
    param([Parameter(Mandatory=$true)]$Process,[int]$TimeoutSeconds=1800,[string]$BusyText="Executando...")
    $overlay = $null
    try {
        $overlayReader = [System.Xml.XmlNodeReader]::new([xml]$global:LoadingOverlayXaml)
        $overlay = [System.Windows.Markup.XamlReader]::Load($overlayReader)
        $overlay.Owner = $global:MainWindow
        Set-DialogTheme -Dialog $overlay
        $overlay.FindName("TxtLoadingStatus").Text = $BusyText
    } catch { $overlay = $null }

    $state = @{ TimedOut = $false }
    if ($overlay -ne $null) {
        $start = Get-Date
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(300)
        $timer.Add_Tick({
            if ($Process.HasExited) {
                $timer.Stop(); $overlay.Close()
            } elseif ($TimeoutSeconds -gt 0 -and ((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
                $timer.Stop()
                try { $Process.Kill() } catch {}
                $state.TimedOut = $true
                $overlay.Close()
            }
        }.GetNewClosure())
        $timer.Start()
        [void]$overlay.ShowDialog()
    } else {
        # Overlay falhou ao carregar - ainda assim nao trava: pump manual
        # da fila de mensagens da UI entre cada verificacao.
        $start = Get-Date
        while (-not $Process.HasExited) {
            Start-Sleep -Milliseconds 200
            if ($global:MainWindow -ne $null) { $global:MainWindow.Dispatcher.Invoke([System.Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) }
            if ($TimeoutSeconds -gt 0 -and ((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
                try { $Process.Kill() } catch {}
                $state.TimedOut = $true
                break
            }
        }
    }
    if (-not $Process.HasExited) { try { $Process.WaitForExit(2000) } catch {} }
    return [bool]$state.TimedOut
}

# Mesmo padrao do Wait-ProcessResponsive acima, mas pra um array de PowerShell
# Jobs (usado pelo Deploy Remoto: Invoke-Command bloqueia a thread que chama
# sem nenhum jeito de fazer polling nativo tipo Process.HasExited, entao cada
# maquina alvo roda como um Job em segundo plano e este wait so faz o polling
# de .State via DispatcherTimer). Mostra quantos jobs ja terminaram no texto
# do overlay - todos os jobs continuam rodando em paralelo por baixo.
function Wait-JobsResponsive {
    param([Parameter(Mandatory=$true)][array]$Jobs,[int]$TimeoutSeconds=900,[string]$BusyTextPrefix="Executando")
    $overlay = $null
    $txtStatus = $null
    try {
        $overlayReader = [System.Xml.XmlNodeReader]::new([xml]$global:LoadingOverlayXaml)
        $overlay = [System.Windows.Markup.XamlReader]::Load($overlayReader)
        $overlay.Owner = $global:MainWindow
        Set-DialogTheme -Dialog $overlay
        $txtStatus = $overlay.FindName("TxtLoadingStatus")
    } catch { $overlay = $null }

    $state = @{ TimedOut = $false }
    $total = $Jobs.Count
    if ($overlay -ne $null) {
        $start = Get-Date
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(400)
        $timer.Add_Tick({
            $done = @($Jobs | Where-Object { $_.State -ne 'Running' -and $_.State -ne 'NotStarted' }).Count
            if ($txtStatus -ne $null) { $txtStatus.Text = "{0}... ({1}/{2} concluidas)" -f $BusyTextPrefix,$done,$total }
            if ($done -ge $total) {
                $timer.Stop(); $overlay.Close()
            } elseif ($TimeoutSeconds -gt 0 -and ((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
                $timer.Stop()
                foreach ($j in $Jobs) { try { Stop-Job $j -ErrorAction SilentlyContinue } catch {} }
                $state.TimedOut = $true
                $overlay.Close()
            }
        }.GetNewClosure())
        $timer.Start()
        [void]$overlay.ShowDialog()
    } else {
        # Overlay falhou ao carregar - ainda assim nao trava: pump manual
        # da fila de mensagens da UI entre cada verificacao.
        $start = Get-Date
        while (@($Jobs | Where-Object { $_.State -eq 'Running' -or $_.State -eq 'NotStarted' }).Count -gt 0) {
            Start-Sleep -Milliseconds 300
            if ($global:MainWindow -ne $null) { $global:MainWindow.Dispatcher.Invoke([System.Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) }
            if ($TimeoutSeconds -gt 0 -and ((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
                foreach ($j in $Jobs) { try { Stop-Job $j -ErrorAction SilentlyContinue } catch {} }
                $state.TimedOut = $true
                break
            }
        }
    }
    return [bool]$state.TimedOut
}

# Roda um comando num console DE VERDADE, visivel (nao oculto/redirecionado)
# - o usuario ve o progresso nativo (ex.: percentual do SFC) em vez de so um
# overlay generico. Sem captura de output (uma janela visivel nao pode ser
# lida como texto sem redirecionar, o que esconderia a janela de novo) -
# quem chamar depende so do ExitCode. A janela fica alguns segundos aberta
# no final (timeout /t) pra dar tempo de ler a ultima mensagem antes de
# fechar sozinha.
function Invoke-VisibleConsoleCommand {
    param([Parameter(Mandatory=$true)][string]$CommandLine,[string]$Description="Comando",[int]$TimeoutSeconds=1800,[string]$BusyText="Executando...")
    Write-Log -Message ("{0}: {1}" -f $Description,$CommandLine)
    $proc = $null
    try {
        $quote = [char]34
        # set captura o ERRORLEVEL do comando original ANTES dos comandos
        # decorativos do final (senao o codigo de saida devolvido seria o do
        # 'timeout' cosmetico, nao o do comando que o usuario pediu) - e
        # "exit /b" no final reaplica esse valor como saida do cmd.exe
        # inteiro. Usa !VAR! (expansao adiada, ligada via /V:ON) em vez de
        # %VAR% porque numa linha /c unica o cmd.exe expande todo %VAR%
        # de uma vez, ANTES de qualquer comando da cadeia rodar - "%ELGIN_EL%"
        # ficaria vazio mesmo depois do "set" (testado e confirmado). Caminho
        # completo do timeout.exe (nao so "timeout") pra nao depender da
        # ordem do PATH.
        $tail  = " & set ELGIN_EL=!ERRORLEVEL! & echo. & echo ============================== & echo Concluido - esta janela fecha sozinha em alguns segundos... & "+$quote+(Join-Path $env:WINDIR "System32\timeout.exe")+$quote+" /t 5 /nobreak>nul & exit /b !ELGIN_EL!"
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $env:ComSpec
        $psi.Arguments       = "/d /s /v:on /c "+$quote+$CommandLine+$tail+$quote
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $false
        $psi.WindowStyle     = [System.Diagnostics.ProcessWindowStyle]::Normal
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
    } catch {
        Write-Log -Message ("Falha em {0}: {1}" -f $Description,$_.Exception.Message) -Level "ERROR"
        return [PSCustomObject]@{ExitCode=-1;Error=$_.Exception.Message;TimedOut=$false}
    }
    try {
        $timedOut = Wait-ProcessResponsive -Process $proc -TimeoutSeconds $TimeoutSeconds -BusyText $BusyText
        $exit = try { $proc.ExitCode } catch { -1 }
        if ($timedOut) {
            Write-Log -Message ("{0}: timeout apos {1}s" -f $Description,$TimeoutSeconds) -Level "ERROR"
            return [PSCustomObject]@{ExitCode=-999;Error=("Timeout apos {0}s" -f $TimeoutSeconds);TimedOut=$true}
        }
        Write-Log -Message ("{0}: concluido, codigo de saida {1}" -f $Description,$exit) -Level "SUCCESS"
        return [PSCustomObject]@{ExitCode=$exit;Error="";TimedOut=$false}
    } finally { if ($proc -ne $null) { try { $proc.Dispose() } catch {} } }
}

function Invoke-ConsoleCommand {
    param([Parameter(Mandatory=$true)][string]$CommandLine,[string]$Description="Comando",[int]$TimeoutSeconds=45,[string]$BusyText="")
    Write-Log -Message ("{0}: {1}" -f $Description,$CommandLine)
    $proc = $null
    $sub  = $null
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

        # Mesmo padrao aplicado em Invoke-ManagedProcess: leitura assincrona
        # (nao ReadToEnd sincrono) + Wait-ProcessResponsive, pra qualquer
        # comando via console (Rede, Diagnostico, Maximo Desempenho, etc.)
        # nao travar a janela principal.
        $sb = New-Object System.Text.StringBuilder
        $onData = { if ($EventArgs.Data -ne $null) { [void]$Event.MessageData.AppendLine($EventArgs.Data) } }
        [void]$proc.Start()
        $sub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $onData -MessageData $sb
        $proc.BeginOutputReadLine()

        $busyTxt = if ($BusyText) { $BusyText } else { $Description }
        $timedOut = Wait-ProcessResponsive -Process $proc -TimeoutSeconds $TimeoutSeconds -BusyText $busyTxt

        if ($timedOut) {
            try{$proc.Kill()}catch{}
            return [PSCustomObject]@{ExitCode=-999;Output=$sb.ToString();Error=("Timeout apos {0}s" -f $TimeoutSeconds)}
        }
        $exit   = try{$proc.ExitCode}catch{-1}
        $output = $sb.ToString()
        if ($output) { Write-Log -Message $output.Trim() }
        return [PSCustomObject]@{ExitCode=$exit;Output=$output;Error=""}
    } catch {
        Write-Log -Message ("Falha em {0}: {1}" -f $Description,$_.Exception.Message) -Level "ERROR"
        return [PSCustomObject]@{ExitCode=-1;Output="";Error=$_.Exception.Message}
    } finally {
        if ($sub -ne $null) { try { Unregister-Event -SourceIdentifier $sub.Name -ErrorAction SilentlyContinue; Remove-Job -Id $sub.Id -Force -ErrorAction SilentlyContinue } catch {} }
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
    <SolidColorBrush x:Key="BrushWindowBg"    Color="#F5F5F9"/>
    <SolidColorBrush x:Key="BrushSidebarBg"   Color="#FFFFFF"/>
    <SolidColorBrush x:Key="BrushSidebarBrd"  Color="#E7E7F0"/>
    <SolidColorBrush x:Key="BrushSurface"     Color="#FFFFFF"/>
    <SolidColorBrush x:Key="BrushSurfaceAlt"  Color="#F7F7FB"/>
    <SolidColorBrush x:Key="BrushBorder"      Color="#E7E7F0"/>
    <SolidColorBrush x:Key="BrushText"        Color="#1B1C29"/>
    <SolidColorBrush x:Key="BrushTextMuted"   Color="#6B6F82"/>
    <SolidColorBrush x:Key="BrushTextFaint"   Color="#9296A8"/>
    <SolidColorBrush x:Key="BrushAccent"      Color="#7C6FFA"/>
    <SolidColorBrush x:Key="BrushAccentHover" Color="#6C5CE7"/>
    <SolidColorBrush x:Key="BrushSuccess"     Color="#16A34A"/>
    <SolidColorBrush x:Key="BrushDanger"      Color="#DC2626"/>
    <SolidColorBrush x:Key="BrushWarning"     Color="#D97706"/>
    <SolidColorBrush x:Key="BrushTopBarBg"    Color="#FFFFFF"/>
    <SolidColorBrush x:Key="BrushStatusBarBg" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="BrushHover"       Color="#F5F5F9"/>
    <SolidColorBrush x:Key="BrushActiveNav"   Color="#EEEBFF"/>
    <SolidColorBrush x:Key="BrushInputBg"     Color="#F7F7FB"/>
    <SolidColorBrush x:Key="BrushInputBorder" Color="#DCDCE6"/>
</ResourceDictionary>
'@
    }
    return @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <SolidColorBrush x:Key="BrushWindowBg"    Color="#0A0A0F"/>
    <SolidColorBrush x:Key="BrushSidebarBg"   Color="#0D0E14"/>
    <SolidColorBrush x:Key="BrushSidebarBrd"  Color="#1E1F2E"/>
    <SolidColorBrush x:Key="BrushSurface"     Color="#14151F"/>
    <SolidColorBrush x:Key="BrushSurfaceAlt"  Color="#0F1017"/>
    <SolidColorBrush x:Key="BrushBorder"      Color="#23242F"/>
    <SolidColorBrush x:Key="BrushText"        Color="#F4F4F6"/>
    <SolidColorBrush x:Key="BrushTextMuted"   Color="#9296A8"/>
    <SolidColorBrush x:Key="BrushTextFaint"   Color="#6B6F82"/>
    <SolidColorBrush x:Key="BrushAccent"      Color="#7C6FFA"/>
    <SolidColorBrush x:Key="BrushAccentHover" Color="#8F84FF"/>
    <SolidColorBrush x:Key="BrushSuccess"     Color="#22C55E"/>
    <SolidColorBrush x:Key="BrushDanger"      Color="#EF4444"/>
    <SolidColorBrush x:Key="BrushWarning"     Color="#F59E0B"/>
    <SolidColorBrush x:Key="BrushTopBarBg"    Color="#0D0E14"/>
    <SolidColorBrush x:Key="BrushStatusBarBg" Color="#0D0E14"/>
    <SolidColorBrush x:Key="BrushHover"       Color="#1A1B26"/>
    <SolidColorBrush x:Key="BrushActiveNav"   Color="#1E1D33"/>
    <SolidColorBrush x:Key="BrushInputBg"     Color="#0F1017"/>
    <SolidColorBrush x:Key="BrushInputBorder" Color="#23242F"/>
</ResourceDictionary>
'@
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
    # Start-Process -ArgumentList NAO coloca aspas em elementos com espaco
    # (testado: um caminho com espaco vira varios argumentos soltos pro
    # instalador, que ai ignora "--install" silenciosamente) - as aspas
    # tem que vir escritas dentro do proprio elemento do array.
    $q = [char]34
    $anyDeskDir = $q + (Join-Path ${env:ProgramFiles(x86)} "AnyDesk") + $q
    return @(
        [PSCustomObject]@{Name="AnyDesk"; Winget=""; Choco=""; Scope=""; TimeoutSeconds=600; Enabled=$true; Special="AnyDeskDirect"; Url=$global:AnyDeskDownloadUrl; IsMSI=$false; Ext=".exe"; SilentArgs=@("--install",$anyDeskDir,"--start-with-win","--silent")}
        [PSCustomObject]@{Name="RustDesk";                        Winget="RustDesk.RustDesk";             Choco="rustdesk";                Scope="";TimeoutSeconds=600; Enabled=$true}
        [PSCustomObject]@{Name="Microsoft Teams";                 Winget="Microsoft.Teams";               Choco="microsoft-teams.install"; Scope="";TimeoutSeconds=900; Enabled=$true}
        [PSCustomObject]@{Name="Adobe Acrobat Reader";            Winget="Adobe.Acrobat.Reader.64-bit";   Choco="adobereader";             Scope="";TimeoutSeconds=900; Enabled=$true}
        [PSCustomObject]@{Name="Google Chrome"; Winget=""; Choco=""; Scope=""; TimeoutSeconds=600; Enabled=$true; Special="DirectDownload"; Url="https://dl.google.com/edgedl/chrome/install/GoogleChromeStandaloneEnterprise64.msi"; IsMSI=$true; Ext=".msi"; SilentArgs=@("/qn","/norestart")}
        [PSCustomObject]@{Name="7-Zip";                           Winget="7zip.7zip";                     Choco="7zip";                    Scope="";TimeoutSeconds=300; Enabled=$true}
        [PSCustomObject]@{Name="Oracle Java Runtime Environment"; Winget="Oracle.JavaRuntimeEnvironment"; Choco="";                        Scope="";TimeoutSeconds=900; Enabled=$true}
        [PSCustomObject]@{Name="Lightshot";                       Winget="Skillbrains.Lightshot";         Choco="lightshot.install";       Scope="";TimeoutSeconds=300; Enabled=$true}
        [PSCustomObject]@{Name="Microsoft Office (365 Apps for enterprise, pt-br)"; Winget=""; Choco=""; Scope=""; TimeoutSeconds=5400; Enabled=$true; Special="OfficeODT"}
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

# extra_apps.json e um arquivo LOCAL por maquina (nao vai no git/gist) -
# antes, uma maquina nova comecava com Pacote Extra vazio (so ficava
# populado se um tecnico usasse "Adicionar" manualmente). Isso e o que
# fazia os itens "sumirem": maquina/instalacao nova = lista vazia, mesmo
# sendo os instaladores oficiais da empresa. Agora ha uma lista padrao
# embutida no script (mesmo padrao do Get-DefaultAppList da Lista Padrao).
function Get-DefaultExtraAppList {
    return @(
        [PSCustomObject]@{Name="CrowdStriker (Anti-Virus)"; Url="https://github.com/Dan-Vaz/elgin-service-desk-tool/releases/download/v1.0.0/FalconSensor_Windows.exe"; SilentArgs=@("/install","/quiet","/norestart","CID=8777EA0847824F13B27F1DFF7C0A27C4-27","ProvWaitTime=1200000"); Ext=".exe"; IsMSI=$false; TimeoutSeconds=1800; Enabled=$true; UninstallMatch="CrowdStrike"}
        [PSCustomObject]@{Name="DELL SupportAssist";        Url="https://github.com/Dan-Vaz/ignyz/releases/download/script/DELL.SupportAssistLauncher.exe"; SilentArgs=@(); Ext=".exe"; IsMSI=$false; TimeoutSeconds=900; Enabled=$true; UninstallMatch="SupportAssist"}
        [PSCustomObject]@{Name="Easy Inventory (EasyELGIN)"; Url="https://github.com/Dan-Vaz/ignyz/releases/download/script/EasyELGIN.msi"; SilentArgs=@("/qn","/norestart"); Ext=".msi"; IsMSI=$true; TimeoutSeconds=900; Enabled=$true; UninstallMatch="EasyELGIN"}
        [PSCustomObject]@{Name="FortiClient VPN";           Url="https://github.com/Dan-Vaz/ignyz/releases/download/script/FortiClientVPNOnlineInstaller.exe"; SilentArgs=@(); Ext=".exe"; IsMSI=$false; TimeoutSeconds=900; Enabled=$true; UninstallMatch="FortiClient"}
        [PSCustomObject]@{Name="HP Support Assistant";      Url="https://github.com/Dan-Vaz/ignyz/releases/download/script/HP.Support.Assistant.exe"; SilentArgs=@(); Ext=".exe"; IsMSI=$false; TimeoutSeconds=900; Enabled=$true; UninstallMatch="HP Support Assistant"}
        [PSCustomObject]@{Name="OCS Inventory Agent";       Url="https://github.com/Dan-Vaz/ignyz/releases/download/script/OcsPackage.exe"; SilentArgs=@(); Ext=".exe"; IsMSI=$false; TimeoutSeconds=600; Enabled=$true; UninstallMatch="OCS Inventory"}
        [PSCustomObject]@{Name="Linkus VoIP";               Url="https://github.com/Dan-Vaz/ignyz/releases/download/script/Linkus-desktop-win-setup.exe"; SilentArgs=@(); Ext=".exe"; IsMSI=$false; TimeoutSeconds=600; Enabled=$true; UninstallMatch="Linkus"}
    )
}

function Initialize-ExtraDatabase {
    if (-not (Test-Path $global:ExtraConfigFile)) {
        [PSCustomObject]@{SchemaVersion=$global:ExtraSchemaVersion; Apps=@(Get-DefaultExtraAppList)} |
            ConvertTo-Json -Depth 5 | Out-File $global:ExtraConfigFile -Encoding UTF8 -Force
    }
}

# Antes o arquivo era so um array cru (sem versao). Se o arquivo local
# estiver nesse formato antigo, ou com SchemaVersion desatualizado (ex.:
# trocar Bitdefender por CrowdStrike na lista padrao), faz backup e
# restaura a lista nova - mesmo padrao ja usado pro apps.json
# (Update-LegacyDefaultListIfNeeded).
function Update-LegacyExtraListIfNeeded {
    if (-not (Test-Path $global:ExtraConfigFile)) { return }
    try {
        $json = Get-Content $global:ExtraConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $cur = if ($json.PSObject.Properties['SchemaVersion']) { [int]$json.SchemaVersion } else { 1 }
        if ($cur -lt $global:ExtraSchemaVersion) {
            $bkPath = Join-Path $global:ConfigPath ("extra_apps_v{0}_{1}.json" -f $cur,(Get-Date -Format "yyyyMMdd-HHmmss"))
            Copy-Item $global:ExtraConfigFile $bkPath -Force -EA SilentlyContinue
            Write-Log -Message ("Schema de extra_apps.json v{0} -> v{1}. Backup em: {2}. Restaurando lista padrao." -f $cur,$global:ExtraSchemaVersion,$bkPath) -Level "WARN"
            [PSCustomObject]@{SchemaVersion=$global:ExtraSchemaVersion; Apps=@(Get-DefaultExtraAppList)} |
                ConvertTo-Json -Depth 5 | Out-File $global:ExtraConfigFile -Encoding UTF8 -Force
        }
    } catch { Write-Log -Message ("Falha ao verificar schema de extra_apps.json: {0}" -f $_.Exception.Message) -Level "WARN" }
}

function Import-ExtraDatabase {
    $global:ExtraAppsList.Clear()
    try {
        $json = Get-Content $global:ExtraConfigFile -Raw -EA Stop | ConvertFrom-Json -EA Stop
        $apps = if ($json.PSObject.Properties['Apps']) { @($json.Apps) } else { @($json) }
        foreach ($item in $apps) { [void]$global:ExtraAppsList.Add($item) }
    } catch { Write-Log -Message ("Falha ao carregar extra_apps.json: {0}" -f $_.Exception.Message) -Level "WARN" }

    # Rede de seguranca para instalacoes existentes cujo extra_apps.json ja
    # existia vazio (a causa dos itens terem "sumido") - repovoa com o
    # padrao e salva, sem sobrescrever customizacoes que ja existirem.
    if ($global:ExtraAppsList.Count -eq 0) {
        foreach ($app in Get-DefaultExtraAppList) { [void]$global:ExtraAppsList.Add($app) }
        Export-ExtraDatabase | Out-Null
        Write-Log -Message "Pacote Extra estava vazio - lista padrao restaurada." -Level "WARN"
    }
}

function Export-ExtraDatabase {
    try {
        [PSCustomObject]@{SchemaVersion=$global:ExtraSchemaVersion; Apps=@($global:ExtraAppsList)} |
            ConvertTo-Json -Depth 5 | Out-File $global:ExtraConfigFile -Encoding UTF8 -Force
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
    $silentArgs = @()
    try { if ($App.SilentArgs) { $silentArgs = @($App.SilentArgs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } } catch { $silentArgs = @() }

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
        # SilentArgs (vindo do cadastro do app) precisa ser aplicado de
        # verdade aqui - antes era lido do JSON mas nunca usado na
        # instalacao em si (MSI sempre rodava so "/norestart" e o EXE
        # rodava sem nenhum argumento).
        if ($isMSI) {
            $msiArgs = @("/i",$tempFile)
            if ($silentArgs.Count -gt 0) { $msiArgs += $silentArgs } else { $msiArgs += "/norestart" }
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -PassThru -ErrorAction Stop
        } elseif ($silentArgs.Count -gt 0) {
            $proc = Start-Process -FilePath $tempFile -ArgumentList $silentArgs -PassThru -ErrorAction Stop
        } else {
            $proc = Start-Process -FilePath $tempFile -PassThru -ErrorAction Stop
        }
        Set-WindowForeground -Proc $proc -TimeoutSeconds 15

        $timedOut = Wait-ProcessResponsive -Process $proc -TimeoutSeconds $timeout -BusyText ("Instalando {0}... (se abrir uma janela propria, siga as instrucoes nela)" -f $appName)
        if ($timedOut) { Write-Log -Message ("[EXTRA] Timeout em {0}" -f $appName) -Level "ERROR"; return $false }
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

# ---- ANYDESK (download direto + senha de acesso nao supervisionado) ----
function Get-AnyDeskExePath {
    foreach ($base in @(${env:ProgramFiles(x86)},$env:ProgramFiles)) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $p = Join-Path $base "AnyDesk\AnyDesk.exe"
        if (Test-Path $p) { return $p }
    }
    return $null
}

# "--set-password" precisa da senha via STDIN (nao como argumento de linha de
# comando - e a forma documentada pela AnyDesk, evita expor a senha em texto
# puro no Gerenciador de Tarefas/Process Explorer enquanto o comando roda).
# Usa Wait-ProcessResponsive (nao WaitForExit sincrono) para nao travar a UI.
function Set-AnyDeskUnattendedPassword {
    param([Parameter(Mandatory=$true)][string]$ExePath)
    $proc = $null
    try {
        Set-Status "Configurando senha de acesso nao supervisionado do AnyDesk..."
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName              = $ExePath
        $psi.Arguments             = "--set-password"
        $psi.UseShellExecute       = $false
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow        = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $proc.StandardInput.WriteLine($global:AnyDeskUnattendedPassword)
        $proc.StandardInput.Close()

        $timedOut = Wait-ProcessResponsive -Process $proc -TimeoutSeconds 20 -BusyText "Configurando senha do AnyDesk..."
        if ($timedOut) {
            try { $proc.Kill() } catch {}
            Write-Log -Message "[INSTALL] Timeout ao definir senha do AnyDesk." -Level "WARN"
            return $true
        }
        $exitCode = try { $proc.ExitCode } catch { -1 }
        if ($exitCode -eq 0) { Write-Log -Message "[INSTALL] Senha de acesso nao supervisionado do AnyDesk configurada." -Level "SUCCESS" }
        else { Write-Log -Message ("[INSTALL] AnyDesk --set-password saiu com codigo {0}." -f $exitCode) -Level "WARN" }
        return $true
    } catch {
        Write-Log -Message ("[INSTALL] Falha ao configurar senha do AnyDesk: {0}" -f $_.Exception.Message) -Level "WARN"
        return $true
    } finally {
        if ($proc -ne $null) { try { $proc.Dispose() } catch {} }
    }
}

# O "--silent" do instalador da AnyDesk registra o servico e o item no
# Painel de Controle, mas de proposito NAO cria atalho nenhum (Area de
# Trabalho/Menu Iniciar) - confirmado apos instalacao real numa maquina de
# teste. Cria os atalhos manualmente via WScript.Shell (COM nativo do
# Windows, sem dependencia extra) pra ficar igual a uma instalacao normal.
function New-AnyDeskShortcuts {
    param([Parameter(Mandatory=$true)][string]$ExePath)
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $alvos = @(
            (Join-Path ([Environment]::GetFolderPath("CommonDesktopDirectory")) "AnyDesk.lnk")
            (Join-Path ([Environment]::GetFolderPath("CommonStartMenu")) "Programs\AnyDesk.lnk")
        )
        foreach ($lnkPath in $alvos) {
            $sc = $wsh.CreateShortcut($lnkPath)
            $sc.TargetPath       = $ExePath
            $sc.WorkingDirectory = Split-Path $ExePath -Parent
            $sc.IconLocation     = $ExePath
            $sc.Save()
        }
        Write-Log -Message "[INSTALL] Atalhos do AnyDesk criados (Area de Trabalho + Menu Iniciar)." -Level "SUCCESS"
    } catch {
        Write-Log -Message ("[INSTALL] Falha ao criar atalhos do AnyDesk: {0}" -f $_.Exception.Message) -Level "WARN"
    } finally {
        if ($wsh -ne $null) { try { [void][System.Runtime.Interopservices.Marshal]::ReleaseComObject($wsh) } catch {} }
    }
}

function Install-AnyDeskDirect {
    param([Parameter(Mandatory=$true)]$App)
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return $false }

    $exePath = Get-AnyDeskExePath
    if ($exePath) {
        # NAO forca reinstalacao por cima de uma instalacao existente: o
        # cliente AnyDesk se auto-atualiza sozinho em segundo plano (opcao
        # "Atualizacao automatica", ligada por padrao) e frequentemente ja
        # esta em uma versao mais nova que o instalador estatico baixado
        # aqui. Reinstalar por cima faz o proprio instalador da AnyDesk
        # recusar (mostra "ja existe uma versao mais nova instalada" e nao
        # faz nada) - reproduzido manualmente com o mesmo .exe baixado por
        # este script. So garantimos a senha e os atalhos (idempotente -
        # nao tem problema recriar se ja existirem).
        Write-Log -Message "[INSTALL] AnyDesk ja instalado (se auto-atualiza sozinho). Configurando senha de acesso nao supervisionado." -Level "INFO"
        New-AnyDeskShortcuts -ExePath $exePath
        return (Set-AnyDeskUnattendedPassword -ExePath $exePath)
    }

    # AnyDesk.exe nao encontrado em Program Files, mas se a maquina ja teve
    # AnyDesk instalado antes (desinstalado sem limpeza completa), sobra
    # config em %ProgramData%\AnyDesk com a versao anterior gravada - isso
    # engana o instalador com o mesmo "ja existe versao mais nova" mesmo sem
    # o programa presente. Limpa antes de instalar do zero.
    $residuo = Join-Path $env:ProgramData "AnyDesk"
    if (Test-Path $residuo) {
        Write-Log -Message ("[INSTALL] Residuo encontrado em '{0}' sem AnyDesk.exe instalado - removendo antes de instalar." -f $residuo) -Level "WARN"
        try { Remove-Item -Path $residuo -Recurse -Force -ErrorAction Stop } catch {
            Write-Log -Message ("[INSTALL] Falha ao remover residuo do AnyDesk: {0}" -f $_.Exception.Message) -Level "WARN"
        }
    }

    if (-not (Install-DirectApp -App $App)) { return $false }

    $exePath = Get-AnyDeskExePath
    if (-not $exePath) {
        Write-Log -Message "[INSTALL] AnyDesk.exe nao encontrado apos a instalacao." -Level "ERROR"
        return $false
    }
    New-AnyDeskShortcuts -ExePath $exePath
    return (Set-AnyDeskUnattendedPassword -ExePath $exePath)
}

# ---- MICROSOFT OFFICE (Microsoft 365 Apps for enterprise) ----
# O pacote "Microsoft.Office" do winget instala via Microsoft Store e
# frequentemente resolve pra Microsoft 365 versao consumidor, sem escolha
# de idioma/SKU - por isso o winget/choco nao sao confiaveis pra Office em
# ambiente corporativo. O metodo oficial da Microsoft pra scriptar isso e o
# Office Deployment Tool (ODT): o proprio setup.exe do Click-to-Run pode
# ser baixado direto (sem precisar do instalador do ODT que so empacota
# esse mesmo setup.exe) do CDN oficial, e roda com um Configuration.xml
# escolhendo produto/idioma. Product ID "O365ProPlusRetail" = Microsoft 365
# Apps for enterprise (a licenca de "Office 365 para grandes empresas").
$global:OfficeODTSetupUrl = "https://officecdn.microsoft.com/pr/wsus/setup.exe"

function Install-OfficeViaODT {
    param([Parameter(Mandatory=$true)]$App)
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return $false }
    $appName = "Microsoft Office (Microsoft 365 Apps for enterprise)"
    $timeout = 5400
    try { if ($App.TimeoutSeconds -and [int]$App.TimeoutSeconds -gt 0) { $timeout = [int]$App.TimeoutSeconds } } catch {}

    $workDir  = Join-Path $env:TEMP ("ElginOfficeODT_" + [guid]::NewGuid().ToString("N").Substring(0,8))
    $setupExe = Join-Path $workDir "setup.exe"
    $configXml = Join-Path $workDir "configuration.xml"
    try { New-Item -Path $workDir -ItemType Directory -Force | Out-Null } catch {
        Write-Log -Message ("[INSTALL] Falha ao criar pasta de trabalho do ODT: {0}" -f $_.Exception.Message) -Level "ERROR"
        return $false
    }

    try {
        Set-Status "Baixando instalador oficial do Office (ODT)..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
        $downloadOk = $false; $lastError = ""

        $curlExe = "$env:SystemRoot\System32\curl.exe"
        if (-not (Test-Path $curlExe)) { $curlExe = "$env:SystemRoot\SysWOW64\curl.exe" }
        if (Test-Path $curlExe) {
            $cr = Invoke-ManagedProcess -FilePath $curlExe -Arguments @("-L","--fail","--silent","--show-error","-A","Mozilla/5.0 (Windows NT 10.0; Win64; x64)","-o",$setupExe,$global:OfficeODTSetupUrl) -Description "[INSTALL] Download ODT setup.exe" -TimeoutSeconds 300 -BusyText "Baixando instalador oficial do Office..."
            if ($cr.ExitCode -eq 0 -and (Test-Path $setupExe)) { $downloadOk = $true } else { $lastError = ("curl exit {0}" -f $cr.ExitCode) }
        }
        if (-not $downloadOk) {
            try {
                $prev = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
                Invoke-WebRequest -Uri $global:OfficeODTSetupUrl -OutFile $setupExe -UseBasicParsing -Headers @{"User-Agent"="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"} -ErrorAction Stop
                $ProgressPreference = $prev; $downloadOk = $true
            } catch { $ProgressPreference = $prev; $lastError = $_.Exception.Message }
        }
        if (-not $downloadOk -or -not (Test-Path $setupExe)) {
            Write-Log -Message ("[INSTALL] Falha ao baixar setup.exe do ODT: {0}" -f $lastError) -Level "ERROR"
            Show-Warning ("Falha ao baixar o instalador oficial do Office.`n`n{0}" -f $lastError)
            return $false
        }

        # Display Level="Full" (nao "None") de proposito: o setup.exe do
        # Click-to-Run e um instalador grafico, nao um app de console - o
        # progresso de verdade (a tela "So um instante, preparando o
        # Office...") so aparece com Full. Rodar como GUI visivel + esperar
        # via Wait-ProcessResponsive (em vez de WaitForExit direto) e o que
        # evita a app travar durante os varios minutos que isso leva.
        $configBody = @'
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current">
    <Product ID="O365ProPlusRetail">
      <Language ID="pt-br" />
    </Product>
  </Add>
  <Display Level="Full" AcceptEULA="TRUE" />
  <Property Name="AUTOACTIVATE" Value="1" />
</Configuration>
'@
        Set-Content -Path $configXml -Value $configBody -Encoding ASCII -Force

        Set-Status "Instalando Microsoft Office - isso pode levar bastante tempo..."
        $quote = [char]34
        $proc = Start-Process -FilePath $setupExe -ArgumentList ("/configure "+$quote+$configXml+$quote) -PassThru -ErrorAction Stop
        Set-WindowForeground -Proc $proc -TimeoutSeconds 15
        $timedOut = Wait-ProcessResponsive -Process $proc -TimeoutSeconds $timeout -BusyText "Instalando Microsoft Office - acompanhe o progresso na janela do instalador..."
        if ($timedOut) {
            Write-Log -Message ("[INSTALL] Timeout instalando Office via ODT.") -Level "ERROR"
            return $false
        }
        $exitCode = try { $proc.ExitCode } catch { -1 }
        $ok = ($exitCode -eq 0)
        if ($ok) {
            Write-Log -Message "[INSTALL] Office instalado com sucesso via ODT." -Level "SUCCESS"
        } else {
            Write-Log -Message ("[INSTALL] Office ODT terminou com codigo {0}." -f $exitCode) -Level "ERROR"
        }
        return $ok
    } catch {
        Write-Log -Message ("[INSTALL] Excecao instalando Office via ODT: {0}" -f $_.Exception.Message) -Level "ERROR"
        return $false
    } finally {
        try { Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
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
    $special=""; try{$special=[string]$App.Special}catch{$special=""}
    if ($special -eq "OfficeODT") { return (Install-OfficeViaODT -App $App) }
    if ($special -eq "AnyDeskDirect") { return (Install-AnyDeskDirect -App $App) }
    if ($special -eq "DirectDownload") {
        # Install-DirectApp nao verifica "ja instalado" sozinho (generico
        # demais pra isso) - checagem pontual aqui pra nao rebaixar o MSI
        # do Chrome (~100MB) toda vez que a Lista Padrao roda de novo numa
        # maquina que ja tem o Chrome.
        $jaInstalado = @(
            (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe")
            (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe")
            (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
        ) | Where-Object { $_ -and (Test-Path $_) }
        if ([string]$App.Name -eq "Google Chrome" -and $jaInstalado) {
            Write-Log -Message "[INSTALL] Google Chrome ja instalado. Pulando." -Level "INFO"
            return $true
        }
        return (Install-DirectApp -App $App)
    }

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
        $r=Invoke-ManagedProcess -FilePath $winget -Arguments $wargs -Description ("[INSTALL] winget {0}" -f $appName) -TimeoutSeconds $timeout -BusyText ("Instalando {0} via winget..." -f $appName)
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
        $r=Invoke-ManagedProcess -FilePath $choco -Arguments @("install",$chocoId,"-y","--no-progress","--accept-license") -Description ("[INSTALL] choco {0}" -f $appName) -TimeoutSeconds $timeout -BusyText ("Instalando {0} via Chocolatey..." -f $appName)
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

# -Silent: usado na verificacao automatica de inicializacao (sem Confirm-Action
# nem popups de sucesso/erro - so loga - para nao interromper o tecnico toda
# vez que a ferramenta abre).
function Install-WingetPackageManager {
    param([switch]$Silent)
    Update-Prerequisites
    if ($global:HasWinget) { if (-not $Silent) { Show-Info "Winget ja esta instalado." }; return }
    if (-not $Silent -and -not (Confirm-Action "Deseja instalar o Winget/App Installer usando o pacote oficial da Microsoft?" "Instalar Winget")) { return }
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
        if (-not $dlOk) {
            $msg = ("Falha ao baixar Winget. Todos os metodos falharam.`n`nUltimo erro: {0}" -f $dlErr)
            if ($Silent) { Write-Log -Message ("[STARTUP] {0}" -f $msg) -Level "WARN" } else { Show-ErrorBox $msg }
            return
        }
        Set-Status "Instalando Winget/App Installer..."
        Add-AppxPackage -Path $wingetTemp -ErrorAction Stop
        Update-Prerequisites
        if ($global:HasWinget) {
            if ($Silent) { Write-Log -Message "[STARTUP] Winget instalado automaticamente com sucesso." -Level "SUCCESS" } else { Show-Info "Winget instalado com sucesso." }
        } else {
            $msg = "Instalador executado, mas winget nao foi localizado. Reinicie o PowerShell/computador."
            if ($Silent) { Write-Log -Message ("[STARTUP] {0}" -f $msg) -Level "WARN" } else { Show-Warning $msg }
        }
    } catch {
        $msg = ("Falha ao instalar Winget.`n`n{0}" -f $_.Exception.Message)
        if ($Silent) { Write-Log -Message ("[STARTUP] {0}" -f $msg) -Level "ERROR" } else { Show-ErrorBox $msg }
    } finally { if (Test-Path $wingetTemp) { Remove-Item $wingetTemp -Force -EA SilentlyContinue } }
}

function Install-ChocolateyPackageManager {
    param([switch]$Silent)
    Update-Prerequisites
    if ($global:HasChoco) { if (-not $Silent) { Show-Info "Chocolatey ja esta instalado." }; return }
    if (-not $global:IsAdmin) { if (-not $Silent) { Show-Warning "A instalacao do Chocolatey requer Administrador." }; return }
    if (-not $Silent -and -not (Confirm-Action "Deseja instalar o Chocolatey usando o script oficial?" "Instalar Chocolatey")) { return }
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
            if ($Silent) { Write-Log -Message "[STARTUP] Chocolatey instalado automaticamente com sucesso." -Level "SUCCESS" }
            else { Show-Info "Chocolatey instalado com sucesso.`n`nSe 'choco' nao for reconhecido, feche e abra a ferramenta novamente." }
        } else {
            $msg = ("Instalador retornou ExitCode {0}, mas choco.exe nao foi localizado. Verifique os Logs." -f $result.ExitCode)
            if ($Silent) { Write-Log -Message ("[STARTUP] {0}" -f $msg) -Level "WARN" } else { Show-Warning $msg }
        }
    } catch {
        $msg = ("Falha ao instalar Chocolatey.`n`n{0}" -f $_.Exception.Message)
        if ($Silent) { Write-Log -Message ("[STARTUP] {0}" -f $msg) -Level "ERROR" } else { Show-ErrorBox $msg }
    } finally { if (Test-Path $tempScript) { Remove-Item $tempScript -Force -EA SilentlyContinue } }
}

# Verificacao automatica ao abrir a ferramenta: instala o Winget/Chocolatey se
# estiverem ausentes, ou repara o Winget se estiver presente mas nao responder
# (App Installer registrado incorretamente). Roda depois da janela principal
# aparecer (Add_ContentRendered) - ShowDialog ja bombeia a fila de mensagens
# durante o Wait-ProcessResponsive de cada instalacao, entao a janela fica
# responsiva o tempo todo (mesmo padrao "nao trava" usado no resto do app).
function Initialize-PackageManagersAutoFix {
    if (-not $global:HasInternet) {
        Write-Log -Message "[STARTUP] Sem internet - pulando verificacao automatica de Winget/Chocolatey." -Level "WARN"
        return
    }
    if (-not $global:HasWinget) {
        Write-Log -Message "[STARTUP] Winget nao encontrado. Instalando automaticamente..." -Level "WARN"
        Install-WingetPackageManager -Silent
    } elseif ([string]::IsNullOrWhiteSpace((Get-WingetVersion))) {
        Write-Log -Message "[STARTUP] Winget presente mas nao respondeu. Tentando reparar automaticamente..." -Level "WARN"
        Repair-Winget | Out-Null
    }
    if ($global:IsAdmin -and -not $global:HasChoco) {
        Write-Log -Message "[STARTUP] Chocolatey nao encontrado. Instalando automaticamente..." -Level "WARN"
        Install-ChocolateyPackageManager -Silent
    }
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

function Clear-AllUsersTempFolders {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    $usersRoot = Join-Path $env:SystemDrive "Users"
    if (-not (Test-Path $usersRoot)) { return }
    $skip = @("Public","Default","Default User","All Users")
    foreach ($userDir in Get-ChildItem -Path $usersRoot -Directory -Force -ErrorAction SilentlyContinue) {
        if ($skip -contains $userDir.Name) { continue }
        $tempPath = Join-Path $userDir.FullName "AppData\Local\Temp"
        if (Test-Path $tempPath) {
            Set-Status ("Limpando temporarios em {0}..." -f $tempPath)
            Get-ChildItem -Path $tempPath -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
    Write-Log -Message "[CLEANUP] Temporarios limpos para todos os perfis de usuario." -Level "SUCCESS"
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
    $busyTxt = "{0}..." -f $Action
    switch ($Action) {
        "Flush DNS"     { Invoke-ConsoleCommand "ipconfig /flushdns" "[NETWORK] Flush DNS" 60 -BusyText $busyTxt | Out-Null; Show-Info "Cache DNS limpo." }
        "Renew IP"      { Invoke-ConsoleCommand "ipconfig /release & ipconfig /renew" "[NETWORK] Renew IP" 120 -BusyText $busyTxt | Out-Null; Show-Info "IP renovado." }
        "Reset Winsock" { Invoke-ConsoleCommand "netsh winsock reset" "[NETWORK] Reset Winsock" 120 -BusyText $busyTxt | Out-Null; Show-Info "Reset Winsock executado. Reinicie o computador." }
        "Ping Google"   { $r=Invoke-ConsoleCommand "ping 8.8.8.8 -n 4" "[NETWORK] Ping" 60 -BusyText $busyTxt; Show-Info $r.Output "Resultado do Ping" }
        "Teste DNS"     { $r=Invoke-ConsoleCommand "nslookup google.com" "[NETWORK] DNS" 60 -BusyText $busyTxt; Show-Info ($r.Output+$r.Error) "Resultado DNS" }
    }
}

function Reset-PrintSpooler {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    $ov = Show-BusyOverlay -Text "Reiniciando spooler de impressao..."
    try {
        Stop-Service spooler -Force -EA SilentlyContinue
        $spool=Join-Path $env:SystemRoot "System32\spool\PRINTERS"
        if (Test-Path $spool) { Get-ChildItem $spool -Force -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue }
        Start-Service spooler -EA SilentlyContinue
        Write-Log -Message "[PRINT] Spooler reiniciado e fila limpa." -Level "SUCCESS"; Show-Info "Spooler reiniciado e fila de impressao limpa."
    } catch { Show-ErrorBox ("Falha ao reiniciar spooler.`n`n{0}" -f $_.Exception.Message)
    } finally { Close-BusyOverlay -Overlay $ov }
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

    # Get-PrinterPort/Get-Printer -ComputerName sao chamadas RPC sincronas -
    # contra um servidor inacessivel podem travar por MINUTOS (timeout de RPC
    # do Windows), o que parece "a ferramenta travou/fechou" pro usuario.
    # Rodar numa runspace do MESMO processo nao resolve: .Stop()/.Dispose()
    # numa runspace presa numa chamada nativa bloqueante tambem trava (nao da
    # pra interromper uma thread a forca em .NET). A unica forma confiavel de
    # limitar isso e rodar num PROCESSO filho de verdade e matar o processo
    # (Process.Kill funciona mesmo com a thread presa em codigo nativo).
    $ports = $null; $printers = $null; $consultaOk = $false; $erroConsulta = ""
    $tempOut = Join-Path $env:TEMP ("elgin_printquery_" + [guid]::NewGuid().ToString("N").Substring(0,8) + ".json")
    $tempScript = Join-Path $env:TEMP ("elgin_printquery_" + [guid]::NewGuid().ToString("N").Substring(0,8) + ".ps1")
    $proc = $null
    try {
        $scriptBody = @'
param([string]$Servidor,[string]$OutFile)
try {
    $ports    = Get-PrinterPort -ComputerName $Servidor -ErrorAction Stop
    $printers = Get-Printer -ComputerName $Servidor -ErrorAction Stop
    [PSCustomObject]@{ Ok=$true; Ports=@($ports); Printers=@($printers) } | ConvertTo-Json -Depth 6 -Compress | Out-File -LiteralPath $OutFile -Encoding UTF8
} catch {
    [PSCustomObject]@{ Ok=$false; Error=$_.Exception.Message } | ConvertTo-Json -Compress | Out-File -LiteralPath $OutFile -Encoding UTF8
}
'@
        Set-Content -LiteralPath $tempScript -Value $scriptBody -Encoding UTF8 -Force
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = "powershell.exe"
        $psi.Arguments = ConvertTo-ProcessArgumentString -Arguments @("-NoProfile","-NonInteractive","-File",$tempScript,$cfg.ServidorPrint,$tempOut)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $psi.WindowStyle     = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        if ($proc.WaitForExit(12000)) {
            if (Test-Path $tempOut) {
                $res = Get-Content -LiteralPath $tempOut -Raw | ConvertFrom-Json
                if ($res.Ok) { $ports = @($res.Ports); $printers = @($res.Printers); $consultaOk = $true }
                else { $erroConsulta = [string]$res.Error }
            } else { $erroConsulta = "Processo de consulta nao gerou resultado." }
        } else {
            $erroConsulta = "Timeout apos 12s consultando o servidor de impressao."
            try { $proc.Kill() } catch {}
        }
    } catch { $erroConsulta = $_.Exception.Message }
    finally {
        if ($proc -ne $null) { try { $proc.Dispose() } catch {} }
        if (Test-Path $tempScript) { Remove-Item $tempScript -Force -EA SilentlyContinue }
        if (Test-Path $tempOut)    { Remove-Item $tempOut -Force -EA SilentlyContinue }
    }

    if (-not $consultaOk) {
        Write-Log -Message ("[PRINT] Servidor '{0}' inacessivel: {1}" -f $cfg.ServidorPrint,$erroConsulta) -Level "ERROR"
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
            <Setter Property="Margin" Value="12,0,12,3"/>
            <Setter Property="Foreground" Value="{DynamicResource BrushTextMuted}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="Medium"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding" Value="10,0,10,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="9">
                            <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource BrushHover}"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="SidebarNavIcon" TargetType="Border">
            <Setter Property="Width" Value="26"/>
            <Setter Property="Height" Value="26"/>
            <Setter Property="CornerRadius" Value="7"/>
            <Setter Property="Margin" Value="0,0,10,0"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style x:Key="SidebarNavIconText" TargetType="TextBlock">
            <Setter Property="FontSize" Value="10"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="HorizontalAlignment" Value="Center"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style x:Key="SidebarNavLabel" TargetType="TextBlock">
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
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
            <Setter Property="Height" Value="150"/>
            <Setter Property="Margin" Value="0,0,12,12"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="VerticalContentAlignment" Value="Stretch"/>
            <Setter Property="Padding" Value="18"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Background" Value="{DynamicResource BrushSurface}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BrushBorder}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10">
                            <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Margin="{TemplateBinding Padding}"/>
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
            <Setter Property="CornerRadius" Value="10"/>
            <Setter Property="Padding" Value="16,12"/>
            <Setter Property="Margin" Value="0,0,12,12"/>
        </Style>
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource BrushSurface}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BrushBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="10"/>
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
            <ColumnDefinition Width="258"/>
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
                <Border DockPanel.Dock="Top" Height="1" Background="{DynamicResource BrushSidebarBrd}" Margin="22,0,22,12"/>
                <ScrollViewer DockPanel.Dock="Top" VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="0,4,0,0">
                        <TextBlock Text="PRINCIPAL" Style="{StaticResource NavGroupLabel}" Margin="22,4,0,6"/>
                        <Button x:Name="NavInicio" Style="{StaticResource SidebarButton}" Background="{DynamicResource BrushActiveNav}" Foreground="{DynamicResource BrushAccent}" FontWeight="Bold">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource SidebarNavIcon}" Background="#06B6D4">
                                    <TextBlock Text="HM" Style="{StaticResource SidebarNavIconText}"/>
                                </Border>
                                <TextBlock Grid.Column="1" Text="Inicio" Style="{StaticResource SidebarNavLabel}"/>
                            </Grid>
                        </Button>
                        <Button x:Name="NavChecklist" Style="{StaticResource SidebarButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource SidebarNavIcon}" Background="#4C6FFF">
                                    <TextBlock Text="CK" Style="{StaticResource SidebarNavIconText}"/>
                                </Border>
                                <TextBlock Grid.Column="1" Text="Checklist" Style="{StaticResource SidebarNavLabel}"/>
                            </Grid>
                        </Button>
                        <Button x:Name="NavInstalar" Style="{StaticResource SidebarButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource SidebarNavIcon}" Background="#22C55E">
                                    <TextBlock Text="IN" Style="{StaticResource SidebarNavIconText}"/>
                                </Border>
                                <TextBlock Grid.Column="1" Text="Instalar Aplicativos" Style="{StaticResource SidebarNavLabel}"/>
                            </Grid>
                        </Button>
                        <TextBlock Text="REDE" Style="{StaticResource NavGroupLabel}"/>
                        <Button x:Name="NavRede" Style="{StaticResource SidebarButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource SidebarNavIcon}" Background="#0EA5E9">
                                    <TextBlock Text="RD" Style="{StaticResource SidebarNavIconText}"/>
                                </Border>
                                <TextBlock Grid.Column="1" Text="Rede" Style="{StaticResource SidebarNavLabel}"/>
                            </Grid>
                        </Button>
                        <Button x:Name="NavImpressao" Style="{StaticResource SidebarButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource SidebarNavIcon}" Background="#7C6FFA">
                                    <TextBlock Text="IP" Style="{StaticResource SidebarNavIconText}"/>
                                </Border>
                                <TextBlock Grid.Column="1" Text="Impressao" Style="{StaticResource SidebarNavLabel}"/>
                            </Grid>
                        </Button>
                        <Button x:Name="NavDeploy" Style="{StaticResource SidebarButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource SidebarNavIcon}" Background="#F97316">
                                    <TextBlock Text="DP" Style="{StaticResource SidebarNavIconText}"/>
                                </Border>
                                <TextBlock Grid.Column="1" Text="Deploy" Style="{StaticResource SidebarNavLabel}"/>
                            </Grid>
                        </Button>
                        <TextBlock Text="SISTEMA" Style="{StaticResource NavGroupLabel}"/>
                        <Button x:Name="NavDiagnostico" Style="{StaticResource SidebarButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource SidebarNavIcon}" Background="#2563EB">
                                    <TextBlock Text="DG" Style="{StaticResource SidebarNavIconText}"/>
                                </Border>
                                <TextBlock Grid.Column="1" Text="Diagnostico" Style="{StaticResource SidebarNavLabel}"/>
                            </Grid>
                        </Button>
                        <Button x:Name="NavLimpeza" Style="{StaticResource SidebarButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource SidebarNavIcon}" Background="#14B8A6">
                                    <TextBlock Text="LO" Style="{StaticResource SidebarNavIconText}"/>
                                </Border>
                                <TextBlock Grid.Column="1" Text="Limpeza e Otimizacao" Style="{StaticResource SidebarNavLabel}"/>
                            </Grid>
                        </Button>
                        <Button x:Name="NavFerramentas" Style="{StaticResource SidebarButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource SidebarNavIcon}" Background="#EF4444">
                                    <TextBlock Text="FR" Style="{StaticResource SidebarNavIconText}"/>
                                </Border>
                                <TextBlock Grid.Column="1" Text="Ferramentas" Style="{StaticResource SidebarNavLabel}"/>
                            </Grid>
                        </Button>
                        <Button x:Name="NavLogs" Style="{StaticResource SidebarButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource SidebarNavIcon}" Background="#6B7280">
                                    <TextBlock Text="LG" Style="{StaticResource SidebarNavIconText}"/>
                                </Border>
                                <TextBlock Grid.Column="1" Text="Logs" Style="{StaticResource SidebarNavLabel}"/>
                            </Grid>
                        </Button>
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

                <!-- Instalar Aplicativos (inclui Pacote Extra) -->
                <Grid x:Name="PanelInstalar">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Instalar Aplicativos" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,14"/>

                    <ScrollViewer Grid.Row="1">
                        <StackPanel>
                            <Border Style="{StaticResource Card}">
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                    <StackPanel Grid.Column="0">
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
                                    <Button Grid.Column="1" x:Name="BtnAbrirUtilitarios" Content="UTILITARIOS" Style="{StaticResource CardButton}" Background="{DynamicResource BrushSuccess}" Foreground="White" FontWeight="Bold" Width="170" Height="54" VerticalAlignment="Center" Margin="14,0,0,0"/>
                                </Grid>
                            </Border>

                            <Border Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="BUSCAR OUTRO SOFTWARE (WINGET / CHOCOLATEY)" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <StackPanel Orientation="Horizontal">
                                        <TextBox x:Name="TxtBuscaOnline" Style="{StaticResource SearchBox}" Width="360" Margin="0,0,10,0"/>
                                        <Button x:Name="BtnBuscarOnline" Content="Buscar" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Width="110" Height="36"/>
                                    </StackPanel>
                                    <StackPanel x:Name="SpBuscaResultados" Margin="0,10,0,0"/>
                                    <StackPanel x:Name="SpBuscaBotoesSelecao" Orientation="Horizontal" Margin="0,8,0,0" Visibility="Collapsed">
                                        <Button x:Name="BtnMarcarTodosBusca" Content="Marcar Todos" Width="120" Height="28" FontSize="11" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" Margin="0,0,8,0"/>
                                        <Button x:Name="BtnDesmarcarTodosBusca" Content="Desmarcar Todos" Width="130" Height="28" FontSize="11" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                    </StackPanel>
                                    <Button x:Name="BtnInstalarBusca" Content="Instalar Selecionados da Busca" Style="{StaticResource CardButton}" Background="{DynamicResource BrushSuccess}" Width="240" HorizontalAlignment="Left" Margin="0,10,0,0" Visibility="Collapsed"/>
                                </StackPanel>
                            </Border>

                            <Grid Margin="0,0,0,20">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>

                                <TextBlock Grid.Row="0" Grid.Column="0" Text="LISTA PADRAO" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold" Margin="4,6,0,10"/>
                                <StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal" Margin="14,6,0,10">
                                    <TextBlock Text="PACOTE EXTRA" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/>
                                    <Border Background="{DynamicResource BrushDanger}" CornerRadius="4" Padding="7,2" Margin="10,0,0,0">
                                        <TextBlock Text="Instalar apos colocar no dominio" Foreground="White" FontSize="10" FontWeight="Bold"/>
                                    </Border>
                                </StackPanel>

                                <Border Grid.Row="1" Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,7,0" VerticalAlignment="Top">
                                    <StackPanel>
                                        <TextBox x:Name="TxtFiltroApps" Style="{StaticResource SearchBox}" Text="Pesquisar na lista padrao..." Foreground="{DynamicResource BrushTextMuted}" Margin="0,0,0,10"/>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                            <Button x:Name="BtnMarcarTodosApps" Content="Marcar Todos" Width="120" Height="28" FontSize="11" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" Margin="0,0,8,0"/>
                                            <Button x:Name="BtnDesmarcarTodosApps" Content="Desmarcar Todos" Width="130" Height="28" FontSize="11" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        </StackPanel>
                                        <StackPanel x:Name="SpAppsList"/>
                                        <Button x:Name="BtnInstalarSelecionados" Content="Instalar Selecionados" Width="220" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Margin="0,10,0,0"/>
                                    </StackPanel>
                                </Border>

                                <Border Grid.Row="1" Grid.Column="1" Style="{StaticResource Card}" Margin="7,0,0,0" VerticalAlignment="Top">
                                    <StackPanel>
                                        <TextBlock Text="Instaladores diretos hospedados fora do winget/choco (FortiClient, EasyELGIN, etc.)." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,10" TextWrapping="Wrap"/>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                            <Button x:Name="BtnMarcarTodosExtra" Content="Marcar Todos" Width="120" Height="28" FontSize="11" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" Margin="0,0,8,0"/>
                                            <Button x:Name="BtnDesmarcarTodosExtra" Content="Desmarcar Todos" Width="130" Height="28" FontSize="11" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        </StackPanel>
                                        <StackPanel x:Name="SpExtraList"/>
                                        <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                                            <Button x:Name="BtnAdicionarExtra" Content="Adicionar" Width="140" Style="{StaticResource CardButton}" Background="{DynamicResource BrushSuccess}" Margin="0,0,10,0"/>
                                            <Button x:Name="BtnInstalarExtra" Content="Instalar Selecionados" Width="220" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                                        </StackPanel>
                                    </StackPanel>
                                </Border>
                            </Grid>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>
'@

$script:XamlPanelsB = @'
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

$global:LoadingOverlayXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Carregando" Height="140" Width="380"
        WindowStartupLocation="CenterOwner" WindowStyle="None" ResizeMode="NoResize"
        Background="{DynamicResource BrushSurface}">
    <Border BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" CornerRadius="10">
        <StackPanel Margin="20" VerticalAlignment="Center">
            <TextBlock x:Name="TxtLoadingStatus" Text="Carregando..." Foreground="{DynamicResource BrushText}" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,12"/>
            <ProgressBar IsIndeterminate="True" Height="4" Background="{DynamicResource BrushSurfaceAlt}" Foreground="{DynamicResource BrushAccent}" BorderThickness="0"/>
        </StackPanel>
    </Border>
</Window>
'@

# Overlay generico "carregando" usado por qualquer acao que bloqueia a
# thread da UI por mais de uma fracao de segundo (a app e single-thread,
# entao sem isso a janela principal so parece congelada). Nao e modal
# (.Show(), nao .ShowDialog()) e um unico Dispatcher.Invoke com prioridade
# Render forca o overlay a desenhar antes do trabalho bloqueante comecar -
# ele nao anima durante o trabalho em si (mesma limitacao de thread unica),
# mas deixa claro que a acao esta em andamento e nao que a ferramenta travou.
function Show-BusyOverlay {
    param([string]$Text = "Carregando...")
    try {
        $overlayReader = [System.Xml.XmlNodeReader]::new([xml]$global:LoadingOverlayXaml)
        $overlay = [System.Windows.Markup.XamlReader]::Load($overlayReader)
        $overlay.Owner = $global:MainWindow
        Set-DialogTheme -Dialog $overlay
        $overlay.FindName("TxtLoadingStatus").Text = $Text
        $overlay.Show()
        $overlay.Dispatcher.Invoke([System.Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        return $overlay
    } catch { return $null }
}

function Close-BusyOverlay {
    param($Overlay)
    if ($Overlay -ne $null) { try { $Overlay.Close() } catch {} }
}

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
function Show-ProcessResultInfo {
    param([Parameter(Mandatory=$true)]$Result,[string]$Titulo="Operacao")
    if ($Result.TimedOut) { Show-Warning ("{0}: tempo esgotado. O processo foi encerrado." -f $Titulo); return }
    if ($Result.ExitCode -eq 0) { Show-Info ("{0} concluido com sucesso." -f $Titulo) }
    else { Show-Warning ("{0} finalizado com codigo de saida {1}. Confira a janela que abriu para detalhes." -f $Titulo,$Result.ExitCode) }
}

function Invoke-SfcScan {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    Set-Status "Executando SFC /scannow - isso pode levar varios minutos..."
    $r = Invoke-VisibleConsoleCommand "sfc /scannow" "[REPAIR] SFC /scannow" 1800 "Executando SFC /scannow - isso pode levar varios minutos..."
    Show-ProcessResultInfo -Result $r -Titulo "SFC /scannow"
}

function Invoke-DismRestoreHealth {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    Set-Status "Executando DISM RestoreHealth - isso pode levar varios minutos..."
    $r = Invoke-VisibleConsoleCommand "DISM /Online /Cleanup-Image /RestoreHealth" "[REPAIR] DISM RestoreHealth" 1800 "Executando DISM RestoreHealth - isso pode levar varios minutos..."
    Show-ProcessResultInfo -Result $r -Titulo "DISM RestoreHealth"
}

# chkdsk /f no disco do sistema nao pode rodar com o volume em uso - o
# Windows so oferece agendar a checagem completa pra proxima inicializacao,
# respondendo "S"/"Y" (depende do idioma do Windows) a um prompt
# interativo. Em vez de depender do idioma, usamos "fsutil dirty set" pra
# marcar o volume como sujo diretamente - e exatamente o mesmo mecanismo
# que aquele "sim" aciona (autochk roda no proximo boot), sem prompt e sem
# depender de locale. A barra de progresso de verdade dessa checagem
# acontece na tela de boot, antes do Windows carregar - fora do alcance de
# qualquer overlay desta ferramenta, entao so confirmamos que ficou marcada.
function Invoke-ChkdskScheduled {
    param([string]$Drive = "C:")
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    $msg = "Isso vai marcar o disco {0} para uma verificacao completa (chkdsk /f) na proxima vez que o computador for reiniciado.`n`nComo {0} esta em uso pelo Windows agora, a checagem so pode rodar durante o boot (antes do Windows carregar) - a barra de progresso real dela aparece na tela azul de inicializacao, nao dentro desta ferramenta.`n`nO computador precisa ser reiniciado para a verificacao realmente acontecer. Deseja continuar?" -f $Drive
    if (-not (Confirm-Action $msg "Chkdsk /f - Agendar para o proximo boot")) { return }
    Set-Status ("Agendando verificacao de disco em {0}..." -f $Drive)
    $r = Invoke-VisibleConsoleCommand ("fsutil dirty set "+$Drive) ("[REPAIR] fsutil dirty set {0} (chkdsk agendado)" -f $Drive) 60 ("Agendando verificacao de disco em {0}..." -f $Drive)
    if ($r.TimedOut) { Show-Warning "Chkdsk: tempo esgotado ao tentar agendar. Confira a janela do console."; return }
    if ($r.ExitCode -eq 0) {
        Show-Info ("Verificacao de {0} agendada. Ela vai rodar automaticamente na proxima vez que o computador for reiniciado." -f $Drive)
    } else {
        Show-Warning ("Nao foi possivel agendar a verificacao (codigo {0}). Confira a janela do console para detalhes." -f $r.ExitCode)
    }
}

function Update-WingetApps {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    Update-Prerequisites
    if (-not $global:HasWinget) { Show-Warning "Winget nao esta instalado."; return }
    Set-Status "Atualizando aplicativos via winget..."
    $winget = Get-CommandPathSafe -Name "winget"
    $argLine = ConvertTo-ProcessArgumentString -Arguments @("upgrade","--all","--silent","--accept-package-agreements","--accept-source-agreements")
    $r = Invoke-VisibleConsoleCommand ((([char]34)+$winget+([char]34))+" "+$argLine) "[REPAIR] winget upgrade --all" 1800 "Atualizando aplicativos via winget..."
    Show-ProcessResultInfo -Result $r -Titulo "Atualizar Apps Winget"
}

# Ativa o plano de energia "Desempenho Maximo" (Ultimate Performance, oculto
# por padrao no Windows). Se a duplicacao falhar, cai para "Alto Desempenho"
# (plano padrao do Windows, sempre disponivel).
function Enable-MaxPerformancePowerPlan {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    $ultimateSourceGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
    $highPerfGuid       = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    try {
        $list = Invoke-ConsoleCommand "powercfg /list" "[REPAIR] powercfg /list" 20 -BusyText "Verificando planos de energia..."
        $existing = $null
        if ($list.Output -match "([0-9a-fA-F-]{36})\s+\(.*Desempenho M.ximo.*\)" -or $list.Output -match "([0-9a-fA-F-]{36})\s+\(.*Ultimate Performance.*\)") {
            $existing = $matches[1]
        }
        if (-not $existing) {
            $dup = Invoke-ConsoleCommand ("powercfg /duplicatescheme {0}" -f $ultimateSourceGuid) "[REPAIR] powercfg /duplicatescheme" 20 -BusyText "Criando plano de maximo desempenho..."
            if ($dup.Output -match "([0-9a-fA-F-]{36})") { $existing = $matches[1] }
        }
        $targetGuid = if ($existing) { $existing } else { $highPerfGuid }
        Invoke-ConsoleCommand ("powercfg /setactive {0}" -f $targetGuid) "[REPAIR] powercfg /setactive" 20 -BusyText "Ativando plano de maximo desempenho..." | Out-Null
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
        $r = Invoke-ConsoleCommand $Program.UninstallCmd ("[UNINSTALL] {0}" -f $Program.Name) 600 -BusyText ("Desinstalando {0}... (se abrir uma janela propria, siga as instrucoes nela)" -f $Program.Name)
        Write-Log -Message ("[UNINSTALL] {0} finalizado. ExitCode {1}" -f $Program.Name,$r.ExitCode) -Level "SUCCESS"
        Show-Info ("Desinstalacao de '{0}' finalizada. Se o desinstalador abriu uma janela propria, siga as instrucoes nela." -f $Program.Name)

        $residuos = @(Find-UninstallLeftovers -Program $Program)
        if ($residuos.Count -gt 0) { Show-LeftoverDialog -ProgramName $Program.Name -Leftovers $residuos }
        return $true
    } catch { Show-ErrorBox ("Falha ao desinstalar.`n`n{0}" -f $_.Exception.Message); return $false
    } finally { Close-BusyOverlay -Overlay $ov }
}

# ---- LIMPEZA DE RESIDUOS (estilo Revo Uninstaller) ----
# Depois que o desinstalador oficial do programa roda, sobra costumeiramente
# pasta em Program Files/AppData e chave de registro em HKCU/HKLM Software -
# essa varredura procura por essas sobras usando o nome do programa como
# termo de busca (mesma limitacao de qualquer scanner desse tipo, incluindo
# o Revo de verdade: pode dar falso positivo, por isso SEMPRE mostra uma
# lista pra revisao com tudo pre-marcado, nunca apaga sozinho).
function Find-UninstallLeftovers {
    param([Parameter(Mandatory=$true)]$Program)
    $termoBusca = ([string]$Program.Name) -replace '[^a-zA-Z0-9 ]',''
    $palavras = @($termoBusca -split '\s+' | Where-Object { $_.Length -ge 3 })
    if ($palavras.Count -eq 0) { return @() }

    $achados = New-Object System.Collections.ArrayList

    $pastasBase = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA) |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    foreach ($base in $pastasBase) {
        Get-ChildItem -Path $base -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($p in $palavras) {
                if ($_.Name -match [regex]::Escape($p)) {
                    [void]$achados.Add([PSCustomObject]@{ Tipo="Pasta"; Caminho=$_.FullName })
                    break
                }
            }
        }
    }

    $chavesBase = @("HKCU:\SOFTWARE","HKLM:\SOFTWARE","HKLM:\SOFTWARE\WOW6432Node")
    foreach ($base in $chavesBase) {
        if (-not (Test-Path $base)) { continue }
        Get-ChildItem -Path $base -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($p in $palavras) {
                if ($_.PSChildName -match [regex]::Escape($p)) {
                    [void]$achados.Add([PSCustomObject]@{ Tipo="Registro"; Caminho=$_.PSPath })
                    break
                }
            }
        }
    }

    return @($achados | Sort-Object Tipo,Caminho -Unique)
}

function Remove-UninstallLeftover {
    param([Parameter(Mandatory=$true)]$Item)
    try {
        if (Test-Path $Item.Caminho) { Remove-Item -Path $Item.Caminho -Recurse -Force -ErrorAction Stop }
        return $true
    } catch {
        Write-Log -Message ("[UNINSTALL] Falha ao remover residuo {0}: {1}" -f $Item.Caminho,$_.Exception.Message) -Level "ERROR"
        return $false
    }
}

$script:LeftoverDialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Limpar Residuos" Height="520" Width="720"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="{DynamicResource BrushWindowBg}">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" x:Name="TxtLeftoverTitle" Text="Residuos encontrados" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource BrushText}" Margin="0,0,0,4"/>
        <TextBlock Grid.Row="1" Text="Pastas e chaves de registro que sobraram apos a desinstalacao (podem incluir falsos positivos - revise antes de remover)." Foreground="{DynamicResource BrushTextMuted}" FontSize="11.5" TextWrapping="Wrap" Margin="0,0,0,12"/>
        <Border Grid.Row="2" Background="{DynamicResource BrushSurfaceAlt}" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" CornerRadius="8">
            <ScrollViewer Padding="12">
                <StackPanel x:Name="SpLeftovers"/>
            </ScrollViewer>
        </Border>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="BtnLeftoverTodos" Content="Selecionar Tudo" Width="130" Height="34" Margin="0,0,8,0" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0" Cursor="Hand"/>
            <Button x:Name="BtnLeftoverNenhum" Content="Desmarcar Tudo" Width="130" Height="34" Margin="0,0,8,0" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0" Cursor="Hand"/>
            <Button x:Name="BtnLeftoverPular" Content="Pular" Width="100" Height="34" Margin="0,0,8,0" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0" Cursor="Hand"/>
            <Button x:Name="BtnLeftoverRemover" Content="Remover Selecionados" Width="180" Height="34" Background="{DynamicResource BrushDanger}" Foreground="White" BorderThickness="0" FontWeight="Bold" Cursor="Hand"/>
        </StackPanel>
    </Grid>
</Window>
'@

function Show-LeftoverDialog {
    param([Parameter(Mandatory=$true)][string]$ProgramName, [Parameter(Mandatory=$true)][array]$Leftovers)
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:LeftoverDialogXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow
    Set-DialogTheme -Dialog $dlg
    $dlg.FindName("TxtLeftoverTitle").Text = ("Residuos encontrados de '{0}' ({1})" -f $ProgramName,$Leftovers.Count)

    $spLeftovers = $dlg.FindName("SpLeftovers")
    $leftoverCheckboxes = @()
    foreach ($item in $Leftovers) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = ("[{0}] {1}" -f $item.Tipo,$item.Caminho)
        $cb.IsChecked = $true
        $cb.Tag = $item
        $cb.Margin = "0,0,0,8"
        [void]$spLeftovers.Children.Add($cb)
        $leftoverCheckboxes += $cb
    }

    $dlg.FindName("BtnLeftoverTodos").Add_Click({ foreach ($cb in $leftoverCheckboxes) { $cb.IsChecked = $true } }.GetNewClosure())
    $dlg.FindName("BtnLeftoverNenhum").Add_Click({ foreach ($cb in $leftoverCheckboxes) { $cb.IsChecked = $false } }.GetNewClosure())
    $dlg.FindName("BtnLeftoverPular").Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.FindName("BtnLeftoverRemover").Add_Click({
        $selecionados = @($leftoverCheckboxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if ($selecionados.Count -eq 0) { Show-Warning "Nenhum item selecionado."; return }
        if (-not (Confirm-Action ("Remover {0} item(ns) selecionado(s)? Essa acao nao pode ser desfeita." -f $selecionados.Count) "Remover Residuos")) { return }
        $ok = 0; $falhou = 0
        foreach ($item in $selecionados) { if (Remove-UninstallLeftover -Item $item) { $ok++ } else { $falhou++ } }
        Write-Log -Message ("[UNINSTALL] Residuos removidos: {0} ok, {1} falharam." -f $ok,$falhou) -Level "SUCCESS"
        $dlg.Close()
        Show-Info ("Residuos removidos: {0}. Falhas: {1}." -f $ok,$falhou)
    }.GetNewClosure())

    [void]$dlg.ShowDialog()
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
    $ov = Show-BusyOverlay -Text "Limpando cache dos navegadores..."
    $limpos = @()
    try {
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
    } finally { Close-BusyOverlay -Overlay $ov }
    Write-Log -Message ("[CLEANUP] Cache de navegadores limpo: {0}" -f ($limpos -join ", ")) -Level "SUCCESS"
    Show-Info ("Cache limpo para: {0}.`n`nFeche o navegador antes de limpar para melhores resultados (arquivos em uso sao ignorados)." -f ($(if($limpos.Count -gt 0){$limpos -join ", "}else{"nenhum navegador encontrado"})))
}

# ---- LIMPEZA DO SISTEMA (avancada) ----
function Clear-PrefetchCache {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    $ov = Show-BusyOverlay -Text "Limpando cache de Prefetch..."
    try {
        $p = Join-Path $env:WINDIR "Prefetch"
        if (Test-Path $p) { Get-ChildItem $p -Force -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue }
        Write-Log -Message "[CLEANUP] Cache de Prefetch limpo." -Level "SUCCESS"
    } finally { Close-BusyOverlay -Overlay $ov }
    Show-Info "Cache de Prefetch limpo."
}

function Clear-FontCacheData {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    $ov = Show-BusyOverlay -Text "Limpando cache de fontes..."
    try {
        Stop-Service -Name "FontCache" -Force -EA SilentlyContinue
        Start-Sleep -Seconds 1
        $p1 = Join-Path $env:WINDIR "ServiceProfiles\LocalService\AppData\Local\FontCache"
        if (Test-Path $p1) { Get-ChildItem $p1 -Force -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue }
        $p2 = Join-Path $env:WINDIR "System32\FNTCACHE.DAT"
        if (Test-Path $p2) { Remove-Item $p2 -Force -EA SilentlyContinue }
        Start-Service -Name "FontCache" -EA SilentlyContinue
        Write-Log -Message "[CLEANUP] Cache de fontes limpo e servico reiniciado." -Level "SUCCESS"
        Show-Info "Cache de fontes limpo."
    } catch { Show-ErrorBox ("Falha ao limpar cache de fontes.`n`n{0}" -f $_.Exception.Message)
    } finally { Close-BusyOverlay -Overlay $ov }
}

function Get-ShadowCopiesInfo {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return "" }
    $r = Invoke-ConsoleCommand "vssadmin list shadows" "[REPAIR] vssadmin list shadows" 30 -BusyText "Consultando shadow copies..."
    return $r.Output
}

function Invoke-DismComponentCleanup {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    Set-Status "Executando limpeza de componentes WinSxS - isso pode levar varios minutos..."
    $r = Invoke-VisibleConsoleCommand "DISM /Online /Cleanup-Image /StartComponentCleanup" "[REPAIR] DISM StartComponentCleanup" 1800 "Executando limpeza de componentes WinSxS - isso pode levar varios minutos..."
    Show-ProcessResultInfo -Result $r -Titulo "WinSxS / DISM Cleanup"
}

# ---- LIMPEZA AVANCADA ----

# Usa a Limpeza de Disco nativa (cleanmgr /sagerun) em vez de apagar a pasta
# na mao - varios arquivos dentro de Windows.old pertencem ao
# TrustedInstaller e um "rd /s" direto costuma falhar com Acesso Negado. O
# StateFlags marcado no registro diz ao cleanmgr quais categorias incluir
# nessa execucao "sageset" especifica (65432 e so um numero arbitrario
# nao usado por outra coisa).
function Clear-WindowsOldFolder {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    $p = Join-Path $env:SystemDrive "Windows.old"
    if (-not (Test-Path $p)) { Show-Info "Nao ha pasta Windows.old neste computador."; return }
    if (-not (Confirm-Action "Isso vai remover permanentemente C:\Windows.old (arquivos da instalacao anterior do Windows) usando a Limpeza de Disco do Windows.`n`nDepois disso NAO e mais possivel voltar para a versao anterior do Windows.`n`nDeseja continuar?" "Remover Windows.old")) { return }
    $sageId = 65432
    $base = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
    $categorias = @("Previous Installations","Windows ESD installation files","Windows Upgrade Log Files","Temporary Windows Installation Files")
    foreach ($cat in $categorias) {
        $kp = Join-Path $base $cat
        if (Test-Path $kp) { try { Set-ItemProperty -Path $kp -Name ("StateFlags{0:D4}" -f $sageId) -Value 2 -Type DWord -ErrorAction Stop } catch {} }
    }
    $r = Invoke-VisibleConsoleCommand ("cleanmgr /sagerun:{0}" -f $sageId) "[CLEANUP] cleanmgr Windows.old" 900 "Removendo Windows.old via Limpeza de Disco - isso pode levar varios minutos..."
    Show-ProcessResultInfo -Result $r -Titulo "Remover Windows.old"
}

# So mostra a lista (nao apaga nada) - identificar com seguranca qual
# versao de um driver esta REALMENTE em uso, de forma independente do
# idioma do Windows (os rotulos do "pnputil /enum-drivers" sao localizados,
# entao fazer parsing automatico do texto e arriscado: um parsing errado
# poderia remover o driver ativo de uma peca de hardware). Fica pro tecnico
# decidir manualmente com "pnputil /delete-driver oemXX.inf /uninstall".
function Get-DriverStoreInfo {
    $r = Invoke-ConsoleCommand "pnputil /enum-drivers" "[CLEANUP] pnputil enum-drivers" 60 -BusyText "Listando drivers no DriverStore..."
    return $r.Output
}

# ---- ANALISE DE DISCO ----
function Get-FolderSizeMB {
    param([string]$Path)
    try {
        $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $bytes) { return 0 }
        return [math]::Round($bytes / 1MB, 1)
    } catch { return 0 }
}

function Get-DiskUsageReport {
    param([string]$RootPath)
    if (-not (Test-Path $RootPath)) { return ("Caminho nao encontrado: {0}" -f $RootPath) }
    $pastas = @(Get-ChildItem -LiteralPath $RootPath -Directory -Force -ErrorAction SilentlyContinue)
    if ($pastas.Count -eq 0) { return ("Nenhuma pasta encontrada em {0}." -f $RootPath) }
    $ov = Show-BusyOverlay -Text ("Analisando espaco em disco em {0}..." -f $RootPath)
    $txtOv = if ($ov -ne $null) { $ov.FindName("TxtLoadingStatus") } else { $null }
    try {
        $itens = New-Object System.Collections.ArrayList
        $i = 0
        foreach ($pasta in $pastas) {
            $i++
            # Atualiza o texto ANTES de cada pasta (algumas pastas, tipo
            # AppData, podem levar bastante tempo sozinhas - sem isso o
            # overlay ficaria parado no mesmo texto por minutos, exatamente
            # o "parece travado" que se quer evitar aqui).
            if ($txtOv -ne $null) {
                $txtOv.Text = "Analisando {0}/{1}: {2}..." -f $i,$pastas.Count,$pasta.Name
                $ov.Dispatcher.Invoke([System.Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
            }
            [void]$itens.Add([PSCustomObject]@{ Nome = $pasta.Name; TamanhoMB = (Get-FolderSizeMB -Path $pasta.FullName) })
        }
        $ordenado = @($itens | Sort-Object TamanhoMB -Descending | Select-Object -First 20)
        $linhas = foreach ($it in $ordenado) { "{0,10:N1} MB   {1}" -f $it.TamanhoMB,$it.Nome }
        return ($linhas -join "`r`n")
    } finally { Close-BusyOverlay -Overlay $ov }
}

# ---- OTIMIZACAO ----

# Reset "classico" de Windows Update: para os servicos, RENOMEIA (nao
# apaga) as pastas de cache - assim fica reversivel e o Windows recria
# pastas novas sozinho na proxima verificacao de updates.
function Invoke-WindowsUpdateReset {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    if (-not (Confirm-Action "Isso vai parar os servicos do Windows Update, renomear as pastas de cache (SoftwareDistribution e catroot2) e reiniciar os servicos - conserto comum para Windows Update travado ou com erro. As pastas antigas nao sao apagadas, so renomeadas.`n`nDeseja continuar?" "Resetar Windows Update")) { return }
    $ov = Show-BusyOverlay -Text "Resetando componentes do Windows Update..."
    try {
        $servicos = @("wuauserv","bits","cryptsvc","msiserver")
        foreach ($svc in $servicos) { try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch {} }
        Start-Sleep -Seconds 2
        $stamp = Get-Date -Format "yyyyMMddHHmmss"
        foreach ($p in @((Join-Path $env:WINDIR "SoftwareDistribution"),(Join-Path $env:WINDIR "System32\catroot2"))) {
            if (Test-Path $p) { try { Rename-Item -Path $p -NewName ("{0}.old.{1}" -f (Split-Path $p -Leaf),$stamp) -ErrorAction SilentlyContinue } catch {} }
        }
        foreach ($svc in $servicos) { try { Start-Service -Name $svc -ErrorAction SilentlyContinue } catch {} }
        Write-Log -Message "[REPAIR] Componentes do Windows Update resetados." -Level "SUCCESS"
    } finally { Close-BusyOverlay -Overlay $ov }
    Show-Info "Componentes do Windows Update resetados. As pastas antigas foram renomeadas (nao apagadas) e o Windows recria pastas novas na proxima verificacao de atualizacoes."
}

function Invoke-SearchIndexRebuild {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    if (-not (Confirm-Action "Isso vai parar o servico de busca do Windows e apagar o indice atual, deixando ele se reconstruir do zero. A busca pode ficar mais lenta/incompleta ate terminar de reindexar em segundo plano (pode levar um tempo).`n`nDeseja continuar?" "Reconstruir Indice de Busca")) { return }
    $ov = Show-BusyOverlay -Text "Reconstruindo indice de busca..."
    try {
        try { Stop-Service -Name "WSearch" -Force -ErrorAction Stop } catch {
            Close-BusyOverlay -Overlay $ov
            Show-Warning "Nao foi possivel parar o servico de busca (WSearch)."
            return
        }
        Start-Sleep -Seconds 2
        $dataPath = Join-Path $env:ProgramData "Microsoft\Search\Data\Applications\Windows"
        if (Test-Path $dataPath) { Get-ChildItem -Path $dataPath -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue }
        try { Start-Service -Name "WSearch" -ErrorAction SilentlyContinue } catch {}
        Write-Log -Message "[REPAIR] Indice de busca apagado - Windows vai reconstruir em segundo plano." -Level "SUCCESS"
    } finally { Close-BusyOverlay -Overlay $ov }
    Show-Info "Indice de busca apagado. O Windows Search vai reconstrui-lo automaticamente em segundo plano."
}

function Invoke-DiskOptimize {
    param([string]$Drive = "C")
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    Set-Status ("Otimizando disco {0}: - isso pode levar varios minutos..." -f $Drive)
    # "defrag /O" detecta o tipo de midia sozinho: faz TRIM em SSD e
    # desfragmentacao tradicional em HD, sem precisar perguntar qual e.
    $r = Invoke-VisibleConsoleCommand ("defrag {0}: /O" -f $Drive) ("[REPAIR] defrag {0}: /O" -f $Drive) 1800 ("Otimizando disco {0}: - isso pode levar varios minutos..." -f $Drive)
    Show-ProcessResultInfo -Result $r -Titulo ("Otimizar Disco {0}:" -f $Drive)
}

function Invoke-BatteryReport {
    $outPath = Join-Path $env:TEMP ("BatteryReport_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".html")
    $r = Invoke-ConsoleCommand ("powercfg /batteryreport /output "+([char]34)+$outPath+([char]34)) "[REPAIR] powercfg batteryreport" 30 -BusyText "Gerando relatorio de bateria..."
    if (Test-Path $outPath) {
        try { Start-Process $outPath } catch {}
        Show-Info ("Relatorio de bateria gerado e aberto no navegador.`n`nArquivo: {0}" -f $outPath)
    } else {
        Show-Warning "Nao foi possivel gerar o relatorio de bateria (a maquina pode nao ter bateria, ex.: desktop)."
    }
}

# ---- GERENCIADOR DE ITENS DE INICIALIZACAO ----
# "Desativar" NUNCA apaga nada - move o valor de registro pra uma chave de
# backup propria (HKCU:\Software\ElginServiceDesk\DisabledStartup) ou o
# atalho pra uma subpasta "_DesativadoElgin" dentro da propria pasta
# Inicializar (o Windows so roda atalhos direto na pasta, nao em
# subpastas - isso ja desativa sem precisar apagar o arquivo). "Reativar"
# desfaz exatamente isso.
$global:StartupBackupKey = "HKCU:\Software\ElginServiceDesk\DisabledStartup"
$global:StartupRegSources = @(
    @{ Path="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; Tag="HKLM_Run" }
    @{ Path="HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Tag="HKLM_Run32" }
    @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; Tag="HKCU_Run" }
)

function Get-StartupRegSourcePath {
    param([string]$Tag)
    $found = $global:StartupRegSources | Where-Object { $_.Tag -eq $Tag }
    if ($found) { return $found.Path }
    return $null
}

function Get-StartupItems {
    $itens = New-Object System.Collections.ArrayList
    foreach ($src in $global:StartupRegSources) {
        if (Test-Path $src.Path) {
            $props = Get-ItemProperty -Path $src.Path -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($prop in $props.PSObject.Properties) {
                    if ($prop.Name -match '^PS(Path|ParentPath|ChildName|Provider)$') { continue }
                    [void]$itens.Add([PSCustomObject]@{
                        Nome=[string]$prop.Name; Comando=[string]$prop.Value; Origem=$src.Tag; Tipo="Registro"; CaminhoArquivo=$null
                    })
                }
            }
        }
    }
    foreach ($folderInfo in @(
        @{ Path=[Environment]::GetFolderPath('Startup'); Tag="Startup_User" }
        @{ Path=[Environment]::GetFolderPath('CommonStartup'); Tag="Startup_AllUsers" }
    )) {
        if (Test-Path $folderInfo.Path) {
            Get-ChildItem -Path $folderInfo.Path -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                [void]$itens.Add([PSCustomObject]@{
                    Nome=$_.BaseName; Comando=$_.FullName; Origem=$folderInfo.Tag; Tipo="Pasta Inicializar"; CaminhoArquivo=$_.FullName
                })
            }
        }
    }
    return @($itens | Sort-Object Nome)
}

function Get-DisabledStartupItems {
    $itens = New-Object System.Collections.ArrayList
    if (Test-Path $global:StartupBackupKey) {
        $props = Get-ItemProperty -Path $global:StartupBackupKey -ErrorAction SilentlyContinue
        if ($props) {
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -match '^PS(Path|ParentPath|ChildName|Provider)$') { continue }
                $parts = $prop.Name -split '\|',2
                if ($parts.Count -eq 2) {
                    [void]$itens.Add([PSCustomObject]@{ Origem=$parts[0]; Nome=$parts[1]; Comando=[string]$prop.Value; Tipo="Registro"; CaminhoArquivo=$null })
                }
            }
        }
    }
    foreach ($folderInfo in @(
        @{ Path=(Join-Path ([Environment]::GetFolderPath('Startup')) "_DesativadoElgin"); Tag="Startup_User" }
        @{ Path=(Join-Path ([Environment]::GetFolderPath('CommonStartup')) "_DesativadoElgin"); Tag="Startup_AllUsers" }
    )) {
        if (Test-Path $folderInfo.Path) {
            Get-ChildItem -Path $folderInfo.Path -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                [void]$itens.Add([PSCustomObject]@{ Origem=$folderInfo.Tag; Nome=$_.BaseName; Comando=$_.FullName; Tipo="Pasta Inicializar"; CaminhoArquivo=$_.FullName })
            }
        }
    }
    return @($itens | Sort-Object Nome)
}

function Disable-StartupItem {
    param([Parameter(Mandatory=$true)]$Item)
    if (($Item.Origem -eq "HKLM_Run" -or $Item.Origem -eq "HKLM_Run32" -or $Item.Origem -eq "Startup_AllUsers") -and -not $global:IsAdmin) {
        Show-Warning "Este item vale para todos os usuarios da maquina - requer Administrador para desativar."
        return $false
    }
    try {
        if ($Item.Tipo -eq "Registro") {
            if (-not (Test-Path $global:StartupBackupKey)) { New-Item -Path $global:StartupBackupKey -Force | Out-Null }
            $backupName = "{0}|{1}" -f $Item.Origem,$Item.Nome
            Set-ItemProperty -Path $global:StartupBackupKey -Name $backupName -Value $Item.Comando -Type String -Force
            $livePath = Get-StartupRegSourcePath -Tag $Item.Origem
            if ($livePath) { Remove-ItemProperty -Path $livePath -Name $Item.Nome -ErrorAction SilentlyContinue }
        } else {
            $parentFolder = Split-Path $Item.CaminhoArquivo -Parent
            $disabledFolder = Join-Path $parentFolder "_DesativadoElgin"
            if (-not (Test-Path $disabledFolder)) { New-Item -Path $disabledFolder -ItemType Directory -Force | Out-Null }
            Move-Item -Path $Item.CaminhoArquivo -Destination $disabledFolder -Force
        }
        Write-Log -Message ("[STARTUP] Desativado: {0} ({1})" -f $Item.Nome,$Item.Origem) -Level "SUCCESS"
        return $true
    } catch {
        Write-Log -Message ("[STARTUP] Falha ao desativar {0}: {1}" -f $Item.Nome,$_.Exception.Message) -Level "ERROR"
        return $false
    }
}

function Enable-StartupItem {
    param([Parameter(Mandatory=$true)]$Item)
    if (($Item.Origem -eq "HKLM_Run" -or $Item.Origem -eq "HKLM_Run32" -or $Item.Origem -eq "Startup_AllUsers") -and -not $global:IsAdmin) {
        Show-Warning "Este item vale para todos os usuarios da maquina - requer Administrador para reativar."
        return $false
    }
    try {
        if ($Item.Tipo -eq "Registro") {
            $livePath = Get-StartupRegSourcePath -Tag $Item.Origem
            if (-not $livePath) { return $false }
            if (-not (Test-Path $livePath)) { New-Item -Path $livePath -Force | Out-Null }
            Set-ItemProperty -Path $livePath -Name $Item.Nome -Value $Item.Comando -Type String -Force
            $backupName = "{0}|{1}" -f $Item.Origem,$Item.Nome
            if (Test-Path $global:StartupBackupKey) { Remove-ItemProperty -Path $global:StartupBackupKey -Name $backupName -ErrorAction SilentlyContinue }
        } else {
            $disabledFolder = Split-Path $Item.CaminhoArquivo -Parent
            $parentFolder = Split-Path $disabledFolder -Parent
            Move-Item -Path $Item.CaminhoArquivo -Destination $parentFolder -Force
        }
        Write-Log -Message ("[STARTUP] Reativado: {0} ({1})" -f $Item.Nome,$Item.Origem) -Level "SUCCESS"
        return $true
    } catch {
        Write-Log -Message ("[STARTUP] Falha ao reativar {0}: {1}" -f $Item.Nome,$_.Exception.Message) -Level "ERROR"
        return $false
    }
}

$script:StartupManagerDialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Itens de Inicializacao" Height="600" Width="740"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="{DynamicResource BrushWindowBg}">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Text="Itens de Inicializacao" Foreground="{DynamicResource BrushText}" FontSize="18" FontWeight="Bold" Margin="0,0,0,4"/>
        <TextBlock Grid.Row="1" Text="Programas que iniciam junto com o Windows. Desativar move o item pra um local de backup - nada e apagado, e pode ser reativado depois." Foreground="{DynamicResource BrushTextMuted}" FontSize="11.5" TextWrapping="Wrap" Margin="0,0,0,12"/>

        <DataGrid Grid.Row="2" x:Name="DgStartupAtivos" AutoGenerateColumns="False" IsReadOnly="True"
                  Background="{DynamicResource BrushSurface}" Foreground="{DynamicResource BrushText}" BorderThickness="1" BorderBrush="{DynamicResource BrushBorder}"
                  HeadersVisibility="Column" RowBackground="{DynamicResource BrushSurface}" AlternatingRowBackground="{DynamicResource BrushSurfaceAlt}"
                  GridLinesVisibility="None" RowHeight="36" Margin="0,0,0,4">
            <DataGrid.Columns>
                <DataGridTextColumn Header="ATIVOS" Binding="{Binding Nome}" Width="1.6*"/>
                <DataGridTextColumn Header="ORIGEM" Binding="{Binding Origem}" Width="1*"/>
                <DataGridTextColumn Header="COMANDO / CAMINHO" Binding="{Binding Comando}" Width="2.6*"/>
                <DataGridTemplateColumn Header="ACAO" Width="100">
                    <DataGridTemplateColumn.CellTemplate>
                        <DataTemplate>
                            <Button Content="Desativar" Width="86" Height="26" FontSize="10.5"
                                    Background="{DynamicResource BrushWarning}" Foreground="White" BorderThickness="0" Cursor="Hand"/>
                        </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
            </DataGrid.Columns>
        </DataGrid>

        <TextBlock Grid.Row="3" Text="DESATIVADOS" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold" Margin="0,8,0,4"/>

        <DataGrid Grid.Row="4" x:Name="DgStartupDesativados" AutoGenerateColumns="False" IsReadOnly="True"
                  Background="{DynamicResource BrushSurface}" Foreground="{DynamicResource BrushText}" BorderThickness="1" BorderBrush="{DynamicResource BrushBorder}"
                  HeadersVisibility="Column" RowBackground="{DynamicResource BrushSurface}" AlternatingRowBackground="{DynamicResource BrushSurfaceAlt}"
                  GridLinesVisibility="None" RowHeight="36">
            <DataGrid.Columns>
                <DataGridTextColumn Header="DESATIVADOS" Binding="{Binding Nome}" Width="1.6*"/>
                <DataGridTextColumn Header="ORIGEM" Binding="{Binding Origem}" Width="1*"/>
                <DataGridTextColumn Header="COMANDO / CAMINHO" Binding="{Binding Comando}" Width="2.6*"/>
                <DataGridTemplateColumn Header="ACAO" Width="100">
                    <DataGridTemplateColumn.CellTemplate>
                        <DataTemplate>
                            <Button Content="Reativar" Width="86" Height="26" FontSize="10.5"
                                    Background="{DynamicResource BrushSuccess}" Foreground="White" BorderThickness="0" Cursor="Hand"/>
                        </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
            </DataGrid.Columns>
        </DataGrid>

        <Button Grid.Row="5" x:Name="BtnFecharStartup" Content="Fechar" Width="100" Height="34" HorizontalAlignment="Right" Margin="0,14,0,0"
                Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0"/>
    </Grid>
</Window>
'@

function Show-StartupManagerDialog {
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:StartupManagerDialogXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow
    Set-DialogTheme -Dialog $dlg

    $dgAtivos = $dlg.FindName("DgStartupAtivos")
    $dgDesativados = $dlg.FindName("DgStartupDesativados")

    $RefreshStartupLists = {
        $dgAtivos.ItemsSource = @(Get-StartupItems)
        $dgDesativados.ItemsSource = @(Get-DisabledStartupItems)
    }.GetNewClosure()
    & $RefreshStartupLists

    $dgAtivos.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($senderObj,$e)
        $btn = $e.OriginalSource
        if ($btn -isnot [System.Windows.Controls.Button]) { return }
        $item = $btn.DataContext
        if ($null -eq $item) { return }
        if (-not (Confirm-Action ("Desativar '{0}'?`n`nO item e movido para backup (nao apagado) e pode ser reativado depois." -f $item.Nome) "Desativar item de inicializacao")) { return }
        if (Disable-StartupItem -Item $item) { & $RefreshStartupLists } else { Show-ErrorBox "Nao foi possivel desativar este item." }
    }.GetNewClosure())

    $dgDesativados.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($senderObj,$e)
        $btn = $e.OriginalSource
        if ($btn -isnot [System.Windows.Controls.Button]) { return }
        $item = $btn.DataContext
        if ($null -eq $item) { return }
        if (Enable-StartupItem -Item $item) { & $RefreshStartupLists } else { Show-ErrorBox "Nao foi possivel reativar este item." }
    }.GetNewClosure())

    $dlg.FindName("BtnFecharStartup").Add_Click({ $dlg.Close() }.GetNewClosure())
    [void]$dlg.ShowDialog()
}

# ---- REDE AVANCADA ----
function Get-WifiProfilesInfo {
    $r = Invoke-ConsoleCommand "netsh wlan show profiles" "[NETWORK] Perfis Wi-Fi" 20 -BusyText "Consultando perfis de Wi-Fi..."
    return $r.Output
}

function Get-NetworkConnectionsInfo {
    $r = Invoke-ConsoleCommand "netstat -ano" "[NETWORK] Conexoes/Portas" 30 -BusyText "Consultando conexoes e portas..."
    return $r.Output
}

function Get-MappedDrivesInfo {
    $r = Invoke-ConsoleCommand "net use" "[NETWORK] Unidades mapeadas" 20 -BusyText "Consultando unidades mapeadas..."
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

# Desinstalador oficial do Bitdefender GravityZone (BEST Uninstall Tool) -
# reaproveita Install-DirectApp (baixa + roda com os argumentos de
# desinstalacao), mesmo mecanismo generico ja usado no Pacote Extra.
function Invoke-BitdefenderUninstall {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    if (-not (Confirm-Action "Isso vai baixar e executar o desinstalador oficial do Bitdefender (BEST Uninstall Tool) nesta maquina. Continuar?" "Desinstalador do Bitdefender")) { return }
    $app = [PSCustomObject]@{
        Name           = "Bitdefender (Desinstalador)"
        Url            = $global:BitdefenderUninstallUrl
        SilentArgs     = $global:BitdefenderUninstallArgs
        Ext            = ".exe"
        IsMSI          = $false
        TimeoutSeconds = 600
    }
    if (Install-DirectApp -App $app) { Show-Info "Desinstalador do Bitdefender executado." }
    else { Show-Warning "Falha ao executar o desinstalador do Bitdefender. Verifique os Logs." }
}

function Show-UninstallerDialog {
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:UninstallerDialogXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow
    Set-DialogTheme -Dialog $dlg

    Set-Status "Lendo programas instalados..."
    $ovUninstall = Show-BusyOverlay -Text "Lendo programas instalados..."
    $todosOsProgramas = @(Get-InstalledProgramsList)
    Close-BusyOverlay -Overlay $ovUninstall
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

# ==============================================================================
# DIALOGO DE ATENCAO (customizado, com triangulo de aviso) - usado antes de
# acoes que merecem uma checagem manual extra antes de continuar (ex.:
# ativacao por script).
# ==============================================================================
$script:AttentionDialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Atencao" Height="270" Width="460"
        WindowStartupLocation="CenterOwner" WindowStyle="None" ResizeMode="NoResize"
        Background="{DynamicResource BrushSurface}">
    <Border BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" CornerRadius="10">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="4"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="{DynamicResource BrushWarning}"/>
            <TextBlock Grid.Row="1" x:Name="TxtAttentionTitle" Text="Atencao" Foreground="{DynamicResource BrushText}" FontSize="16" FontWeight="Bold" Margin="20,16,20,0"/>
            <Grid Grid.Row="2" Margin="20,14,20,10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid Grid.Column="0" Width="40" Height="40" VerticalAlignment="Top" Margin="0,0,14,0">
                    <Polygon Points="20,2 38,36 2,36" Fill="{DynamicResource BrushWarning}"/>
                    <TextBlock Text="!" FontSize="20" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,3"/>
                </Grid>
                <TextBlock Grid.Column="1" x:Name="TxtAttentionMessage" Text="" Foreground="{DynamicResource BrushTextMuted}" FontSize="13" TextWrapping="Wrap" VerticalAlignment="Top"/>
            </Grid>
            <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="20,0,20,18">
                <Button x:Name="BtnAttentionCancelar" Content="CANCELAR" Width="110" Height="36" Margin="0,0,10,0" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0" FontWeight="Bold" Cursor="Hand"/>
                <Button x:Name="BtnAttentionContinuar" Content="CONTINUAR" Width="120" Height="36" Background="{DynamicResource BrushAccent}" Foreground="White" BorderThickness="0" FontWeight="Bold" Cursor="Hand"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
'@

function Show-AttentionDialog {
    param([string]$Title = "Atencao", [string]$Message = "")
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:AttentionDialogXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow
    Set-DialogTheme -Dialog $dlg
    $dlg.Title = $Title
    $dlg.FindName("TxtAttentionTitle").Text = $Title
    $dlg.FindName("TxtAttentionMessage").Text = $Message
    $dlg.FindName("BtnAttentionContinuar").Add_Click({ $dlg.DialogResult = $true; $dlg.Close() }.GetNewClosure())
    $dlg.FindName("BtnAttentionCancelar").Add_Click({ $dlg.DialogResult = $false; $dlg.Close() }.GetNewClosure())
    return [bool]$dlg.ShowDialog()
}

# ==============================================================================
# DIAGNOSTICO
# ==============================================================================

function Get-DiagnosticReportText {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(("Relatorio de Diagnostico - {0}" -f $global:AppName))
    [void]$sb.AppendLine(("Gerado em: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")))
    [void]$sb.AppendLine("============================================================")
    [void]$sb.AppendLine(("Computador: {0}" -f $env:COMPUTERNAME))
    [void]$sb.AppendLine(("Usuario: {0}" -f $env:USERNAME))
    [void]$sb.AppendLine(("Administrador: {0}" -f $global:IsAdmin))
    [void]$sb.AppendLine(("Winget: {0}" -f $global:HasWinget))
    [void]$sb.AppendLine(("Chocolatey: {0}" -f $global:HasChoco))
    [void]$sb.AppendLine(("Internet: {0}" -f $global:HasInternet))
    [void]$sb.AppendLine("")

    try {
        $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $uptime = (Get-Date) - $os.LastBootUpTime

        [void]$sb.AppendLine(("Sistema Operacional: {0}" -f $os.Caption))
        [void]$sb.AppendLine(("Versao: {0} | Build: {1} | Arquitetura: {2}" -f $os.Version,$os.BuildNumber,$os.OSArchitecture))
        [void]$sb.AppendLine(("Ultimo boot: {0} | Uptime: {1:N1} horas" -f $os.LastBootUpTime.ToString("dd/MM/yyyy HH:mm:ss"),$uptime.TotalHours))
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine(("Fabricante: {0}" -f $cs.Manufacturer))
        [void]$sb.AppendLine(("Modelo: {0}" -f $cs.Model))
        $dominio = if ($cs.PartOfDomain) { $cs.Domain } else { $cs.Workgroup }
        [void]$sb.AppendLine(("Dominio/Grupo: {0}" -f $dominio))
        [void]$sb.AppendLine(("Memoria RAM: {0:N2} GB" -f ($cs.TotalPhysicalMemory / 1GB)))
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine(("Serial/Service Tag: {0}" -f $bios.SerialNumber))
    } catch { [void]$sb.AppendLine(("Falha ao ler informacoes do sistema: {0}" -f $_.Exception.Message)) }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Discos:")
    try {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | ForEach-Object {
            [void]$sb.AppendLine(("  {0} Total: {1:N2} GB | Livre: {2:N2} GB" -f $_.DeviceID,($_.Size/1GB),($_.FreeSpace/1GB)))
        }
    } catch { [void]$sb.AppendLine("  Falha ao ler discos.") }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Rede:")
    try {
        Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction Stop | ForEach-Object {
            $ip  = @($_.IPAddress) -join ", "
            $gw  = @($_.DefaultIPGateway) -join ", "
            $dns = @($_.DNSServerSearchOrder) -join ", "
            [void]$sb.AppendLine(("  {0}" -f $_.Description))
            [void]$sb.AppendLine(("    IP: {0} | Gateway: {1}" -f $ip,$gw))
            [void]$sb.AppendLine(("    MAC: {0} | DNS: {1}" -f $_.MACAddress,$dns))
        }
    } catch { [void]$sb.AppendLine("  Falha ao ler configuracao de rede.") }

    return $sb.ToString()
}

function Save-DiagnosticReportTxt {
    param([string]$Text)
    $path = Join-Path $global:ReportsPath ("Diagnostico-{0}-{1}.txt" -f $env:COMPUTERNAME,(Get-Date -Format "yyyyMMdd-HHmmss"))
    $Text | Out-File -FilePath $path -Encoding UTF8 -Force
    return $path
}

function Save-DiagnosticReportHtml {
    param([string]$Text)
    $path = Join-Path $global:ReportsPath ("Diagnostico-{0}-{1}.html" -f $env:COMPUTERNAME,(Get-Date -Format "yyyyMMdd-HHmmss"))
    $escaped = [System.Net.WebUtility]::HtmlEncode($Text)
    $html = "<html><head><meta charset=" + ([char]34) + "utf-8" + ([char]34) + "><title>Relatorio de Diagnostico</title></head><body><pre style=" + ([char]34) + "font-family:Consolas,monospace;font-size:13px;" + ([char]34) + ">" + $escaped + "</pre></body></html>"
    $html | Out-File -FilePath $path -Encoding UTF8 -Force
    return $path
}

function Open-ReportsFolder {
    try { Start-Process explorer.exe -ArgumentList $global:ReportsPath } catch { Show-Warning "Nao foi possivel abrir a pasta de relatorios." }
}

function Open-BatterySettings {
    try { Start-Process "ms-settings:batterysaver" } catch { Show-Warning "Nao foi possivel abrir as configuracoes de bateria." }
}

# Mesma logica que o Windows/slmgr/ospp usam para reportar ativacao -
# LicenseStatus 1 = licenciado. Office e detectado procurando ospp.vbs nas
# pastas padrao de instalacao (o caminho muda conforme a versao/arquitetura
# do Office instalado).
function Get-ActivationStatusText {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("WINDOWS")
        try {
            $lic = Get-CimInstance -Query "SELECT LicenseStatus,Name FROM SoftwareLicensingProduct WHERE PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction Stop
            if ($lic) {
                foreach ($l in @($lic)) {
                    $status = switch ([int]$l.LicenseStatus) {
                        0 { "Nao licenciado" }
                        1 { "Licenciado (ativado)" }
                        2 { "Periodo inicial (grace)" }
                        3 { "Modo indulgente (nao genuino)" }
                        4 { "Nao autorizado (VL nao ativado)" }
                        5 { "Notificacao (nao ativado)" }
                        default { "Status desconhecido ({0})" -f $l.LicenseStatus }
                    }
                    [void]$sb.AppendLine(("  {0}: {1}" -f $l.Name,$status))
                }
            } else { [void]$sb.AppendLine("  Nao foi possivel ler o status de licenciamento.") }
        } catch { [void]$sb.AppendLine(("  Falha ao consultar ativacao do Windows: {0}" -f $_.Exception.Message)) }

        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("OFFICE")
        try {
            $osppCandidates = @(Get-ChildItem -Path "C:\Program Files\Microsoft Office*","C:\Program Files (x86)\Microsoft Office*" -Filter "ospp.vbs" -Recurse -ErrorAction SilentlyContinue)
        } catch { $osppCandidates = @() }
        if ($osppCandidates.Count -eq 0) {
            [void]$sb.AppendLine("  Office nao encontrado (ospp.vbs nao localizado).")
        } else {
            $ospp = $osppCandidates[0].FullName
            $r = Invoke-ConsoleCommand ("cscript //nologo "+([char]34)+$ospp+([char]34)+" /dstatus") "[DIAG] ospp.vbs /dstatus" 30 -BusyText "Verificando ativacao do Office..."
            if ($r.Output) { [void]$sb.AppendLine($r.Output.Trim()) } else { [void]$sb.AppendLine("  Nao foi possivel ler o status do Office.") }
        }
        return $sb.ToString()
}

function Get-BootHistory {
    try {
        $eventos = Get-WinEvent -FilterHashtable @{LogName='System'; Id=6005} -MaxEvents 15 -ErrorAction Stop
        return @($eventos | ForEach-Object {
            [PSCustomObject]@{
                DataHoraInicio = $_.TimeCreated.ToString("dd/MM/yyyy HH:mm:ss")
                DiaDaSemana    = $_.TimeCreated.ToString("dddd")
            }
        })
    } catch { return @() }
}

# ---- HARDWARE E DRIVERS ----
# Lista TODOS os dispositivos com driver assinado (nao so os com problema -
# Win32_PnPSignedDriver ja cobre isso, diferente de filtrar por
# ConfigManagerErrorCode). Baixar/instalar em si e feito pelo proprio
# Windows Update (fonte oficial, sempre compativel com o hardware) ou pelo
# site do fabricante - nao existe uma forma segura e universal de "baixar o
# arquivo certo" pra qualquer hardware/fabricante fora dessas duas fontes
# oficiais, entao a ferramenta abre elas em vez de tentar reinventar isso.
function Get-DeviceDriverInventory {
    $ov = Show-BusyOverlay -Text "Escaneando dispositivos e drivers..."
    try {
        $devices = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object { $_.DeviceName } | Sort-Object DeviceClass,DeviceName
        return @($devices | ForEach-Object {
            $dataStr = ""
            if ($_.DriverDate) {
                try {
                    $dt = if ($_.DriverDate -is [datetime]) { $_.DriverDate } else { [Management.ManagementDateTimeConverter]::ToDateTime([string]$_.DriverDate) }
                    $dataStr = $dt.ToString("dd/MM/yyyy")
                } catch { $dataStr = "" }
            }
            [PSCustomObject]@{
                Dispositivo  = [string]$_.DeviceName
                Classe       = [string]$_.DeviceClass
                Fabricante   = [string]$_.Manufacturer
                VersaoDriver = [string]$_.DriverVersion
                DataDriver   = $dataStr
            }
        })
    } finally { Close-BusyOverlay -Overlay $ov }
}

function Open-WindowsUpdateDriverScan {
    try { & pnputil.exe /scan-devices | Out-Null } catch {}
    try { Start-Process "ms-settings:windowsupdate-optionalupdates" -ErrorAction Stop }
    catch { try { Start-Process "ms-settings:windowsupdate" } catch { Show-Warning "Nao foi possivel abrir o Windows Update."; return } }
    Show-Info "Abrindo Windows Update. Em 'Atualizacoes opcionais > Atualizacoes de driver' aparecem os drivers disponiveis (fonte oficial da Microsoft) para instalar."
}

# So Dell tem um padrao de URL por Service Tag confirmado e estavel o
# suficiente pra linkar direto - HP/Lenovo/outros vao pra pagina geral de
# drivers do fabricante (link profundo por numero de serie neles nao e
# confiavel o bastante pra garantir que abre no lugar certo).
function Open-ManufacturerDriverPage {
    try {
        $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $fabricante = [string]$cs.Manufacturer
        $tag        = [string]$bios.SerialNumber
        $url = $null
        if ($fabricante -match "Dell") { $url = "https://www.dell.com/support/home/pt-br/product-support/servicetag/{0}/drivers" -f $tag }
        elseif ($fabricante -match "HP|Hewlett") { $url = "https://support.hp.com/us-en/drivers" }
        elseif ($fabricante -match "Lenovo") { $url = "https://pcsupport.lenovo.com/" }
        elseif ($fabricante -match "ASUS") { $url = "https://www.asus.com/support/" }
        elseif ($fabricante -match "Acer") { $url = "https://www.acer.com/br-pt/support" }
        if ($url) {
            Start-Process $url
            if ($fabricante -notmatch "Dell") { Show-Info ("Site do fabricante aberto. Use o Serial/Service Tag para localizar os drivers: {0}" -f $tag) }
        } else {
            Show-Warning ("Fabricante '{0}' nao reconhecido para link direto. Serial/Service Tag da maquina: {1}" -f $fabricante,$tag)
        }
    } catch { Show-Warning "Nao foi possivel identificar o fabricante/service tag da maquina." }
}

# Ativacao por script (Microsoft Activation Scripts, get.activated.win) -
# abre uma janela de PowerShell PROPRIA e visivel (mesmo padrao ja usado em
# Invoke-RemoveWindowsAI: escreve um .cmd temporario e da Start-Process nele,
# sem esperar) porque o script e interativo (o tecnico escolhe opcoes no
# menu dele) - nao faz sentido nem e seguro tentar capturar/automatizar essa
# interacao por aqui.
$global:ActivationScriptUrl = "https://get.activated.win"

function Invoke-ActivationByScript {
    if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
    $msg = "Antes de ativar o Windows ou Office por script deve-se primeiro confirmar a versao conforme etiqueta do equipamento e, se nao ha uma chave de ativacao, confirmar com o lider ou coordenador."
    if (-not (Show-AttentionDialog -Title "Ativacao por Script" -Message $msg)) { return }
    Write-Log -Message "[ACTIVATION] Solicitada ativacao por script (get.activated.win)." -Level "WARN"
    $cmdFile = $null
    try {
        $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        if (-not (Test-Path $psExe)) { $psExe = "powershell.exe" }
        $cmdFile = Join-Path $env:TEMP ("Elgin_Ativacao_" + [guid]::NewGuid().ToString("N") + ".cmd")
        $quote     = [char]34
        $psCommand = "irm " + $global:ActivationScriptUrl + " | iex"
        $cmdBody   = "@echo off`r`n" + $quote + $psExe + $quote + " -NoProfile -NoExit -Command " + $quote + $psCommand + $quote + "`r`n"
        Set-Content -Path $cmdFile -Value $cmdBody -Encoding ASCII -Force
        Start-Process -FilePath $cmdFile -ErrorAction Stop
        Write-Log -Message "[ACTIVATION] Janela de ativacao por script aberta." -Level "INFO"
    } catch {
        Write-Log -Message ("[ACTIVATION] Falha ao abrir ativacao por script: {0}" -f $_.Exception.Message) -Level "ERROR"
        Show-ErrorBox ("Falha ao iniciar a ativacao por script.`n`n{0}" -f $_.Exception.Message)
    }
}

$script:XamlPanelsD = @'
                <!-- Diagnostico -->
                <Grid x:Name="PanelDiagnostico" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,14">
                        <Border Width="40" Height="40" CornerRadius="9" Background="#2563EB" Margin="0,0,12,0">
                            <TextBlock Text="DG" FontSize="13" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Text="Diagnostico" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" VerticalAlignment="Center"/>
                    </StackPanel>

                    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,14">
                        <Button x:Name="TabDiagGeral" Content="Geral" Height="34" Padding="16,0" Margin="0,0,6,0" Background="{DynamicResource BrushActiveNav}" Foreground="{DynamicResource BrushAccent}" FontWeight="Bold" BorderThickness="0" Cursor="Hand"/>
                        <Button x:Name="TabDiagHardware" Content="Hardware &amp; Drivers" Height="34" Padding="16,0" Margin="0,0,6,0" Background="Transparent" Foreground="{DynamicResource BrushTextMuted}" BorderThickness="0" Cursor="Hand"/>
                        <Button x:Name="TabDiagEventos" Content="Eventos" Height="34" Padding="16,0" Margin="0,0,6,0" Background="Transparent" Foreground="{DynamicResource BrushTextMuted}" BorderThickness="0" Cursor="Hand"/>
                        <Button x:Name="TabDiagAtivacao" Content="Ativacao &amp; Boot" Height="34" Padding="16,0" Background="Transparent" Foreground="{DynamicResource BrushTextMuted}" BorderThickness="0" Cursor="Hand"/>
                    </StackPanel>

                    <Grid Grid.Row="2">
                        <!-- GERAL -->
                        <Grid x:Name="SubDiagGeral" Visibility="Visible">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <Border Grid.Row="0" Background="{DynamicResource BrushSurfaceAlt}" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" CornerRadius="8" Margin="0,0,0,12">
                                <TextBox x:Name="TxtDiagReport" Background="Transparent" Foreground="{DynamicResource BrushText}" FontFamily="Consolas" FontSize="12" Padding="12"
                                         BorderThickness="0" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
                            </Border>
                            <UniformGrid Grid.Row="1" Columns="5" Margin="0,0,0,8">
                                <Button x:Name="BtnDiagMostrarInfo" Content="Mostrar Info" Height="36" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                                <Button x:Name="BtnDiagSalvarTxt" Content="Salvar TXT" Height="36" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushSuccess}"/>
                                <Button x:Name="BtnDiagSalvarHtml" Content="Salvar HTML" Height="36" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushSuccess}"/>
                                <Button x:Name="BtnDiagCopiar" Content="Copiar" Height="36" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                <Button x:Name="BtnDiagVerRelatorios" Content="Ver Relatorios" Height="36" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                            </UniformGrid>
                            <UniformGrid Grid.Row="2" Columns="2">
                                <Button x:Name="BtnDiagRelatorioBateria" Content="Relatorio Bateria" Height="36" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushWarning}"/>
                                <Button x:Name="BtnDiagAbrirBateria" Content="Abrir Bateria" Height="36" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                            </UniformGrid>
                        </Grid>

                        <!-- HARDWARE E DRIVERS -->
                        <Grid x:Name="SubDiagHardware" Visibility="Collapsed">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <TextBlock Grid.Row="0" Text="Lista todos os dispositivos e drivers instalados (nao so os com problema). Para baixar/atualizar, use o Windows Update (fonte oficial da Microsoft) ou o site do fabricante." Foreground="{DynamicResource BrushTextMuted}" FontSize="11.5" TextWrapping="Wrap" Margin="0,0,0,10"/>
                            <Border Grid.Row="1" Background="{DynamicResource BrushSurfaceAlt}" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" CornerRadius="8" Margin="0,0,0,12">
                                <DataGrid x:Name="DgDiagDrivers" AutoGenerateColumns="False" IsReadOnly="True" Background="Transparent" Foreground="{DynamicResource BrushText}" BorderThickness="0"
                                          HeadersVisibility="Column" RowBackground="{DynamicResource BrushSurfaceAlt}" AlternatingRowBackground="{DynamicResource BrushSurface}"
                                          GridLinesVisibility="None" RowHeight="30">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="DISPOSITIVO" Binding="{Binding Dispositivo}" Width="2.2*"/>
                                        <DataGridTextColumn Header="CLASSE" Binding="{Binding Classe}" Width="1*"/>
                                        <DataGridTextColumn Header="FABRICANTE" Binding="{Binding Fabricante}" Width="1.2*"/>
                                        <DataGridTextColumn Header="VERSAO DRIVER" Binding="{Binding VersaoDriver}" Width="1*"/>
                                        <DataGridTextColumn Header="DATA" Binding="{Binding DataDriver}" Width="0.8*"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </Border>
                            <UniformGrid Grid.Row="2" Columns="3">
                                <Button x:Name="BtnDiagEscanearDrivers" Content="Escanear Dispositivos" Height="38" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                                <Button x:Name="BtnDiagWuDrivers" Content="Verificar no Windows Update" Height="38" Margin="6,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                <Button x:Name="BtnDiagSiteFabricante" Content="Site do Fabricante (Drivers)" Height="38" Margin="6,0,0,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                            </UniformGrid>
                        </Grid>

                        <!-- EVENTOS -->
                        <Grid x:Name="SubDiagEventos" Visibility="Collapsed">
                            <TextBlock Text="Ainda sem conteudo definido para esta aba - aguardando referencia visual (print) pra portar certo." Foreground="{DynamicResource BrushTextMuted}" FontSize="13" TextWrapping="Wrap" VerticalAlignment="Top" HorizontalAlignment="Left"/>
                        </Grid>

                        <!-- ATIVACAO E BOOT -->
                        <Grid x:Name="SubDiagAtivacao" Visibility="Collapsed">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="1.1*"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="1.4*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <TextBlock Grid.Row="0" Text="ATIVACAO WINDOWS E OFFICE" Foreground="{DynamicResource BrushAccent}" FontSize="12" FontWeight="Bold" Margin="0,0,0,8"/>
                            <Border Grid.Row="1" Background="{DynamicResource BrushSurfaceAlt}" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" CornerRadius="8" Margin="0,0,0,14">
                                <TextBox x:Name="TxtDiagAtivacao" Background="Transparent" Foreground="{DynamicResource BrushText}" FontFamily="Consolas" FontSize="12" Padding="12"
                                         BorderThickness="0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
                            </Border>
                            <TextBlock Grid.Row="2" Text="HISTORICO DE BOOT (ultimos inicios do Windows)" Foreground="{DynamicResource BrushAccent}" FontSize="12" FontWeight="Bold" Margin="0,0,0,8"/>
                            <Border Grid.Row="3" Background="{DynamicResource BrushSurfaceAlt}" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" CornerRadius="8" Margin="0,0,0,14">
                                <DataGrid x:Name="DgDiagBootHistory" AutoGenerateColumns="False" IsReadOnly="True" Background="Transparent" Foreground="{DynamicResource BrushText}" BorderThickness="0"
                                          HeadersVisibility="Column" RowBackground="{DynamicResource BrushSurfaceAlt}" AlternatingRowBackground="{DynamicResource BrushSurface}"
                                          GridLinesVisibility="None" RowHeight="32">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="DATA/HORA INICIO" Binding="{Binding DataHoraInicio}" Width="1*"/>
                                        <DataGridTextColumn Header="DIA DA SEMANA" Binding="{Binding DiaDaSemana}" Width="1*"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </Border>
                            <UniformGrid Grid.Row="4" Columns="3">
                                <Button x:Name="BtnDiagVerificarAtivacao" Content="Verificar Ativacao" Height="38" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                                <Button x:Name="BtnDiagHistoricoBoot" Content="Historico de Boot" Height="38" Margin="6,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                <Button x:Name="BtnDiagAtivarScript" Content="Ativar por Script" Height="38" Margin="6,0,0,0" Style="{StaticResource CardButton}" Background="#7C3AED"/>
                            </UniformGrid>
                        </Grid>
                    </Grid>
                </Grid>

                <!-- Rede -->
                <Grid x:Name="PanelRede" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Rede" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,4"/>
                    <TextBlock Grid.Row="1" Text="Diagnostico de rede, Wi-Fi, conexoes/portas e unidades mapeadas." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,14"/>
                    <ScrollViewer Grid.Row="2">
                        <StackPanel>
                            <!-- REDE -->
                            <Border Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="REDE" Foreground="{DynamicResource BrushAccent}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <UniformGrid Columns="3">
                                        <Button x:Name="BtnFerrFlushDns" Content="Flush DNS" Height="36" Margin="0,0,6,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" ToolTip="Limpa o cache de resolucao DNS local."/>
                                        <Button x:Name="BtnFerrRenewIp" Content="Renew IP" Height="36" Margin="0,0,6,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" ToolTip="Libera e renova o endereco IP da conexao ativa. Requer Administrador."/>
                                        <Button x:Name="BtnFerrWinsock" Content="Reset Winsock" Height="36" Margin="0,0,0,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" ToolTip="Reinicia o catalogo Winsock. Requer reiniciar o computador depois. Requer Administrador."/>
                                        <Button x:Name="BtnFerrPing" Content="Ping Google" Height="36" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" ToolTip="Testa conectividade externa (8.8.8.8)."/>
                                        <Button x:Name="BtnFerrDns" Content="Teste DNS" Height="36" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" ToolTip="Resolve google.com para checar o DNS configurado."/>
                                    </UniformGrid>
                                </StackPanel>
                            </Border>

                            <!-- REDE AVANCADA -->
                            <Border Style="{StaticResource Card}">
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
                        </StackPanel>
                    </ScrollViewer>
                </Grid>

                <!-- Deploy Remoto -->
                <Grid x:Name="PanelDeploy" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Deploy Remoto" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,4"/>
                    <TextBlock Grid.Row="1" Text="Roda instaladores/desinstaladores personalizados (URL + parametros cadastrados por voce) remotamente via PowerShell Remoting (WinRM). Requer WinRM habilitado e credencial de administrador na maquina alvo." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,14" TextWrapping="Wrap"/>
                    <ScrollViewer Grid.Row="2">
                        <StackPanel>
                            <Border Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="CREDENCIAL DE ADMINISTRADOR" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <StackPanel Orientation="Horizontal">
                                        <StackPanel Margin="0,0,14,0">
                                            <TextBlock Text="Usuario (DOMINIO\usuario)" FontSize="11" Foreground="{DynamicResource BrushTextMuted}" Margin="0,0,0,4"/>
                                            <TextBox x:Name="TxtDeployUser" Style="{StaticResource SearchBox}" Width="260"/>
                                        </StackPanel>
                                        <StackPanel>
                                            <TextBlock Text="Senha" FontSize="11" Foreground="{DynamicResource BrushTextMuted}" Margin="0,0,0,4"/>
                                            <PasswordBox x:Name="PwdDeploy" Width="260" Height="34" Padding="10,0" Background="{DynamicResource BrushInputBg}" BorderBrush="{DynamicResource BrushInputBorder}" BorderThickness="1" Foreground="{DynamicResource BrushText}" VerticalContentAlignment="Center"/>
                                        </StackPanel>
                                    </StackPanel>
                                    <TextBlock Text="A senha fica so em memoria enquanto a ferramenta esta aberta - nunca e salva em disco." Foreground="{DynamicResource BrushTextFaint}" FontSize="10.5" Margin="0,8,0,0"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="MAQUINAS ALVO" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                                        <TextBox x:Name="TxtDeployHostname" Style="{StaticResource SearchBox}" Width="260" Margin="0,0,10,0"/>
                                        <Button x:Name="BtnDeployAddHost" Content="Adicionar" Width="120" Height="36" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Margin="0,0,10,0"/>
                                        <Button x:Name="BtnDeployScan" Content="Escanear Rede" Width="150" Height="36" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                    </StackPanel>
                                    <Border Background="{DynamicResource BrushSurfaceAlt}" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" CornerRadius="8" Padding="4" MinHeight="60" MaxHeight="240">
                                        <ScrollViewer VerticalScrollBarVisibility="Auto">
                                            <StackPanel x:Name="SpDeployHosts"/>
                                        </ScrollViewer>
                                    </Border>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="APPS PERSONALIZADOS" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <TextBlock Text="Lista propria (URL de download + parametros digitados por voce) - nao usa mais o Pacote Extra. O mesmo campo de parametros serve tanto pra instalar quanto pra desinstalar, dependendo do que voce cadastrar." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,10" TextWrapping="Wrap"/>
                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                        <Button x:Name="BtnDeployAdicionarApp" Content="Adicionar App" Width="130" Height="28" FontSize="11" Style="{StaticResource CardButton}" Background="{DynamicResource BrushSuccess}" Margin="0,0,8,0"/>
                                        <Button x:Name="BtnDeployMarcarTodos" Content="Marcar Todos" Width="120" Height="28" FontSize="11" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" Margin="0,0,8,0"/>
                                        <Button x:Name="BtnDeployDesmarcarTodos" Content="Desmarcar Todos" Width="130" Height="28" FontSize="11" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                    </StackPanel>
                                    <StackPanel x:Name="SpDeployApps"/>
                                    <Button x:Name="BtnDeployExecutar" Content="Executar Selecionados nas Maquinas Selecionadas" Width="360" Height="38" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Margin="0,14,0,0"/>
                                </StackPanel>
                            </Border>

                            <TextBlock Text="RESULTADO" Foreground="{DynamicResource BrushTextFaint}" FontSize="11" FontWeight="Bold" Margin="4,6,0,10"/>
                            <Border Style="{StaticResource Card}" Margin="0,0,0,20">
                                <ScrollViewer MaxHeight="260">
                                    <StackPanel x:Name="SpDeployLog"/>
                                </ScrollViewer>
                            </Border>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>

                <!-- Limpeza e Otimizacao -->
                <Grid x:Name="PanelLimpeza" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Limpeza e Otimizacao" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,4"/>
                    <TextBlock Grid.Row="1" Text="Limpeza de arquivos, reparos do Windows, IA/desempenho e analise de disco." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,14"/>
                    <ScrollViewer Grid.Row="2">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <!-- LIMPEZA -->
                            <Border Grid.Row="0" Grid.Column="0" Margin="0,0,5,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="LIMPEZA" Foreground="{DynamicResource BrushAccent}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <CheckBox x:Name="ChkLimpTemp" Content="Temporarios do usuario" IsChecked="True"/>
                                    <CheckBox x:Name="ChkLimpTempTodos" Content="Temporarios de TODOS os usuarios da maquina" ToolTip="Percorre C:\Users\* em vez de so o perfil logado. Requer Administrador."/>
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
                                    </UniformGrid>
                                    <Button x:Name="BtnWingetUpgrade" Content="Atualizar Apps Winget" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushSuccess}" Margin="0,0,0,8"/>
                                    <Button x:Name="BtnChkdsk" Content="Chkdsk /f (agendar no proximo boot)" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushWarning}" Margin="0,8,0,0" ToolTip="Verifica e corrige erros no disco C: - como o disco esta em uso, a checagem so roda na proxima reinicializacao. Requer Administrador."/>
                                    <Button x:Name="BtnMaxPerformance" Content="Habilitar Maximo Desempenho" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Margin="0,8,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- LIMPEZA DO SISTEMA -->
                            <Border Grid.Row="1" Grid.Column="0" Margin="0,0,5,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="LIMPEZA DO SISTEMA" Foreground="{DynamicResource BrushAccent}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <UniformGrid Columns="2">
                                        <Button x:Name="BtnLimparPrefetch" Content="Limpar Prefetch" Height="36" Margin="0,0,6,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnLimparFontCache" Content="Limpar Cache de Fontes" Height="36" Margin="6,0,0,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnVerShadowCopies" Content="Ver Shadow Copies" Height="36" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnWinSxSCleanup" Content="WinSxS / DISM Cleanup" Height="36" Margin="6,0,0,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushWarning}"/>
                                    </UniformGrid>
                                </StackPanel>
                            </Border>

                            <!-- CACHE DE NAVEGADORES -->
                            <Border Grid.Row="1" Grid.Column="1" Margin="5,0,0,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="CACHE DE NAVEGADORES" Foreground="{DynamicResource BrushSuccess}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <CheckBox x:Name="ChkCacheChrome" Content="Google Chrome" IsChecked="True"/>
                                    <CheckBox x:Name="ChkCacheEdge" Content="Microsoft Edge" IsChecked="True"/>
                                    <CheckBox x:Name="ChkCacheFirefox" Content="Mozilla Firefox" IsChecked="True"/>
                                    <Button x:Name="BtnLimparCacheNavegadores" Content="Limpar Cache dos Navegadores" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Margin="0,10,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- IA DO WINDOWS -->
                            <Border Grid.Row="2" Grid.Column="0" Margin="0,0,5,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="IA DO WINDOWS" Foreground="{DynamicResource BrushWarning}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnFerrRemoveAI" Content="Remove IA do Windows" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushWarning}" Margin="0,0,0,10"/>
                                    <TextBlock Text="Libera memoria RAM!" Foreground="{DynamicResource BrushSuccess}" FontSize="11" FontWeight="SemiBold"/>
                                    <TextBlock Text="NAO selecione as opcoes com Triangulo Amarelo!" Foreground="{DynamicResource BrushDanger}" FontSize="11" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- LIMPEZA AVANCADA -->
                            <Border Grid.Row="2" Grid.Column="1" Margin="5,0,0,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="LIMPEZA AVANCADA" Foreground="{DynamicResource BrushDanger}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnRemoverWindowsOld" Content="Remover Windows.old" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushDanger}" Margin="0,0,0,8" ToolTip="Libera espaco da instalacao anterior do Windows. Depois disso nao e mais possivel voltar para a versao anterior. Requer Administrador."/>
                                    <Button x:Name="BtnVerDriverStore" Content="Ver Drivers no DriverStore" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" ToolTip="So mostra a lista - a remocao de driver duplicado e feita manualmente com pnputil pra evitar risco de remover um driver em uso."/>
                                </StackPanel>
                            </Border>

                            <!-- ANALISE DE DISCO -->
                            <Border Grid.Row="3" Grid.Column="0" Margin="0,0,5,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="ANALISE DE DISCO" Foreground="{DynamicResource BrushAccent}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <TextBlock Text="Mostra as maiores pastas dentro do perfil do usuario logado (Downloads, AppData, Desktop, etc.). Pode levar alguns minutos em perfis grandes." Foreground="{DynamicResource BrushTextMuted}" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnAnalisarDisco" Content="Analisar Espaco do Perfil do Usuario" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                                </StackPanel>
                            </Border>

                            <!-- OTIMIZACAO -->
                            <Border Grid.Row="3" Grid.Column="1" Margin="5,0,0,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="OTIMIZACAO" Foreground="{DynamicResource BrushSuccess}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <UniformGrid Columns="2">
                                        <Button x:Name="BtnGerenciarInicializacao" Content="Itens de Inicializacao" Height="36" Margin="0,0,6,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}"/>
                                        <Button x:Name="BtnResetWU" Content="Resetar Windows Update" Height="36" Margin="6,0,0,8" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnReconstruirIndice" Content="Reconstruir Indice de Busca" Height="36" Margin="0,0,6,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                        <Button x:Name="BtnOtimizarDisco" Content="Otimizar Disco (TRIM)" Height="36" Margin="6,0,0,0" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                    </UniformGrid>
                                    <Button x:Name="BtnRelatorioBateria" Content="Relatorio de Bateria" Height="36" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" Margin="0,8,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                </Grid>

                <!-- Ferramentas -->
                <Grid x:Name="PanelFerramentas" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Ferramentas" Foreground="{DynamicResource BrushText}" FontSize="22" FontWeight="Bold" Margin="0,0,0,4"/>
                    <TextBlock Grid.Row="1" Text="Desinstalador, impressao e configuracoes da ferramenta." Foreground="{DynamicResource BrushTextMuted}" FontSize="12" Margin="0,0,0,14"/>
                    <ScrollViewer Grid.Row="2">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

                            <!-- DESINSTALADOR SEGURO -->
                            <Border Grid.Row="0" Grid.Column="0" Margin="0,0,5,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="DESINSTALADOR SEGURO" Foreground="{DynamicResource BrushDanger}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <TextBlock Text="Desinstala o programa e depois procura residuos (pastas e chaves de registro) deixados para tras, igual o Revo Uninstaller - voce revisa e escolhe o que apagar." Foreground="{DynamicResource BrushTextMuted}" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnUninstaller" Content="Desinstalador Seguro" Height="38" Width="240" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushDanger}"/>
                                </StackPanel>
                            </Border>

                            <!-- DESINSTALADOR DO BITDEFENDER -->
                            <Border Grid.Row="0" Grid.Column="1" Margin="5,0,0,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="DESINSTALADOR DO BITDEFENDER" Foreground="{DynamicResource BrushWarning}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <TextBlock Text="Baixa e roda o desinstalador oficial da Bitdefender (BEST Uninstall Tool) com os parametros de desinstalacao silenciosa - ferramenta separada, nao passa pelo Desinstalador Seguro." Foreground="{DynamicResource BrushTextMuted}" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnDesinstalarBitdefender" Content="Desinstalador do Bitdefender" Height="38" Width="240" HorizontalAlignment="Left" Style="{StaticResource CardButton}" Background="{DynamicResource BrushWarning}"/>
                                </StackPanel>
                            </Border>

                            <!-- IMPRESSAO -->
                            <Border Grid.Row="1" Grid.Column="0" Margin="0,0,5,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="IMPRESSAO" Foreground="{DynamicResource BrushAccent}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnFerrSpooler" Content="Reiniciar Spooler e Limpar Fila" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushAccent}" Margin="0,0,0,8"/>
                                    <Button x:Name="BtnAbrirImpressoras" Content="Abrir Impressoras" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                </StackPanel>
                            </Border>

                            <!-- CONFIGURACOES -->
                            <Border Grid.Row="1" Grid.Column="1" Margin="5,0,0,12" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="CONFIGURACOES" Foreground="{DynamicResource BrushTextMuted}" FontSize="12" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnResetAppsJson" Content="Apagar JSON e Recriar Lista Padrao" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushDanger}" Margin="0,0,0,8"/>
                                    <Button x:Name="BtnAbrirPastaFerramenta" Content="Abrir Pasta da Ferramenta" Height="38" Style="{StaticResource CardButton}" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                </Grid>
'@

# ==============================================================================
# DEPLOY REMOTO - roda instaladores/desinstaladores personalizados (URL +
# parametros cadastrados pelo proprio tecnico) em outras maquinas via
# PowerShell Remoting (WinRM). Cada maquina alvo roda como um Job em
# segundo plano (Invoke-Command bloqueia a thread que chama, sem jeito nativo
# de fazer polling como Process.HasExited - por isso Job + Wait-JobsResponsive
# em vez do padrao Invoke-ManagedProcess/Wait-ProcessResponsive usado pro
# resto do app). O scriptblock remoto ($global:DeploySbCustomRun) e
# auto-contido (sem chamar nenhuma funcao local do script) porque o
# PowerShell Remoting serializa o texto do scriptblock pra rodar na maquina
# alvo - funcoes definidas so localmente nao existem la. Aba protegida por
# senha (ver Show-DeployPasswordDialog) - restrita a poucas pessoas.
# ==============================================================================

function Get-LocalIPv4Base {
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -notmatch '^169\.254\.' -and $_.PrefixOrigin -ne "WellKnown" } |
            Select-Object -First 1
        if ($ip) {
            $parts = $ip.IPAddress -split '\.'
            return ($parts[0..2] -join '.')
        }
    } catch {}
    return $null
}

function Test-DeployHostOnline {
    param([Parameter(Mandatory=$true)][string]$Hostname)
    try { return [bool](Test-Connection -ComputerName $Hostname -Count 1 -Quiet -ErrorAction Stop) } catch { return $false }
}

function Test-DeployPassword {
    param([string]$PlainText)
    if ([string]::IsNullOrEmpty($PlainText)) { return $false }
    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($PlainText))
    $hex = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
    return ($hex -eq $global:DeployPasswordHash)
}

$script:DeployPasswordDialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Deploy Remoto - Acesso Restrito" Height="230" Width="400"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="{DynamicResource BrushSurface}">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Esta aba requer senha de acesso." Foreground="{DynamicResource BrushText}" FontWeight="Bold"/>
        <TextBlock Grid.Row="1" Text="Informe a senha para continuar." Foreground="{DynamicResource BrushTextMuted}" FontSize="11" Margin="0,4,0,14"/>
        <PasswordBox x:Name="PwdAcesso" Grid.Row="2" Height="34" Padding="8,0" Background="{DynamicResource BrushInputBg}" BorderBrush="{DynamicResource BrushInputBorder}" BorderThickness="1" Foreground="{DynamicResource BrushText}" VerticalContentAlignment="Center"/>
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="BtnCancelar" Content="Cancelar" Width="100" Height="34" Margin="0,0,10,0" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0"/>
            <Button x:Name="BtnEntrar" Content="Entrar" Width="120" Height="34" Background="{DynamicResource BrushAccent}" Foreground="White" BorderThickness="0" FontWeight="Bold"/>
        </StackPanel>
    </Grid>
</Window>
'@

function Show-DeployPasswordDialog {
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:DeployPasswordDialogXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow
    Set-DialogTheme -Dialog $dlg

    $pwdBox      = $dlg.FindName("PwdAcesso")
    $btnEntrar   = $dlg.FindName("BtnEntrar")
    $btnCancelar = $dlg.FindName("BtnCancelar")

    $global:DeployPasswordDialogOk = $false
    $btnEntrar.Add_Click({
        if (Test-DeployPassword -PlainText $pwdBox.Password) {
            $global:DeployPasswordDialogOk = $true
            $dlg.DialogResult = $true
            $dlg.Close()
        } else {
            Show-Warning "Senha incorreta."
            $pwdBox.Password = ""
        }
    }.GetNewClosure())
    $btnCancelar.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() }.GetNewClosure())
    [void]$dlg.ShowDialog()
    return $global:DeployPasswordDialogOk
}

function Import-DeployCustomApps {
    $global:DeployCustomApps.Clear()
    if (-not (Test-Path $global:DeployCustomAppsFile)) { return }
    try {
        $json = Get-Content $global:DeployCustomAppsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($item in @($json)) { [void]$global:DeployCustomApps.Add($item) }
    } catch { Write-Log -Message ("Falha ao carregar deploy_apps.json: {0}" -f $_.Exception.Message) -Level "WARN" }
}

function Export-DeployCustomApps {
    try {
        @($global:DeployCustomApps) | ConvertTo-Json -Depth 5 | Out-File $global:DeployCustomAppsFile -Encoding UTF8 -Force
        return $true
    } catch { Show-ErrorBox ("Falha ao salvar deploy_apps.json.`n`n{0}" -f $_.Exception.Message); return $false }
}

$script:AddDeployAppDialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Adicionar App Personalizado" Height="380" Width="520"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="{DynamicResource BrushSurface}">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Nome (identificacao na lista):" Foreground="{DynamicResource BrushTextMuted}" Margin="0,0,0,4"/>
        <TextBox x:Name="TxtNome" Grid.Row="1" Height="30" Padding="6,4" Background="{DynamicResource BrushInputBg}" Foreground="{DynamicResource BrushText}" BorderBrush="{DynamicResource BrushInputBorder}"/>
        <TextBlock Grid.Row="2" Text="URL de download direto (.exe/.msi):" Foreground="{DynamicResource BrushTextMuted}" Margin="0,14,0,4"/>
        <TextBox x:Name="TxtUrl" Grid.Row="3" Height="30" Padding="6,4" Background="{DynamicResource BrushInputBg}" Foreground="{DynamicResource BrushText}" BorderBrush="{DynamicResource BrushInputBorder}"/>
        <TextBlock Grid.Row="4" Text="Parametros (instalacao ou desinstalacao - conforme o software):" Foreground="{DynamicResource BrushTextMuted}" Margin="0,14,0,4"/>
        <TextBox x:Name="TxtParams" Grid.Row="5" Height="30" Padding="6,4" Background="{DynamicResource BrushInputBg}" Foreground="{DynamicResource BrushText}" BorderBrush="{DynamicResource BrushInputBorder}"/>
        <TextBlock Grid.Row="6" Text="Digite igual digitaria numa linha de comando - use aspas se algum valor tiver espaco, ex.: /D=&quot;C:\Pasta Com Espaco&quot;. Deixe em branco se o instalador nao precisar de parametros." Foreground="{DynamicResource BrushTextFaint}" FontSize="10.5" TextWrapping="Wrap" Margin="0,6,0,0"/>
        <StackPanel Grid.Row="8" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="BtnCancelar" Content="Cancelar" Width="100" Height="34" Margin="0,0,10,0" Background="{DynamicResource BrushBorder}" Foreground="{DynamicResource BrushText}" BorderThickness="0"/>
            <Button x:Name="BtnSalvar" Content="Adicionar" Width="120" Height="34" Background="{DynamicResource BrushSuccess}" Foreground="White" BorderThickness="0" FontWeight="Bold"/>
        </StackPanel>
    </Grid>
</Window>
'@

function Show-AddDeployAppDialog {
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:AddDeployAppDialogXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $global:MainWindow
    Set-DialogTheme -Dialog $dlg

    $txtNome   = $dlg.FindName("TxtNome")
    $txtUrl    = $dlg.FindName("TxtUrl")
    $txtParams = $dlg.FindName("TxtParams")
    $btnSalvar   = $dlg.FindName("BtnSalvar")
    $btnCancelar = $dlg.FindName("BtnCancelar")

    $global:DeployAppDialogResult = $null
    $btnSalvar.Add_Click({
        $n = $txtNome.Text.Trim(); $u = $txtUrl.Text.Trim(); $p = $txtParams.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($n)) { Show-Warning "Informe o nome."; return }
        if ([string]::IsNullOrWhiteSpace($u) -or $u -notmatch "^https?://") { Show-Warning "Informe uma URL valida (https://)."; return }
        $global:DeployAppDialogResult = [PSCustomObject]@{ Name=$n; Url=$u; Params=$p }
        $dlg.DialogResult = $true
        $dlg.Close()
    }.GetNewClosure())
    $btnCancelar.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() }.GetNewClosure())
    [void]$dlg.ShowDialog()
    return $global:DeployAppDialogResult
}

# Varredura de rede: pinga a sub-rede /24 da maquina atual em paralelo (Ping
# assincrono do .NET, nao Test-Connection sequencial - varrer 254 hosts um a
# um levaria minutos). Roda dentro de um Job proprio (chamado com
# Wait-JobsResponsive) pra nao travar a UI.
$global:DeploySbScan = {
    param($BaseIp)
    $tasks = foreach ($i in 1..254) {
        $ip = "$BaseIp.$i"
        $ping = New-Object System.Net.NetworkInformation.Ping
        [PSCustomObject]@{ Ip=$ip; Task=$ping.SendPingAsync($ip,300) }
    }
    try { [System.Threading.Tasks.Task]::WaitAll(@($tasks.Task)) } catch {}
    $achados = New-Object System.Collections.ArrayList
    foreach ($t in $tasks) {
        try {
            if ($t.Task.Result.Status -eq 'Success') {
                $hn = $t.Ip
                try { $hn = ([System.Net.Dns]::GetHostEntry($t.Ip)).HostName } catch {}
                [void]$achados.Add([PSCustomObject]@{ Ip=$t.Ip; Hostname=$hn })
            }
        } catch {}
    }
    return @($achados | Sort-Object Ip)
}

function Invoke-DeployNetworkScan {
    $base = Get-LocalIPv4Base
    if (-not $base) { Show-Warning "Nao foi possivel identificar a sub-rede local."; return @() }
    $job = Start-Job -ScriptBlock $global:DeploySbScan -ArgumentList $base
    $timedOut = Wait-JobsResponsive -Jobs @($job) -TimeoutSeconds 120 -BusyTextPrefix ("Escaneando {0}.0/24..." -f $base)
    if ($timedOut) { Write-Log -Message "[DEPLOY] Timeout no scan de rede." -Level "WARN"; Remove-Job $job -Force -ErrorAction SilentlyContinue; return @() }
    $out = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    return $out
}

# Baixa o arquivo da URL informada e roda com os Params exatamente como o
# tecnico digitou (string crua, sem split/quote automatico - o Windows so
# trata espaco como separador de argumento quando NAO esta entre aspas, e
# isso e responsabilidade de quem digita o parametro, igual digitar um
# comando de instalacao/desinstalacao manualmente no cmd). Serve tanto pra
# instalar quanto pra desinstalar - a "acao" e definida pelo proprio
# Url+Params que o tecnico cadastrou (ex.: um instalador com flags de
# instalacao silenciosa, ou um desinstalador oficial com flags de remocao
# silenciosa, como o BEST Uninstall Tool do Bitdefender).
$global:DeploySbCustomRun = {
    param($Apps)
    $results = New-Object System.Collections.ArrayList
    foreach ($app in $Apps) {
        $r = [PSCustomObject]@{ Name=$app.Name; Success=$false; Detail="" }
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
            $ext = [System.IO.Path]::GetExtension($app.Url)
            if ([string]::IsNullOrWhiteSpace($ext) -or $ext.Length -gt 5) { $ext = ".exe" }
            $temp = Join-Path $env:TEMP ("elgin_deploy_{0}{1}" -f ([guid]::NewGuid().ToString("N").Substring(0,8)),$ext)
            $prevProg = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
            Invoke-WebRequest -Uri $app.Url -OutFile $temp -UseBasicParsing -ErrorAction Stop
            $ProgressPreference = $prevProg

            $params = [string]$app.Params
            if ($ext -ieq ".msi") {
                $q = [char]34
                $linha = "/i " + $q + $temp + $q
                if (-not [string]::IsNullOrWhiteSpace($params)) { $linha += " " + $params } else { $linha += " /norestart" }
                $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $linha -Wait -PassThru -ErrorAction Stop
            } elseif (-not [string]::IsNullOrWhiteSpace($params)) {
                $p = Start-Process -FilePath $temp -ArgumentList $params -Wait -PassThru -ErrorAction Stop
            } else {
                $p = Start-Process -FilePath $temp -Wait -PassThru -ErrorAction Stop
            }
            Remove-Item $temp -Force -ErrorAction SilentlyContinue
            $r.Success = ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010 -or $p.ExitCode -eq 1641)
            $r.Detail  = "ExitCode $($p.ExitCode)"
        } catch {
            $r.Detail = $_.Exception.Message
        }
        [void]$results.Add($r)
    }
    return $results
}

# Um Job por maquina (Invoke-Command conecta e roda o scriptblock la dentro);
# todas as maquinas rodam em paralelo, Wait-JobsResponsive espera todas juntas
# mostrando quantas ja terminaram. Retorna resultado achatado (uma linha por
# maquina+app) pra quem chamou desenhar no log da UI.
function Invoke-DeployAction {
    param(
        [Parameter(Mandatory=$true)][array]$Apps,
        [Parameter(Mandatory=$true)][string[]]$TargetHostnames,
        [Parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential
    )
    $appsPayload = @($Apps | ForEach-Object {
        [PSCustomObject]@{ Name=$_.Name; Url=$_.Url; Params=$_.Params }
    })

    $jobs = @()
    foreach ($h in $TargetHostnames) {
        # ScriptBlock NAO sobrevive como [scriptblock] ao cruzar pro processo
        # do Job via -ArgumentList - vira string e quebra na hora de invocar
        # (testado isoladamente: "not recognized as a name of a cmdlet").
        # Passa o texto e reconstroi com [scriptblock]::Create() dentro do
        # job. PSCredential nao tem esse problema, atravessa como objeto real.
        $j = Start-Job -ScriptBlock {
            param($Hostname,$Cred,$InnerSbText,$AppsPayload)
            try {
                $innerSb = [scriptblock]::Create($InnerSbText)
                Invoke-Command -ComputerName $Hostname -Credential $Cred -ScriptBlock $innerSb -ArgumentList (,$AppsPayload) -ErrorAction Stop
            } catch {
                [PSCustomObject]@{ Name="(conexao)"; Success=$false; Detail=$_.Exception.Message }
            }
        } -ArgumentList $h,$Credential,$global:DeploySbCustomRun.ToString(),$appsPayload
        $jobs += [PSCustomObject]@{ Hostname=$h; Job=$j }
    }

    $timedOut = Wait-JobsResponsive -Jobs @($jobs.Job) -TimeoutSeconds 1200 -BusyTextPrefix ("Executando em {0} maquina(s)..." -f $jobs.Count)

    $linhas = New-Object System.Collections.ArrayList
    foreach ($item in $jobs) {
        if ($item.Job.State -eq 'Running') {
            try { Stop-Job $item.Job -ErrorAction SilentlyContinue } catch {}
            [void]$linhas.Add([PSCustomObject]@{ Hostname=$item.Hostname; AppName="(timeout)"; Success=$false; Detail="Tempo esgotado." })
            Remove-Job $item.Job -Force -ErrorAction SilentlyContinue
            continue
        }
        $out = @(Receive-Job -Job $item.Job -ErrorAction SilentlyContinue)
        Remove-Job -Job $item.Job -Force -ErrorAction SilentlyContinue
        if ($out.Count -eq 0) {
            [void]$linhas.Add([PSCustomObject]@{ Hostname=$item.Hostname; AppName="(sem resposta)"; Success=$false; Detail="Job nao retornou resultado." })
            continue
        }
        foreach ($r in $out) {
            [void]$linhas.Add([PSCustomObject]@{ Hostname=$item.Hostname; AppName=$r.Name; Success=[bool]$r.Success; Detail=[string]$r.Detail })
        }
    }
    if ($timedOut) { Write-Log -Message "[DEPLOY] Timeout geral atingido - alguma maquina pode nao ter sido processada." -Level "WARN" }
    return @($linhas)
}

function Show-MainWindow {
    $script:MainWindowXaml = $script:XamlHead + $script:XamlPanelsA + $script:XamlPanelsB + $script:XamlPanelsD + $script:XamlPanelsC
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:MainWindowXaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    $global:MainWindow = $window
    $window.Title = "{0} v{1}" -f $global:AppName,$global:AppVersion

    # Para-quedas global: sem isso, qualquer excecao nao tratada dentro de um
    # Add_Click (ex.: winget indisponivel, servidor de impressao inacessivel,
    # etc.) propaga pro Dispatcher do WPF e derruba o processo inteiro sem
    # aviso - e exatamente o "a ferramenta fecha sozinha" que acontecia antes
    # desta linha existir. Mostra o erro e mantem a janela aberta.
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
        param($senderObj,$e)
        try {
            Write-Log -Message ("[FATAL] Excecao nao tratada: {0}" -f $e.Exception.Message) -Level "ERROR"
            Show-ErrorBox ("Ocorreu um erro inesperado, mas a ferramenta continua aberta.`n`nDetalhe: {0}" -f $e.Exception.Message)
        } catch {}
        $e.Handled = $true
    })

    # Sempre abre no tema claro, independente do que foi salvo da ultima vez
    # que o tecnico trocou de tema - troca continua disponivel a qualquer
    # momento pelo botao "Tema" na barra superior.
    Set-AppTheme -Theme "Light"

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
        Diagnostico = $window.FindName("PanelDiagnostico")
        Rede      = $window.FindName("PanelRede")
        Impressao = $window.FindName("PanelImpressao")
        Deploy    = $window.FindName("PanelDeploy")
        Limpeza   = $window.FindName("PanelLimpeza")
        Ferramentas = $window.FindName("PanelFerramentas")
        Logs      = $window.FindName("PanelLogs")
    }
    $navButtons = @{
        Inicio    = $window.FindName("NavInicio")
        Checklist = $window.FindName("NavChecklist")
        Instalar  = $window.FindName("NavInstalar")
        Diagnostico = $window.FindName("NavDiagnostico")
        Rede      = $window.FindName("NavRede")
        Impressao = $window.FindName("NavImpressao")
        Deploy    = $window.FindName("NavDeploy")
        Limpeza   = $window.FindName("NavLimpeza")
        Ferramentas = $window.FindName("NavFerramentas")
        Logs      = $window.FindName("NavLogs")
    }
    $panelTitles = @{
        Inicio="Inicio"; Checklist="Checklist"; Instalar="Instalar Aplicativos"
        Diagnostico="Diagnostico"; Rede="Rede"; Impressao="Impressao"; Deploy="Deploy Remoto"; Limpeza="Limpeza e Otimizacao"
        Ferramentas="Ferramentas"; Logs="Logs"
    }
    # Scriptblock (nao function aninhada) - funcoes definidas dentro de outra
    # funcao nao ficam visiveis de dentro de closures de eventos WPF (Add_Click),
    # mas um scriptblock capturado via GetNewClosure() funciona corretamente.
    $ShowSection = {
        param([string]$Key)
        if ($Key -eq "Deploy" -and -not $global:DeployUnlocked) {
            if (-not (Show-DeployPasswordDialog)) { return }
            $global:DeployUnlocked = $true
        }
        foreach ($k in $panels.Keys) {
            $panels[$k].Visibility = if ($k -eq $Key) { "Visible" } else { "Collapsed" }
            $navButtons[$k].Background = if ($k -eq $Key) { Get-ThemeBrush "BrushActiveNav" } else { Get-Brush "Transparent" }
            $navButtons[$k].Foreground = if ($k -eq $Key) { Get-ThemeBrush "BrushAccent" } else { Get-ThemeBrush "BrushTextMuted" }
            $navButtons[$k].FontWeight = if ($k -eq $Key) { "Bold" } else { "Medium" }
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
        @{ Key="Checklist";   Title="Checklist";            Desc="Formatacao e configuracao passo a passo";                     Categoria="Setup";         Mono="CK"; Cor="#4C6FFF" }
        @{ Key="Instalar";    Title="Instalar Aplicativos";  Desc="Lista padrao, busca winget/choco e Pacote Extra";             Categoria="Instalacao";    Mono="IN"; Cor="#22C55E" }
        @{ Key="Diagnostico"; Title="Diagnostico";           Desc="Relatorio do sistema, ativacao do Windows/Office e boot";     Categoria="Diagnostico";   Mono="DG"; Cor="#2563EB" }
        @{ Key="Rede";        Title="Rede";                  Desc="DNS, IP, Winsock, Wi-Fi, conexoes e unidades mapeadas";       Categoria="Diagnostico";   Mono="RD"; Cor="#0EA5E9" }
        @{ Key="Impressao";   Title="Impressao";             Desc="Spooler, monitor SNMP e gerenciamento de impressoras";        Categoria="Equipamentos";  Mono="IP"; Cor="#7C6FFA" }
        @{ Key="Deploy";      Title="Deploy Remoto";         Desc="Roda instaladores/desinstaladores personalizados via WinRM (acesso restrito)"; Categoria="Rede";          Mono="DP"; Cor="#F97316" }
        @{ Key="Limpeza";     Title="Limpeza e Otimizacao";  Desc="Limpeza de arquivos, reparos do Windows e desempenho";        Categoria="Manutencao";    Mono="LO"; Cor="#14B8A6" }
        @{ Key="Ferramentas"; Title="Ferramentas";           Desc="Desinstalador seguro, impressao e configuracoes da ferramenta"; Categoria="Avancado";      Mono="FR"; Cor="#EF4444" }
        @{ Key="Logs";        Title="Logs";                  Desc="Historico de acoes e erros da ferramenta";                    Categoria="Historico";     Mono="LG"; Cor="#6B7280" }
    )
    foreach ($shortcut in $homeShortcuts) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $window.FindResource("ShortcutCardButton")

        $card = New-Object System.Windows.Controls.Grid
        for ($i=0; $i -lt 4; $i++) { [void]$card.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) }
        $card.RowDefinitions[0].Height = "Auto"; $card.RowDefinitions[1].Height = "Auto"
        $card.RowDefinitions[2].Height = "Auto"; $card.RowDefinitions[3].Height = "Auto"

        $headerRow = New-Object System.Windows.Controls.Grid
        $headerRow.Margin = "0,0,0,10"
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = "Auto"
        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        [void]$headerRow.ColumnDefinitions.Add($c0); [void]$headerRow.ColumnDefinitions.Add($c1)

        $iconBox = New-Object System.Windows.Controls.Border
        $iconBox.Width = 40; $iconBox.Height = 40; $iconBox.CornerRadius = 9
        $iconBox.Background = Get-Brush $shortcut.Cor
        $iconTxt = New-Object System.Windows.Controls.TextBlock
        $iconTxt.Text = $shortcut.Mono; $iconTxt.Foreground = "White"; $iconTxt.FontWeight = "Bold"; $iconTxt.FontSize = 12
        $iconTxt.HorizontalAlignment = "Center"; $iconTxt.VerticalAlignment = "Center"
        $iconBox.Child = $iconTxt
        [System.Windows.Controls.Grid]::SetColumn($iconBox,0)
        [void]$headerRow.Children.Add($iconBox)

        $badge = New-Object System.Windows.Controls.Border
        $badge.CornerRadius = 9; $badge.Padding = "9,3"; $badge.HorizontalAlignment = "Right"; $badge.VerticalAlignment = "Top"
        $badge.Background = Get-Brush ("#26" + $shortcut.Cor.TrimStart('#'))
        $badgeTxt = New-Object System.Windows.Controls.TextBlock
        $badgeTxt.Text = $shortcut.Categoria; $badgeTxt.Foreground = Get-Brush $shortcut.Cor; $badgeTxt.FontSize = 10; $badgeTxt.FontWeight = "SemiBold"
        $badge.Child = $badgeTxt
        [System.Windows.Controls.Grid]::SetColumn($badge,1)
        [void]$headerRow.Children.Add($badge)

        [System.Windows.Controls.Grid]::SetRow($headerRow,0)
        [void]$card.Children.Add($headerRow)

        $tTitle = New-Object System.Windows.Controls.TextBlock
        $tTitle.Text = $shortcut.Title
        $tTitle.FontSize = 15; $tTitle.FontWeight = "Bold"; $tTitle.Margin = "0,0,0,4"
        $tTitle.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "BrushText")
        [System.Windows.Controls.Grid]::SetRow($tTitle,1)
        [void]$card.Children.Add($tTitle)

        $tDesc = New-Object System.Windows.Controls.TextBlock
        $tDesc.Text = $shortcut.Desc
        $tDesc.FontSize = 11; $tDesc.TextWrapping = "Wrap"; $tDesc.Margin = "0,0,0,10"
        $tDesc.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "BrushTextMuted")
        [System.Windows.Controls.Grid]::SetRow($tDesc,2)
        [void]$card.Children.Add($tDesc)

        $tLink = New-Object System.Windows.Controls.TextBlock
        $tLink.Text = "Acessar modulo ->"
        $tLink.FontSize = 11; $tLink.FontWeight = "SemiBold"
        $tLink.Foreground = Get-Brush $shortcut.Cor
        [System.Windows.Controls.Grid]::SetRow($tLink,3)
        [void]$card.Children.Add($tLink)

        $btn.Content = $card
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

    # $global: (nao variavel local) porque isso e chamado de dentro do
    # Add_Click criado dentro de $BuildChecklistColumn - closure criada
    # durante a execucao de outra closure. Variaveis locais capturadas via
    # GetNewClosure() nao propagam de forma confiavel nesse cenario de
    # closure-dentro-de-closure (mesma armadilha de $script: dentro de
    # closures, ver notas gerais do projeto).
    $global:UpdateChecklistProgressRef = {
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
                try {
                    $global:ChecklistState[[string]$cb.Tag] = [bool]$cb.IsChecked
                    Save-ChecklistState -State $global:ChecklistState
                    & $global:UpdateChecklistProgressRef
                } catch { Write-Log -Message ("[CHECKLIST] Falha ao marcar item: {0}" -f $_.Exception.Message) -Level "ERROR"; Show-ErrorBox $_.Exception.Message }
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
                    try {
                        $global:ChecklistState[[string]$ccb.Tag] = [bool]$ccb.IsChecked
                        Save-ChecklistState -State $global:ChecklistState
                        & $global:UpdateChecklistProgressRef
                    } catch { Write-Log -Message ("[CHECKLIST] Falha ao marcar item: {0}" -f $_.Exception.Message) -Level "ERROR"; Show-ErrorBox $_.Exception.Message }
                }.GetNewClosure())
                [void]$Parent.Children.Add($ccb)
                $global:ChecklistCheckboxes += $ccb
            }
        }
    }.GetNewClosure()

    $checklistDef = @(Get-ChecklistDefinition)
    & $BuildChecklistColumn -Parent $spChecklistLeft  -Items @($checklistDef[0..5])
    & $BuildChecklistColumn -Parent $spChecklistRight -Items @($checklistDef[6..7])
    & $global:UpdateChecklistProgressRef

    $window.FindName("BtnResetarChecklist").Add_Click({
        try {
            if (-not (Confirm-Action "Isso vai desmarcar todos os itens do checklist. Deseja continuar?" "Resetar Checklist")) { return }
            $global:ChecklistState = @{}
            Save-ChecklistState -State $global:ChecklistState
            foreach ($cb in $global:ChecklistCheckboxes) { $cb.IsChecked = $false }
            & $global:UpdateChecklistProgressRef
        } catch { Write-Log -Message ("[CHECKLIST] Falha ao resetar: {0}" -f $_.Exception.Message) -Level "ERROR"; Show-ErrorBox $_.Exception.Message }
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
    $window.FindName("BtnInstalarWinget").Add_Click({
        $btn = $window.FindName("BtnInstalarWinget"); $btn.IsEnabled = $false
        try { Install-WingetPackageManager; & $RefreshPkgMgrStatus } finally { $btn.IsEnabled = $true }
    }.GetNewClosure())
    $window.FindName("BtnRepararWinget").Add_Click({
        $btn = $window.FindName("BtnRepararWinget"); $btn.IsEnabled = $false
        try {
            $r = Repair-Winget
            if ($r.Missing) { Show-Warning "Winget nao esta instalado. Use 'Instalar Winget' primeiro." }
            elseif ($r.Ok) { Show-Info "Winget reparado com sucesso." }
            else { Show-Warning "Nao foi possivel reparar o winget automaticamente. Verifique os Logs." }
            & $RefreshPkgMgrStatus
        } finally { $btn.IsEnabled = $true }
    }.GetNewClosure())
    $window.FindName("BtnInstalarChoco").Add_Click({
        $btn = $window.FindName("BtnInstalarChoco"); $btn.IsEnabled = $false
        try { Install-ChocolateyPackageManager; & $RefreshPkgMgrStatus } finally { $btn.IsEnabled = $true }
    }.GetNewClosure())
    $window.FindName("BtnAbrirUtilitarios").Add_Click({
        try { Start-Process "https://drive.google.com/drive/folders/1JaT4OOO1jjLzdyd6D_iz8d2AfK5M39X1?usp=sharing" }
        catch { Show-Warning "Nao foi possivel abrir a pasta de Utilitarios." }
    }.GetNewClosure())

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

    $window.FindName("BtnMarcarTodosApps").Add_Click({ foreach ($cb in $appCheckboxes) { if ($cb.Visibility -eq "Visible") { $cb.IsChecked = $true } } }.GetNewClosure())
    $window.FindName("BtnDesmarcarTodosApps").Add_Click({ foreach ($cb in $appCheckboxes) { $cb.IsChecked = $false } }.GetNewClosure())

    $window.FindName("BtnInstalarSelecionados").Add_Click({
        if (-not $global:IsAdmin) { Show-Warning "Instalacao requer Administrador. Reabra a ferramenta como Admin."; return }
        $selecionados = @($appCheckboxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if ($selecionados.Count -eq 0) { Show-Warning "Selecione ao menos um aplicativo."; return }
        $ov = Show-BusyOverlay -Text "Instalando aplicativos..."
        $txtOv = if ($ov -ne $null) { $ov.FindName("TxtLoadingStatus") } else { $null }
        try {
            $results = @{}
            $i = 0
            foreach ($app in $selecionados) {
                $i++
                if ($txtOv -ne $null) { $txtOv.Text = "Instalando {0}/{1}: {2}..." -f $i,$selecionados.Count,$app.Name; $ov.Dispatcher.Invoke([System.Action]{}, [System.Windows.Threading.DispatcherPriority]::Render) }
                $results[$app.Name] = Install-OnlineApp -App $app
            }
        } finally { Close-BusyOverlay -Overlay $ov }
        $path = Export-InstallReport -Results $results -Section "Instalacao"
        Show-Info ("Instalacao concluida. Relatorio salvo em:`n{0}" -f $path)
    }.GetNewClosure())

    $txtBuscaOnline    = $window.FindName("TxtBuscaOnline")
    $spBuscaResultados = $window.FindName("SpBuscaResultados")
    $btnInstalarBusca  = $window.FindName("BtnInstalarBusca")
    $spBuscaBotoesSelecao = $window.FindName("SpBuscaBotoesSelecao")
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
            $spBuscaBotoesSelecao.Visibility = "Collapsed"
        } else {
            foreach ($row in $rows) {
                $cb = New-Object System.Windows.Controls.CheckBox
                $cb.Content = ("{0}  [{1}: {2}]" -f $row.Name,$row.Source,$row.Id)
                $cb.Tag = $row
                [void]$spBuscaResultados.Children.Add($cb)
                $global:BuscaCheckboxes += $cb
            }
            $btnInstalarBusca.Visibility = "Visible"
            $spBuscaBotoesSelecao.Visibility = "Visible"
        }
        Set-Status ("Busca concluida: {0} resultado(s)." -f @($rows).Count) "SUCCESS"
    }.GetNewClosure())
    $window.FindName("BtnMarcarTodosBusca").Add_Click({ foreach ($cb in $global:BuscaCheckboxes) { $cb.IsChecked = $true } }.GetNewClosure())
    $window.FindName("BtnDesmarcarTodosBusca").Add_Click({ foreach ($cb in $global:BuscaCheckboxes) { $cb.IsChecked = $false } }.GetNewClosure())
    $btnInstalarBusca.Add_Click({
        if (-not $global:IsAdmin) { Show-Warning "Instalacao requer Administrador."; return }
        $selecionados = @($global:BuscaCheckboxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if ($selecionados.Count -eq 0) { Show-Warning "Selecione ao menos um item da busca."; return }
        $ov = Show-BusyOverlay -Text "Instalando aplicativos..."
        $txtOv = if ($ov -ne $null) { $ov.FindName("TxtLoadingStatus") } else { $null }
        try {
            $results = @{}
            $i = 0
            foreach ($row in $selecionados) {
                $i++
                if ($txtOv -ne $null) { $txtOv.Text = "Instalando {0}/{1}: {2}..." -f $i,$selecionados.Count,$row.Name; $ov.Dispatcher.Invoke([System.Action]{}, [System.Windows.Threading.DispatcherPriority]::Render) }
                $appObj = [PSCustomObject]@{
                    Name = $row.Name
                    Winget = if ($row.Source -eq "Winget") { $row.Id } else { "" }
                    Choco = if ($row.Source -eq "Chocolatey") { $row.Id } else { "" }
                    Scope = ""; TimeoutSeconds = 1800
                }
                $results[$row.Name] = Install-OnlineApp -App $appObj
            }
        } finally { Close-BusyOverlay -Overlay $ov }
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
    $window.FindName("BtnMarcarTodosExtra").Add_Click({ foreach ($cb in $global:ExtraCheckboxes) { $cb.IsChecked = $true } }.GetNewClosure())
    $window.FindName("BtnDesmarcarTodosExtra").Add_Click({ foreach ($cb in $global:ExtraCheckboxes) { $cb.IsChecked = $false } }.GetNewClosure())
    $window.FindName("BtnInstalarExtra").Add_Click({
        if (-not $global:IsAdmin) { Show-Warning "Instalacao requer Administrador. Reabra a ferramenta como Admin."; return }
        $selecionados = @($global:ExtraCheckboxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if ($selecionados.Count -eq 0) { Show-Warning "Selecione ao menos um item."; return }
        $ov = Show-BusyOverlay -Text "Instalando pacote extra..."
        $txtOv = if ($ov -ne $null) { $ov.FindName("TxtLoadingStatus") } else { $null }
        try {
            $results = @{}
            $i = 0
            foreach ($app in $selecionados) {
                $i++
                if ($txtOv -ne $null) { $txtOv.Text = "Instalando {0}/{1}: {2}..." -f $i,$selecionados.Count,$app.Name; $ov.Dispatcher.Invoke([System.Action]{}, [System.Windows.Threading.DispatcherPriority]::Render) }
                $results[$app.Name] = Install-DirectApp -App $app
            }
        } finally { Close-BusyOverlay -Overlay $ov }
        $path = Export-InstallReport -Results $results -Section "PacoteExtra"
        Show-Info ("Instalacao concluida. Relatorio salvo em:`n{0}" -f $path)
    }.GetNewClosure())


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
            $overlay = Show-BusyOverlay -Text "Escaneando impressoras..."
        }
        try {
            $resultado = Get-ImpressorasRede
            $global:PrintersList.Clear()
            foreach ($r in $resultado) { [void]$global:PrintersList.Add($r) }
            & $ApplyPrinterFilter
            & $UpdatePrinterStats
        } catch {
            Write-Log -Message ("[PRINT] Falha ao escanear: {0}" -f $_.Exception.Message) -Level "ERROR"
            if (-not $Silencioso) { Show-ErrorBox ("Falha ao escanear a rede de impressoras.`n`n{0}" -f $_.Exception.Message) }
        } finally {
            Close-BusyOverlay -Overlay $overlay
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

    # ---- Diagnostico ----
    $diagSubPanels = @{
        Geral    = $window.FindName("SubDiagGeral")
        Hardware = $window.FindName("SubDiagHardware")
        Eventos  = $window.FindName("SubDiagEventos")
        Ativacao = $window.FindName("SubDiagAtivacao")
    }
    $diagTabButtons = @{
        Geral    = $window.FindName("TabDiagGeral")
        Hardware = $window.FindName("TabDiagHardware")
        Eventos  = $window.FindName("TabDiagEventos")
        Ativacao = $window.FindName("TabDiagAtivacao")
    }
    $ShowDiagTab = {
        param([string]$Key)
        foreach ($k in $diagSubPanels.Keys) {
            $diagSubPanels[$k].Visibility = if ($k -eq $Key) { "Visible" } else { "Collapsed" }
            $diagTabButtons[$k].Background = if ($k -eq $Key) { Get-ThemeBrush "BrushActiveNav" } else { Get-Brush "Transparent" }
            $diagTabButtons[$k].Foreground = if ($k -eq $Key) { Get-ThemeBrush "BrushAccent" } else { Get-ThemeBrush "BrushTextMuted" }
            $diagTabButtons[$k].FontWeight = if ($k -eq $Key) { "Bold" } else { "Normal" }
        }
    }.GetNewClosure()
    foreach ($diagKey in $diagTabButtons.Keys) {
        $diagTabButtons[$diagKey].Add_Click({ & $ShowDiagTab -Key $diagKey }.GetNewClosure())
    }

    $txtDiagReport = $window.FindName("TxtDiagReport")
    $window.FindName("BtnDiagMostrarInfo").Add_Click({ $txtDiagReport.Text = Get-DiagnosticReportText }.GetNewClosure())
    $window.FindName("BtnDiagSalvarTxt").Add_Click({
        if ([string]::IsNullOrWhiteSpace($txtDiagReport.Text)) { $txtDiagReport.Text = Get-DiagnosticReportText }
        $path = Save-DiagnosticReportTxt -Text $txtDiagReport.Text
        Show-Info ("Relatorio salvo em:`n{0}" -f $path)
    }.GetNewClosure())
    $window.FindName("BtnDiagSalvarHtml").Add_Click({
        if ([string]::IsNullOrWhiteSpace($txtDiagReport.Text)) { $txtDiagReport.Text = Get-DiagnosticReportText }
        $path = Save-DiagnosticReportHtml -Text $txtDiagReport.Text
        Show-Info ("Relatorio salvo em:`n{0}" -f $path)
    }.GetNewClosure())
    $window.FindName("BtnDiagCopiar").Add_Click({
        if ([string]::IsNullOrWhiteSpace($txtDiagReport.Text)) { $txtDiagReport.Text = Get-DiagnosticReportText }
        try { Set-Clipboard -Value $txtDiagReport.Text; Show-Info "Relatorio copiado para a area de transferencia." } catch { Show-Warning "Nao foi possivel copiar." }
    }.GetNewClosure())
    $window.FindName("BtnDiagVerRelatorios").Add_Click({ Open-ReportsFolder }.GetNewClosure())
    $window.FindName("BtnDiagRelatorioBateria").Add_Click({ Invoke-BatteryReport }.GetNewClosure())
    $window.FindName("BtnDiagAbrirBateria").Add_Click({ Open-BatterySettings }.GetNewClosure())

    $txtDiagAtivacao   = $window.FindName("TxtDiagAtivacao")
    $dgDiagBootHistory = $window.FindName("DgDiagBootHistory")
    $window.FindName("BtnDiagVerificarAtivacao").Add_Click({ $txtDiagAtivacao.Text = Get-ActivationStatusText }.GetNewClosure())
    $window.FindName("BtnDiagHistoricoBoot").Add_Click({ $dgDiagBootHistory.ItemsSource = @(Get-BootHistory) }.GetNewClosure())
    $window.FindName("BtnDiagAtivarScript").Add_Click({ Invoke-ActivationByScript }.GetNewClosure())

    $dgDiagDrivers = $window.FindName("DgDiagDrivers")
    $window.FindName("BtnDiagEscanearDrivers").Add_Click({ $dgDiagDrivers.ItemsSource = @(Get-DeviceDriverInventory) }.GetNewClosure())
    $window.FindName("BtnDiagWuDrivers").Add_Click({ Open-WindowsUpdateDriverScan }.GetNewClosure())
    $window.FindName("BtnDiagSiteFabricante").Add_Click({ Open-ManufacturerDriverPage }.GetNewClosure())

    # ---- Ferramentas ----
    $chkLimpTemp      = $window.FindName("ChkLimpTemp")
    $chkLimpTempTodos = $window.FindName("ChkLimpTempTodos")
    $chkLimpWinTemp   = $window.FindName("ChkLimpWinTemp")
    $chkLimpLixeira   = $window.FindName("ChkLimpLixeira")
    $chkLimpWU        = $window.FindName("ChkLimpWU")
    $chkLimpGeo       = $window.FindName("ChkLimpGeo")
    $window.FindName("BtnExecutarLimpeza").Add_Click({
        $etapas = New-Object System.Collections.ArrayList
        if ($chkLimpTemp.IsChecked)      { [void]$etapas.Add(@{ Texto="Limpando temporarios do usuario..."; Acao={ Invoke-CleanupOperation } }) }
        if ($chkLimpTempTodos.IsChecked) { [void]$etapas.Add(@{ Texto="Limpando temporarios de todos os usuarios..."; Acao={ Clear-AllUsersTempFolders } }) }
        if ($chkLimpWinTemp.IsChecked)   { [void]$etapas.Add(@{ Texto="Limpando C:\Windows\Temp..."; Acao={ Invoke-CleanupOperation -IncludeWindowsTemp } }) }
        if ($chkLimpLixeira.IsChecked)   { [void]$etapas.Add(@{ Texto="Esvaziando a lixeira..."; Acao={ Clear-RecycleBinContents } }) }
        if ($chkLimpWU.IsChecked)        { [void]$etapas.Add(@{ Texto="Limpando cache do Windows Update..."; Acao={ Clear-WindowsUpdateCache } }) }
        if ($chkLimpGeo.IsChecked)       { [void]$etapas.Add(@{ Texto="Limpando cache de geolocalizacao..."; Acao={ Clear-GeolocationCache } }) }
        if ($etapas.Count -eq 0) { Show-Warning "Selecione ao menos uma opcao de limpeza."; return }

        $ov = Show-BusyOverlay -Text "Limpando..."
        $txtOv = if ($ov -ne $null) { $ov.FindName("TxtLoadingStatus") } else { $null }
        try {
            $i = 0
            foreach ($etapa in $etapas) {
                $i++
                if ($txtOv -ne $null) {
                    $txtOv.Text = "{0}/{1}: {2}" -f $i,$etapas.Count,$etapa.Texto
                    $ov.Dispatcher.Invoke([System.Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
                }
                & $etapa.Acao
            }
        } finally { Close-BusyOverlay -Overlay $ov }
        Show-Info "Limpeza concluida."
    }.GetNewClosure())

    $window.FindName("BtnSfcScan").Add_Click({ Invoke-SfcScan }.GetNewClosure())
    $window.FindName("BtnDismRestore").Add_Click({ Invoke-DismRestoreHealth }.GetNewClosure())
    $window.FindName("BtnWingetUpgrade").Add_Click({ Update-WingetApps }.GetNewClosure())
    $window.FindName("BtnUninstaller").Add_Click({
        if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
        Show-UninstallerDialog
    }.GetNewClosure())
    $window.FindName("BtnDesinstalarBitdefender").Add_Click({ Invoke-BitdefenderUninstall }.GetNewClosure())
    $window.FindName("BtnChkdsk").Add_Click({ Invoke-ChkdskScheduled -Drive "C:" }.GetNewClosure())
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

    $window.FindName("BtnRemoverWindowsOld").Add_Click({ Clear-WindowsOldFolder }.GetNewClosure())
    $window.FindName("BtnVerDriverStore").Add_Click({ Show-TextResultDialog -Title "Drivers no DriverStore" -Text (Get-DriverStoreInfo) }.GetNewClosure())
    $window.FindName("BtnAnalisarDisco").Add_Click({ Show-TextResultDialog -Title ("Maiores pastas em {0}" -f $env:USERPROFILE) -Text (Get-DiskUsageReport -RootPath $env:USERPROFILE) }.GetNewClosure())
    $window.FindName("BtnGerenciarInicializacao").Add_Click({ Show-StartupManagerDialog }.GetNewClosure())
    $window.FindName("BtnResetWU").Add_Click({ Invoke-WindowsUpdateReset }.GetNewClosure())
    $window.FindName("BtnReconstruirIndice").Add_Click({ Invoke-SearchIndexRebuild }.GetNewClosure())
    $window.FindName("BtnOtimizarDisco").Add_Click({ Invoke-DiskOptimize -Drive "C" }.GetNewClosure())
    $window.FindName("BtnRelatorioBateria").Add_Click({ Invoke-BatteryReport }.GetNewClosure())

    $window.FindName("BtnWifiPerfis").Add_Click({ Show-TextResultDialog -Title "Perfis Wi-Fi" -Text (Get-WifiProfilesInfo) }.GetNewClosure())
    $window.FindName("BtnConexoesPortas").Add_Click({ Show-TextResultDialog -Title "Conexoes / Portas" -Text (Get-NetworkConnectionsInfo) }.GetNewClosure())
    $window.FindName("BtnMapearUnidade").Add_Click({ Show-MapNetworkDriveDialog }.GetNewClosure())
    $window.FindName("BtnVerUnidadesMapeadas").Add_Click({ Show-TextResultDialog -Title "Unidades Mapeadas" -Text (Get-MappedDrivesInfo) }.GetNewClosure())

    # ---- Deploy Remoto ----
    $txtDeployUser     = $window.FindName("TxtDeployUser")
    $pwdDeploy         = $window.FindName("PwdDeploy")
    $txtDeployHostname = $window.FindName("TxtDeployHostname")
    $spDeployHosts     = $window.FindName("SpDeployHosts")
    $spDeployApps      = $window.FindName("SpDeployApps")
    $spDeployLog       = $window.FindName("SpDeployLog")

    # Mesmo padrao do $RefreshDeployHosts (linha do item + remove via
    # $this.Tag) - lista personalizada persiste em deploy_apps.json.
    $global:DeployAppCheckboxes = @()
    $RefreshDeployApps = {
        $spDeployApps.Children.Clear()
        $global:DeployAppCheckboxes = @()
        foreach ($app in @($global:DeployCustomApps)) {
            $row = New-Object System.Windows.Controls.Grid
            $row.Margin = "0,4,0,4"
            $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = "Auto"
            $c1 = New-Object System.Windows.Controls.ColumnDefinition
            $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = "Auto"
            [void]$row.ColumnDefinitions.Add($c0); [void]$row.ColumnDefinitions.Add($c1); [void]$row.ColumnDefinitions.Add($c2)

            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Tag = $app
            $cb.VerticalAlignment = "Center"
            [System.Windows.Controls.Grid]::SetColumn($cb,0)
            [void]$row.Children.Add($cb)
            $global:DeployAppCheckboxes += $cb

            $txtInfo = New-Object System.Windows.Controls.TextBlock
            $txtInfo.Text = if ($app.Params) { "{0}  -  {1}" -f $app.Name,$app.Params } else { $app.Name }
            $txtInfo.Foreground = Get-ThemeBrush "BrushText"
            $txtInfo.FontSize = 12
            $txtInfo.VerticalAlignment = "Center"
            $txtInfo.Margin = "8,0,10,0"
            $txtInfo.ToolTip = $app.Url
            [System.Windows.Controls.Grid]::SetColumn($txtInfo,1)
            [void]$row.Children.Add($txtInfo)

            $btnDel = New-Object System.Windows.Controls.Button
            $btnDel.Content = "Remover"
            $btnDel.FontSize = 10
            $btnDel.Height = 24
            $btnDel.Padding = "8,0"
            $btnDel.Background = Get-ThemeBrush "BrushBorder"
            $btnDel.Foreground = Get-ThemeBrush "BrushText"
            $btnDel.BorderThickness = 0
            $btnDel.Cursor = "Hand"
            $btnDel.Tag = $app.Name
            $btnDel.Add_Click({
                $alvo = $global:DeployCustomApps | Where-Object { $_.Name -eq $this.Tag } | Select-Object -First 1
                if ($alvo) { [void]$global:DeployCustomApps.Remove($alvo); Export-DeployCustomApps | Out-Null }
                & $RefreshDeployApps
            }.GetNewClosure())
            [System.Windows.Controls.Grid]::SetColumn($btnDel,2)
            [void]$row.Children.Add($btnDel)

            [void]$spDeployApps.Children.Add($row)
        }
    }.GetNewClosure()
    & $RefreshDeployApps

    $window.FindName("BtnDeployAdicionarApp").Add_Click({
        $novo = Show-AddDeployAppDialog
        if ($novo) { [void]$global:DeployCustomApps.Add($novo); Export-DeployCustomApps | Out-Null; & $RefreshDeployApps }
    }.GetNewClosure())
    $window.FindName("BtnDeployMarcarTodos").Add_Click({ foreach ($cb in $global:DeployAppCheckboxes) { $cb.IsChecked = $true } }.GetNewClosure())
    $window.FindName("BtnDeployDesmarcarTodos").Add_Click({ foreach ($cb in $global:DeployAppCheckboxes) { $cb.IsChecked = $false } }.GetNewClosure())

    $AddDeployLogLine = {
        param([string]$Text,[string]$Level="INFO")
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $Text
        $tb.TextWrapping = "Wrap"
        $tb.FontSize = 12
        $tb.Margin = "0,2,0,2"
        $corKey = switch ($Level) { "SUCCESS" { "BrushSuccess" } "ERROR" { "BrushDanger" } "WARN" { "BrushWarning" } default { "BrushText" } }
        $tb.Foreground = Get-ThemeBrush $corKey
        [void]$spDeployLog.Children.Add($tb)
    }.GetNewClosure()

    # Lista paralela de checkboxes das maquinas (mesmo padrao do
    # $global:DeployAppCheckboxes/$global:ExtraCheckboxes) - evita indexar
    # Children[N] do Grid de cada linha pra achar o checkbox de volta.
    $global:DeployHostCheckboxes = @()
    $RefreshDeployHosts = {
        $spDeployHosts.Children.Clear()
        $global:DeployHostCheckboxes = @()
        foreach ($t in @($global:DeployTargets)) {
            $row = New-Object System.Windows.Controls.Grid
            $row.Margin = "0,4,0,4"
            $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = "Auto"
            $c1 = New-Object System.Windows.Controls.ColumnDefinition
            $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = "Auto"
            $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = "Auto"
            [void]$row.ColumnDefinitions.Add($c0); [void]$row.ColumnDefinitions.Add($c1)
            [void]$row.ColumnDefinitions.Add($c2); [void]$row.ColumnDefinitions.Add($c3)

            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.IsChecked = $true
            $cb.Tag = $t.Hostname
            $cb.VerticalAlignment = "Center"
            [System.Windows.Controls.Grid]::SetColumn($cb,0)
            [void]$row.Children.Add($cb)
            $global:DeployHostCheckboxes += $cb

            $txtHost = New-Object System.Windows.Controls.TextBlock
            $txtHost.Text = $t.Hostname
            $txtHost.Foreground = Get-ThemeBrush "BrushText"
            $txtHost.VerticalAlignment = "Center"
            $txtHost.Margin = "8,0,0,0"
            [System.Windows.Controls.Grid]::SetColumn($txtHost,1)
            [void]$row.Children.Add($txtHost)

            $txtStat = New-Object System.Windows.Controls.TextBlock
            $txtStat.Text = if ($t.Online) { "Online" } else { "Offline" }
            $txtStat.Foreground = Get-ThemeBrush $(if ($t.Online) { "BrushSuccess" } else { "BrushDanger" })
            $txtStat.FontSize = 11
            $txtStat.VerticalAlignment = "Center"
            $txtStat.Margin = "10,0,10,0"
            [System.Windows.Controls.Grid]::SetColumn($txtStat,2)
            [void]$row.Children.Add($txtStat)

            $btnDel = New-Object System.Windows.Controls.Button
            $btnDel.Content = "Remover"
            $btnDel.FontSize = 10
            $btnDel.Height = 24
            $btnDel.Padding = "8,0"
            $btnDel.Background = Get-ThemeBrush "BrushBorder"
            $btnDel.Foreground = Get-ThemeBrush "BrushText"
            $btnDel.BorderThickness = 0
            $btnDel.Cursor = "Hand"
            $btnDel.Tag = $t.Hostname
            # Usa $this.Tag (nao uma variavel capturada do loop) - testado
            # isoladamente antes de aplicar: variavel local de loop capturada
            # por uma closure criada DENTRO da execucao de outra closure
            # (este $RefreshDeployHosts) e a mesma armadilha ja documentada
            # no Checklist. $this sempre resolve pro botao que foi clicado.
            $btnDel.Add_Click({
                $alvo = $global:DeployTargets | Where-Object { $_.Hostname -eq $this.Tag } | Select-Object -First 1
                if ($alvo) { [void]$global:DeployTargets.Remove($alvo) }
                & $RefreshDeployHosts
            }.GetNewClosure())
            [System.Windows.Controls.Grid]::SetColumn($btnDel,3)
            [void]$row.Children.Add($btnDel)

            [void]$spDeployHosts.Children.Add($row)
        }
    }.GetNewClosure()

    $window.FindName("BtnDeployAddHost").Add_Click({
        $hn = $txtDeployHostname.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($hn)) { return }
        if (@($global:DeployTargets | Where-Object { $_.Hostname -eq $hn }).Count -gt 0) { Show-Warning "Essa maquina ja esta na lista."; return }
        $job = Start-Job -ScriptBlock { param($h) try { [bool](Test-Connection -ComputerName $h -Count 1 -Quiet -ErrorAction Stop) } catch { $false } } -ArgumentList $hn
        Wait-JobsResponsive -Jobs @($job) -TimeoutSeconds 20 -BusyTextPrefix ("Verificando {0}..." -f $hn) | Out-Null
        $online = $false
        try { $online = [bool](Receive-Job -Job $job -ErrorAction SilentlyContinue) } catch {}
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        [void]$global:DeployTargets.Add([PSCustomObject]@{ Hostname=$hn; Online=$online })
        $txtDeployHostname.Text = ""
        & $RefreshDeployHosts
        if (-not $online) { Show-Warning ("'{0}' nao respondeu ao ping. Foi adicionada mesmo assim, mas o deploy provavelmente vai falhar nela." -f $hn) }
    }.GetNewClosure())

    $window.FindName("BtnDeployScan").Add_Click({
        $achados = @(Invoke-DeployNetworkScan)
        if ($achados.Count -eq 0) { Show-Info "Nenhuma maquina encontrada na sub-rede local (ou nao foi possivel identificar a sub-rede)."; return }
        $novos = 0
        foreach ($a in $achados) {
            $nome = if ($a.Hostname -and $a.Hostname -ne $a.Ip) { $a.Hostname } else { $a.Ip }
            if (@($global:DeployTargets | Where-Object { $_.Hostname -eq $nome -or $_.Hostname -eq $a.Ip }).Count -eq 0) {
                [void]$global:DeployTargets.Add([PSCustomObject]@{ Hostname=$nome; Online=$true })
                $novos++
            }
        }
        & $RefreshDeployHosts
        Show-Info ("Scan concluido: {0} maquina(s) respondendo, {1} nova(s) adicionada(s) a lista." -f $achados.Count,$novos)
    }.GetNewClosure())

    $window.FindName("BtnDeployExecutar").Add_Click({
        if (-not $global:IsAdmin) { Show-Warning "Requer Administrador."; return }
        $user = $txtDeployUser.Text.Trim()
        $secure = $pwdDeploy.SecurePassword
        if ([string]::IsNullOrWhiteSpace($user) -or $secure.Length -eq 0) { Show-Warning "Informe usuario e senha de administrador."; return }
        $apps = @($global:DeployAppCheckboxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if ($apps.Count -eq 0) { Show-Warning "Selecione ao menos um app personalizado (ou cadastre um em 'Adicionar App')."; return }
        $alvos = @($global:DeployHostCheckboxes | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
        if ($alvos.Count -eq 0) { Show-Warning "Selecione ao menos uma maquina."; return }

        $listaApps = ($apps | ForEach-Object { $_.Name }) -join ", "
        $listaHosts = $alvos -join ", "
        if (-not (Confirm-Action ("Isso vai executar:`n{0}`n`nNas maquinas:`n{1}`n`nContinuar?" -f $listaApps,$listaHosts) "Deploy Remoto")) { return }

        $cred = New-Object System.Management.Automation.PSCredential($user,$secure)
        & $AddDeployLogLine ("--- Iniciando {0} app(s) em {1} maquina(s) ---" -f $apps.Count,$alvos.Count) "INFO"
        $resultados = @(Invoke-DeployAction -Apps $apps -TargetHostnames $alvos -Credential $cred)
        foreach ($r in $resultados) {
            $nivel = if ($r.Success) { "SUCCESS" } else { "ERROR" }
            & $AddDeployLogLine ("{0} - {1}: {2}" -f $r.Hostname,$r.AppName,$r.Detail) $nivel
        }
        & $AddDeployLogLine "--- Deploy finalizado ---" "INFO"
        Show-Info "Deploy finalizado. Veja o resultado detalhado na secao RESULTADO."
    }.GetNewClosure())

    & $RefreshDeployHosts

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
        Initialize-PackageManagersAutoFix
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
Update-LegacyExtraListIfNeeded
Import-ExtraDatabase
Import-DeployCustomApps
Update-Prerequisites
Show-MainWindow
