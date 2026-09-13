package.path = "./?.lua;" .. package.path

local function recipe(name, product, ingredient)
  local result = {type = "item", name = product, amount = 1}
  return {
    name = name, categories = {"crafting"}, main_product = result, products = {result},
    ingredients = {{type = "item", name = ingredient, amount = 1}}
  }
end

local recipe_a = recipe("make-a", "a", "iron")
local recipe_b = recipe("make-b", "b", "a")
prototypes = {
  entity = {assembler = {crafting_categories = {crafting = true}}},
  recipe = {[recipe_a.name] = recipe_a, [recipe_b.name] = recipe_b}
}
defines = {wire_connector_id = {combinator_input_red = 1, combinator_input_green = 2}}
game = {tick = 0}

local inventory = {{signal = {type = "item", name = "a", quality = "normal"}, count = 10}}
local orders = {
  {signal = {type = "item", name = "a", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "b", quality = "normal"}, count = 10}
}
local force = {index = 1, recipes = {['make-a'] = {enabled = true}, ['make-b'] = {enabled = true}}}
local entity = {force = force, get_signals = function(connector_id)
  return connector_id == defines.wire_connector_id.combinator_input_green and orders or inventory
end}
local record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single",
  sequential_production = true, recurise_depth = 0, recursion_timeout = 0
}}

local Mode = require("scripts.modes.supermarket_order")
Mode.calculate(record)
assert(record.supermarket_sequence_index == 2)
assert(record.supermarket_order_diagnostics["item:a:normal"].kind == "supermarket_completed")

inventory = {}
Mode.calculate(record)
assert(record.supermarket_sequence_index == 2)
assert(record.supermarket_order_diagnostics["item:a:normal"].kind == "supermarket_completed")

Mode.restart_sequence(record)
local restarted = Mode.calculate(record)
assert(record.supermarket_sequence_index == 1)
assert(restarted["item:iron:normal"].count == 10)
assert(record.supermarket_order_diagnostics["item:b:normal"].kind == "waiting_for_order")

inventory = {{signal = {type = "item", name = "a", quality = "normal"}, count = 10}}
Mode.calculate(record)
inventory = {}
orders[2].count = 11
local changed = Mode.calculate(record)
assert(record.supermarket_sequence_index == 1)
assert(changed["item:iron:normal"].count == 10)

print("supermarket sequential progress: ok")
