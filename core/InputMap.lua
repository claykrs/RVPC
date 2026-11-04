--!strict
-- InputMap.lua -- host key names to IBM PC set-1 make codes.
--
-- The table is keyed by Roblox Enum.KeyCode names so the environment-pure core
-- can be tested by Lune without referencing Roblox types. Values above 0xFF are
-- E0-prefixed set-1 keys (arrows, Home/End, right Ctrl/Alt, keypad Divide and
-- Enter). A host that cannot emit the E0 prefix can use the low byte, which is
-- the keypad alias the guest sees on a real controller without the prefix.

const InputMap = {}

const SCANCODES: { [string]: number } = {
	-- Letters.
	A = 0x1E,
	B = 0x30,
	C = 0x2E,
	D = 0x20,
	E = 0x12,
	F = 0x21,
	G = 0x22,
	H = 0x23,
	I = 0x17,
	J = 0x24,
	K = 0x25,
	L = 0x26,
	M = 0x32,
	N = 0x31,
	O = 0x18,
	P = 0x19,
	Q = 0x10,
	R = 0x13,
	S = 0x1F,
	T = 0x14,
	U = 0x16,
	V = 0x2F,
	W = 0x11,
	X = 0x2D,
	Y = 0x15,
	Z = 0x2C,

	-- Number row.
	One = 0x02,
	Two = 0x03,
	Three = 0x04,
	Four = 0x05,
	Five = 0x06,
	Six = 0x07,
	Seven = 0x08,
	Eight = 0x09,
	Nine = 0x0A,
	Zero = 0x0B,

	-- Punctuation.
	Minus = 0x0C,
	Equals = 0x0D,
	LeftBracket = 0x1A,
	RightBracket = 0x1B,
	BackSlash = 0x2B,
	Semicolon = 0x27,
	Quote = 0x28,
	Comma = 0x33,
	Period = 0x34,
	Slash = 0x35,
	Backquote = 0x29,

	-- Editing and modifiers.
	Escape = 0x01,
	Backspace = 0x0E,
	Tab = 0x0F,
	Return = 0x1C,
	Space = 0x39,
	CapsLock = 0x3A,
	LeftShift = 0x2A,
	RightShift = 0x36,
	LeftControl = 0x1D,
	RightControl = 0xE01D,
	LeftAlt = 0x38,
	RightAlt = 0xE038,
	LeftMeta = 0xE05B,
	RightMeta = 0xE05C,
	Menu = 0xE05D,

	-- Function row.
	F1 = 0x3B,
	F2 = 0x3C,
	F3 = 0x3D,
	F4 = 0x3E,
	F5 = 0x3F,
	F6 = 0x40,
	F7 = 0x41,
	F8 = 0x42,
	F9 = 0x43,
	F10 = 0x44,
	F11 = 0x57,
	F12 = 0x58,

	-- Lock keys. PrintScreen and Pause are multi-byte E0/E1 sequences; they are
	-- intentionally absent because a single pressKey byte cannot encode them.
	ScrollLock = 0x46,
	NumLock = 0x45,

	-- Navigation (E0-prefixed on set 1).
	Insert = 0xE052,
	Home = 0xE047,
	PageUp = 0xE049,
	Delete = 0xE053,
	End = 0xE04F,
	PageDown = 0xE051,
	Right = 0xE04D,
	Left = 0xE04B,
	Down = 0xE050,
	Up = 0xE048,

	-- Keypad. Divide and Enter are E0-prefixed like their main-key aliases.
	KeypadDivide = 0xE035,
	KeypadMultiply = 0x37,
	KeypadMinus = 0x4A,
	KeypadPlus = 0x4E,
	KeypadEnter = 0xE01C,
	KeypadPeriod = 0x53,
	KeypadZero = 0x52,
	KeypadOne = 0x4F,
	KeypadTwo = 0x50,
	KeypadThree = 0x51,
	KeypadFour = 0x4B,
	KeypadFive = 0x4C,
	KeypadSix = 0x4D,
	KeypadSeven = 0x47,
	KeypadEight = 0x48,
	KeypadNine = 0x49,
}

InputMap.Scancodes = SCANCODES

function InputMap.scancode(name: string): number?
	return SCANCODES[name]
end

function InputMap.isExtended(scancode: number): boolean
	return scancode > 0xFF
end

return InputMap
