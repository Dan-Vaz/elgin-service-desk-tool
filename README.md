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
gh gist edit <GIST_ID> ServiceDeskTool.ps1
```

Uma nova tag (`vX.Y.Z`) publica um novo `Elgin-Service-Desk-Tool.bat` na aba Releases (o `.bat` em si raramente muda — só a URL do Gist, se ele for recriado).
