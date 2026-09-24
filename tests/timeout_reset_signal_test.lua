package.path = "./?.lua;" .. package.path

local product = {type = "item", name = "product", amount = 1}
local recipe = {
  name = "make-product", categories = {"crafting"}, main_product = product, products = {product},
  ingredients = {{type = "item", name = "iron", amount = 1}}
}
local batch_product = {type = "item", name = "batch-product", amount = 2}
local batch_recipe = {
  name = "make-batch-product", categories = {"crafting"}, main_product = batch_product,
  products = {batch_product}, ingredients = {
    {type = "item", name = "iron", amount = 3},
    {type = "item", name = "copper", amount = 2}
  }
}
local iron_product = {type = "item", name = "iron", amount = 1}
local iron_recipe = {
  name = "make-iron", categories = {"crafting"}, main_product = iron_product,
  products = {iron_product}, ingredients = {{type = "item", name = "ore", amount = 2}}
}
prototypes = {
  entity = {assembler = {crafting_categories = {crafting = true}}},
  recipe = {[recipe.name] = recipe, [batch_recipe.name] = batch_recipe, [iron_recipe.name] = iron_recipe}
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
assert(normalized.production_timeout_monitor_item_changes == true)
assert(normalized.recursion_timeout_monitor_item_changes == false)
assert(normalized.recursion_additional_production_rate == 2)
assert((Config.normalize{schema_revision = 17, recursion_additional_production_rate = 1})
  .recursion_additional_production_rate == 2)
assert(normalized.recursion_material_wait_time == 0)
assert(normalized.inventory_validation == Config.inventory_validation.none)
assert(normalized.swap_loop == false)
assert(normalized.swap_conditions[1].first.signal.name == "signal-R")
assert(normalized.swap_conditions[1].second.signal.type == "item")
assert(normalized.swap_conditions[1].first.signal ~= reset)
local target_source = {['item:product:normal'] = {recipe = 'make-product', products = {
  {type = 'item', name = 'product', quality = 'normal'},
  {type = 'item', name = 'product', quality = 'normal'}
}}}
local normalized_targets = Config.normalize{order_targets = target_source}.order_targets
assert(normalized_targets['item:product:normal'].recipe == 'make-product')
assert(#normalized_targets['item:product:normal'].products == 1)
target_source['item:product:normal'].products[1].name = 'changed'
assert(normalized_targets['item:product:normal'].products[1].name == 'product')
local copied = Config.normalize{schema_revision = normalized.schema_revision,
  mode = Config.mode.swap_order, swap_timeout = 12, swap_loop = true,
  recipe_query_cache_grid_number = 7,
  recursion_material_wait_time = 7,
  recursion_strict_validation = true,
  production_timeout_monitor_item_changes = false,
  recursion_timeout_monitor_item_changes = false,
  recursion_additional_production_rate = 2, recursion_material_demand_rate = 6,
  recursion_material_retention_rate = 2,
  production_timeout_conditions = normalized.production_timeout_conditions,
  recursion_timeout_conditions = normalized.recursion_timeout_conditions,
  swap_conditions = normalized.swap_conditions}
assert(copied.mode == Config.mode.swap_order and copied.swap_timeout == 12)
assert(copied.swap_loop == true)
assert(copied.recipe_query_cache_grid_number == 7)
assert(copied.recursion_material_wait_time == 7)
assert(copied.inventory_validation == Config.inventory_validation.inventory)
assert(copied.production_timeout_monitor_item_changes == false)
assert(copied.recursion_timeout_monitor_item_changes == false)
assert(copied.recursion_additional_production_rate == 2)
assert(copied.recursion_material_demand_rate == 6 and copied.recursion_material_retention_rate == 2)
assert(copied.production_timeout_conditions[1].first.signal.name == "signal-R")
assert(copied.recursion_timeout_conditions[1].first.signal.name == "iron")
assert(copied.swap_conditions[1].second.signal.name == "iron")
assert(Config.normalize{inventory_validation = Config.inventory_validation.linked}.inventory_validation
  == Config.inventory_validation.linked)
local green = {
  {signal = {type = "item", name = "product", quality = "normal"}, count = 10},
  {signal = reset, count = 1}
}
local reset_conditions = {{first = {signal = reset, red = false, green = true}, comparator = ">",
  second = {constant = 0}}}
local force = {index = 1, recipes = {
  ['make-product'] = {enabled = true}, ['make-batch-product'] = {enabled = true}
}}
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
local production_diagnostic = production_record.production_order_diagnostics["item:product:normal"]
assert(production_diagnostic.order.signal.name == "product" and production_diagnostic.order.count == 10)
assert(production_diagnostic.product.signal.name == "product")
assert(production_diagnostic.product.target == 10 and production_diagnostic.product.stock == 0)
assert(production_diagnostic.product.remaining == 10)
assert(production_diagnostic.stage.signal.name == "product" and production_diagnostic.stage.level == 1)
assert(production_diagnostic.stage.output_count == 10 and production_diagnostic.stage.start_ready)
assert(production_diagnostic.stage.gate_kind == "start")
assert(production_diagnostic.stage.ingredients[1].required == 10)
assert(production_diagnostic.stage.ingredients[1].stock == 100)
assert(production_diagnostic.stage.ingredients[1].shortage == 0)
assert(production_diagnostic.stage.ingredients[1].start_threshold == 1)
assert(production_diagnostic.stage.ingredients[1].threshold_comparator == ">")
game.tick = 120
ProductionOrder.calculate(production_record)
assert(production_record.production_order_changed_tick == 120)
production_diagnostic = production_record.production_order_diagnostics["item:product:normal"]
assert(production_diagnostic.stage.gate_kind == "retention")
assert(production_diagnostic.stage.ingredients[1].start_threshold == 0)
assert(production_diagnostic.stage.ingredients[1].threshold_comparator == ">=")
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
  recurise_depth = 10, recursion_timeout = 1, recursion_timeout_conditions = reset_conditions
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
  recurise_depth = 10, recursion_timeout = 0, recursion_timeout_conditions = reset_conditions
}}
green[2].count = 1
game.tick = 0
SupermarketOrder.calculate(supermarket_record)
game.tick = 120
SupermarketOrder.calculate(supermarket_record)
assert(supermarket_record.recursion_output_changed_tick == 0)

