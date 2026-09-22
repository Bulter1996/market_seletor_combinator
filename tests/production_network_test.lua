package.path = "./?.lua;" .. package.path
local Config = require("scripts.config")
local Util = require("scripts.common_util")
local Network = require("scripts.production_network")
local Mode = require("scripts.modes.supermarket_order")
local Policy = require("scripts.recipe_policy")
storage = {combinators = {}}
game = {tick = 0}
defines = {wire_connector_id = {combinator_input_red = 1, combinator_input_green = 2}}
local function recipe(name, product, ingredient, category)
  local p = {type = "item", name = product, amount = 1}
  return {name = name, categories = {category}, main_product = p, products = {p},
    ingredients = {{type = "item", name = ingredient, amount = 1}}}
end
local recipes = {gear = recipe("gear", "gear", "plate", "craft"),
  plate = recipe("plate", "plate", "ore", "smelt"),
  alternative = recipe("alternative", "plate", "scrap", "smelt"),
  widget = recipe("widget", "widget", "fuel", "smelt"),
  machine = recipe("machine", "machine", "frame", "craft"),
  frame = recipe("frame", "frame", "plate", "smelt")}
prototypes = {recipe = recipes, entity = {assembler = {crafting_categories = {craft = true}},
  furnace = {crafting_categories = {smelt = true}}}}
