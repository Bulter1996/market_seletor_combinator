package.path = "./?.lua;" .. package.path
local Gui = require("scripts.gui")
local UI = require("scripts.network_gui")
local Mode = require("scripts.modes.supermarket_order")
local Config = require("scripts.config")

-- 模拟 Factorio：control.lua 解析结束后，即便模块已缓存，也不得 require。
local original_require = require
require = function() error("runtime require is forbidden") end
local function element()
  -- Factorio 为 `element.style = "..."` 保留 LuaStyle 对象；测试替身也要让
  -- 后续的 `element.style.width = ...` 继续可用。
  local e = {valid = true, _style = {}, children = {}, tags = {}}
  setmetatable(e, {
    __index = function(t, key)
      if key == "style" then return rawget(t, "_style") end
    end,
    __newindex = function(t, key, value)
      if key == "style" then
        rawset(t, "style_name", value)
      else
        rawset(t, key, value)
      end
    end
  })
  e.add = function(spec)
    local child = element()
    child.name, child.type, child.number, child.tags, child.caption = spec.name, spec.type, spec.number, spec.tags or {}, spec.caption
    child.text, child.selected_index, child.items = spec.text, spec.selected_index, spec.items
    child.direction = spec.direction
    child.sprite, child.tooltip, child.elem_tooltip, child.style_name = spec.sprite, spec.tooltip, spec.elem_tooltip, spec.style
    child.visible = spec.visible ~= false
    child.enabled = spec.enabled ~= false
    child.state = spec.state == true
    child.toggled = spec.toggled == true
    child.parent = e
    e.children[#e.children + 1] = child
    if spec.name then e[spec.name] = child end
    return child
  end
  e.force_auto_center = function() end
  e.destroy = function() e.valid = false end
  e.clear = function()
    for _, child in ipairs(e.children) do if child.name then e[child.name] = nil end end
    e.children = {}
  end
  return e
end
local force = {index = 1}
local messages = {}
local player = {index = 1, force = force, gui = {screen = element()},
  display_scale = 1, display_resolution = {width = 1920, height = 1080},
  mod_settings = { ["bmsc-policy-gui-opacity"] = {value = "60"} },
  print = function(message) messages[#messages + 1] = message end}
player.set_controller = function(spec) player.remote_controller = spec end
local record = {entity = {valid = true, force = force, unit_number = 1, combinator_description = "",
  get_wire_connector = function() return {connection_count = 0} end},
  config = Config.default()}
record.config.recipe_policies = {plate = {{recipe = "plate", priority = 0, demand = 2, retention = 1}}}
game = {get_player = function() return player end}
defines = {controllers = {remote = 1}, mouse_button_type = {left = 1, right = 2}, wire_connector_id = {
  combinator_input_red = 1, combinator_input_green = 2, combinator_output_red = 3, combinator_output_green = 4}}
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
record.config.recurise_depth = 1
record.entity.position, record.entity.surface = {x = 10, y = 20}, {index = 1, name = "nauvis"}
record.supermarket_order_plan = {roots = {{source_key = "item:plate:normal", level = 1,
  signal = {type = "item", name = "plate"}, product_amount = 1, recipe_name = "plate", children = {{
    level = 2, signal = {type = "item", name = "ore"}, amount = 1, children = {{
      level = 3, signal = {type = "item", name = "coal"}, amount = 1, children = {}}}}}}}}
UI.open_tree(player, record, {type = "item", name = "plate"}, 1)
numbered = {}
for _, slot in ipairs(sprites(player.gui.screen[UI.tree_name])) do if slot.number ~= nil then numbered[#numbered + 1] = slot end end
assert(#numbered == 2, "a limited recursion tree must retain its boundary output but omit deeper descendants")
assert(UI.on_click({player_index = 1, element = {tags = {bmsc_net_action = "locate", unit = 1}}}, {[1] = record}))
assert(player.remote_controller.position == record.entity.position and player.zoom == 0.5,
  "locating a combinator must use a readable remote zoom instead of the closest view")
record.config.recurise_depth = 0
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

-- 主窗口默认是运行页；页面切换不得重建配置控件，也不能把纯界面状态写进实体配置。
local rebuild_conditions = Gui.rebuild_conditions
-- 这个轻量 GUI 模拟器不能复现 Factorio 对 `element.style = "..."` 的代理赋值；
-- 页面结构断言不依赖条件行本身，因此在此处跳过条件行的具体渲染。
Gui.rebuild_conditions = function() end
local main = Gui.open(player, record.entity, record.config, nil, nil, {
  current = {stage = {signal = {type = "item", name = "plate"}, target = 100, stock = 25,
    single_output = true, product_output = true, ingredients = {
      {required = 10, stock = 12, demand_ready = true}}},
    product = {signal = {type = "item", name = "plate"}, target = 100, stock = 25, remaining = 75}},
  next = nil, source = "local"})
local content = main["bmsc-content"]
local runtime_column = content["bmsc-runtime-column"]
local config_column = content["bmsc-config-column"]
local runtime_page = runtime_column["bmsc-runtime-page"]
local config_page = config_column["bmsc-config-page"]
assert(content.type == "flow" and content.direction == "horizontal",
  "main content must be a horizontal layout container, not one shared vertical scroll pane")
assert(runtime_page.visible and not config_column.visible,
  "main window must open with the parameter column collapsed")
assert(main.style.width == 552,
  "a collapsed configuration page must keep the runtime window compact")
assert(runtime_page["bmsc-signals"], "runtime page must own the shared signal panel")
local work_grid = runtime_page["bmsc-work-panel"]["bmsc-work-grid"]
assert(work_grid["bmsc-work-production-target"].caption == "100"
  and work_grid["bmsc-work-production-remaining"].caption == "75"
  and work_grid["bmsc-work-production-stock"].caption == "25",
  "current production must keep target, shortage, and stock in fixed numeric columns")
assert(work_grid["bmsc-work-production-separator-three"].caption == "｜",
  "stock and state must remain separate columns")
assert(work_grid["bmsc-work-next-kind"].caption == ""
  and work_grid["bmsc-work-next-separator-one"].caption == ""
  and work_grid["bmsc-work-next-separator-two"].caption == "",
  "an absent next order must retain its row but leave every visible field empty")
local signal_panel = Gui.add_signal_panel(element(), player)
Gui.refresh_signal_panel(signal_panel, {
  {color = "red", signals = {{signal = {type = "item", name = "plate"}, count = 3}}},
  {color = "green", signals = {{signal = {type = "item", name = "plate"}, count = 7}}}
}, {}, {}, {
  network_orders = {{signal = {type = "item", name = "gear"}, count = 10}},
  linked_inventory = {{signal = {type = "item", name = "ore"}, count = 80}}
})
local green_slots = signal_panel["bmsc-local-green-signals"]["bmsc-signal-scroll"]["bmsc-signal-slots"]
local red_slots = signal_panel["bmsc-local-red-signals"]["bmsc-signal-scroll"]["bmsc-signal-slots"]
local network_slots = signal_panel["bmsc-network-order-signals"]["bmsc-signal-scroll"]["bmsc-signal-slots"]
local linked_slots = signal_panel["bmsc-linked-inventory-signals"]["bmsc-signal-scroll"]["bmsc-signal-slots"]
assert(#green_slots.children == 1 and green_slots.children[1].number == 7
  and green_slots.children[1].tags.bmsc_signal_source == "local-order"
  and #red_slots.children == 1 and red_slots.children[1].number == 3
  and red_slots.children[1].tags.bmsc_signal_source == "local-stock"
  and #network_slots.children == 1 and network_slots.children[1].tags.bmsc_signal_source == "network-order"
  and #linked_slots.children == 1 and linked_slots.children[1].tags.bmsc_signal_source == "linked-inventory",
  "each input source must have its own slots and interaction source")
assert(not content["bmsc-production-details"], "configuration details must not remain direct content children")
local closed, config_open = Gui.show_page(main["bmsc-page-switcher"]["bmsc-page-config"], "config")
assert(not closed and config_open,
  "opening the configuration drawer must report its player-persisted visual state")
assert(runtime_page.visible and config_column.visible,
  "configuration drawer must leave the runtime panel visible")
assert(main.style.width == 996,
  "opening configuration must add its fixed column without stretching the runtime column")
assert(config_page["bmsc-production-details"],
  "configuration page must retain the existing production settings")
assert(config_page["bmsc-network-settings"] and config_page["bmsc-network-settings"].type == "frame",
  "network settings must remain an independent configuration component")
local order_settings = config_page["bmsc-recursion-details"]["bmsc-recursion-settings"]
local timeout_settings = config_page["bmsc-recursion-details"]["bmsc-recursion-timeout-settings"]
assert(order_settings and timeout_settings,
  "supermarket order parameters and timeout settings must be separate GUI components")
local order_fields = order_settings["bmsc-recursion-fields"]
local generation = order_fields["bmsc-recursion-additional-controls"]
local material_range = order_fields["bmsc-recursion-material-controls"]
assert(generation["bmsc-recursion-additional-min"].enabled == false
  and generation["bmsc-recursion-additional"],
  "generation rate must expose a disabled zero lower bound and editable upper value")
assert(material_range["bmsc-recursion-material-retention"]
  and material_range["bmsc-recursion-material"],
  "material rate must expose retention and demand as one two-sided control")
assert(order_fields["bmsc-restart-sequence"]
  and order_fields["bmsc-recursion-output-controls"]["bmsc-sequential-production"].type == "checkbox",
  "sequential production must be a checkbox next to the single-output selector")
local valid, demand, retention = Gui.validate_material_rate_inputs(material_range["bmsc-recursion-material"])
assert(valid and demand == 10 and retention == 1,
  "two-sided material rate inputs must retain the existing demand-greater-than-retention validation")
Gui.set_recursion_single_options_visible(order_fields["bmsc-recursion-output-controls"]["bmsc-recursion-output"], false)
assert(not timeout_settings.visible and not order_fields["bmsc-recursion-output-controls"]["bmsc-sequential-production"].visible,
  "All output must hide the timeout component and sequential checkbox together")
Gui.set_recursion_single_options_visible(order_fields["bmsc-recursion-output-controls"]["bmsc-recursion-output"], true)
assert(timeout_settings.visible and order_fields["bmsc-recursion-output-controls"]["bmsc-sequential-production"].visible,
  "Single output must restore the timeout component and sequential checkbox")
local reopened, config_closed = Gui.show_page(main["bmsc-page-switcher"]["bmsc-page-config"], "config")
assert(reopened and not config_closed and main.style.width == 552,
  "closing the configuration drawer must refresh runtime and restore compact width")

local remembered_main = Gui.open(player, record.entity, record.config, nil, nil, nil, nil, true)
assert(remembered_main.style.width == 996
  and remembered_main["bmsc-content"]["bmsc-config-column"].visible,
  "a caller-provided player preference must reopen the configuration page expanded")

-- 逻辑宽度不足双栏最小值时，配置必须作为覆盖层打开，不能再挤压运行面板。
player.display_resolution = {width = 1000, height = 1080}
local narrow_main = Gui.open(player, record.entity, record.config)
local narrow_content = narrow_main["bmsc-content"]
local overlay = player.gui.screen[Gui.config_overlay_name]
assert(not narrow_content["bmsc-config-column"] and overlay and not overlay.visible,
  "narrow screens must keep configuration outside the runtime layout until requested")
assert(not Gui.show_page(narrow_main["bmsc-page-switcher"]["bmsc-page-config"], "config")
  and overlay.visible and overlay["bmsc-content"]["bmsc-config-column"] and narrow_main.style.width == 552,
  "opening configuration on a narrow screen must show the standalone overlay without widening runtime")
narrow_main.location = {x = 100, y = 20}
Gui.sync_config_overlay_location(narrow_main)
assert(overlay.location.x == 100 and overlay.location.y == 76,
  "the narrow-screen configuration overlay must follow a dragged main window")
assert(Gui.show_page(narrow_main["bmsc-page-switcher"]["bmsc-page-config"], "config")
  and not overlay.visible and narrow_main.style.width == 552,
  "closing the narrow-screen overlay must request a runtime refresh")
player.display_resolution = {width = 1920, height = 1080}
Gui.rebuild_conditions = rebuild_conditions
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
