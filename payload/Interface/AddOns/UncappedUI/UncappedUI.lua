-- UncappedUI -- shared modular UI/theme library for Uncapped addons.
-- Written for 3.3.5a: no BackdropTemplate and no modern C_ APIs.
--
-- Namespace bootstrap only. Every other file in this addon hangs its API
-- off the _G.UncappedUI table created here, and every file after this one
-- guards itself with `if not UncappedUI then return end` so load order
-- mistakes fail quietly instead of throwing on a missing global.

local UncappedUI = _G.UncappedUI or {}
_G.UncappedUI = UncappedUI

UncappedUI.ADDON = "UncappedUI"
UncappedUI.version = "0.0.0"
