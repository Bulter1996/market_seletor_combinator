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
local recipe_z = recipe("make-z", "z", "a")
local circuit = {type = "item", name = "circuit", amount = 1}
local recipe_circuit = {name = "make-circuit", categories = {"crafting"}, main_product = circuit,
  products = {circuit}, ingredients = {
    {type = "item", name = "wire", amount = 3}, {type = "item", name = "plate", amount = 1}
  }}
local wire = {type = "item", name = "wire", amount = 1}
local recipe_wire = {name = "make-wire", categories = {"crafting"}, main_product = wire,
  products = {wire}, ingredients = {{type = "item", name = "copper-plate", amount = 1}}}
local remote_tower = {type = "item", name = "remote-tower", amount = 1}
local recipe_remote_tower = {name = "make-remote-tower", categories = {"crafting"}, main_product = remote_tower,
  products = {remote_tower}, ingredients = {{type = "item", name = "iron", amount = 1}}}
local factory_2 = {type = "item", name = "factory-2", amount = 1}
local recipe_factory_2 = {name = "make-factory-2", categories = {"crafting"}, main_product = factory_2,
  products = {factory_2}, ingredients = {
    {type = "item", name = "steel", amount = 250},
    {type = "item", name = "remote-tower", amount = 50},
    {type = "item", name = "stone-brick", amount = 1000}
  }}
prototypes = {
  entity = {assembler = {crafting_categories = {crafting = true}}},
  recipe = {[recipe_a.name] = recipe_a, [recipe_b.name] = recipe_b,
    [recipe_z.name] = recipe_z, [recipe_circuit.name] = recipe_circuit,
    [recipe_wire.name] = recipe_wire, [recipe_remote_tower.name] = recipe_remote_tower,
    [recipe_factory_2.name] = recipe_factory_2}
}
defines = {wire_connector_id = {combinator_input_red = 1, combinator_input_green = 2}}
game = {tick = 0}

local inventory = {{signal = {type = "item", name = "a", quality = "normal"}, count = 10}}
local orders = {
  {signal = {type = "item", name = "a", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "b", quality = "normal"}, count = 10}
}
local force = {index = 1, recipes = {['make-a'] = {enabled = true}, ['make-b'] = {enabled = true},
  ['make-z'] = {enabled = true}, ['make-circuit'] = {enabled = true},
  ['make-wire'] = {enabled = true}, ['make-remote-tower'] = {enabled = true},
  ['make-factory-2'] = {enabled = true}}}
local entity = {force = force, get_signals = function(connector_id)
  return connector_id == defines.wire_connector_id.combinator_input_green and orders or inventory
end}
local record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single",
  sequential_production = true, recurise_depth = 10, recursion_timeout = 0
}}

local Mode = require("scripts.modes.supermarket_order")
Mode.calculate(record)
assert(record.supermarket_sequence_index == 2)
assert(record.supermarket_order_diagnostics["item:a:normal"].kind == "supermarket_completed")

inventory = {}
Mode.calculate(record)
assert(record.supermarket_sequence_index == 2)
assert(record.supermarket_order_diagnostics["item:a:normal"].kind == "waiting_for_order")

-- 最后一项完成后立即绕回第一项重新检查；第一项库存已下降时会重新进入制作队列。
inventory = {{signal = {type = "item", name = "b", quality = "normal"}, count = 10}}
local cycled = Mode.calculate(record)
assert(record.supermarket_sequence_index == 1)
assert(cycled["item:iron:normal"].count == 10)

-- 右键后移当前订单会直接选择下一项，即使配置了原料等待时间也不会保留旧输出。
orders = {
  {signal = {type = "item", name = "a", quality = "normal"}, count = 20},
  {signal = {type = "item", name = "b", quality = "normal"}, count = 20}
}
inventory = {
  {signal = {type = "item", name = "a", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "iron", quality = "normal"}, count = 10}
}
local deferred_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single",
  sequential_production = true, recurise_depth = 10, recursion_timeout = 0,
  recursion_material_wait_time = 10
}}
assert(Mode.calculate(deferred_record)["item:a:normal"].count == 10)
assert(Mode.defer_current_order(deferred_record, "item:a:normal"))
local deferred = Mode.calculate(deferred_record)
assert(deferred_record.recursion_order_key == "item:b:normal")
assert(deferred["item:b:normal"].count == 20)
assert(deferred_record.recursion_material_wait_tick == nil)

