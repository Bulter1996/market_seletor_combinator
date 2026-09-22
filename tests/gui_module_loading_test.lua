package.path = "./?.lua;" .. package.path
local Gui = require("scripts.gui")
local UI = require("scripts.network_gui")
local Mode = require("scripts.modes.supermarket_order")

-- 模拟 Factorio：control.lua 解析结束后，即便模块已缓存，也不得 require。
local original_require = require
require = function() error("runtime require is forbidden") end
local function element()
  local e = {valid = true, style = {}, children = {}}
  e.add = function(spec)
    local child = element()
    child.name, child.type, child.number, child.tags, child.caption = spec.name, spec.type, spec.number, spec.tags, spec.caption
    child.sprite, child.tooltip, child.elem_tooltip, child.style_name = spec.sprite, spec.tooltip, spec.elem_tooltip, spec.style
    e.children[#e.children + 1] = child
    if spec.name then e[spec.name] = child end
    return child
  end
  e.force_auto_center = function() end
  e.destroy = function() e.valid = false end
  return e
end
local force = {index = 1}
local messages = {}
local player = {index = 1, force = force, gui = {screen = element()},
  display_scale = 1, display_resolution = {width = 1920, height = 1080},
  mod_settings = { ["bmsc-policy-gui-opacity"] = {value = "60"} },
  print = function(message) messages[#messages + 1] = message end}
local record = {entity = {valid = true, force = force, unit_number = 1},
  config = {production_machine = "assembling-machine-1", recurise_depth = 0,
    order_targets = {}, recipe_policies = {plate = {{recipe = "plate", priority = 0, demand = 2, retention = 1}}}}}
game = {get_player = function() return player end}
defines = {mouse_button_type = {left = 1, right = 2}}
storage = {bmsc_network_views = {[1] = {unit = 1, signal = {type = "item", name = "plate"}, count = 1}}}
prototypes = {
  item = {plate = {localised_name = "Plate"}, ore = {localised_name = "Ore"}},
  entity = { ["assembling-machine-1"] = {name = "assembling-machine-1", localised_name = "Assembler"}},
  recipe = {chance = {localised_name = "Chance recipe"}}
}

local function sprites(parent, result)
  result = result or {}
  if parent.type == "sprite-button" then result[#result + 1] = parent end
  for _, child in ipairs(parent.children or {}) do sprites(child, result) end
  return result
end

local function has_connector(parent)
  if parent.type == "label" and (parent.caption == "│" or parent.caption == "─" or parent.caption == "┼") then return true end
  for _, child in ipairs(parent.children or {}) do if has_connector(child) then return true end end
  return false
end

local function has_button_caption(parent, caption)
  if parent.type == "button" and parent.caption == caption then return true end
  for _, child in ipairs(parent.children or {}) do
    if has_button_caption(child, caption) then return true end
  end
  return false
end

local function find_sprite(parent, sprite)
  if parent.sprite == sprite then return parent end
  for _, child in ipairs(parent.children or {}) do
    local found = find_sprite(child, sprite)
    if found then return found end
  end
end

local function textfields(parent, result)
  result = result or {}
  if parent.type == "textfield" then result[#result + 1] = parent end
  for _, child in ipairs(parent.children or {}) do textfields(child, result) end
  return result
end

local location_element = {valid = true, name = UI.tree_name, location = {x = 720, y = 80}}
assert(UI.on_location_changed({player_index = 1, element = location_element}))
assert(storage.bmsc_network_views[1].tree_location.x == 720 and storage.bmsc_network_views[1].tree_location.y == 80,
  "moving the recursive strategy window must retain the player view location")

-- 概率配方必须沿用公共平均产量并在每层向上取整；空红线库存是有效的 0，不能静默跳过。
record.config.inventory_validation = "inventory"
record.network_observed_inventory = {}
record.supermarket_order_plan = {roots = {{source_key = "item:plate:normal", signal = {type = "item", name = "plate"},
  product_amount = 0.25, recipe_name = "chance", children = {{signal = {type = "item", name = "ore"}, amount = 1, children = {}}}}}}
UI.open_tree(player, record, {type = "item", name = "plate"}, 1)
assert(player.gui.screen[UI.tree_name].style.width == 1280 and player.gui.screen[UI.tree_name].style.height == 540,
  "1x tree window must use the previous 2x dimensions")
local tree_frame = player.gui.screen[UI.tree_name]
assert(has_button_caption(tree_frame["bmsc-tree-titlebar"], "1x") and has_button_caption(tree_frame["bmsc-tree-titlebar"], "2x"),
  "tree header must provide separate 1x and 2x reset buttons")
assert(tree_frame["bmsc-tree-titlebar"].children[3].tooltip[1] == "bmsc-net.tree-size-1x"
  and tree_frame["bmsc-tree-titlebar"].children[4].tooltip[1] == "bmsc-net.tree-size-2x",
  "tree size buttons must explain their separate reset behavior")
assert(tree_frame["bmsc-tree-titlebar"].children[5].sprite == "utility/enter",
  "tree pin button must use the pin glyph instead of an arrow")
assert(has_button_caption(tree_frame["bmsc-tree-actions"], "+") and has_button_caption(tree_frame["bmsc-tree-actions"], "−"),
  "tree-wide expand and collapse controls must sit above the tree and use compact plus and minus buttons")
assert(#tree_frame["bmsc-tree-context"].children == 2,
  "production machine context must omit the redundant production-machine label")
assert(tree_frame["bmsc-tree-content"].children[1].style.left_padding > 0,
  "the root row must add left padding to stay centered in a wider tree viewport")
storage.bmsc_network_views[1].window_scale = 2
UI.open_tree(player, record, {type = "item", name = "plate"}, 1)
assert(player.gui.screen[UI.tree_name].style.width == 1910 and player.gui.screen[UI.tree_name].style.height == 1070,
  "2x tree window must leave ten pixels on each screen dimension")
storage.bmsc_network_views[1].window_scale = nil
UI.open_tree(player, record, {type = "item", name = "plate"}, 1)
assert(UI.on_zoom({player_index = 1, in_gui = true}, {[1] = record}, 0.25))
assert(storage.bmsc_network_views[1].tree_scale == 1.25,
  "Alt+wheel zoom must remain available and only change the tree scale")
local tree_slots = sprites(player.gui.screen[UI.tree_name])
local numbered = {}
for _, slot in ipairs(tree_slots) do if slot.number ~= nil then numbered[#numbered + 1] = slot end end
assert(numbered[#numbered - 1].number == 1 and numbered[#numbered].number == 4,
  "tree requirements must round probability crafts up before counting ingredients")
assert(numbered[#numbered].style_name == "red_circuit_network_content_slot",
  "an empty red inventory input is a valid zero stock and must be shown as insufficient")
assert(has_connector(player.gui.screen[UI.tree_name]), "tree must draw connectors between recipe products and ingredients")
record.config.inventory_validation = nil
UI.open_policy(player, record, {type = "item", name = "plate"}, {x = 400, y = 160})
local policy = player.gui.screen[UI.policy_name]
assert(policy.location.x == 150 and policy.location.y == 184, "policy popup must align its right edge to the cursor")
assert(policy.style.width == 250, "policy popup must use a fixed compact width for exact cursor alignment")
assert(policy.style_name == "bmsc_policy_frame_60", "policy popup must use the configured transparent frame style")
assert(policy.children[1].drag_target == policy, "policy title bar must drag its own popup frame")
assert(find_sprite(policy, "item/plate").style.width == 42,
  "policy header signal icon must use a compact 1.3x size")
for index, input in ipairs(textfields(policy)) do
  local expected = (index - 1) % 3 == 2 and 30 or 56
  assert(input.style.width == expected, "policy priority fields must be last and narrower than rate fields")
end
player.mod_settings["bmsc-policy-gui-opacity"].value = "80"
UI.open_policy(player, record, {type = "item", name = "plate"})
policy = player.gui.screen[UI.policy_name]
assert(policy.style_name == "bmsc_policy_frame_80",
  "policy popup must apply the current player's configured opacity")
UI.open_policy(player, record, {type = "item", name = "plate"})
policy = player.gui.screen[UI.policy_name]
assert(policy.location.x == 150 and policy.location.y == 184,
  "rebuilding the policy popup without an opening click must retain its current location")
policy.destroy()
player.gui.screen[UI.policy_name] = nil
UI.open_policy(player, record, {type = "item", name = "plate"})
policy = player.gui.screen[UI.policy_name]
assert(policy.location.x == 150 and policy.location.y == 184,
  "policy popup must retain its remembered location after tree refresh closes the old popup")
local tree = player.gui.screen[UI.tree_name]
assert(UI.on_closed({player_index = 1, element = tree}, {[1] = record}) and tree.valid and policy.valid,
  "opening the policy popup must not close the still-visible tree")
assert(player.opened == policy and UI.on_closed({player_index = 1, element = policy}, {[1] = record}),
  "Esc closing the policy popup must be handled independently from the tree")
assert(player.opened == player.gui.screen[UI.tree_name], "closing policy must restore the still-open tree")

local wide_children = {}
for index = 1, 40 do
  wide_children[index] = {signal = {type = "item", name = "ore"}, amount = 1, children = {}}
end
record.supermarket_order_plan = {roots = {{source_key = "item:plate:normal", signal = {type = "item", name = "plate"},
  product_amount = 1, children = wide_children}}}
storage.bmsc_network_views[1].window_scale = 1
storage.bmsc_network_views[1].collapsed = {}
UI.open_tree(player, record, {type = "item", name = "plate"}, 1)
assert(UI.on_click({player_index = 1, element = {tags = {bmsc_net_action = "tree-size", tree_window_scale = 2}}}, {[1] = record}))
assert(storage.bmsc_network_views[1].window_scale == 2 and storage.bmsc_network_views[1].tree_scale < 0.5,
  "2x must shrink a wide visible tree until it fits the enlarged viewport")
storage.bmsc_network_views[1].tree_scale = 2
assert(UI.on_click({player_index = 1, element = {tags = {bmsc_net_action = "tree-size", tree_window_scale = 2}}}, {[1] = record}))
assert(storage.bmsc_network_views[1].tree_scale < 0.5,
  "clicking the current size button must reset manual tree zoom to fit")
storage.bmsc_network_views[1].window_scale = nil

-- 主窗口仅构建到网络设置入口，后续无关控件不在本测试范围内。
local settings = UI.settings
local reached_settings = {}
UI.settings = function() error(reached_settings) end
local ok, err = pcall(Gui.open, player, record.entity, record.config)
assert(not ok and err == reached_settings, "main window must reach network settings without runtime require")
UI.settings = settings

local calculate, invalidate, open_tree, open_policy = Mode.calculate, Mode.invalidate_plan, UI.open_tree, UI.open_policy
local calculated, invalidated, opened, policy_opened = 0, 0, 0, 0
Mode.calculate = function(r) assert(r == record); calculated = calculated + 1 end
Mode.invalidate_plan = function(r) assert(r == record); invalidated = invalidated + 1 end
UI.open_tree = function() opened = opened + 1 end
UI.open_policy = function() policy_opened = policy_opened + 1 end
assert(UI.on_click({player_index = 1, element = {tags = {bmsc_net_action = "select", key = "plate"}}}, {[1] = record}))
assert(calculated == 0 and opened == 0 and policy_opened == 1, "node selection must open the policy popup without rebuilding the tree")
assert(UI.on_click({player_index = 1, button = defines.mouse_button_type.right, element = {tags = {
  bmsc_net_action = "select", key = "plate", path = "0", has_children = true}}}, {[1] = record}))
assert(storage.bmsc_network_views[1].collapsed["0"] and opened == 1 and policy_opened == 1,
  "right-clicking a node must collapse its complete subtree instead of opening policy")
storage.bmsc_network_views[1].collapsed["0.1"] = true
assert(UI.on_click({player_index = 1, button = defines.mouse_button_type.right, element = {tags = {
  bmsc_net_action = "select", key = "plate", path = "0", has_children = true}}}, {[1] = record}))
assert(storage.bmsc_network_views[1].collapsed["0"] == nil and storage.bmsc_network_views[1].collapsed["0.1"],
  "expanding a node must retain each descendant's own collapsed state")
assert(UI.on_click({player_index = 1, element = {tags = {bmsc_net_action = "tree-size", tree_window_scale = 2}}}, {[1] = record}))
assert(storage.bmsc_network_views[1].window_scale == 2, "tree size button must switch to 2x")
assert(UI.on_click({player_index = 1, element = {tags = {bmsc_net_action = "tree-pin"}}}, {[1] = record}))
assert(storage.bmsc_network_views[1].pinned, "pin button must retain the tree window")
assert(UI.on_click({player_index = 1, element = {tags = {bmsc_net_action = "tree-collapse-all"}}}, {[1] = record}))
assert(storage.bmsc_network_views[1].collapsed["0"], "collapse-all must collapse the root branch")
assert(UI.on_click({player_index = 1, element = {tags = {bmsc_net_action = "tree-expand-all"}}}, {[1] = record}))
assert(not next(storage.bmsc_network_views[1].collapsed), "expand-all must clear all collapsed branches")
assert(UI.on_text({player_index = 1, element = {text = "3", tags = {
  bmsc_net_field = "demand", unit = 1, key = "plate", recipe = "plate"}}}, {[1] = record}))
assert(invalidated == 1 and record.config.recipe_policies.plate[1].demand == 3,
  "editing recipe policy must invalidate plan")
assert(UI.on_click({player_index = 1, element = {tags = {
  bmsc_net_action = "policy", key = "plate", recipe = "plate"}}}, {[1] = record}))
assert(record.config.recipe_policies.plate[1].recipe == "plate" and #messages == 1,
  "clicking the final enabled recipe must leave it enabled and report the requirement")
assert(UI.on_click({player_index = 1, element = {tags = {
  bmsc_net_action = "policy", key = "plate", recipe = "other"}}}, {[1] = record}))
assert(#record.config.recipe_policies.plate == 2, "clicking another recipe must update policy immediately")
assert(UI.on_click({player_index = 1, element = {tags = {
  bmsc_net_action = "policy", key = "plate", recipe = "plate"}}}, {[1] = record}))
assert(record.config.recipe_policies.plate[1].recipe == "other", "an enabled recipe may be removed when another remains")
Mode.calculate, Mode.invalidate_plan, UI.open_tree, UI.open_policy = calculate, invalidate, open_tree, open_policy
require = original_require
print("gui_module_loading_test: ok")