local force = {index = 1, recipes = {}}
for name in pairs(recipes) do force.recipes[name] = {enabled = true} end
local surface = {index = 1, name = "nauvis"}
local function sig(name) return {type = "item", name = name, quality = "normal"} end
local function key(name) return "item:" .. name .. ":normal" end
local function entries(values)
  local result = {}
  for name, count in pairs(values) do result[#result + 1] = {signal = sig(name), count = count} end
  return result
end
local function record(unit, machine, red, green, pool)
  local r = {red = red, green = green, config = Config.normalize{
    production_machine = machine, inventory_validation = "inventory", network_publish = true,
    network_accept = true, recursion_additional_production_rate = 0,
    recursion_material_demand_rate = 1, recursion_material_retention_rate = 0}}
  r.entity = {valid = true, unit_number = unit, force = force, surface = surface,
    get_signals = function(id) return entries(id == 1 and r.red or r.green) end,
    get_circuit_network = function() return {network_id = pool or unit} end}
  storage.combinators[unit] = r
  return r
end
local function tick()
  game.tick = game.tick + 30
  Network.prepare(storage.combinators)
  for unit = 1, 10 do
    local r = storage.combinators[unit]
    if r then r.output = Mode.calculate(r) end
  end
end
local a = record(1, "assembler", {}, {gear = 10})
local b = record(2, "furnace", {ore = 100}, {})
tick(); tick()
local task = Network.tasks(1)[1]
assert(task and task.signal.name == "plate" and task.owner == 2, "machine-capable owner")
assert(b.output["recipe:plate"], "assigned demand executes real recipe")
assert(#Network.tasks(1) == 1, "one request per source/material")

-- 网络节点运行期间，本地订单恢复不抢占；完成当前节点后返回本地。
b.green = {widget = 5}; b.red.fuel = 50
tick()
assert(b.output["recipe:plate"], "local recovery must not preempt active network node")
b.red.plate = 10
tick()
assert(task.status == "waiting_transport", "producer red inventory completes production")
assert(b.output["recipe:widget"], "local order wins next scheduling boundary")
b.red.plate = 0
tick()
assert(task.status == "waiting_transport" and task.owner == 2, "in-transit stock never duplicates task")
a.green.gear = 20
tick(); tick()
local pending_delta = Network.tasks(1)
assert(#pending_delta == 2 and task.quantity == 10 and task.status == "waiting_transport",
  "larger source order must not inflate finished transport promise")
assert(pending_delta[2].quantity == 10 and pending_delta[2].status ~= "waiting_transport")
assert(pending_delta[2].reserved_before == 0, "departed goods do not inflate the new production target")
a.green.gear = 10
a.red.plate = 10
tick(); tick()
assert(#Network.tasks(1) == 0, "requester physical stock releases commitment")

-- 同池库存不能重复交付；本地目标受保护。
storage.bmsc_production_network = nil
storage.combinators = {}
a = record(1, "assembler", {}, {gear = 10})
b = record(2, "furnace", {plate = 10, ore = 100}, {plate = 10})
tick(); tick()
task = Network.tasks(1)[1]
assert(task.status ~= "waiting_transport", "local ten plates cannot also supply remote ten")
b.red.plate = 20
tick()
assert(task.status == "waiting_transport")

-- 跨星球要求双方许可，势力始终隔离。
storage.bmsc_production_network = nil
a.network_requests = nil; b.network_requests = nil
a.red = {}; b.green = {}; b.red = {ore = 100}
b.entity.surface = {index = 2, name = "vulcanus"}
tick(); tick()
task = Network.tasks(1)[1]
assert(not task.owner)
a.config.network_export = true
tick(); assert(not task.owner)
b.config.network_import = true
tick(); assert(task.owner == 2)

-- 高优先级候选恢复不抢占当前配方，保留边界相等即失效。
b.config.recipe_policies = {[key("plate")] = {
  {recipe = "plate", priority = 10, demand = 10, retention = 2},
  {recipe = "alternative", priority = 0, demand = 5, retention = 1}}}
b.selected_recursion_output = "recipe:alternative"
assert(Policy.choose(b, sig("plate"), {[key("ore")] = 100, [key("scrap")] = 2}).name == "alternative")
assert(Policy.choose(b, sig("plate"), {[key("ore")] = 100, [key("scrap")] = 1}).name == "plate")
local copy = Config.normalize(b.config)
copy.recipe_policies[key("plate")][1].priority = 99
assert(b.config.recipe_policies[key("plate")][1].priority == 10, "blueprint config is deep-copied")
-- 已有基础数量也必须完成承接方的额外生产目标。
storage.bmsc_production_network = nil; storage.combinators = {}
a = record(1, "assembler", {}, {machine = 10})
b = record(2, "furnace", {ore = 100}, {})
tick(); tick()
task = Network.tasks(1)[1]
assert(task.signal.name == "frame" and b.output["recipe:plate"], "network task starts its intermediate material")
b.green.widget = 5; b.red.fuel = 100
tick()
assert(b.output["recipe:plate"], "local order does not interrupt intermediate material")
b.red.plate = 11
tick()
assert(b.output["recipe:widget"], "local order wins after intermediate finishes, before whole task finishes")
assert(task.owner == 2 and task.status ~= "waiting_transport", "parent task remains assigned")

-- 已有基础数量也必须完成承接方的额外生产目标。
storage.bmsc_production_network = nil; storage.combinators = {}
a = record(1, "assembler", {}, {gear = 10})
b = record(2, "furnace", {plate = 10, ore = 100}, {})
b.config.recursion_additional_production_rate = 1
tick(); tick()
task = Network.tasks(1)[1]
assert(task.status == "producing" and b.output["recipe:plate"].count == 10, "extra production must not stall at base target")
b.red.plate = 20; tick()
assert(task.status == "waiting_transport")

-- 两个生产者读取同一个红线网络，十个实物最多交付一个十个的任务。
storage.bmsc_production_network = nil; storage.combinators = {}
a = record(1, "assembler", {}, {gear = 10})
b = record(2, "furnace", {plate = 10, ore = 100}, {}, 100)
local c = record(3, "assembler", {}, {gear = 10})
local d = record(4, "furnace", b.red, {}, 100)
tick(); tick()
local waiting = 0
for _, t in ipairs(Network.tasks(1)) do if t.status == "waiting_transport" then waiting = waiting + 1 end end
assert(waiting == 1, "shared red pool must commit existing stock exactly once")
b.red.plate = 20; tick()
waiting = 0
for _, t in ipairs(Network.tasks(1)) do if t.status == "waiting_transport" then waiting = waiting + 1 end end
assert(waiting == 2)
local first = Network.tasks(1)[1]
local old_owner = first.owner
storage.combinators[old_owner].entity.valid = false
tick()
assert(first.owner == old_owner and first.status == "waiting_transport", "demolishing producer must not duplicate in-transit delivery")
assert(not Network.release(first.key, 2), "other force cannot release task")
assert(Network.release(first.key, 1))

-- 已分配但尚未完成的生产者失效后，唯一任务可重新分配。
storage.bmsc_production_network = nil; storage.combinators = {}
a = record(1, "assembler", {}, {gear = 10})
b = record(2, "furnace", {ore = 100}, {})
d = record(4, "furnace", {ore = 100}, {})
tick(); tick()
task = Network.tasks(1)[1]
assert(task.owner == 2)
b.entity.valid = false
tick(); assert(task.owner == 4)

-- 子任务继续跨机器发布，依赖再次遇到祖先材料则阻断。
storage.bmsc_production_network = nil; storage.combinators = {}
recipes.ore = recipe("ore", "ore", "gear", "mine")
force.recipes.ore = {enabled = true}
prototypes.entity.miner = {crafting_categories = {mine = true}}
a = record(1, "assembler", {}, {gear = 10})
b = record(2, "furnace", {}, {})
c = record(3, "miner", {}, {})
for _ = 1, 5 do tick() end
local found_cycle, found_child = false, false
for _, t in ipairs(Network.tasks(1)) do
  if t.signal.name == "ore" and t.parent then found_child = true end
  if t.blocked == "cycle" then found_cycle = true; assert(not t.owner) end
end
assert(found_child and found_cycle, "multi-hop needs preserve ancestor lineage")

-- 网络发布必须与本机递归使用同一深度边界，不能把边界以下的终端材料另行发布。
storage.bmsc_production_network = nil; storage.combinators = {}
a = record(1, "assembler", {}, {gear = 10})
a.config.recurise_depth = 1
tick(); tick()
assert(#Network.tasks(1) == 0, "network publishing must not traverse beyond the configured recursion depth")
print("production network: ok")