-- 左键双击的 GUI 分发最终调用此入口：只有等待项可被立即提升。
assert(not Mode.prioritize_waiting_order(deferred_record, "item:b:normal"))
assert(Mode.prioritize_waiting_order(deferred_record, "item:a:normal"))
local prioritized = Mode.calculate(deferred_record)
assert(deferred_record.recursion_order_key == "item:a:normal")
assert(prioritized["item:a:normal"].count == 10)
assert(deferred_record.recursion_material_wait_tick == nil)

-- 非顺序 single 也把各根订单映射到自己的可生产候选，支持同样的后移和置顶交互。
orders = {
  {signal = {type = "item", name = "a", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "circuit", quality = "normal"}, count = 10}
}
inventory = {
  {signal = {type = "item", name = "iron", quality = "normal"}, count = 1},
  {signal = {type = "item", name = "wire", quality = "normal"}, count = 31},
  {signal = {type = "item", name = "plate", quality = "normal"}, count = 11}
}
local nonsequential_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single",
  sequential_production = false, recurise_depth = 10, recursion_timeout = 0,
  recursion_material_wait_time = 10, recursion_material_demand_rate = 0,
  recursion_material_retention_rate = 0
}}
assert(Mode.calculate(nonsequential_record)["item:a:normal"].count == 10)
assert(nonsequential_record.recursion_order_key == "item:a:normal")
assert(nonsequential_record.supermarket_order_diagnostics["item:circuit:normal"].kind
  == "waiting_for_order")
assert(Mode.prioritize_waiting_order(nonsequential_record, "item:circuit:normal"))
assert(Mode.calculate(nonsequential_record)["item:circuit:normal"].count == 10)
assert(nonsequential_record.recursion_material_wait_tick == nil)
assert(Mode.defer_current_order(nonsequential_record, "item:circuit:normal"))
assert(Mode.calculate(nonsequential_record)["item:a:normal"].count == 10)
assert(nonsequential_record.recursion_material_wait_tick == nil)

orders = {
  {signal = {type = "item", name = "a", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "b", quality = "normal"}, count = 10}
}
inventory = {{signal = {type = "item", name = "a", quality = "normal"}, count = 10}}
Mode.calculate(record)
inventory = {}
orders[2].count = 11
local changed = Mode.calculate(record)
assert(record.supermarket_sequence_index == 1)
assert(changed["item:iron:normal"].count == 10)

-- 超时轮换时若只有当前一个候选，必须解除锁定并立即按材料需求倍率重新判断。
orders = {{signal = {type = "item", name = "b", quality = "normal"}, count = 10}}
inventory = {
  {signal = {type = "item", name = "a", quality = "normal"}, count = 11},
  {signal = {type = "item", name = "iron", quality = "normal"}, count = 11}
}
game.tick = 0
local single_timeout_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recurise_depth = 10, recursion_timeout = 1, recursion_timeout_monitor_item_changes = false,
  recursion_additional_production_rate = 0, recursion_material_demand_rate = 10,
  recursion_material_retention_rate = 1
}}
assert(Mode.calculate(single_timeout_record)["item:b:normal"].count == 10)
assert(single_timeout_record.selected_recursion_output == "item:b:normal")
inventory[1].count = 5
game.tick = 60
local timeout_rechecked = Mode.calculate(single_timeout_record)
assert(timeout_rechecked["item:a:normal"].count == 6)
assert(single_timeout_record.selected_recursion_output == "item:a:normal")
local timeout_stage = single_timeout_record.supermarket_order_diagnostics["item:b:normal"].stage
assert(timeout_stage.signal.name == "a" and timeout_stage.gate_kind == "start")
assert(timeout_stage.ingredients[1].start_threshold == 10)
assert(timeout_stage.ingredients[1].threshold_comparator == ">")

