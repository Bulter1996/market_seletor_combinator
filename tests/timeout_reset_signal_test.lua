package.path = "./?.lua;" .. package.path

local product = {type = "item", name = "product", amount = 1}
local recipe = {
  name = "make-product", categories = {"crafting"}, main_product = product, products = {product},
  ingredients = {{type = "item", name = "iron", amount = 1}}
}
prototypes = {
  entity = {assembler = {crafting_categories = {crafting = true}}},
  recipe = {[recipe.name] = recipe}
}
defines = {wire_connector_id = {combinator_input_red = 1, combinator_input_green = 2}}
game = {tick = 0}

local reset = {type = "virtual", name = "signal-R"}
local Config = require("scripts.config")
local normalized = Config.normalize{production_timeout_reset_signal = reset,
  recursion_timeout_reset_signal = {name = "iron", quality = "normal"},
  swap_conditions = {{
    first = {signal = reset}, comparator = "=", second = {signal = {name = "iron", quality = "normal"}}
  }}}
assert(normalized.production_timeout_conditions[1].first.signal.name == "signal-R")
assert(normalized.production_timeout_conditions[1].first.green == true)
assert(normalized.recursion_timeout_conditions[1].first.signal.type == "item")
assert(normalized.swap_conditions[1].first.signal.name == "signal-R")
assert(normalized.swap_conditions[1].second.signal.type == "item")
assert(normalized.swap_conditions[1].first.signal ~= reset)
local copied = Config.normalize{mode = Config.mode.swap_order, swap_timeout = 12,
  recipe_query_cache_grid_number = 7,
  recursion_additional_production_rate = 2, recursion_material_demand_rate = 6,
  recursion_material_retention_rate = 2,
  production_timeout_conditions = normalized.production_timeout_conditions,
  recursion_timeout_conditions = normalized.recursion_timeout_conditions,
  swap_conditions = normalized.swap_conditions}
assert(copied.mode == Config.mode.swap_order and copied.swap_timeout == 12)
assert(copied.recipe_query_cache_grid_number == 7)
assert(copied.recursion_additional_production_rate == 2)
assert(copied.recursion_material_demand_rate == 6 and copied.recursion_material_retention_rate == 2)
assert(copied.production_timeout_conditions[1].first.signal.name == "signal-R")
assert(copied.recursion_timeout_conditions[1].first.signal.name == "iron")
assert(copied.swap_conditions[1].second.signal.name == "iron")
local green = {
  {signal = {type = "item", name = "product", quality = "normal"}, count = 10},
  {signal = reset, count = 1}
}
local reset_conditions = {{first = {signal = reset, red = false, green = true}, comparator = ">",
  second = {constant = 0}}}
local force = {index = 1, recipes = {['make-product'] = {enabled = true}}}
local red = {{signal = {type = "item", name = "iron", quality = "normal"}, count = 100}}
local entity = {force = force, get_signals = function(connector_id)
  return connector_id == defines.wire_connector_id.combinator_input_green and green or red
end}

local ProductionOrder = require("scripts.modes.production_order")
local production_record = {entity = entity, config = {
  production_machine = "assembler", remember_order = false, production_timeout = 1,
  production_timeout_conditions = reset_conditions, additional_production_rate = 0,
  material_demand_rate = 1, material_retention_rate = 0, output_mode = "all", cache_grid_number = 0
}}
ProductionOrder.calculate(production_record)
assert(production_record.production_order_diagnostics["item:product:normal"].kind == "active_output")
game.tick = 120
ProductionOrder.calculate(production_record)
assert(production_record.production_order_changed_tick == 120)
assert(production_record.production_order_diagnostics["virtual:signal-R"] == nil)
green[2].count = 0
game.tick = 181
ProductionOrder.calculate(production_record)
assert(production_record.production_order_changed_tick == 181)

production_record = {entity = entity, config = {
  production_machine = "assembler", remember_order = false, production_timeout = 0,
  production_timeout_conditions = reset_conditions, additional_production_rate = 0,
  material_demand_rate = 1, material_retention_rate = 0, output_mode = "all", cache_grid_number = 0
}}
green[2].count = 1
game.tick = 0
ProductionOrder.calculate(production_record)
game.tick = 120
ProductionOrder.calculate(production_record)
assert(production_record.production_order_changed_tick == 0)

red = {}
green[2].count = 1
game.tick = 0
local SupermarketOrder = require("scripts.modes.supermarket_order")
local supermarket_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recurise_depth = 0, recursion_timeout = 1, recursion_timeout_conditions = reset_conditions
}}
SupermarketOrder.calculate(supermarket_record)
game.tick = 120
SupermarketOrder.calculate(supermarket_record)
assert(supermarket_record.recursion_output_changed_tick == 120)
assert(supermarket_record.supermarket_order_diagnostics["virtual:signal-R"] == nil)
green[2].count = 0
game.tick = 181
SupermarketOrder.calculate(supermarket_record)
assert(supermarket_record.recursion_output_changed_tick == 181)

supermarket_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recurise_depth = 0, recursion_timeout = 0, recursion_timeout_conditions = reset_conditions
}}
green[2].count = 1
game.tick = 0
SupermarketOrder.calculate(supermarket_record)
game.tick = 120
SupermarketOrder.calculate(supermarket_record)
assert(supermarket_record.recursion_output_changed_tick == 0)

print("timeout reset signal: ok")