-- 数量监控默认开启；关闭后输出数量变化只更新基准，不重置计时，线路条件仍可重置。
green[2].count = 0
red = {{signal = {type = "item", name = "iron", quality = "normal"}, count = 100}}
game.tick = 0
local monitored_production = {entity = entity, config = {
  production_machine = "assembler", remember_order = false, production_timeout = 1,
  production_timeout_monitor_item_changes = true, production_timeout_conditions = reset_conditions,
  additional_production_rate = 0, material_demand_rate = 1, material_retention_rate = 0,
  output_mode = "all", cache_grid_number = 0
}}
ProductionOrder.calculate(monitored_production)
red[#red + 1] = {signal = {type = "item", name = "product", quality = "normal"}, count = 1}
game.tick = 30
ProductionOrder.calculate(monitored_production)
assert(monitored_production.production_order_changed_tick == 30)

red = {{signal = {type = "item", name = "iron", quality = "normal"}, count = 100}}
game.tick = 0
local unmonitored_production = {entity = entity, config = {
  production_machine = "assembler", remember_order = false, production_timeout = 1,
  production_timeout_monitor_item_changes = false, production_timeout_conditions = reset_conditions,
  additional_production_rate = 0, material_demand_rate = 1, material_retention_rate = 0,
  output_mode = "all", cache_grid_number = 0
}}
ProductionOrder.calculate(unmonitored_production)
red[#red + 1] = {signal = {type = "item", name = "product", quality = "normal"}, count = 1}
game.tick = 30
ProductionOrder.calculate(unmonitored_production)
assert(unmonitored_production.production_order_changed_tick == 0)
green[2].count = 1
game.tick = 40
ProductionOrder.calculate(unmonitored_production)
assert(unmonitored_production.production_order_changed_tick == 40)

-- 生产订单超时后移到持久队尾；下一个订单完成后继续第三项，不会立刻回到超时项。
force.recipes["make-iron"] = {enabled = true}
local queue_green = {
  {signal = {type = "item", name = "batch-product", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "iron", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "product", quality = "normal"}, count = 10}
}
local queue_inventory = {
  {signal = {type = "item", name = "iron", quality = "normal"}, count = 4},
  {signal = {type = "item", name = "copper", quality = "normal"}, count = 3},
  {signal = {type = "item", name = "ore", quality = "normal"}, count = 3}
}
local queue_entity = {force = force, get_signals = function(connector_id)
  return connector_id == defines.wire_connector_id.combinator_input_green
    and queue_green or queue_inventory
end}
local queue_record = {entity = queue_entity, config = {
  production_machine = "assembler", remember_order = false, production_timeout = 1,
  production_timeout_monitor_item_changes = false, production_timeout_conditions = reset_conditions,
  additional_production_rate = 0, material_demand_rate = 1, material_retention_rate = 0,
  output_mode = "all", cache_grid_number = 0
}}
game.tick = 0
ProductionOrder.calculate(queue_record)
assert(queue_record.selected_request == "item:batch-product:normal")
game.tick = 60
ProductionOrder.calculate(queue_record)
assert(queue_record.selected_request == "item:iron:normal")
assert(table.concat(queue_record.production_order_queue, ",")
  == "item:iron:normal,item:product:normal,item:batch-product:normal")
queue_inventory[1].count = 10
game.tick = 61
ProductionOrder.calculate(queue_record)
assert(queue_record.selected_request == "item:product:normal")
queue_inventory[#queue_inventory + 1] = {
  signal = {type = "item", name = "product", quality = "normal"}, count = 10}
game.tick = 62
ProductionOrder.calculate(queue_record)
assert(queue_record.selected_request == "item:batch-product:normal")
force.recipes["make-iron"] = nil

green[2].count = 0
red = {}
game.tick = 0
local unmonitored_supermarket = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recurise_depth = 10, recursion_timeout = 1, recursion_timeout_monitor_item_changes = false,
  recursion_timeout_conditions = reset_conditions
}}
SupermarketOrder.calculate(unmonitored_supermarket)
red = {{signal = {type = "item", name = "iron", quality = "normal"}, count = 1}}
game.tick = 30
SupermarketOrder.calculate(unmonitored_supermarket)
assert(unmonitored_supermarket.recursion_output_count == 9)
assert(unmonitored_supermarket.recursion_output_changed_tick == 0)

