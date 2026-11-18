--!nonstrict
-- InputMapTests.lua -- host key names to PC set-1 make codes.

const InputMap = require("../core/InputMap")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

T("letters_and_digits", function(expect)
	expect(InputMap.scancode("A") == 0x1E, "A")
	expect(InputMap.scancode("Q") == 0x10, "Q")
	expect(InputMap.scancode("Z") == 0x2C, "Z")
	expect(InputMap.scancode("M") == 0x32, "M")
	expect(InputMap.scancode("One") == 0x02, "One")
	expect(InputMap.scancode("Nine") == 0x0A, "Nine")
	expect(InputMap.scancode("Zero") == 0x0B, "Zero")
end)

T("editing_and_modifiers", function(expect)
	expect(InputMap.scancode("Escape") == 0x01, "Escape")
	expect(InputMap.scancode("Return") == 0x1C, "Return")
	expect(InputMap.scancode("Backspace") == 0x0E, "Backspace")
	expect(InputMap.scancode("Tab") == 0x0F, "Tab")
	expect(InputMap.scancode("Space") == 0x39, "Space")
	expect(InputMap.scancode("LeftShift") == 0x2A, "LeftShift")
	expect(InputMap.scancode("RightShift") == 0x36, "RightShift")
	expect(InputMap.scancode("LeftControl") == 0x1D, "LeftControl")
	expect(InputMap.scancode("LeftAlt") == 0x38, "LeftAlt")
	expect(InputMap.scancode("LeftMeta") == 0xE05B, "LeftMeta")
	expect(InputMap.scancode("RightMeta") == 0xE05C, "RightMeta")
	expect(InputMap.scancode("Menu") == 0xE05D, "Menu")
end)

T("function_row", function(expect)
	expect(InputMap.scancode("F1") == 0x3B, "F1")
	expect(InputMap.scancode("F10") == 0x44, "F10")
	expect(InputMap.scancode("F11") == 0x57, "F11")
	expect(InputMap.scancode("F12") == 0x58, "F12")
end)

T("punctuation", function(expect)
	expect(InputMap.scancode("Minus") == 0x0C, "Minus")
	expect(InputMap.scancode("Equals") == 0x0D, "Equals")
	expect(InputMap.scancode("LeftBracket") == 0x1A, "LeftBracket")
	expect(InputMap.scancode("BackSlash") == 0x2B, "BackSlash")
	expect(InputMap.scancode("Semicolon") == 0x27, "Semicolon")
	expect(InputMap.scancode("Quote") == 0x28, "Quote")
	expect(InputMap.scancode("Comma") == 0x33, "Comma")
	expect(InputMap.scancode("Period") == 0x34, "Period")
	expect(InputMap.scancode("Slash") == 0x35, "Slash")
	expect(InputMap.scancode("Backquote") == 0x29, "Backquote")
end)

T("navigation_is_extended", function(expect)
	const arrowCodes = {
		Up = 0xE048,
		Down = 0xE050,
		Left = 0xE04B,
		Right = 0xE04D,
	}
	for name, code in arrowCodes do
		expect(InputMap.scancode(name) == code, name)
		expect(InputMap.isExtended(code), name .. " not extended")
		expect(not InputMap.isExtended(code % 0x100), name .. " low byte extended")
	end
	expect(InputMap.scancode("Home") == 0xE047, "Home")
	expect(InputMap.scancode("End") == 0xE04F, "End")
	expect(InputMap.scancode("PageUp") == 0xE049, "PageUp")
	expect(InputMap.scancode("PageDown") == 0xE051, "PageDown")
	expect(InputMap.scancode("Insert") == 0xE052, "Insert")
	expect(InputMap.scancode("Delete") == 0xE053, "Delete")
end)

T("keypad_and_locks", function(expect)
	expect(InputMap.scancode("KeypadZero") == 0x52, "KeypadZero")
	expect(InputMap.scancode("KeypadFive") == 0x4C, "KeypadFive")
	expect(InputMap.scancode("KeypadNine") == 0x49, "KeypadNine")
	expect(InputMap.scancode("KeypadPlus") == 0x4E, "KeypadPlus")
	expect(InputMap.scancode("KeypadMultiply") == 0x37, "KeypadMultiply")
	expect(InputMap.scancode("KeypadDivide") == 0xE035, "KeypadDivide")
	expect(InputMap.scancode("KeypadEnter") == 0xE01C, "KeypadEnter")
	expect(InputMap.scancode("NumLock") == 0x45, "NumLock")
	expect(InputMap.scancode("ScrollLock") == 0x46, "ScrollLock")
end)

T("coverage_and_bounds", function(expect)
	local count = 0
	local extended = 0
	local missed = {}
	for name, code in InputMap.Scancodes do
		count += 1
		if code <= 0 or code > 0xFFFF then
			missed[#missed + 1] = name
		end
		if InputMap.isExtended(code) then
			extended += 1
			if math.floor(code / 0x100) ~= 0xE0 then
				missed[#missed + 1] = name .. " prefix"
			end
		end
	end
	expect(count >= 90, "only " .. count .. " keys mapped")
	expect(extended >= 14, "only " .. extended .. " extended keys")
	expect(#missed == 0, "bad entries: " .. table.concat(missed, ", "))
	expect(InputMap.scancode("NotAKey") == nil, "unknown key mapped")
end)

return TESTS
