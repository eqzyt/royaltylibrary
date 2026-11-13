# Como construir páginas e controles

Este guia usa a API publicada no final de `RoyaltyUI.lua`. Carregue o arquivo principal antes de executar estes exemplos.

## Uma página com seção

```lua
local env = (getgenv and getgenv()) or _G
local UI = assert(env.GlassUI and env.GlassUI.UI, "Carregue a biblioteca primeiro")

local page, err = UI.CreatePage("Visual", "Preferências visuais")
assert(page, err)

local section = UI.CreateSection(
	page,
	"Aparência",
	UDim2.fromOffset(12, 12),
	UDim2.new(1, -24, 0, 420)
)
```

Páginas personalizadas são `ScrollingFrame`s. Posicione os controles com coordenadas em pixels relativas à página/seção. A página cresce verticalmente e pode ser rolada. O conteúdo interno do card deve ficar dentro das dimensões que você definiu.

## Label e botão

```lua
UI.CreateLabel(section, "Ajustes gerais", UDim2.fromOffset(16, 42), UDim2.new(1, -32, 0, 20), {
	TextSize = 13,
	Bold = true,
})

UI.CreateButton(section, "Aplicar", UDim2.fromOffset(16, 74), UDim2.fromOffset(180, 40), function()
	print("Aplicado")
	env.GlassUI.Notify("OK", "Preferência aplicada")
end)
```

## Toggle

```lua
local enabled = UI.CreateToggle(
	section,
	"Ativar efeito",
	UDim2.fromOffset(16, 124),
	260,
	false,
	function(value)
		print("Ativo:", value)
	end
)

enabled.SetValue(true, false) -- atualiza sem disparar o callback
print(enabled.GetValue())
```

## Dropdown / selector

```lua
local quality = UI.CreateDropdown(
	section,
	"Qualidade",
	UDim2.fromOffset(16, 174),
	280,
	{ "Baixa", "Média", "Alta" },
	"Média",
	function(value)
		print("Qualidade escolhida:", value)
	end
)

quality.SetValue("Alta", false)
```

Reserve na seção espaço vertical suficiente para o dropdown: a linha ocupa 42 px mais até cinco linhas de opções e margens. Para listas longas, o menu interno tem rolagem.

## Slider

```lua
local opacity = UI.CreateSlider(
	section,
	"Opacidade",
	UDim2.fromOffset(16, 330),
	280,
	0,
	100,
	75,
	5,
	function(value)
		print("Opacidade:", value)
	end
)

opacity.SetValue(50, false)
print(opacity.GetValue())
-- opacity.Destroy() desconecta os listeners de arraste e remove o controle.
```

## Campo de texto

```lua
local note = UI.CreateTextBox(
	section,
	"Escreva uma observação",
	UDim2.fromOffset(16, 280),
	UDim2.fromOffset(280, 44),
	function(text, enterPressed)
		if enterPressed then print("Enviado:", text) end
	end
)

note.SetValue("Olá")
print(note.GetValue()) -- preserva espaços digitados
-- note.Destroy() desconecta o callback de FocusLost e remove o campo.
```

## Página criada mais tarde

Você pode registrar uma página em qualquer momento enquanto a UI continua ativa. Ela aparece no menu lateral; `ShowPage` pode selecioná-la pelo nome.

```lua
local page, err = UI.CreatePage("Diagnostics", "Estado e informações")
if page then
	local section = UI.CreateSection(page, "Sessão", UDim2.fromOffset(12, 12), UDim2.new(1, -24, 0, 120))
	UI.CreateLabel(section, "Cliente conectado", UDim2.fromOffset(16, 44), UDim2.new(1, -32, 0, 24))
	UI.ShowPage("Diagnostics")
else
	warn(err)
end
```

Para remover uma página criada pela API (e destruir seus controles), use `UI.RemovePage("Diagnostics")`. As quatro páginas padrão são fixas.

## Regras de layout

1. Use nomes curtos para páginas; há no máximo oito abas totais.
2. Deixe margens internas de 12–18 px nos cards.
3. Não sobreponha controles: prefira posições Y crescentes e reserve altura suficiente para dropdowns.
4. `CreateButton` recebe `UDim2` completos; toggles, dropdowns e sliders recebem largura em pixels e altura própria.
5. Use `SetValue(..., false)` ao carregar estado inicial para evitar side effects nos callbacks.
6. Destrua sliders e TextBoxes criados dinamicamente quando removê-los; isso libera os listeners adicionais.
7. Mantenha callbacks curtos. Se uma ação demora, use `task.spawn` dentro do callback e trate erros com `pcall`.

Para um script de exemplo pronto, veja [`../examples/CustomPage.lua`](../examples/CustomPage.lua).