red = {}
game.tick = 0
local monitored_supermarket = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recurise_depth = 10, recursion_timeout = 1, recursion_timeout_monitor_item_changes = true,
  recursion_timeout_conditions = reset_conditions
}}
SupermarketOrder.calculate(monitored_supermarket)
red = {{signal = {type = "item", name = "iron", quality = "normal"}, count = 1}}
game.tick = 30
SupermarketOrder.calculate(monitored_supermarket)
assert(monitored_supermarket.recursion_output_changed_tick == 30)

-- 配方订单在“仅原料”下仍保留原配方、解析产品及完整制造缺口，且不会误称产品已输出。
green = {{signal = {type = "recipe", name = "make-batch-product"}, count = 3}}
force.recipes['make-iron'] = {enabled = true}
red = {
  {signal = {type = "item", name = "batch-product", quality = "normal"}, count = 1},
  {signal = {type = "item", name = "iron", quality = "normal"}, count = 4},
  {signal = {type = "item", name = "copper", quality = "normal"}, count = 3}
}
game.tick = 0
local material_only_record = {entity = entity, config = {
  production_machine = "assembler", remember_order = false, production_timeout = 0,
  additional_production_rate = 0.5, material_demand_rate = 1, material_retention_rate = 0.5,
  output_mode = "only_material", cache_grid_number = 0
}}
local material_only_outputs = ProductionOrder.calculate(material_only_record)
assert(material_only_outputs["recipe:make-batch-product"] == nil)
assert(material_only_outputs["item:batch-product:normal"] == nil)
assert(material_only_outputs["item:iron:normal"].count == 6)
assert(material_only_outputs["item:copper:normal"].count == 4)
local recipe_diagnostic = material_only_record.production_order_diagnostics["recipe:make-batch-product"]
assert(recipe_diagnostic.kind == "active_output")
assert(recipe_diagnostic.order.signal.type == "recipe")
assert(recipe_diagnostic.order.signal.name == "make-batch-product" and recipe_diagnostic.order.count == 3)
assert(recipe_diagnostic.product.signal.name == "batch-product")
assert(recipe_diagnostic.product.target == 5 and recipe_diagnostic.product.stock == 1)
assert(recipe_diagnostic.product.remaining == 4)
assert(recipe_diagnostic.stage.signal.type == "item")
assert(recipe_diagnostic.stage.signal.name == "batch-product")
assert(recipe_diagnostic.stage.output_count == 4 and recipe_diagnostic.stage.product_output == false)
assert(recipe_diagnostic.stage.material_output == true and recipe_diagnostic.stage.start_ready == true)
local ingredient_diagnostics = {}
for _, ingredient in ipairs(recipe_diagnostic.stage.ingredients) do
  ingredient_diagnostics[ingredient.signal.name] = ingredient
