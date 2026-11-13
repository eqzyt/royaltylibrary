# Referência da API

O script principal publica a tabela `GlassUI` no ambiente global do executor e disponibiliza a API visual em `GlassUI.UI`.
Os métodos são funções comuns: chame com ponto (`UI.CreatePage(...)`), sem `:`.

```lua
local env = (getgenv and getgenv()) or _G
local GlassUI = assert(env.GlassUI, "Carregue RoyaltyUI.lua primeiro")
local UI = assert(GlassUI.UI, "API UI não inicializada")
print(UI.Version)
```

Todos os métodos de criação recebem `Instance` Roblox como parent. Use um page, section ou outro `GuiObject` criado pela UI. As posições e tamanhos são `UDim2`.

## API global

### `GlassUI.Notify(kind, text, seconds?)`

Exibe um toast. `kind` pode ser `INFO`, `OK`, `ERROR` ou `DANGER`. Duração opcional é limitada ao intervalo de 0,1 a 60 segundos. A função retorna o toast ou `nil` se a UI já foi encerrada.

```lua
GlassUI.Notify("OK", "Configuração salva")
GlassUI.Notify("INFO", "A tarefa pode levar alguns segundos", 5)
```

### `GlassUI.Destroy()`

Encerra a UI, para conexões globais e destrói a janela. O alias `getgenv().GlassUI_Destroy()` também está disponível.

### `GlassUI.Backend`

Implementação de demonstração com `register(name, key)` e `authenticate(name, key)`. Ela é local e não autentica contra servidor ou API. Leia [Segurança e backend](./ARCHITECTURE.md#backend-e-seguranca) antes de usar keys reais.

### `GlassUI.UI.Version`

Versão semântica da API de criação atual: `1.0.0`.

## Criar páginas

### `UI.CreatePage(name, subtitle?) -> ScrollingFrame | nil, errorMessage?`

Cria uma página na navegação da área de membros e devolve o `ScrollingFrame` no qual os controles devem ser adicionados. Nome: 1–24 caracteres imprimíveis. A navegação comporta até oito páginas no total; quatro já existem (`Home`, `Scripts`, `Tools`, `Settings`).

```lua
local page, err = UI.CreatePage("Automation", "Ações rápidas da biblioteca")
if not page then error(err) end
```

### `UI.ShowPage(name) -> boolean`

Mostra uma página registrada. Retorna `false` para nome desconhecido.

### `UI.RemovePage(name) -> boolean`

Remove uma página adicionada pela API, seus controles e a aba correspondente. As quatro páginas padrão não podem ser removidas.

## Controles

### `UI.CreateSection(parent, title, position?, size?) -> CanvasGroup`

Cria um card com borda, fundo e título no estilo vidro. Tamanho padrão: largura do parent e 120 px de altura.

```lua
local section = UI.CreateSection(page, "Geral", UDim2.fromOffset(12, 12), UDim2.new(1, -24, 0, 170))
```

### `UI.CreateLabel(parent, text, position?, size?, options?) -> TextLabel`

`options` aceita `Color` (`Color3`), `Transparency` (0–1), `Bold` (`boolean`) e `TextSize` (`number`). O label retorna a instância, então `label.Text` pode ser atualizado depois.

### `UI.CreateButton(parent, text, position, size, callback?) -> TextButton`

Botão com hover e borda animados. O callback não recebe argumentos. Erros do callback são capturados e enviados ao console com `warn`.

### `UI.CreateToggle(parent, text, position, width, defaultValue, callback?) -> ToggleAPI`

Retorna `{ Instance, GetValue(), SetValue(value, fireCallback?) }`. `SetValue` chama o callback por padrão; passe `false` para apenas atualizar a aparência.

### `UI.CreateDropdown(parent, title, position, width, options, defaultValue?, callback?) -> DropdownAPI`

Também está disponível como `CreateSelect` e `CreateSelector`. `options` é uma lista não vazia. Até cinco opções aparecem de uma vez; listas maiores podem ser roladas. Retorna `{ Instance, GetValue(), SetValue(value, fireCallback?) }`. `SetValue` retorna `false` se o item não estiver na lista.

### `UI.CreateSlider(parent, title, position, width, min, max, defaultValue?, step?, callback?) -> SliderAPI`

Exige `max > min`; passo inválido ou ausente vira `1`. Retorna `{ Instance, GetValue(), SetValue(value, fireCallback?), Destroy() }`. `Destroy()` também desconecta os listeners globais usados durante o arraste.

### `UI.CreateTextBox(parent, placeholder, position, size, callback?) -> TextBoxAPI`

Retorna os métodos compatíveis com o input interno (`get`, `set`, `reset`, `setVisible`, `setError`) mais `GetValue()`, `SetValue(text)`, `Destroy()` e `Instance`. `GetValue()` e o callback de `FocusLost` preservam o texto como foi digitado. O `get()` interno faz trim e é usado pela autenticação.

## Retornos e callbacks

- `CreateButton`, `CreateLabel` e `CreateSection` devolvem a instância Roblox.
- `CreatePage` pode devolver `nil, mensagem` quando o nome é inválido, duplicado ou o limite de páginas foi atingido.
- `CreateToggle` e `CreateDropdown` expõem get/set; os callbacks recebem o valor novo.
- `CreateSlider` expõe get/set e `Destroy`; o callback recebe um número.
- `CreateTextBox` expõe o texto e chama seu callback ao perder foco, com `(texto, enterPressed)`.
- Callbacks de controles são executados com `pcall`; exceções aparecem em `warn` e não devem parar a UI.

Veja [Como construir a UI](./BUILDING_UI.md) para exemplos completos e convenções de layout.
