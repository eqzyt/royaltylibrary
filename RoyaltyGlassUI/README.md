# Royalty Glass UI

Biblioteca de interface em **Luau para executores Roblox**, distribuída como um único arquivo. A janela inclui acesso/cadastro demonstrativos, configurações, tema chroma, área de membros e uma API para páginas e controles extras.

> Esta versão foi escrita para execução no cliente pelo executor. Não precisa de Rojo, Wally, Vide ou instalação dentro de um place. Ela aplica alguns dos mesmos princípios de composição e estado reativo, mas usa `TweenService` e APIs Roblox nativas para continuar autocontida.

## Começar

1. Abra [`RoyaltyUI.lua`](./RoyaltyUI.lua) e execute o arquivo inteiro no executor.
2. Depois que a janela inicializar, use `getgenv().GlassUI.UI` para acrescentar páginas e controles. Exemplos completos estão em [`examples/CustomPage.lua`](./examples/CustomPage.lua).
3. Leia o [guia de instalação e atualização](./docs/INSTALLATION.md) e a [referência da API](./docs/API.md).

Quando o projeto estiver hospedado em um repositório público, o carregador remoto terá este formato:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/SEU_USUARIO/RoyaltyGlassUI/main/RoyaltyUI.lua"))()
```

Troque `SEU_USUARIO` pelo proprietário real do repositório. O endereço só funcionará depois de publicar o arquivo no GitHub.

## Funcionalidades

- Janela compacta de 400×300 que expande para a área de membros de 860×530.
- Entrada/cadastro com key fornecida pelo administrador, estados de erro e bloqueio temporário após falhas repetidas.
- Telas com fade e deslocamento, loading animado, botão de configurações, avisos e atalho configurável.
- Preenchimento chroma animado, seletor HSV/hex, presets e salvamento local quando o executor oferece as funções de arquivo.
- API de páginas e controles: seção, label, botão, toggle, dropdown/select, slider e TextBox.
- Escopo de limpeza para a UI, conexões globais e tweens em andamento.

## Documentação

- [Instalação, carregamento e atualização](./docs/INSTALLATION.md)
- [Referência completa da API](./docs/API.md)
- [Como construir páginas e controles](./docs/BUILDING_UI.md)
- [Arquitetura, visual e ciclo de vida](./docs/ARCHITECTURE.md)
- [Ajuda e solução de problemas](./docs/HELP.md)

## Segurança e armazenamento

O `Backend` incluído é **somente uma demonstração local**. As contas ficam no cliente e podem ser lidas ou alteradas pelo usuário; portanto, isso não protege keys. Para autenticação real, substitua o backend por validação em serviço confiável e nunca coloque um segredo privado da API em um script cliente. As funções `readfile`/`writefile` também são opcionais do executor; sem elas, a UI continua funcionando em memória durante a sessão.

O contêiner principal usa `CanvasGroup` e `UICorner` para recortar chroma, brilho, páginas e conteúdo pelos cantos arredondados. `CanvasGroup` usa memória de textura adicional; a biblioteca o reserva para superfícies que precisam de recorte ou fade em grupo. [Documentação Roblox: CanvasGroup](https://create.roblox.com/docs/reference/engine/classes/CanvasGroup) · [UICorner](https://create.roblox.com/docs/reference/engine/classes/UICorner).

## Versão

API atual: **1.0.0**. Consulte [`CHANGELOG.md`](./CHANGELOG.md) para mudanças e limitações conhecidas.
