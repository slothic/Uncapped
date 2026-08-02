-- UncappedUIKit -- shared modular UI/theme library for Uncapped addons.
-- Written for 3.3.5a: no BackdropTemplate and no modern C_ APIs.
--
-- Namespace bootstrap only. Every other file in this addon hangs its API
-- off the _G.UncappedUIKit table created here, and every file after this one
-- guards itself with `if not UncappedUIKit then return end` so load order
-- mistakes fail quietly instead of throwing on a missing global.

local UncappedUIKit = _G.UncappedUIKit or {}
_G.UncappedUIKit = UncappedUIKit

UncappedUIKit.ADDON = "UncappedUI"
UncappedUIKit.version = "0.0.0"