-- “所有”输出包含产品以及每一层分别抵扣库存后的全部材料缺口，基础材料优先排序。
inventory = {{signal = {type = "item", name = "wire", quality = "normal"}, count = 10}}
orders = {{signal = {type = "item", name = "circuit", quality = "normal"}, count = 10}}
local all_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "all", sequential_production = false,
  recurise_depth = 10, recursion_timeout = 0
}}
local all_outputs = Mode.calculate(all_record)
assert(all_record.detail_outputs == nil)
assert(all_outputs["item:circuit:normal"].count == 10)
assert(all_outputs["item:wire:normal"].count == 20)
assert(all_outputs["item:plate:normal"].count == 10)
assert(all_outputs["item:copper-plate:normal"].count == 30)
local all_diagnostic = all_record.supermarket_order_diagnostics["item:circuit:normal"]
assert(all_diagnostic.order.signal.name == "circuit" and all_diagnostic.order.count == 10)
assert(all_diagnostic.product.signal.name == "circuit")
assert(all_diagnostic.product.target == 10 and all_diagnostic.product.stock == 0
  and all_diagnostic.product.remaining == 10)
assert(#all_diagnostic.outputs == 4)
assert(all_diagnostic.outputs[1].signal.name == "copper-plate"
  and all_diagnostic.outputs[1].count == 30 and all_diagnostic.outputs[1].depth == 3)
assert(all_diagnostic.outputs[4].signal.name == "circuit"
  and all_diagnostic.outputs[4].count == 10 and all_diagnostic.outputs[4].depth == 1)
local ordered = require("scripts.common_util").sorted_outputs(all_outputs)
assert(ordered[1].key == "item:copper-plate:normal")
assert(ordered[4].key == "item:circuit:normal")

-- 多个订单的全量输出虽然会在线路端合并，悬浮信息仍必须保留各自的生产链归属。
orders = {
  {signal = {type = "item", name = "b", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "z", quality = "normal"}, count = 5}
}
inventory = {}
local multi_all_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "all", sequential_production = false,
  recurise_depth = 10, recursion_timeout = 0
}}
local multi_all_outputs = Mode.calculate(multi_all_record)
assert(multi_all_outputs["item:a:normal"].count == 15)
assert(multi_all_outputs["item:iron:normal"].count == 15)
local b_outputs = multi_all_record.supermarket_order_diagnostics["item:b:normal"].outputs
local z_outputs = multi_all_record.supermarket_order_diagnostics["item:z:normal"].outputs
assert(b_outputs[1].signal.name == "iron" and b_outputs[1].count == 10 and b_outputs[1].depth == 3)
assert(b_outputs[2].signal.name == "a" and b_outputs[2].count == 10 and b_outputs[2].depth == 2)
assert(b_outputs[3].signal.name == "b" and b_outputs[3].count == 10 and b_outputs[3].depth == 1)
assert(z_outputs[1].signal.name == "iron" and z_outputs[1].count == 5 and z_outputs[1].depth == 3)
assert(z_outputs[2].signal.name == "a" and z_outputs[2].count == 5 and z_outputs[2].depth == 2)
assert(z_outputs[3].signal.name == "z" and z_outputs[3].count == 5 and z_outputs[3].depth == 1)

-- 当前层缺少的可制造中间原料会再展开一层，展示应生产数量及其下一层真实缺口。
orders = {{signal = {type = "item", name = "circuit", quality = "normal"}, count = 10}}
inventory = {
  {signal = {type = "item", name = "wire", quality = "normal"}, count = 31},
  {signal = {type = "item", name = "plate", quality = "normal"}, count = 11},
  {signal = {type = "item", name = "copper-plate", quality = "normal"}, count = 10}
}
local detail_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recurise_depth = 10, recursion_timeout = 0, recursion_additional_production_rate = 2,
  recursion_material_demand_rate = 10, recursion_material_retention_rate = 5
}}
assert(Mode.calculate(detail_record)["item:circuit:normal"].count == 30)
local detail_stage = detail_record.supermarket_order_diagnostics["item:circuit:normal"].stage
local detail_ingredients = {}
for _, ingredient in ipairs(detail_stage.ingredients) do
  detail_ingredients[ingredient.signal.name] = ingredient
