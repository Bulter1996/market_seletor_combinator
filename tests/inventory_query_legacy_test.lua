package.path = "./?.lua;" .. package.path

-- 原版 LinkedChestAndPipe 没有地表协议信号；此时查询器必须退回旧的一势力一探针协议。
storage = {}
script = {active_mods = {LinkedChestAndPipe = "1.2.96"}}
defines = {wire_connector_id = {combinator_input_red = 1, combinator_input_green = 2}}
prototypes = {
  entity = {["share-network-output"] = {}}, recipe = {}, virtual_signal = {},
  item = {iron = {}}, fluid = {}, quality = {normal = {}}
}

local section = {filters = {}}
local behavior = {
  sections_count = 1,
  get_section = function(index) return index == 1 and section or nil end,
  add_section = function() return section end,
  remove_section = function() end
}
local force = {index = 1, name = "player"}
local probe = {
  valid = true, name = "share-network-output", force = force, unit_number = 1,
  get_or_create_control_behavior = function() return behavior end
}
local probe_surface = {
  find_entities_filtered = function() return {} end,
  create_entity = function() return probe end
}
local nauvis = {index = 1, name = "nauvis", valid = true}
local vulcanus = {index = 2, name = "vulcanus", valid = true}
local created_probe_surface
game = {
  tick = 0,
  get_surface = function(value)
    if value == "__market-selector-combinator-query__" then return created_probe_surface end
    if value == 1 then return nauvis end
    if value == 2 then return vulcanus end
  end,
  create_surface = function() created_probe_surface = probe_surface; return probe_surface end
}

local Mode = require("scripts.modes.inventory_query")
local record = {entity = {valid = true, force = force, surface = nauvis}, config = {
  mode = "inventory_query", query_type = "all", query_all = false
}}
local Util = require("scripts.common_util")
local original_read_network = Util.read_network
Util.read_network = function(_, connector_id)
  if connector_id == defines.wire_connector_id.combinator_input_red then
    return nil, {{signal = {type = "item", name = "iron", quality = "normal"}}}
  end
  return nil, {}
end

Mode.prepare({record})
assert(#section.filters == 1 and section.filters[1].value.name == "iron")
section.filters[1].min = 12
game.tick = 13
Mode.prepare({record})

local requested = {['item:iron:normal'] = {type = "item", name = "iron", quality = "normal"}}
local inventory = Mode.get_shared_inventory(force, vulcanus, requested)
assert(inventory and inventory['item:iron:normal'] == 12)

Util.read_network = original_read_network
print("legacy linked inventory query fallback: ok")