end
assert(ingredient_diagnostics.iron.required == 6 and ingredient_diagnostics.iron.stock == 4)
assert(ingredient_diagnostics.iron.shortage == 2 and ingredient_diagnostics.iron.start_threshold == 3)
assert(ingredient_diagnostics.iron.threshold_comparator == ">" and ingredient_diagnostics.iron.start_ready)
assert(ingredient_diagnostics.iron.production.signal.name == "iron")
assert(ingredient_diagnostics.iron.production.count == 2)
assert(ingredient_diagnostics.iron.production.ingredients[1].signal.name == "ore")
assert(ingredient_diagnostics.iron.production.ingredients[1].required == 4)
assert(ingredient_diagnostics.iron.production.ingredients[1].stock == 0)
assert(ingredient_diagnostics.iron.production.ingredients[1].shortage == 4)
assert(ingredient_diagnostics.copper.required == 4 and ingredient_diagnostics.copper.stock == 3)
assert(ingredient_diagnostics.copper.shortage == 1 and ingredient_diagnostics.copper.start_threshold == 2)
assert(ingredient_diagnostics.copper.production == nil)

-- 大型配方的详细提示也必须低于 Factorio 本地化字符串最大 20 层限制。
local Gui = require("scripts.gui")
local deep_diagnostic = {
  kind = "active_output",
  order = {signal = {type = "item", name = "product"}, count = 100},
  product = {signal = {type = "item", name = "product"}, target = 100, stock = 0, remaining = 100},
  outputs = {},
  stage = {
    signal = {type = "item", name = "product"}, level = 2, target = 100, stock = 0,
    output_count = 100, ingredients = {}, start_ready = true
  }
}
for index = 1, 64 do
  local signal = {type = "item", name = "material-" .. index}
  deep_diagnostic.outputs[index] = {signal = signal, count = index, depth = index}
  deep_diagnostic.stage.ingredients[index] = {
    signal = signal, required = index, stock = 0, shortage = index,
    start_threshold = 1, threshold_comparator = ">",
    production = {
      signal = signal, count = index,
      ingredients = {{signal = {type = "item", name = "ore-" .. index},
        required = index * 2, stock = 0, shortage = index * 2}}
    }
  }
end
local function localised_depth(value)
  if type(value) ~= "table" then return 0 end
  local depth = 0
  for _, child in pairs(value) do depth = math.max(depth, localised_depth(child)) end
  return depth + 1
end
assert(localised_depth(Gui.production_diagnostic_tooltip(deep_diagnostic)) <= 20)
local surface_tooltip = Gui.production_diagnostic_tooltip{kind = "surface_conditions"}
assert(surface_tooltip[1] == "bmsc.production-no-output-reason")
assert(surface_tooltip[2][1] == "bmsc.supermarket-reason-surface-conditions")

-- 切换订单只锁定前两项；数量变化不重选，重置条件满足时刷新计时起点。
local swap_inputs = {
  {signal = {type = "fluid", name = "water"}, count = 20},
  {signal = {type = "fluid", name = "steam"}, count = 10},
  {signal = {type = "fluid", name = "crude-oil"}, count = 1},
  {signal = reset, count = 0}
}
local swap_entity = {get_signals = function(connector_id)
  return connector_id == defines.wire_connector_id.combinator_input_green and swap_inputs or {}
end}
local SwapOrder = require("scripts.modes.swap_order")
local legacy_swap_record = {}
SwapOrder.restore_state(legacy_swap_record, {
  signature = "legacy", sources = {"fluid:water", "fluid:steam"}, permutation = {2, 1}})
assert(legacy_swap_record.swap_sources == nil and legacy_swap_record.swap_permutation == nil
  and legacy_swap_record.swap_reversed == nil)
local swap_record = {entity = swap_entity, config = {
  swap_output_mode = "fluid", swap_timeout = 1, swap_loop = false,
  swap_conditions = reset_conditions
}}
game.tick = 0
local initial_swap = SwapOrder.calculate(swap_record)
assert(swap_record.swap_sources[1] == "fluid:water" and swap_record.swap_sources[2] == "fluid:steam")
assert(initial_swap.separated == true)
assert(initial_swap.red["fluid:water"].count == 101 and initial_swap.green["fluid:steam"].count == 102)
assert(swap_record.swap_order_diagnostics["fluid:crude-oil"].kind == "swap_discarded"
  and swap_record.swap_order_diagnostics["fluid:crude-oil"].all_colors == true)