end
local wire_detail = detail_ingredients.wire
assert(wire_detail.required == 90 and wire_detail.stock == 31 and wire_detail.shortage == 59)
assert(wire_detail.production.signal.name == "wire" and wire_detail.production.count == 59)
assert(wire_detail.production.ingredients[1].signal.name == "copper-plate")
assert(wire_detail.production.ingredients[1].required == 59)
assert(wire_detail.production.ingredients[1].stock == 10)
assert(wire_detail.production.ingredients[1].shortage == 49)
assert(detail_ingredients.plate.production == nil)

orders = {{signal = {type = "item", name = "circuit", quality = "normal"}, count = 10}}
inventory = {{signal = {type = "item", name = "wire", quality = "normal"}, count = 10}}
all_record.config.recursion_additional_production_rate = 1
local expanded_outputs = Mode.calculate(all_record)
assert(expanded_outputs["item:circuit:normal"].count == 20)
assert(expanded_outputs["item:wire:normal"].count == 50)
assert(expanded_outputs["item:plate:normal"].count == 20)
assert(expanded_outputs["item:copper-plate:normal"].count == 60)

-- 每一层递归产品都使用扩展目标和材料迟滞。电路板 10、额外倍率 2、材料倍率 10
-- 时，铜丝整单目标 90 已超过单份启动线 30，因此目标仍为 90；铜板超过 10 才启动。
orders = {{signal = {type = "item", name = "circuit", quality = "normal"}, count = 10}}
inventory = {
  {signal = {type = "item", name = "wire", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "plate", quality = "normal"}, count = 11},
  {signal = {type = "item", name = "copper-plate", quality = "normal"}, count = 10}
}
local hysteresis_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recurise_depth = 10, recursion_timeout = 0, recursion_additional_production_rate = 2,
  recursion_material_demand_rate = 10, recursion_material_retention_rate = 5
}}
local below_start = Mode.calculate(hysteresis_record)
assert(below_start["item:copper-plate:normal"].count == 80)

inventory[3].count = 11
local started = Mode.calculate(hysteresis_record)
assert(started["item:wire:normal"].count == 81)
assert(hysteresis_record.supermarket_order_diagnostics["item:circuit:normal"].kind == "supermarket_expanding")
local active_diagnostic = hysteresis_record.supermarket_order_diagnostics["item:circuit:normal"]
assert(active_diagnostic.order.count == 10)
assert(active_diagnostic.product.target == 30 and active_diagnostic.product.stock == 0
  and active_diagnostic.product.remaining == 30)
assert(active_diagnostic.stage.signal.name == "wire" and active_diagnostic.stage.level == 2)
assert(active_diagnostic.stage.target == 91 and active_diagnostic.stage.stock == 10
  and active_diagnostic.stage.output_count == 81)
