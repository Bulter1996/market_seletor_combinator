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
local circuit = {type = "item", name = "circuit", amount = 1}
local recipe_circuit = {name = "make-circuit", categories = {"crafting"}, main_product = circuit,
  products = {circuit}, ingredients = {
    {type = "item", name = "wire", amount = 3}, {type = "item", name = "plate", amount = 1}
  }}
local wire = {type = "item", name = "wire", amount = 1}
local recipe_wire = {name = "make-wire", categories = {"crafting"}, main_product = wire,
  products = {wire}, ingredients = {{type = "item", name = "copper-plate", amount = 1}}}
prototypes = {
  entity = {assembler = {crafting_categories = {crafting = true}}},
  recipe = {[recipe_a.name] = recipe_a, [recipe_b.name] = recipe_b,
    [recipe_circuit.name] = recipe_circuit, [recipe_wire.name] = recipe_wire}
}
defines = {wire_connector_id = {combinator_input_red = 1, combinator_input_green = 2}}
game = {tick = 0}

local inventory = {{signal = {type = "item", name = "a", quality = "normal"}, count = 10}}
local orders = {
  {signal = {type = "item", name = "a", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "b", quality = "normal"}, count = 10}
}
local force = {index = 1, recipes = {['make-a'] = {enabled = true}, ['make-b'] = {enabled = true},
  ['make-circuit'] = {enabled = true}, ['make-wire'] = {enabled = true}}}
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

-- “所有”输出包含产品以及每一层分别抵扣库存后的全部材料缺口，基础材料优先排序。
inventory = {{signal = {type = "item", name = "wire", quality = "normal"}, count = 10}}
orders = {{signal = {type = "item", name = "circuit", quality = "normal"}, count = 10}}
local all_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "all", sequential_production = false,
  recurise_depth = 0, recursion_timeout = 0
}}
local all_outputs = Mode.calculate(all_record)
assert(all_outputs["item:circuit:normal"].count == 10)
assert(all_outputs["item:wire:normal"].count == 20)
assert(all_outputs["item:plate:normal"].count == 10)
assert(all_outputs["item:copper-plate:normal"].count == 30)
local ordered = require("scripts.common_util").sorted_outputs(all_outputs)
assert(ordered[1].key == "item:copper-plate:normal")
assert(ordered[4].key == "item:circuit:normal")
all_record.config.recursion_additional_production_rate = 1
local expanded_outputs = Mode.calculate(all_record)
assert(expanded_outputs["item:circuit:normal"].count == 20)
assert(expanded_outputs["item:wire:normal"].count == 50)
assert(expanded_outputs["item:plate:normal"].count == 20)
assert(expanded_outputs["item:copper-plate:normal"].count == 60)

-- 每一层递归产品都使用基础/扩展目标和材料迟滞。电路板 10、额外倍率 2 时，铜丝
-- 的基础/扩展目标分别为 30/90；铜板超过 10 才启动铜丝，回落到 5 时仍保持。
orders = {{signal = {type = "item", name = "circuit", quality = "normal"}, count = 10}}
inventory = {
  {signal = {type = "item", name = "wire", quality = "normal"}, count = 10},
  {signal = {type = "item", name = "plate", quality = "normal"}, count = 11},
  {signal = {type = "item", name = "copper-plate", quality = "normal"}, count = 10}
}
local hysteresis_record = {entity = entity, config = {
  production_machine = "assembler", recursion_output_mode = "single", sequential_production = false,
  recurise_depth = 0, recursion_timeout = 0, recursion_additional_production_rate = 2,
  recursion_material_demand_rate = 10, recursion_material_retention_rate = 5
}}
local below_start = Mode.calculate(hysteresis_record)
assert(below_start["item:copper-plate:normal"].count == 80)

inventory[3].count = 11
local started = Mode.calculate(hysteresis_record)
assert(started["item:wire:normal"].count == 80)
assert(hysteresis_record.supermarket_order_diagnostics["item:circuit:normal"].kind == "supermarket_expanding")

inventory[3].count = 5
local retained = Mode.calculate(hysteresis_record)
assert(retained["item:wire:normal"].count == 80)

inventory[3].count = 4
local released = Mode.calculate(hysteresis_record)
assert(released["item:copper-plate:normal"].count == 86)

-- 铜丝达到 90 后进入电路板层；电路板达到 30 后退出，跌回 15 时仍不重新启动。
inventory = {
  {signal = {type = "item", name = "wire", quality = "normal"}, count = 90},
  {signal = {type = "item", name = "plate", quality = "normal"}, count = 11},
  {signal = {type = "item", name = "copper-plate", quality = "normal"}, count = 90}
}
local circuit_stage = Mode.calculate(hysteresis_record)
assert(circuit_stage["item:circuit:normal"].count == 30)
inventory[1].count = 15
inventory[2].count = 11
assert(Mode.calculate(hysteresis_record)["item:circuit:normal"].count == 30)
inventory[1].count = 14
assert(Mode.calculate(hysteresis_record)["item:wire:normal"].count == 76)
inventory[1].count = 90
inventory[2].count = 11
assert(Mode.calculate(hysteresis_record)["item:circuit:normal"].count == 30)
inventory[#inventory + 1] = {signal = {type = "item", name = "circuit", quality = "normal"}, count = 30}
assert(next(Mode.calculate(hysteresis_record)) == nil)
inventory[#inventory].count = 15
assert(next(Mode.calculate(hysteresis_record)) == nil)

print("supermarket sequential progress: ok")
