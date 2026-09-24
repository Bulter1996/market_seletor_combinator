package.path = "./?.lua;" .. package.path

local product = {type = "item", name = "widget", amount = 1}
local byproduct = {type = "item", name = "slag", amount = 1}
local recipe_a = {
  name = "widget-a", categories = {"crafting"}, ingredients = {{type = "item", name = "iron", amount = 1}},
  products = {product}, main_product = product
}
local recipe_b = {
  name = "widget-b", categories = {"crafting"}, ingredients = {{type = "item", name = "copper", amount = 1}},
  products = {product, byproduct}, main_product = product
}
local recipe_b_clone = {
  name = "widget-b-clone", categories = {"crafting"},
  ingredients = {{type = "item", name = "copper", amount = 1}},
  products = {product, byproduct}, main_product = product
}
local recipe_other_machine = {
  name = "widget-smelting", categories = {"smelting"},
  ingredients = {{type = "item", name = "stone", amount = 1}}, products = {product}, main_product = product
}
prototypes = {
  entity = {assembler = {crafting_categories = {crafting = true}}},
  recipe = {[recipe_a.name] = recipe_a, [recipe_b.name] = recipe_b,
    [recipe_b_clone.name] = recipe_b_clone, [recipe_other_machine.name] = recipe_other_machine},
  item = {
    iron = {stack_size = 2, has_flag = function() return false end},
    copper = {stack_size = 2, has_flag = function() return false end}
  }
}

local Util = require("scripts.common_util")
local signal, specified = Util.resolve_recipe_input({type = "recipe", name = "widget-b"}, "assembler")
assert(signal.type == "item" and signal.name == "widget" and specified == recipe_b)
local query_signal, query_recipe = Util.resolve_recipe_input({type = "recipe", name = "widget-b"})
assert(query_signal.type == "item" and query_signal.name == "widget" and query_recipe == recipe_b)
assert(Util.find_recipe_ignoring_research(signal, "assembler") == recipe_a)
assert(Util.find_recipe_ignoring_research(signal, "assembler", specified) == recipe_b)
local force = {index = 1, recipes = {['widget-a'] = {enabled = true}, ['widget-b'] = {enabled = true},
  ['widget-b-clone'] = {enabled = true}, ['widget-smelting'] = {enabled = true}}}
assert(Util.find_recipe(force, signal, "assembler", specified) == recipe_b)
assert(Util.resolve_recipe_input({type = "recipe", name = "widget-b"}, "furnace") == nil)

local OrderTarget = require("scripts.order_target")
assert(#OrderTarget.available_recipes(
  force, "assembler", {type = "item", name = "widget", quality = "normal"}) == 2)
local manual_config = {order_targets = {['item:widget:normal'] = {
  recipe = "widget-b", products = {
    {type = "item", name = "widget", quality = "normal"},
    {type = "item", name = "slag", quality = "normal"}
  }
}}}
local manual_target = OrderTarget.resolve(
  force, "assembler", {type = "item", name = "widget", quality = "normal"}, manual_config)