assert(active_diagnostic.stage.gate_kind == "start" and active_diagnostic.stage.start_ready == true)
assert(#active_diagnostic.stage.ingredients == 1)
local wire_ingredient = active_diagnostic.stage.ingredients[1]
assert(wire_ingredient.signal.name == "copper-plate" and wire_ingredient.required == 81)
assert(wire_ingredient.stock == 11 and wire_ingredient.shortage == 70)
assert(wire_ingredient.start_threshold == 10 and wire_ingredient.threshold_comparator == ">"
  and wire_ingredient.start_ready == true)

inventory[3].count = 6
local retained = Mode.calculate(hysteresis_record)
assert(retained["item:wire:normal"].count == 81)
local retained_stage = hysteresis_record.supermarket_order_diagnostics["item:circuit:normal"].stage
assert(retained_stage.gate_kind == "retention" and retained_stage.start_ready == true)
assert(retained_stage.ingredients[1].start_threshold == 5
  and retained_stage.ingredients[1].threshold_comparator == ">")

-- 已启动的铜丝在等于扩展目标 90 时仍继续输出，达到 91 才停止。
inventory[1].count = 90
assert(Mode.calculate(hysteresis_record)["item:wire:normal"].count == 1)
inventory[1].count = 91
assert(Mode.calculate(hysteresis_record)["item:circuit:normal"].count == 30)

inventory[1].count = 10
inventory[3].count = 4
local released = Mode.calculate(hysteresis_record)
assert(released["item:copper-plate:normal"].count == 86)

-- 电路板达到 30 后退出，跌回 15 时仍不重新启动。
inventory = {
  {signal = {type = "item", name = "wire", quality = "normal"}, count = 91},
  {signal = {type = "item", name = "plate", quality = "normal"}, count = 11},
  {signal = {type = "item", name = "copper-plate", quality = "normal"}, count = 90}
}
local circuit_stage = Mode.calculate(hysteresis_record)
assert(circuit_stage["item:circuit:normal"].count == 30)
inventory[1].count = 16
inventory[2].count = 11
assert(Mode.calculate(hysteresis_record)["item:circuit:normal"].count == 30)
inventory[1].count = 14
assert(Mode.calculate(hysteresis_record)["item:wire:normal"].count == 77)
inventory[1].count = 91
inventory[2].count = 11
assert(Mode.calculate(hysteresis_record)["item:circuit:normal"].count == 30)
inventory[#inventory + 1] = {signal = {type = "item", name = "circuit", quality = "normal"}, count = 30}
assert(next(Mode.calculate(hysteresis_record)) == nil)
inventory[#inventory].count = 15
assert(next(Mode.calculate(hysteresis_record)) == nil)

-- 原料不足是统一取消等待的一种触发原因；恢复库存会取消计时，
-- 再次短缺时重新计时，等待期满后才从当前制作物切换到铜丝。
inventory = {
  {signal = {type = "item", name = "wire", quality = "normal"}, count = 90},
  {signal = {type = "item", name = "plate", quality = "normal"}, count = 11},
  {signal = {type = "item", name = "copper-plate", quality = "normal"}, count = 90}
}
game.tick = 0
local material_wait_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recurise_depth = 10, recursion_timeout = 0, recursion_material_wait_time = 2,
  recursion_additional_production_rate = 2, recursion_material_demand_rate = 10,
  recursion_material_retention_rate = 5
}}
assert(Mode.calculate(material_wait_record)["item:circuit:normal"].count == 30)
inventory[1].count = 14
game.tick = 30
assert(Mode.calculate(material_wait_record)["item:circuit:normal"].count == 30)
assert(material_wait_record.recursion_material_wait_tick == 30)
inventory[1].count = 90
game.tick = 60
assert(Mode.calculate(material_wait_record)["item:circuit:normal"].count == 30)
assert(material_wait_record.recursion_material_wait_tick == nil)
inventory[1].count = 14
game.tick = 90
assert(Mode.calculate(material_wait_record)["item:circuit:normal"].count == 30)
game.tick = 209
assert(Mode.calculate(material_wait_record)["item:circuit:normal"].count == 30)
game.tick = 210
assert(Mode.calculate(material_wait_record)["item:wire:normal"].count == 77)
assert(material_wait_record.recursion_material_wait_tick == nil)

-- 即使订单输入直接消失，也必须先保持上一轮已经实际输出的信号，到期后才清空。
orders = {}
game.tick = 211
assert(Mode.calculate(material_wait_record)["item:wire:normal"].count == 77)
game.tick = 330
assert(Mode.calculate(material_wait_record)["item:wire:normal"].count == 77)
game.tick = 331
assert(next(Mode.calculate(material_wait_record)) == nil)
assert(material_wait_record.recursion_material_wait_tick == nil)

-- 原料不足不能跳过有缺口的订单：顺序模式立即进入当前订单的最深原料，
-- 非顺序模式则汇总全部订单并从最深层开始输出。
orders = {
  {signal = {type = "item", name = "circuit", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "stone-brick", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "z", quality = "normal"}, count = 10}
}
inventory = {{signal = {type = "item", name = "a", quality = "normal"}, count = 11}}
game.tick = 0
local strict_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = true,
  recursion_strict_validation = true, recurise_depth = 10, recursion_timeout = 0,
  recursion_additional_production_rate = 0, recursion_material_demand_rate = 10,
  recursion_material_retention_rate = 1
}}
local skipped = Mode.calculate(strict_record)
assert(skipped["item:copper-plate:normal"].count == 30)
assert(skipped["item:z:normal"] == nil)
assert(skipped["item:stone-brick:normal"] == nil)
assert(strict_record.detail_outputs["item:copper-plate:normal"].count == 30)
local strict_diagnostic = strict_record.supermarket_order_diagnostics["item:circuit:normal"]
assert(strict_diagnostic.kind == "supermarket_expanding")

