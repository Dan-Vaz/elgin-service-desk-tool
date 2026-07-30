# ==============================================================================
# Compila ServiceDeskTool.ps1 em um executavel unico (.exe) usando PS2EXE.
# Gera bin\ServiceDeskTool.exe — esse e o arquivo a distribuir (ex.: anexado
# a uma release no GitHub). Nao precisa mais de Gist, .bat ou irm/iex.
#
# Uso:
#   .\Build-Exe.ps1
#   .\Build-Exe.ps1 -Version "1.0.1"
# ==============================================================================

param(
    [string]$Version = "1.0.0",
    [string]$IconPath = ""
)

$ErrorActionPreference = "Stop"

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Modulo PS2EXE nao encontrado. Instalando (CurrentUser)..." -ForegroundColor Yellow
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe -Force

$root       = $PSScriptRoot
$inputFile  = Join-Path $root "ServiceDeskTool.ps1"
$outDir     = Join-Path $root "bin"
$outputFile = Join-Path $outDir "ServiceDeskTool.exe"

if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$ps2exeArgs = @{
    inputFile   = $inputFile
    outputFile  = $outputFile
    noConsole   = $true      # app grafica (WinForms) — sem janela de console atras
    STA         = $true      # WinForms exige apartment STA
    title       = "Elgin Service Desk Tool"
    version     = $Version
    product     = "Elgin Service Desk Tool"
    company     = "Elgin"
    copyright   = "Elgin"
    requireAdmin = $false    # elevacao e tratada dentro do proprio script (Request-AdminElevation),
                              # com aviso amigavel antes do UAC nativo — nao usar manifest requireAdmin aqui.
}
if ($IconPath -and (Test-Path $IconPath)) { $ps2exeArgs["iconFile"] = $IconPath }

Write-Host "Compilando $inputFile -> $outputFile ..." -ForegroundColor Cyan
Invoke-ps2exe @ps2exeArgs

if (Test-Path $outputFile) {
    Write-Host "Build concluido: $outputFile" -ForegroundColor Green
} else {
    Write-Host "Falha no build. Verifique as mensagens do PS2EXE acima." -ForegroundColor Red
    exit 1
}
