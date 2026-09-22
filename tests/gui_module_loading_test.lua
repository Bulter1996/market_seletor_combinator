package.path = "./?.lua;" .. package.path
local Gui = require("scripts.gui")
local UI = require("scripts.network_gui")
local Mode = require("scripts.modes.supermarket_order")

-- 模拟 Factorio：control.lua 解析结束后，即便模块已缓存，也不得 require。
local original_require = require
require = function() error("runtime require is forbidden") end
local function element()
  local e = {valid = true, style = {}}
  e.add = function(spec)
    local child = element()
    if spec.name then e[spec.name] = child end
    return child
  end
  e.force_auto_center = function() end
  e.destroy = function() e.valid = false end
  return e
end
local force = {index = 1}
local player = {index = 1, force = force, gui = {screen = element()},
  display_scale = 1, display_resolution = {height = 1080}}
local record = {entity = {valid = true, force = force, unit_number = 1},
  config = {recipe_policies = {plate = {{recipe = "plate", priority = 0, demand = 2, retention = 1}}}}}
game = {get_player = function() return player end}
storage = {bmsc_network_views = {[1] = {unit = 1, signal = {type = "item", name = "plate"}, count = 1}}}

-- 主窗口仅构建到网络设置入口，后续无关控件不在本测试范围内。
local settings = UI.settings
local reached_settings = {}
UI.settings = function() error(reached_settings) end
local ok, err = pcall(Gui.open, player, record.entity, record.config)
assert(not ok and err == reached_settings, "main window must reach network settings without runtime require")
UI.settings = settings

local calculate, invalidate, open_tree = Mode.calculate, Mode.invalidate_plan, UI.open_tree
local calculated, invalidated, opened = 0, 0, 0
Mode.calculate = function(r) assert(r == record); calculated = calculated + 1 end
Mode.invalidate_plan = function(r) assert(r == record); invalidated = invalidated + 1 end
UI.open_tree = function() opened = opened + 1 end
assert(UI.on_click({player_index = 1, element = {tags = {bmsc_net_action = "select", key = "plate"}}}, {[1] = record}))
assert(calculated == 1 and opened == 1, "node selection must refresh tree")
assert(UI.on_text({player_index = 1, element = {text = "3", tags = {
  bmsc_net_field = "demand", unit = 1, key = "plate", recipe = "plate"}}}, {[1] = record}))
assert(invalidated == 1 and record.config.recipe_policies.plate[1].demand == 3,
  "editing recipe policy must invalidate plan")
Mode.calculate, Mode.invalidate_plan, UI.open_tree = calculate, invalidate, open_tree
require = original_require
print("gui_module_loading_test: ok")