local strict_all_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "all", sequential_production = false,
  recursion_strict_validation = true, recurise_depth = 10, recursion_additional_production_rate = 0
}}
local strict_all = Mode.calculate(strict_all_record)
assert(strict_all["item:circuit:normal"].count == 10)
assert(strict_all["item:wire:normal"].count == 30)
assert(strict_all["item:copper-plate:normal"].count == 30)
assert(strict_all["item:plate:normal"].count == 10)
assert(strict_all["item:stone-brick:normal"] == nil)
assert(strict_all["item:z:normal"].count == 10)
assert(strict_all_record.detail_outputs == nil)
assert(strict_all_record.supermarket_order_diagnostics["item:stone-brick:normal"].kind == "no_recipe")

local strict_copper = {signal = {type = "item", name = "copper-plate", quality = "normal"}, count = 10}
local strict_plate = {signal = {type = "item", name = "plate", quality = "normal"}, count = 10}
inventory[#inventory + 1] = strict_copper
inventory[#inventory + 1] = strict_plate
game.tick = 15
assert(Mode.calculate(strict_record)["item:copper-plate:normal"].count == 20)

strict_copper.count = 11
strict_plate.count = 11
game.tick = 30
local recovered = Mode.calculate(strict_record)
assert(recovered["item:wire:normal"].count == 31)
assert(strict_record.detail_outputs["item:wire:normal"].count == 31)
assert(strict_record.supermarket_order_diagnostics["item:circuit:normal"].kind == "supermarket_expanding")

-- 不可制造原料超过单份启动阈值即可放行上层生产，但不能把它相对整单目标的缺口输出。
orders = {{signal = {type = "item", name = "circuit", quality = "normal"}, count = 100}}
inventory = {
  {signal = {type = "item", name = "plate", quality = "normal"}, count = 11},
  {signal = {type = "item", name = "copper-plate", quality = "normal"}, count = 11}
}
local strict_partial_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recursion_strict_validation = true, recurise_depth = 10, recursion_timeout = 0,
  recursion_additional_production_rate = 0, recursion_material_demand_rate = 10,
  recursion_material_retention_rate = 1
}}
local strict_partial = Mode.calculate(strict_partial_record)
assert(strict_partial["item:wire:normal"] == nil)
assert(strict_partial["item:plate:normal"].count == 89)
assert(strict_partial["item:copper-plate:normal"] == nil)
strict_partial_record.config.recursion_output_mode = "all"
local strict_partial_all = Mode.calculate(strict_partial_record)
assert(strict_partial_all["item:circuit:normal"].count == 100)
assert(strict_partial_all["item:wire:normal"].count == 300)
assert(strict_partial_all["item:plate:normal"].count == 89)
assert(strict_partial_all["item:copper-plate:normal"].count == 289)

-- all 的精确目标不能污染 single 的严格大于停止边界；切换后 300 仍需输出到 301。
local output_mode_cache_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "all", sequential_production = false,
  recursion_strict_validation = true, recurise_depth = 10, recursion_timeout = 0,
  recursion_additional_production_rate = 0, recursion_material_demand_rate = 10,
  recursion_material_retention_rate = 1
}}
assert(Mode.calculate(output_mode_cache_record)["item:wire:normal"].count == 300)
output_mode_cache_record.config.recursion_output_mode = "single"
Mode.reset(output_mode_cache_record)
assert(Mode.calculate(output_mode_cache_record)["item:plate:normal"].count == 89)

-- 小订单的整单扩展目标可能低于父级材料启动线：电路板 3 需要铜丝 9，而单份启动线
-- 是 3 × 10 = 30，因此只按单份用量兜底，铜丝保持到严格大于 3 × (1 + 10) = 33。
orders = {{signal = {type = "item", name = "circuit", quality = "normal"}, count = 3}}
inventory = {
  {signal = {type = "item", name = "plate", quality = "normal"}, count = 11},
  {signal = {type = "item", name = "copper-plate", quality = "normal"}, count = 11}
}
local strict_small_order_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recursion_strict_validation = true, recurise_depth = 10, recursion_timeout = 0,
  recursion_additional_production_rate = 0, recursion_material_demand_rate = 10,
  recursion_material_retention_rate = 1
}}
assert(Mode.calculate(strict_small_order_record)["item:wire:normal"].count == 34)
local small_order_stage = strict_small_order_record.supermarket_order_diagnostics["item:circuit:normal"].stage
assert(small_order_stage.signal.name == "wire" and small_order_stage.target == 34
  and small_order_stage.output_count == 34)