assert(manual_target.recipe == recipe_b and manual_target.manual_recipe == "widget-b")
assert(#manual_target.products == 2)
local multi_status = OrderTarget.inventory_status(manual_target.products,
  {['item:widget:normal'] = 3, ['item:slag:normal'] = 2}, 3)
assert(not multi_status.satisfied and multi_status.remaining == 1)
local invalid_config = {order_targets = {['item:widget:normal'] = {
  recipe = 'removed-recipe', products = {{type = 'item', name = 'removed-product'}}
}}}
local fallback_target = OrderTarget.resolve(
  force, 'assembler', {type = 'item', name = 'widget', quality = 'normal'}, invalid_config)
assert(fallback_target.recipe == recipe_a and invalid_config.order_targets['item:widget:normal'].recipe == nil)
assert(fallback_target.products[1].name == 'widget')

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

-- “所有”配方查询在缓存为 0 时保持完整需求；有限缓存按配方需求比例缩放完整批次。
recipe_entry = {
  {signal = {type = "recipe", name = "widget-a"}, count = 2},
  {signal = {type = "recipe", name = "widget-b"}, count = 3}
}
local query_config = {
  production_machine = "assembler", multiple_recipe_support = true,
  recipe_query_cache_grid_number = 0
}
local full_query = RecipeQuery.calculate({entity = entity, config = query_config})
assert(full_query["item:iron:normal"].count == 2)
assert(full_query["item:copper:normal"].count == 3)
query_config.recipe_query_cache_grid_number = 2
local limited_query = RecipeQuery.calculate({entity = entity, config = query_config})
assert(limited_query["item:iron:normal"].count == 2)
assert(limited_query["item:copper:normal"].count == 2)
query_config.recipe_query_cache_grid_number = 1
assert(next(RecipeQuery.calculate({entity = entity, config = query_config})) == nil)

-- 同一条多产物配方只制造满足所有目标所需的最大次数，不按每个产物重复累计原料。
recipe_entry = {
  {signal = {type = "item", name = "widget", quality = "normal"}, count = 3},
  {signal = {type = "item", name = "slag", quality = "normal"}, count = 5}
}
local shared_recipe_config = {production_machine = "assembler", multiple_recipe_support = true,
  recipe_query_cache_grid_number = 0, order_targets = {
    ["item:widget:normal"] = {recipe = "widget-b", products = {}},
    ["item:slag:normal"] = {recipe = "widget-b", products = {}}
  }}
local shared_recipe_query = RecipeQuery.calculate({entity = entity, config = shared_recipe_config})
assert(shared_recipe_query["item:copper:normal"].count == 5)

-- 未解锁配方仍可供查询模式使用，但订单模式必须保留选择并等待科技解锁。
force.recipes["widget-b"].enabled = false
local locked_target = OrderTarget.resolve(force, "assembler",
  {type = "item", name = "widget", quality = "normal"}, manual_config)
assert(locked_target.recipe == nil and locked_target.locked_recipe == "widget-b")
assert(manual_config.order_targets["item:widget:normal"].recipe == "widget-b")
local locked_choices = OrderTarget.available_recipes(
  force, "assembler", {type = "item", name = "widget", quality = "normal"})
assert(#locked_choices == 2 and locked_choices[2].name == "widget-b-clone")
local preferred_locked_choices = OrderTarget.available_recipes(
  force, "assembler", {type = "item", name = "widget", quality = "normal"}, "widget-b")
assert(#preferred_locked_choices == 2 and preferred_locked_choices[2].name == "widget-b")
recipe_entry = {{signal = {type = "item", name = "widget", quality = "normal"}, count = 3}}
local locked_query = RecipeQuery.calculate({entity = entity, config = {
  production_machine = "assembler", multiple_recipe_support = false,
  order_targets = manual_config.order_targets
}})
assert(locked_query["item:copper:normal"].count == 1 and locked_query["item:iron:normal"] == nil)
force.recipes["widget-b"].enabled = true

-- 单个配方内部仍按完整制造批次缩放，不会用剩余格数破坏 3:1 的原料比例。
local ratio_recipe = {ingredients = {
  {type = "item", name = "iron", amount = 3},
  {type = "item", name = "copper", amount = 1}
}}
local ratio_limited = Util.limit_recipe_materials_by_cache({{recipe = ratio_recipe, crafts = 10}}, 3)
assert(ratio_limited["item:iron:normal"].count == 3)
assert(ratio_limited["item:copper:normal"].count == 1)

recipe_entry = {{signal = {type = "recipe", name = "widget-b"}, count = 3}}

local ProductionOrder = require("scripts.modes.production_order")
entity.get_signals = function(connector_id)
  return connector_id == defines.wire_connector_id.combinator_input_green and recipe_entry or inventory_entries
end
force.recipes["widget-b"].enabled = false
local locked_recipe_record = {entity = entity, config = {
  production_machine = "assembler", remember_order = false, production_timeout = 0,
  additional_production_rate = 0, material_demand_rate = 1, material_retention_rate = 1,
  output_mode = "all", cache_grid_number = 0
}}
assert(next(ProductionOrder.calculate(locked_recipe_record)) == nil)
assert(locked_recipe_record.production_order_diagnostics["recipe:widget-b"].kind == "recipe_locked")
force.recipes["widget-b"].enabled = true
local produced = ProductionOrder.calculate({entity = entity, config = {
  production_machine = "assembler", remember_order = false, production_timeout = 0,
  additional_production_rate = 0, material_demand_rate = 1, material_retention_rate = 1,
  output_mode = "all", cache_grid_number = 0
}})
assert(produced["recipe:widget-b"].count == 3 and produced["item:widget:normal"] == nil)
assert(produced["item:copper:normal"].count == 3 and produced["item:iron:normal"] == nil)
local separated = ProductionOrder.calculate({entity = entity, config = {
  production_machine = "assembler", remember_order = false, production_timeout = 0,
  additional_production_rate = 0, material_demand_rate = 1, material_retention_rate = 0,
  output_mode = "all_separate_signal", cache_grid_number = 1
}})
assert(separated.separated and separated.red["item:copper:normal"].count == 2)
assert(separated.green["recipe:widget-b"].count == 3)

-- 普通物品订单可以固定另一条合法配方；主产品已达标时，所选副产物不足仍继续输出。
recipe_entry = {{signal = {type = "item", name = "widget", quality = "normal"}, count = 3}}
inventory_entries = {
  {signal = {type = "item", name = "widget", quality = "normal"}, count = 3},
  {signal = {type = "item", name = "slag", quality = "normal"}, count = 1},
  {signal = {type = "item", name = "copper", quality = "normal"}, count = 10}
}
local manual_record = {entity = entity, config = {
  production_machine = "assembler", order_targets = manual_config.order_targets,
  remember_order = false, production_timeout = 0, additional_production_rate = 0,
  material_demand_rate = 1, material_retention_rate = 0, output_mode = "only_item"
}}
force.recipes["widget-b"].enabled = false
local locked_output = ProductionOrder.calculate(manual_record)
assert(next(locked_output) == nil)
assert(manual_record.production_order_diagnostics["item:widget:normal"].kind == "recipe_locked")
force.recipes["widget-b"].enabled = true
local manual_output = ProductionOrder.calculate(manual_record)
assert(manual_output['recipe:widget-b'].count == 2 and manual_output['item:widget:normal'] == nil)
assert(#manual_record.production_order_diagnostics['item:widget:normal'].products == 2)
inventory_entries[2].count = 3
assert(next(ProductionOrder.calculate(manual_record)) == nil)

recipe_entry = {{signal = {type = "recipe", name = "widget-b"}, count = 3}}
local supermarket_inventory = {}
entity.get_signals = function(connector_id)
  return connector_id == defines.wire_connector_id.combinator_input_green and recipe_entry
    or supermarket_inventory
end
local SupermarketOrder = require("scripts.modes.supermarket_order")
force.recipes["widget-b"].enabled = false
local locked_supermarket = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "all", sequential_production = false,
  recurise_depth = 1, inventory_validation = "none"
}}
assert(next(SupermarketOrder.calculate(locked_supermarket)) == nil)
assert(locked_supermarket.supermarket_order_diagnostics["recipe:widget-b"].kind == "recipe_locked")
force.recipes["widget-b"].enabled = true
local expanded = SupermarketOrder.calculate({entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "all", sequential_production = false,
  recurise_depth = 1, inventory_validation = "none"
}})
assert(expanded["item:copper:normal"] == nil and expanded["item:iron:normal"] == nil)
assert(expanded["recipe:widget-b"].count == 3 and expanded["item:widget:normal"] == nil)

supermarket_inventory = {{signal = {type = "item", name = "copper", quality = "normal"}, count = 10}}
local supermarket_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recurise_depth = 0, recursion_timeout = 0, inventory_validation = "none"
}}
local supermarket_recipe = SupermarketOrder.calculate(supermarket_record)
assert(supermarket_recipe["recipe:widget-b"].count == 3)
assert(supermarket_recipe["item:widget:normal"] == nil)
assert(supermarket_record.detail_outputs["recipe:widget-b"].count == 3)
local non_recursive_strict = SupermarketOrder.calculate({entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recurise_depth = 0, recursion_timeout = 0, inventory_validation = "inventory"
}})
assert(non_recursive_strict["recipe:widget-b"].count == 3)
assert(non_recursive_strict["item:copper:normal"] == nil and non_recursive_strict["item:iron:normal"] == nil)
local recipe_diagnostic = supermarket_record.supermarket_order_diagnostics["recipe:widget-b"]
assert(recipe_diagnostic.kind == "active_output")
assert(recipe_diagnostic.order.signal.type == "recipe"
  and recipe_diagnostic.order.signal.name == "widget-b" and recipe_diagnostic.order.count == 3)
