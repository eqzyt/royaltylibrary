# Arquitetura, visual e ciclo de vida

## Visão geral

`RoyaltyUI.lua` é deliberadamente um único arquivo para carregamento pelo executor. Ele separa a implementação em regiões locais:

1. Configuração, cores e dimensões.
2. Helpers de animação, bordas, inputs, botões e toasts.
3. Backend local de demonstração e preferências.
4. Janela de vidro, preenchimento chroma, brilho e drag.
5. Telas de acesso, cadastro, configurações e loading.
6. Páginas de membros, controles e API `GlassUI.UI`.

As funções internas `makeButton`, `makeInput`, `createScreen`, `glassCard` e `memberLabel` mantêm as telas existentes consistentes. A API pública adiciona controles customizados sem recriar a janela.

## Cantos e recorte

`UICorner` arredonda a superfície do próprio objeto, mas não recorta seus descendentes. A janela externa agora é um `CanvasGroup` com `UICorner`; assim chroma, brilho, gelo, abas e telas são recortados juntos. Cards que contêm conteúdo também usam grupos arredondados. Toast, loading, sidebar, mapa de cor e campos têm seus próprios limites arredondados onde necessário.

O recorte é intencional: evita que camadas retangulares apareçam para fora dos cantos. `CanvasGroup` usa memória adicional de textura; evite criar centenas deles para controles simples. A biblioteca reserva grupos para o shell, superfícies com conteúdo que precisa ser recortado e componentes com fade em conjunto. Consulte a [documentação Roblox de CanvasGroup](https://create.roblox.com/docs/reference/engine/classes/CanvasGroup) e [UICorner](https://create.roblox.com/docs/reference/engine/classes/UICorner).

## Animações e atualizações de estado

- `tween(instance, info, properties)` cancela apenas tweens ativos que disputam as mesmas propriedades no mesmo objeto; tweens independentes podem continuar em paralelo.
- Cada tween é removido do registro quando termina.
- `showScreen` usa tokens e `task.delay` em vez de pausar o handler com `task.wait`; requisições durante uma transição são enfileiradas e a mais recente é processada após a animação.
- O loading usa uma conexão de `RenderStepped` que é desconectada ao terminar ou destruir a UI.
- O shake de erro não bloqueia a thread de input e um shake novo invalida a sequência anterior.
- Preferências de cor são salvas com debounce; callbacks atrasados saem quando a interface já foi encerrada.

## Ciclo de vida

`GlassUI.Destroy()`:

- marca a instância como encerrada e invalida tokens de tarefas atrasadas;
- desconecta conexões globais;
- cancela tweens em execução;
- destrói o blur e a GUI;
- limpa os hooks globais da UI.

Controles criados dinamicamente são destruídos pelo parent. `Slider.Destroy()` e `TextBox.Destroy()` também liberam listeners globais próprios.

## Backend e segurança

`Backend.register` e `Backend.authenticate` existem para testar o fluxo, mas são executados localmente. Os dados são editáveis no cliente e o arquivo JSON pode conter a key em texto claro. `BindToRobloxAccount` é conveniência, não defesa contra adulteração.

Para um sistema real, valide a key fora do cliente, por uma API/servidor confiável. Não embuta segredo privado no arquivo hospedado. O hook `CONFIG.OnAuthenticated(name)` só indica que o demo local aceitou a conta; ele não prova autorização remota.

## Performance e limites

- O efeito chroma anima até `BG.Columns × RIDGES × LAYERS` elementos de barra. Reduza `Columns` ou `UpdateHz` se o executor sofrer queda de FPS.
- A janela é desenhada para desktop, com layout compacto de acesso e painel membro 860×530. Em viewports menores, arraste e teste o recorte antes de adicionar conteúdo grande.
- O número de abas adicionais é limitado a quatro além das quatro padrão para a sidebar atual.
- A API não persiste automaticamente estado de toggles, dropdowns ou sliders; salve sua própria preferência via `GlassUI`/executor se necessário.
