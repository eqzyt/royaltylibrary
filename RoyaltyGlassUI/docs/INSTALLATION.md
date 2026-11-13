# Instalação e carregamento

## Execução direta

`RoyaltyUI.lua` é um arquivo único. Copie o arquivo inteiro para o executor e execute. O script cria um `ScreenGui` em `gethui()` quando disponível; se não estiver disponível, tenta `CoreGui` e depois `PlayerGui`.

Ao executar uma segunda cópia, a instância anterior é encerrada pela função global `GlassUI_Destroy`, para evitar duas janelas, dois loops de animação ou duas conexões de entrada em paralelo.

## Execução após publicar no GitHub

Depois de enviar o projeto a um repositório **público**, use o endereço Raw. Exemplo:

```lua
local source = game:HttpGet("https://raw.githubusercontent.com/SEU_USUARIO/RoyaltyGlassUI/main/RoyaltyUI.lua")
loadstring(source)()
```

Substitua o usuário, repositório e branch pelos valores publicados. Para atualizar a UI, publique uma nova versão do arquivo nesse caminho ou fixe uma tag/release para evitar mudanças inesperadas.

## Usar a API de extensão

Execute o arquivo principal primeiro. Em uma execução seguinte no mesmo ambiente, obtenha a API assim:

```lua
local env = (getgenv and getgenv()) or _G
local glass = env.GlassUI
assert(glass and glass.UI, "Royalty Glass UI ainda não foi carregada")
local UI = glass.UI
```

Depois disso, use `UI.CreatePage`, `UI.CreateButton`, `UI.CreateDropdown` e os demais métodos descritos em [API](./API.md). Um exemplo copiável está em [`../examples/CustomPage.lua`](../examples/CustomPage.lua).

## Configuração do acesso

As opções no começo de `RoyaltyUI.lua` ficam na tabela `CONFIG`. Os principais campos são:

| Campo | Efeito |
|---|---|
| `StoreFile` | Nome do JSON local usado pelo executor, se `readfile`/`writefile` existirem. |
| `PrefsFile` | Nome do arquivo local para keybind e cor chroma. |
| `BindToRobloxAccount` | Vincula as contas demonstrativas ao `UserId` que as registrou. |
| `MinNameLength`, `MaxNameLength`, `MinKeyLength` | Limites de validação da tela de cadastro. |
| `MaxAttempts`, `LockoutSeconds` | Número de erros e duração do bloqueio temporário. |
| `CloseOnSuccess` | Fecha a interface após a entrada bem-sucedida. |
| `OnAuthenticated(name)` | Callback executado depois do loading. |

O cadastro local não emite nem valida keys do administrador. Ele apenas armazena o valor que o usuário digitou para permitir testar o fluxo.

## Encerrar a interface

```lua
local env = (getgenv and getgenv()) or _G
if env.GlassUI then
	if env.GlassUI.Destroy then env.GlassUI.Destroy() end
	if env.GlassUI_Destroy then env.GlassUI_Destroy() end
end
```

`Destroy()` desconecta os listeners globais, cancela tweens, remove o blur criado pela biblioteca e destrói a GUI.
