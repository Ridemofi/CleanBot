-- ============================================================
-- spec/run.lua  —  Test entry point. Run from the addon root:
--   luajit spec/run.lua
-- Loads the WoW mock + harness, then each spec, then prints a summary and exits
-- non-zero on any failure (for CI).
-- ============================================================

dofile("spec/wow_mock.lua")

-- Load the real core file so specs exercise its actual helpers (CB_SplitOnce, group
-- iteration, ...) instead of copies. Muted: its load-time banner is noise in a test run.
local realPrint = print
print = function() end
dofile("CleanBot.lua")
print = realPrint
Mock.silenceCore()   -- re-stub CB_Print/CB_After for the test environment

dofile("spec/framework.lua")

-- Spec files (add new ones here).
dofile("spec/core_spec.lua")
dofile("spec/events_spec.lua")
dofile("spec/inventory_spec.lua")
dofile("spec/bridge_spec.lua")
dofile("spec/strategies_spec.lua")
dofile("spec/overhear_spec.lua")
dofile("spec/overhear_appliers_spec.lua")
dofile("spec/chatfilter_spec.lua")
dofile("spec/layout_spec.lua")
dofile("spec/actionbar_layout_spec.lua")
dofile("spec/recruiter_spec.lua")

_RUN_FINISH()
