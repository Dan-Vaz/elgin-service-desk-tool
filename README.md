# Elgin Service Desk Tool

Ferramenta interna de suporte técnico para Windows: instalação de software, limpeza de sistema, diagnóstico de rede e monitoramento de impressoras da rede — tudo em uma única interface (WPF, tema escuro).

## Como usar

1. Baixe o launcher `Elgin-Service-Desk-Tool.bat` na aba [Releases](https://github.com/Dan-Vaz/elgin-service-desk-tool/releases/latest).
2. Dê dois cliques para executar.
3. O Windows vai pedir permissão de Administrador (UAC) — confirme para liberar instalação de apps, limpeza e ferramentas de rede.

O `.bat` sempre busca e executa a versão mais recente do script (hospedado num [Gist](https://gist.github.com/Dan-Vaz/91cf3659c455bb69ff32e6c7cb99fa6d)) — não existe uma cópia local para ficar desatualizada. Toda vez que a ferramenta muda, já é a versão nova que abre da próxima vez.

## O que a ferramenta faz

- **Instalar Aplicativos** — catálogo padrão (AnyDesk, Teams, Chrome, 7-Zip, Office, etc.) via winget/Chocolatey.
- **Pacote Extra** — instaladores diretos (.exe/.msi) que você cadastra pela própria interface, para os softwares específicos da sua empresa.
- **Limpeza** — arquivos temporários, cache do Windows Update, cache de geolocalização.
- **Rede** — flush DNS, renovar IP, reset Winsock, ping, teste de DNS.
- **Impressão** — reiniciar spooler de impressão e monitorar impressoras da rede (nível de toner, status, páginas impressas via SNMP) — requer estar na rede/VPN da empresa.
- **Logs** — histórico de todas as ações executadas nesta sessão.

## Para quem for manter o código

O arquivo fonte é [ServiceDeskTool.ps1](ServiceDeskTool.ps1) neste repositório. **Editar aqui não é suficiente** — o que roda de verdade é o conteúdo publicado no Gist referenciado pelo `.bat`. Depois de alterar o script:

```bash
gh gist edit 91cf3659c455bb69ff32e6c7cb99fa6d ServiceDeskTool.ps1
```

Isso já é suficiente para toda mudança de funcionalidade — não é preciso criar uma tag/Release a cada alteração, já que o `.bat` não muda (ele só referencia o Gist, que sempre serve o conteúdo mais recente). Lembre de também atualizar `$global:AppVersion` no topo do script, para o número exibido na janela refletir a mudança.

Só crie uma nova tag (`vX.Y.Z`) quando o **próprio `Elgin-Service-Desk-Tool.bat`** precisar mudar (ex.: trocar de Gist, mudar o texto do launcher) — isso publica um novo `.bat` na aba [Releases](https://github.com/Dan-Vaz/elgin-service-desk-tool/releases).

### Checklist ao alterar o script
1. Edite `ServiceDeskTool.ps1` e bump `$global:AppVersion`.
2. `git add ServiceDeskTool.ps1 && git commit -m "..." && git push` (mantém o repositório como histórico/backup).
3. `gh gist edit 91cf3659c455bb69ff32e6c7cb99fa6d ServiceDeskTool.ps1` (isso é o que realmente coloca a mudança no ar).
4. Teste rodando o `.bat` uma vez para confirmar.