assert(recipe_diagnostic.product.signal.type == "item"
  and recipe_diagnostic.product.signal.name == "widget" and recipe_diagnostic.product.target == 3)
assert(recipe_diagnostic.stage.signal.type == "item"
  and recipe_diagnostic.stage.signal.name == "widget" and recipe_diagnostic.stage.output_count == 3)

recipe_entry = {{signal = {type = "item", name = "widget", quality = "normal"}, count = 3}}
supermarket_inventory = {
  {signal = {type = "item", name = "widget", quality = "normal"}, count = 3},
  {signal = {type = "item", name = "slag", quality = "normal"}, count = 1},
  {signal = {type = "item", name = "copper", quality = "normal"}, count = 10}
}
local multi_supermarket = {entity = entity, config = {
  production_machine = "assembler", order_targets = manual_config.order_targets,
  recursion_output_mode = "all", sequential_production = false, recurise_depth = 1,
  recursion_additional_production_rate = 0, inventory_validation = "none"
}}
local manual_supermarket_output = SupermarketOrder.calculate(multi_supermarket)
assert(manual_supermarket_output['recipe:widget-b'].count == 2
  and manual_supermarket_output['item:widget:normal'] == nil)
supermarket_inventory[2].count = 3
assert(next(SupermarketOrder.calculate(multi_supermarket)) == nil)

print("recipe input compatibility: ok")
