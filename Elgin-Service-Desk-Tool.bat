@echo off
title Elgin Service Desk Tool

:: ============================================================
:: Aponta para o Gist raw (sempre serve a versao mais recente)
:: ============================================================
set ELGIN_URL=https://gist.githubusercontent.com/Dan-Vaz/91cf3659c455bb69ff32e6c7cb99fa6d/raw/ServiceDeskTool.ps1

echo ============================================================
echo  Elgin Service Desk Tool
echo ============================================================
echo.
echo Abrindo a ferramenta, aguarde...
echo.

powershell.exe -NoProfile -STA -Command "$env:ELGIN_SERVICE_DESK_URL='%ELGIN_URL%'; irm $env:ELGIN_SERVICE_DESK_URL | iex"

if errorlevel 1 (
    echo.
    echo ============================================================
    echo  Ocorreu um erro ao abrir a ferramenta.
    echo  Verifique sua conexao com a internet e tente novamente.
    echo ============================================================
    pause
)
