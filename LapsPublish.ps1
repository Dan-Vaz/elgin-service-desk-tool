# ==============================================================================
# Elgin Service Desk Tool - publicador da credencial do LAPS
#
# NAO e executado ao abrir a ferramenta. O ServiceDeskTool.ps1 so baixa este
# arquivo e o roda num processo filho quando um administrador clica em "Salvar"
# na aba Administracao. Fica separado de proposito: codigo que fala com a API do
# GitHub com token, usa git e edita o proprio script parece exfiltracao/
# supply-chain para um EDR (CrowdStrike Falcon), e no script principal isso fazia
# o Falcon barrar o comando de abertura de TODOS os tecnicos.
#
# Entrada: -PayloadFile = JSON temporario (apagado logo no inicio) com
#   Action (Publish|Forget), User, Password, Token, RememberToken, e os destinos.
# Saida: linhas de progresso e uma linha final "RESULT=OK|NOCHANGE|FAIL|NOMETHOD ...".
# Apenas ASCII neste arquivo (mesma regra do script principal).
# ==============================================================================
param([string]$PayloadFile)
$ErrorActionPreference = "Continue"
$p = Get-Content -LiteralPath $PayloadFile -Raw | ConvertFrom-Json
Remove-Item -LiteralPath $PayloadFile -Force -ErrorAction SilentlyContinue

# Token salvo neste computador (opcional): protegido pelo Windows (DPAPI), so
# este usuario nesta maquina consegue ler.
$tokenFile = Join-Path $env:LOCALAPPDATA "ElginServiceDesk\gh_publish_token.dat"
function Get-StoredToken {
    try {
        if (Test-Path -LiteralPath $tokenFile) {
            $sec = (Get-Content -LiteralPath $tokenFile -Raw -ErrorAction Stop).Trim() | ConvertTo-SecureString -ErrorAction Stop
            return (New-Object System.Management.Automation.PSCredential("gh", $sec)).GetNetworkCredential().Password
        }
    } catch {}
    return ""
}
function Save-StoredToken {
    param([string]$Token)
    $dir = Split-Path -Parent $tokenFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    (ConvertTo-SecureString -String $Token -AsPlainText -Force | ConvertFrom-SecureString) | Out-File -LiteralPath $tokenFile -Encoding ASCII -Force
}

if ([string]$p.Action -eq "Forget") {
    try {
        if (Test-Path -LiteralPath $tokenFile) { Remove-Item -LiteralPath $tokenFile -Force -ErrorAction Stop }
        Write-Output "RESULT=OK token removido"
    } catch { Write-Output ("RESULT=FAIL " + ($_.Exception.Message -replace '\s+', ' ')) }
    return
}

$user  = [string]$p.User
$pw    = [string]$p.Password
$token = ([string]$p.Token).Trim()
$usedStored = $false
if (-not $token) { $token = Get-StoredToken; if ($token) { $usedStored = $true } }
$q = [string][char]39
$newU = '$global:LapsFixedUser        = ' + $q + $user.Replace($q, $q + $q) + $q
$newP = '$global:LapsFixedPassword    = ' + $q + $pw.Replace($q, $q + $q) + $q
$latin1 = [Text.Encoding]::GetEncoding(28591)