local restored_swap_record = {}
SwapOrder.restore_state(restored_swap_record, SwapOrder.save_state(swap_record))
assert(restored_swap_record.swap_sources[1] == "fluid:water"
  and restored_swap_record.swap_sources[2] == "fluid:steam"
  and restored_swap_record.swap_condition_tick == 0)
local discarded_tooltip = Gui.production_diagnostic_tooltip{kind = "swap_discarded"}
assert(discarded_tooltip[2][1] == "bmsc.swap-reason-discarded")

-- 第三项数量升到最高也不替换锁定项，并且数量变化不刷新计时。
swap_inputs[1].count = 5
swap_inputs[3].count = 100
game.tick = 30
local quantity_changed_swap = SwapOrder.calculate(swap_record)
assert(swap_record.swap_condition_tick == 0)
assert(quantity_changed_swap.red["fluid:water"].count == 101
  and quantity_changed_swap.green["fluid:steam"].count == 102)

-- 条件满足时像生产订单一样把计时起点刷新到当前 tick，而不是推进交换。
swap_inputs[4].count = 1
game.tick = 45
SwapOrder.calculate(swap_record)
assert(swap_record.swap_condition_tick == 45 and swap_record.swap_reversed == false)
swap_inputs[4].count = 0
game.tick = 104
SwapOrder.calculate(swap_record)
assert(swap_record.swap_reversed == false)
game.tick = 105
local reversed_swap = SwapOrder.calculate(swap_record)
assert(swap_record.swap_reversed == true)
assert(reversed_swap.red["fluid:steam"].count == 101
  and reversed_swap.green["fluid:water"].count == 102)
game.tick = 165
SwapOrder.calculate(swap_record)
assert(swap_record.swap_reversed == true and swap_record.swap_condition_tick == nil)

-- 主动重新选择会按当前数量锁定新的前两项并恢复初始方向。
SwapOrder.clear(swap_record)
local reselected_swap = SwapOrder.calculate(swap_record)
assert(swap_record.swap_sources[1] == "fluid:crude-oil"
  and swap_record.swap_sources[2] == "fluid:steam" and swap_record.swap_reversed == false)
assert(reselected_swap.red["fluid:crude-oil"].count == 101
  and reselected_swap.green["fluid:steam"].count == 102)

-- 首次数量相同时使用稳定信号 ID 决胜；steam 的 ID 排在 water 前面。
swap_inputs[1].count = 10
swap_inputs[2].count = 10
swap_inputs[3] = nil
local tied_record = {entity = swap_entity, config = {
  swap_output_mode = "fluid", swap_timeout = 0, swap_loop = false,
  swap_conditions = reset_conditions
}}
local tied_swap = SwapOrder.calculate(tied_record)
assert(tied_swap.red["fluid:steam"].count == 101 and tied_swap.green["fluid:water"].count == 102)

-- 只有一个候选时，两条线路都输出第一名编码且完全停止计时。
swap_inputs[2] = nil
local single_swap = SwapOrder.calculate(swap_record)
assert(single_swap.red["fluid:water"].count == 101 and single_swap.green["fluid:water"].count == 101)
assert(swap_record.swap_condition_tick == nil)

-- 开启循环后，每次超时都在两个信号之间往返交换。
swap_inputs[1].count = 20
swap_inputs[2] = {signal = {type = "fluid", name = "steam"}, count = 10}
local looping_swap_record = {entity = swap_entity, config = {
  swap_output_mode = "fluid", swap_timeout = 1, swap_loop = true,
  swap_conditions = reset_conditions
}}
game.tick = 0
SwapOrder.calculate(looping_swap_record)
game.tick = 60
SwapOrder.calculate(looping_swap_record)
assert(looping_swap_record.swap_reversed == true)
game.tick = 120
local looped_swap = SwapOrder.calculate(looping_swap_record)
assert(looping_swap_record.swap_reversed == false)
assert(looped_swap.red["fluid:water"].count == 101 and looped_swap.green["fluid:steam"].count == 102)

print("timeout reset signal: ok")
