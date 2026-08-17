@echo off
title Elgin Service Desk Tool

:: ============================================================
:: Fonte primaria: jsDelivr (CDN servindo o ServiceDeskTool.ps1
:: do repo). Fallback: Gist raw.
:: O githubusercontent responde 429/503/502 para o IP de saida
:: da empresa (anti-scraping do GitHub), por isso o jsDelivr e
:: a fonte primaria. Timeout curto para nao pendurar o launcher
:: caso a fonte da vez esteja fora.
:: ============================================================
set ELGIN_URL_1=https://cdn.jsdelivr.net/gh/Dan-Vaz/elgin-service-desk-tool@master/ServiceDeskTool.ps1
set ELGIN_URL_2=https://gist.githubusercontent.com/Dan-Vaz/91cf3659c455bb69ff32e6c7cb99fa6d/raw/ServiceDeskTool.ps1

echo ============================================================
echo  Elgin Service Desk Tool
echo ============================================================
echo.
echo Abrindo a ferramenta, aguarde...
echo.

powershell.exe -NoProfile -STA -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $src=$null; foreach($u in @('%ELGIN_URL_1%','%ELGIN_URL_2%')){ try{ $src=Invoke-RestMethod -Uri $u -TimeoutSec 20; $env:ELGIN_SERVICE_DESK_URL=$u; break }catch{ Write-Host 'Fonte indisponivel, tentando a proxima...' -ForegroundColor DarkYellow } }; if($src){ Invoke-Expression $src } else { exit 1 }"

if errorlevel 1 (
    echo.
    echo ============================================================
    echo  Ocorreu um erro ao abrir a ferramenta.
    echo  Verifique sua conexao com a internet e tente novamente.
    echo ============================================================
    pause
)