assert(small_order_stage.ingredients[1].signal.name == "copper-plate"
  and small_order_stage.ingredients[1].required == 34
  and small_order_stage.ingredients[1].stock == 11
  and small_order_stage.ingredients[1].shortage == 23)
local small_order_wire = {signal = {type = "item", name = "wire", quality = "normal"}, count = 33}
inventory[#inventory + 1] = small_order_wire
assert(Mode.calculate(strict_small_order_record)["item:wire:normal"].count == 1)
small_order_wire.count = 34
assert(Mode.calculate(strict_small_order_record)["item:circuit:normal"].count == 3)

-- 小订单的直接中间原料低于材料门槛时必须下移到该原料，而不是留下“处理中”但无输出。
-- 厂房 2 ×5、额外倍率 1 时需要远程塔 500；库存 387，应补 114 才能严格超过门槛。
orders = {{signal = {type = "item", name = "factory-2", quality = "normal"}, count = 5}}
inventory = {
  {signal = {type = "item", name = "steel", quality = "normal"}, count = 2501},
  {signal = {type = "item", name = "remote-tower", quality = "normal"}, count = 387},
  {signal = {type = "item", name = "stone-brick", quality = "normal"}, count = 10001},
  {signal = {type = "item", name = "iron", quality = "normal"}, count = 11}
}
local strict_large_ingredient_record = {entity = entity, config = {
  mode = "supermarket_order",
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recursion_strict_validation = true, recurise_depth = 10, recursion_timeout = 0,
  recursion_material_wait_time = 2,
  recursion_additional_production_rate = 1, recursion_material_demand_rate = 10,
  recursion_material_retention_rate = 1
}}
local strict_large_ingredient = Mode.calculate(strict_large_ingredient_record)
assert(strict_large_ingredient["item:remote-tower:normal"].count == 114)
assert(strict_large_ingredient_record.supermarket_order_diagnostics["item:factory-2:normal"].stage.signal.name
  == "remote-tower")
-- control.lua 会在每轮计算前重置非当前模式；生产订单重置不能清掉超市订单用于等待的上一轮输出。
require("scripts.modes.production_order").reset(strict_large_ingredient_record)
inventory[4].count = 0
game.tick = 30
local strict_wait_held = Mode.calculate(strict_large_ingredient_record)
assert(strict_wait_held["item:remote-tower:normal"].count == 114)
assert(strict_large_ingredient_record.supermarket_order_diagnostics["item:factory-2:normal"].kind
  == "supermarket_expanding")
game.tick = 149
assert(Mode.calculate(strict_large_ingredient_record)["item:remote-tower:normal"].count == 114)
game.tick = 150
assert(Mode.calculate(strict_large_ingredient_record)["item:iron:normal"].count == 500)
assert(strict_large_ingredient_record.recursion_material_wait_tick == nil)

-- 严格校验遵守生产机器的地表限制；例如只允许高磁场的机器不能在低磁场地表接单。
prototypes.entity["surface-limited-assembler"] = {
  crafting_categories = {crafting = true},
  surface_conditions = {{property = "magnetic-field", min = 90}}
}
local original_surface = entity.surface
entity.surface = {get_property = function(property)
  return property == "magnetic-field" and 0 or 100
end}
orders = {{signal = {type = "item", name = "circuit", quality = "normal"}, count = 10}}
inventory = {
  {signal = {type = "item", name = "wire", quality = "normal"}, count = 100},
  {signal = {type = "item", name = "plate", quality = "normal"}, count = 100}
}
local surface_limited_record = {entity = entity, config = {
  production_machine = "surface-limited-assembler", recursion_output_mode = "single",
  sequential_production = false, recursion_strict_validation = true, recurise_depth = 10,
  recursion_timeout = 0, recursion_additional_production_rate = 0,
  recursion_material_demand_rate = 1, recursion_material_retention_rate = 0
}}
assert(next(Mode.calculate(surface_limited_record)) == nil)
assert(surface_limited_record.supermarket_order_diagnostics["item:circuit:normal"].kind
  == "surface_conditions")
entity.surface = original_surface

-- 严格开关属于输出缓存条件；开启后不能继续复用关闭时的终端原料输出。
orders = {{signal = {type = "item", name = "stone-brick", quality = "normal"}, count = 10}}
inventory = {}
local strict_toggle_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "all", sequential_production = false,
  recursion_strict_validation = false, recurise_depth = 10, recursion_additional_production_rate = 0
}}
assert(Mode.calculate(strict_toggle_record)["item:stone-brick:normal"].count == 10)
strict_toggle_record.config.recursion_strict_validation = true
Mode.reset(strict_toggle_record)
assert(Mode.calculate(strict_toggle_record)["item:stone-brick:normal"] == nil)
assert(strict_toggle_record.supermarket_order_diagnostics["item:stone-brick:normal"].kind == "no_recipe")

