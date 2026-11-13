# Ajuda e solução de problemas

## A UI não abriu

- Execute o arquivo inteiro, não apenas um trecho.
- Confira se o executor permite criar `ScreenGui` em `gethui()`/`CoreGui`. O script tenta `PlayerGui` como fallback.
- Reabra o executor/cliente se outra cópia deixou uma GUI antiga; a próxima execução normalmente chama `GlassUI_Destroy` para limpar a anterior.
- Veja o console do executor para erros de permissão ou funções do ambiente ausentes.

## A cor/atalho não ficou salvo

Persistência usa `readfile`, `writefile` e `isfile` quando disponíveis. Se o executor não fornece essas funções, a cor e o atalho duram somente até o fim da sessão.

## O cadastro não aceita o nome ou a key

O nome aceita letras, números, `_` e `-`, dentro de `MinNameLength` e `MaxNameLength`. A key tem tamanho mínimo e não pode conter espaços. No backend de demonstração, o cadastro guarda a key digitada localmente; ele não verifica a lista de keys reais do administrador.

## O painel está atrás de outra janela

Pressione o atalho atual (padrão `RightShift`) para ocultar/mostrar. Se alterou a tecla, abra Settings pelo ícone antes do login ou pela página Settings na área de membros e configure de novo.

## Um callback customizado falhou

Exceções de botões, toggles, dropdowns, sliders e campos são capturadas; procure uma linha `[GlassUI] ... callback failed` no console. Confirme se o parent ainda existe e se os argumentos estão na ordem documentada em [API](./API.md).

## O dropdown cobre outros controles

O menu abre abaixo da linha do seletor e fica acima dos irmãos. Posicione o próximo controle após a altura do seletor (42 px + linhas visíveis e margem) ou crie o dropdown em um card separado.

## Slider continua ouvindo depois de remover controles

Use o método `slider.Destroy()` para remover o controle e desconectar os listeners globais. TextBoxes criados pela API também oferecem `Destroy()`.

## Os cantos mostram recortes quadrados

Preserve o `CanvasGroup` externo e seu `UICorner` no painel. Se adicionar uma superfície com filhos visuais, use um `CanvasGroup` com `UICorner` nela também; `UICorner` sozinho não recorta conteúdo descendente.

## As keys serão ligadas à API depois

Troque a implementação `Backend` por um cliente que envie a solicitação para um backend confiável e valide a resposta. Não coloque segredo da KeyAuth no script cliente. O contrato interno atual é:

```lua
Backend.register(name, key)     --> true | false, message
Backend.authenticate(name, key) --> true, displayName | false, message
```

Para problemas visuais, reduza temporariamente `BG.Columns` e `BG.UpdateHz`; para erro de API da biblioteca, consulte os exemplos em [`BUILDING_UI.md`](./BUILDING_UI.md).