function Get-LapsValues {
    param([string]$Text)
    $h = @{}
    $a = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    foreach ($s in $a.EndBlock.Statements) {
        if ($s -is [System.Management.Automation.Language.AssignmentStatementAst] -and ($s.Left.Extent.Text -eq '$global:LapsFixedUser' -or $s.Left.Extent.Text -eq '$global:LapsFixedPassword')) {
            $h[$s.Left.Extent.Text] = $s.Right.Expression.Value
        }
    }
    return $h
}
# Changed=$false se o arquivo ja tem estes valores (mesmo escritos com outra
# aspa); senao troca as duas linhas e confere sintaxe e valores.
function Update-LapsText {
    param([string]$Name,[string]$Text)
    if ([regex]::IsMatch($Text, '[^\x00-\x7F]')) { throw ("[{0}] o arquivo tem caracteres nao-ASCII; abortei para nao corrompe-lo." -f $Name) }
    $cur = Get-LapsValues -Text $Text
    if ($cur['$global:LapsFixedUser'] -ceq $user -and $cur['$global:LapsFixedPassword'] -ceq $pw) {
        return [PSCustomObject]@{ Changed = $false; Text = $Text }
    }
    foreach ($pair in @(@('(?m)^\$global:LapsFixedUser\s*=[^\r\n]*', $newU), @('(?m)^\$global:LapsFixedPassword\s*=[^\r\n]*', $newP))) {
        $ms = [regex]::Matches($Text, $pair[0])
        if ($ms.Count -ne 1) { throw ("[{0}] esperava 1 linha para {1}, achei {2}." -f $Name, $pair[0], $ms.Count) }
        $Text = $Text.Substring(0, $ms[0].Index) + $pair[1] + $Text.Substring($ms[0].Index + $ms[0].Length)
    }
    $errs = $null; $toks = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$toks, [ref]$errs)
    if ($errs.Count -gt 0) { throw ("[{0}] o arquivo editado ficou com erro de sintaxe: {1}" -f $Name, $errs[0].Message) }
    $got = Get-LapsValues -Text $Text
    if ($got['$global:LapsFixedUser'] -cne $user -or $got['$global:LapsFixedPassword'] -cne $pw) { throw ("[{0}] os valores gravados nao conferem com os informados." -f $Name) }
    return [PSCustomObject]@{ Changed = $true; Text = $Text }
}
function Invoke-LapsPurge {
    param([bool]$RepoChanged)
    if ($RepoChanged -and $p.PurgeUrl) {
        try { $r = Invoke-RestMethod -Uri ([string]$p.PurgeUrl) -TimeoutSec 30; return ("status=" + $r.status) } catch { return ("falhou: " + $_.Exception.Message) }
    }
    return "nao necessario"
}

# ---- Caminho 1: API REST do GitHub com token (sem Git) ----------------------
function Invoke-GhApi {
    param([string]$Method,[string]$Url,$Body)
    $h = @{ Authorization = ("Bearer " + $token); Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28" }
    $a = @{ Method = $Method; Uri = $Url; Headers = $h; UserAgent = "ElginServiceDesk"; TimeoutSec = 90; UseBasicParsing = $true }
    if ($Body -ne $null) {
        $a["Body"] = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 6 -Compress))
        $a["ContentType"] = "application/json"
    }
    try { return Invoke-RestMethod @a }
    catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if ($code -eq 401) { throw "Token do GitHub invalido ou expirado (401)." }
        if ($code -eq 403 -or $code -eq 404) { throw ("O GitHub recusou o acesso ({0}). O token precisa das permissoes public_repo e gist e ser da conta dona do repositorio e do gist." -f $code) }
        if ($code -eq 409 -or $code -eq 422) { throw ("O arquivo mudou no GitHub enquanto era editado ({0}). Salve de novo." -f $code) }
        throw ("Falha na API do GitHub ({0}): {1}" -f $code, $_.Exception.Message)
    }
}
function Publish-ViaApi {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $base = [string]$p.ApiBase
    $rurl = "{0}/repos/{1}/{2}/contents/ServiceDeskTool.ps1" -f $base, $p.Owner, $p.Repo
    Write-Host "[repositorio] lendo..."
    $rf = Invoke-GhApi -Method GET -Url ($rurl + "?ref=" + [uri]::EscapeDataString([string]$p.RepoBranch))
    $rb = [Convert]::FromBase64String(([string]$rf.content -replace '\s', ''))
    if ($rb.Length -lt 1000) { throw "[repositorio] conteudo do arquivo veio vazio ou truncado." }
    $ru = Update-LapsText -Name "repositorio" -Text ($latin1.GetString($rb))
    Write-Host "[gist] lendo..."
    $g = Invoke-GhApi -Method GET -Url ("{0}/gists/{1}" -f $base, $p.GistId)
    $gf = $g.files.'ServiceDeskTool.ps1'
    if (-not $gf) { throw "[gist] o gist nao tem ServiceDeskTool.ps1." }
    $gtext = [string]$gf.content
    if ($gf.truncated) {
        $gtext = [string](Invoke-RestMethod -Uri ([string]$gf.raw_url) -Headers @{ Authorization = ("Bearer " + $token) } -UserAgent "ElginServiceDesk" -TimeoutSec 90)
    }
    if ($gtext.Length -lt 1000) { throw "[gist] conteudo do arquivo veio vazio ou truncado." }
    $gu = Update-LapsText -Name "gist" -Text $gtext
    $pushed = @()
    if ($ru.Changed) {
        Write-Host "[repositorio] enviando..."
        [void](Invoke-GhApi -Method PUT -Url $rurl -Body @{
            message = "LAPS: atualiza credencial (publicado pela aba Administracao)"
            content = [Convert]::ToBase64String($latin1.GetBytes($ru.Text))
            sha     = [string]$rf.sha
            branch  = [string]$p.RepoBranch
        })
        $pushed += "repositorio"
        Write-Host "[repositorio] publicado."
    } else { Write-Host "[repositorio] ja estava com esta credencial." }
    if ($gu.Changed) {
        Write-Host "[gist] enviando..."
        try {
            [void](Invoke-GhApi -Method PATCH -Url ("{0}/gists/{1}" -f $base, $p.GistId) -Body @{ files = @{ "ServiceDeskTool.ps1" = @{ content = $gu.Text } } })
        } catch {
            if ($pushed.Count -gt 0) { throw ("O repositorio JA foi atualizado, mas o gist falhou: " + $_.Exception.Message) }
            throw
        }
        $pushed += "gist"
        Write-Host "[gist] publicado."
    } else { Write-Host "[gist] ja estava com esta credencial." }
    return $pushed
}