-- “不校验”只读取产品完成量，原料默认满足并直接输出根订单；超时后顺序切到下一单。
orders = {
  {signal = {type = "item", name = "a", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "b", quality = "normal"}, count = 10}
}
inventory = {}
game.tick = 0
local unchecked_record = {entity = entity, config = {
  production_machine = "assembler", inventory_validation = "none",
  recursion_output_mode = "single", sequential_production = true,
  recurise_depth = 10, recursion_timeout = 1, recursion_timeout_monitor_item_changes = false,
  recursion_additional_production_rate = 0
}}
local unchecked = Mode.calculate(unchecked_record)
assert(unchecked["item:a:normal"].count == 10 and unchecked["item:iron:normal"] == nil)
game.tick = 60
local unchecked_next = Mode.calculate(unchecked_record)
assert(unchecked_next["item:b:normal"].count == 10)

-- 自动关联库存：新订单等待首份快照；共享区与负红线相加；已输出订单连续三份缺料
-- 后才进入原料等待时间，查询空窗本身保持旧输出。
local InventoryQuery = require("scripts.modes.inventory_query")
local original_available = InventoryQuery.is_available
local original_shared = InventoryQuery.get_shared_inventory
InventoryQuery.is_available = function() return true end
local linked_snapshot, linked_generation
InventoryQuery.get_shared_inventory = function()
  return linked_snapshot, linked_generation
end
orders = {{signal = {type = "item", name = "a", quality = "normal"}, count = 10}}
inventory = {{signal = {type = "item", name = "iron", quality = "normal"}, count = -1}}
game.tick = 0
local linked_record = {entity = entity, config = {
  production_machine = "assembler", inventory_validation = "linked",
  recursion_output_mode = "single", sequential_production = true,
  recurise_depth = 10, recursion_timeout = 0, recursion_additional_production_rate = 0,
  recursion_material_demand_rate = 10, recursion_material_retention_rate = 1,
  recursion_material_wait_time = 1
}}
assert(next(Mode.calculate(linked_record)) == nil)
assert(linked_record.supermarket_order_diagnostics["item:a:normal"].kind == "inventory_query_pending")
linked_snapshot = {['item:a:normal'] = 0, ['item:iron:normal'] = 12}
linked_generation = 1
assert(Mode.calculate(linked_record)["item:a:normal"].count == 10)
linked_snapshot = nil
game.tick = 30
assert(Mode.calculate(linked_record)["item:a:normal"].count == 10)
assert(linked_record.supermarket_order_diagnostics["item:a:normal"].kind == "inventory_query_pending")
linked_snapshot = {['item:a:normal'] = 0, ['item:iron:normal'] = 10}
for generation = 2, 4 do
  linked_generation = generation
  game.tick = generation * 120
  assert(Mode.calculate(linked_record)["item:a:normal"].count == 10)
end
game.tick = 541
assert(Mode.calculate(linked_record)["item:a:normal"].count == 10)
assert(linked_record.supermarket_order_diagnostics["item:a:normal"].kind == "active_output")
InventoryQuery.is_available = original_available
InventoryQuery.get_shared_inventory = original_shared

print("supermarket sequential progress: ok")
