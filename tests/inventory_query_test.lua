package.path = "./?.lua;" .. package.path

storage = {}
script = {active_mods = {LinkedChestAndPipe = "1.2.96"}}
defines = {wire_connector_id = {combinator_input_red = 1, combinator_input_green = 2}}
prototypes = {
  entity = {["share-network-output"] = {}}, recipe = {},
  item = {product = {}, iron = {}, byproduct = {}}, fluid = {}, quality = {normal = {}}
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
local surface = {
  find_entities_filtered = function() return {} end,
  create_entity = function() return probe end
}
local created_surface
game = {
  tick = 0,
  get_surface = function() return created_surface end,
  create_surface = function() created_surface = surface; return surface end
}

local Mode = require("scripts.modes.inventory_query")
local plan = {roots = {{
  signal = {type = "item", name = "product", quality = "normal"},
  validation_products = {{type = "item", name = "byproduct", quality = "normal"}},
  children = {{signal = {type = "item", name = "iron", quality = "normal"}, children = {}}}
}}}
local requested = Mode.supermarket_signals(plan)
assert(requested["item:product:normal"] and requested["item:iron:normal"]
  and requested["item:byproduct:normal"])

local record = {entity = {valid = true, force = force}, config = {
  mode = "supermarket_order", inventory_validation = "linked"
}, supermarket_order_plan = plan}
Mode.prepare({record})
assert(Mode.get_shared_inventory(force, requested) == nil)
assert(#section.filters == 3)

for _, filter in pairs(section.filters) do
  filter.min = filter.value.name == "iron" and 42 or 7
end
game.tick = 13
Mode.prepare({record})
local first, first_generation = Mode.get_shared_inventory(force, requested)
assert(first_generation == 1 and first["item:iron:normal"] == 42
  and first["item:product:normal"] == 7)

-- 同一探针缓存被多次读取不能伪装成新的独立快照。
game.tick = 50
Mode.prepare({record})
local _, repeated_generation = Mode.get_shared_inventory(force, requested)
assert(repeated_generation == first_generation)

for _, filter in pairs(section.filters) do filter.min = 3 end
game.tick = 133
Mode.prepare({record})
local second, second_generation = Mode.get_shared_inventory(force, requested)
assert(second_generation == 2 and second["item:iron:normal"] == 3)

print("linked inventory query snapshots: ok")
