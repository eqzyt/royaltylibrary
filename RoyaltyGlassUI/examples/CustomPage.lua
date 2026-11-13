-- Execute this AFTER RoyaltyUI.lua has finished loading in the same executor session.
local env = (getgenv and getgenv()) or _G
local glass = assert(env.GlassUI, "Run RoyaltyUI.lua first")
local UI = assert(glass.UI, "The UI extension API is not ready")

local page, err = UI.CreatePage("Example", "A small page made with the public API")
assert(page, err)

local section = UI.CreateSection(
	page,
	"Controls",
	UDim2.fromOffset(12, 12),
	UDim2.new(1, -24, 0, 420)
)

UI.CreateLabel(section, "Custom controls use the same glass design.", UDim2.fromOffset(16, 42), UDim2.new(1, -32, 0, 22), {
	TextSize = 12,
	Color = Color3.fromRGB(225, 225, 235),
})

UI.CreateButton(section, "Example action", UDim2.fromOffset(16, 74), UDim2.fromOffset(190, 40), function()
	glass.Notify("OK", "The custom button works")
end)

local enabled = UI.CreateToggle(section, "Enable example", UDim2.fromOffset(16, 124), 280, true, function(value)
	print("Example enabled:", value)
end)

local mode = UI.CreateSelect(section, "Mode", UDim2.fromOffset(16, 176), 280, { "Quiet", "Balanced", "Fast" }, "Balanced", function(value)
	print("Selected mode:", value)
end)

local amount = UI.CreateSlider(section, "Amount", UDim2.fromOffset(16, 330), 280, 0, 100, 40, 10, function(value)
	print("Amount:", value)
end)

UI.ShowPage("Example")

-- The returned controls expose state methods:
print(enabled.GetValue(), mode.GetValue(), amount.GetValue())
