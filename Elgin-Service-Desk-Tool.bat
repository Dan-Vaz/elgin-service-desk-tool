@echo off
title Elgin Service Desk Tool

:: ============================================================
:: Fonte primaria: Gist raw. Fallback: jsDelivr.
::
:: A ordem ja foi a inversa: o githubusercontent chegou a
:: responder 429/503/502 para o IP de saida da empresa
:: (anti-scraping do GitHub) e o jsDelivr salvou a distribuicao.
:: Esse bloqueio caiu e a ordem voltou porque o jsDelivr tem um
:: problema proprio: a resolucao do apelido @master para commit
:: fica atrasada por minutos ou horas depois de publicar, e o
:: purge para forcar tem rate limit (purgar repetido faz os
:: pedidos serem descartados). O gist serve a versao nova na
:: hora, sem cache nenhum.
::
:: Ou seja: gist = sempre atual; jsDelivr = rede de seguranca
:: caso o githubusercontent volte a bloquear.
:: Timeout curto para nao pendurar o launcher se a fonte da vez
:: estiver fora.
:: ============================================================
set ELGIN_URL_1=https://gist.githubusercontent.com/Dan-Vaz/91cf3659c455bb69ff32e6c7cb99fa6d/raw/ServiceDeskTool.ps1
set ELGIN_URL_2=https://cdn.jsdelivr.net/gh/Dan-Vaz/elgin-service-desk-tool@master/ServiceDeskTool.ps1

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