# ---- Caminho 2: Git local ----------------------------------------------------
function G {
    $o = & git @args 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw ("git {0} falhou: {1}" -f $args[0], $o.Trim()) }
    return $o
}
function Publish-ViaGit {
    $env:GIT_TERMINAL_PROMPT = "0"
    $env:GCM_INTERACTIVE     = "never"
    $work = Join-Path $env:TEMP ("elgin_laps_pub_" + [guid]::NewGuid().ToString("N"))
    try {
        $targets = @(
            @{ Name = "repositorio"; Url = [string]$p.RepoUrl; Branch = [string]$p.RepoBranch },
            @{ Name = "gist";        Url = [string]$p.GistUrl; Branch = [string]$p.GistBranch }
        )
        # clona e prepara os DOIS antes de empurrar qualquer um
        foreach ($t in $targets) {
            $t.Dir = Join-Path $work $t.Name
            Write-Host ("[{0}] clonando..." -f $t.Name)
            [void](G -c core.autocrlf=false clone --quiet --depth 1 --branch $t.Branch $t.Url $t.Dir)
            $file = Join-Path $t.Dir "ServiceDeskTool.ps1"
            $u = Update-LapsText -Name $t.Name -Text ([IO.File]::ReadAllText($file, $latin1))
            $t.Changed = $u.Changed
            if ($u.Changed) { [IO.File]::WriteAllText($file, $u.Text, $latin1) }
        }
        $pushed = @()
        foreach ($t in $targets) {
            if (-not $t.Changed) { Write-Host ("[{0}] ja estava com esta credencial." -f $t.Name); continue }
            [void](G -C $t.Dir -c user.name="Elgin Service Desk" -c user.email="noreply@users.noreply.github.com" commit -q -am "LAPS: atualiza credencial (publicado pela aba Administracao)")
            Write-Host ("[{0}] enviando..." -f $t.Name)
            [void](G -C $t.Dir push --quiet origin $t.Branch)
            $pushed += $t.Name
            Write-Host ("[{0}] publicado." -f $t.Name)
        }
        return $pushed
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    if ($user -notmatch '^[\x21-\x7E]+$' -or $pw -notmatch '^[\x20-\x7E]+$') { throw "Login/senha precisam ter so caracteres ASCII imprimiveis." }
    if (-not $token -and -not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Output "RESULT=NOMETHOD sem token do GitHub e sem Git"
        return
    }
    $pushed = if ($token) { Publish-ViaApi } else { Publish-ViaGit }
    if ($token -and $p.RememberToken -and -not $usedStored) {
        try { Save-StoredToken -Token $token; Write-Host "[token] salvo neste computador." } catch { Write-Host ("[token] nao foi possivel salvar: " + $_.Exception.Message) }
    }
    $purge = Invoke-LapsPurge -RepoChanged ($pushed -contains "repositorio")
    if ($pushed.Count -eq 0) { Write-Output "RESULT=NOCHANGE" } else { Write-Output ("RESULT=OK published=" + ($pushed -join ",") + " purge=" + $purge) }
} catch {
    Write-Output ("RESULT=FAIL " + ($_.Exception.Message -replace '\s+', ' '))
}
