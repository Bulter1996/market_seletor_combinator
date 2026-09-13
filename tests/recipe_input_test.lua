package.path = "./?.lua;" .. package.path

local product = {type = "item", name = "widget", amount = 1}
local recipe_a = {
  name = "widget-a", categories = {"crafting"}, ingredients = {{type = "item", name = "iron", amount = 1}},
  products = {product}, main_product = product
}
local recipe_b = {
  name = "widget-b", categories = {"crafting"}, ingredients = {{type = "item", name = "copper", amount = 1}},
  products = {product}, main_product = product
}
prototypes = {
  entity = {assembler = {crafting_categories = {crafting = true}}},
  recipe = {[recipe_a.name] = recipe_a, [recipe_b.name] = recipe_b}
}

local Util = require("scripts.common_util")
local signal, specified = Util.resolve_recipe_input({type = "recipe", name = "widget-b"}, "assembler")
assert(signal.type == "item" and signal.name == "widget" and specified == recipe_b)
assert(Util.find_recipe_ignoring_research(signal, "assembler") == recipe_a)
assert(Util.find_recipe_ignoring_research(signal, "assembler", specified) == recipe_b)
local force = {index = 1, recipes = {['widget-a'] = {enabled = true}, ['widget-b'] = {enabled = true}}}
assert(Util.find_recipe(force, signal, "assembler", specified) == recipe_b)
assert(Util.resolve_recipe_input({type = "recipe", name = "widget-b"}, "furnace") == nil)

defines = {wire_connector_id = {combinator_input_red = 1, combinator_input_green = 2}}
game = {tick = 0}
local recipe_entry = {{signal = {type = "recipe", name = "widget-b"}, count = 3}}
local inventory_entries = {{signal = {type = "item", name = "copper", quality = "normal"}, count = 10}}
local entity = {
  force = force,
  get_signals = function(connector_id)
    return connector_id == defines.wire_connector_id.combinator_input_green and recipe_entry or {}
  end
}

local RecipeQuery = require("scripts.modes.recipe_query")
local queried = RecipeQuery.calculate({entity = entity, config = {
  production_machine = "assembler", multiple_recipe_support = false
}})
assert(queried["item:copper:normal"].count == 1 and queried["item:iron:normal"] == nil)

local ProductionOrder = require("scripts.modes.production_order")
entity.get_signals = function(connector_id)
  return connector_id == defines.wire_connector_id.combinator_input_green and recipe_entry or inventory_entries
end
local produced = ProductionOrder.calculate({entity = entity, config = {
  production_machine = "assembler", remember_order = false, production_timeout = 0,
  additional_production_rate = 0, material_demand_rate = 1, material_retention_rate = 1,
  output_mode = "all", cache_grid_number = 0
}})
assert(produced["item:widget:normal"].count == 3)
assert(produced["item:copper:normal"].count == 3 and produced["item:iron:normal"] == nil)

entity.get_signals = function(connector_id)
  return connector_id == defines.wire_connector_id.combinator_input_green and recipe_entry or {}
end
local SupermarketOrder = require("scripts.modes.supermarket_order")
local expanded = SupermarketOrder.calculate({entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "all", sequential_production = false,
  recurise_depth = 1
}})
assert(expanded["item:copper:normal"].count == 3 and expanded["item:iron:normal"] == nil)

print("recipe input compatibility: ok")
