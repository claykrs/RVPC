--!nonstrict
-- Theme.lua -- single source of visual truth for Vdm UI surfaces.

const Colors = table.freeze({
	-- Host desktop (behind the emulator window).
	DesktopTop = Color3.fromRGB(28, 52, 56),
	DesktopBottom = Color3.fromRGB(7, 16, 19),
	-- Windows 3.0 program-manager chrome.
	Background = Color3.fromRGB(192, 192, 192),
	Surface = Color3.fromRGB(192, 192, 192),
	SurfaceRaised = Color3.fromRGB(204, 204, 204),
	BevelLight = Color3.fromRGB(255, 255, 255),
	BevelDark = Color3.fromRGB(128, 128, 128),
	Border = Color3.fromRGB(0, 0, 0),
	Text = Color3.fromRGB(0, 0, 0),
	TextDim = Color3.fromRGB(96, 96, 96),
	Accent = Color3.fromRGB(0, 0, 128),
	AccentText = Color3.fromRGB(255, 255, 255),
	Danger = Color3.fromRGB(160, 0, 0),
	Screen = Color3.fromRGB(0, 0, 0),
	ScreenText = Color3.fromRGB(192, 192, 192),
})

const Fonts = table.freeze({
	Mono = Enum.Font.Code,
	Ui = Enum.Font.Gotham,
	UiBold = Enum.Font.GothamBold,
})

const Sizes = table.freeze({
	TitleBar = 24,
	StatusBar = 24,
	WindowTitle = 13,
	BodyText = 13,
	ScreenText = 14,
	Corner = 0,
	Padding = 8,
})

const Theme = table.freeze({
	Colors = Colors,
	Fonts = Fonts,
	Sizes = Sizes,
})

export type Theme = typeof(Theme)

return Theme
