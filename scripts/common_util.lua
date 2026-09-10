-- 各运算模式共用的 Factorio 运行阶段工具集。
-- 本模块不保存 storage 状态，也不了解 GUI；输入相同参数就得到相同结果，方便复用和测试。

local Util = {}

-- 配方原型在一次 Factorio 运行期间不会变化，因此可以缓存“机器 + 目标信号”的候选列表。
-- 注意这里只缓存原型筛选和排序结果，不缓存某个势力是否已解锁配方；科技状态仍实时检查。
local recipe_candidate_cache = {}

---把品质对象或名称统一为品质原型名。
---@param quality LuaQualityPrototype|string|nil Factorio API 返回的品质。
---@return string name 品质名；缺省为 normal。
function Util.quality_name(quality)
  if type(quality) == "string" then return quality end
  if quality and quality.name then return quality.name end
  return "normal"
end

---判断信号是否能够作为生产配方的产品参与递归。
---@param signal SignalID|nil 待检查信号。
---@return boolean supported 物品或流体信号返回 true，虚拟信号返回 false。
function Util.is_recipe_signal(signal)
  if not (signal and signal.name) then return false end
  local signal_type = signal.type or "item"
  return signal_type == "item" or signal_type == "fluid"
end

---构造规范化的物品或流体 SignalID。
---品质只属于物品；流体不写 quality，避免向 Factorio API 传入无意义字段。
---@param signal_type string|nil `item`、`fluid`，nil 按 `item` 处理。
---@param name string 原型名称。
---@param quality LuaQualityPrototype|string|nil 物品品质；流体会忽略此参数。
---@return SignalID signal 可用于电路输出和 signal_key 的信号。
function Util.make_signal(signal_type, name, quality)
  local normalized_type = signal_type or "item"
  local signal = {type = normalized_type, name = name}
  if normalized_type == "item" then signal.quality = Util.quality_name(quality) end
  return signal
end

---为信号生成稳定且唯一的 table 键。
---@param signal SignalID 信号标识。
---@return string key 物品格式为“item:名称:品质”，流体格式为“fluid:名称”。
function Util.signal_key(signal)
  local signal_type = signal.type or "item"
  if signal_type == "item" then
    return signal_type .. ":" .. signal.name .. ":" .. Util.quality_name(signal.quality)
  end
  return signal_type .. ":" .. signal.name
end

---读取指定连接器的信号，并合并重复信号。
---@param entity LuaEntity 被读取的组合器。
---@param connector_id defines.wire_connector_id 连接器编号。
---@return table totals 按 signal_key 汇总的库存表。
---@return table signals Factorio 返回的原始信号数组。
function Util.read_network(entity, connector_id)
  local totals = {}
  local signals = entity.get_signals(connector_id) or {}
  for _, entry in pairs(signals) do
    if entry.signal and entry.signal.name then
      local key = Util.signal_key(entry.signal)
      totals[key] = (totals[key] or 0) + entry.count
    end
  end
  return totals, signals
end

---判断制造机是否支持配方的任一制造类别。
---@param machine_name string 制造机实体原型名。
---@param recipe LuaRecipePrototype 配方原型。
---@return boolean supported 支持返回 true。
function Util.machine_supports(machine_name, recipe)
  local machine = prototypes.entity[machine_name]
  if not (machine and machine.crafting_categories and recipe) then return false end
  for _, category in pairs(recipe.categories) do
    if machine.crafting_categories[category] then return true end
  end
  return false
end

---取得指定机器能够制造目标信号的稳定候选配方列表。
---候选配方按“主产品、同名配方、配方名称”排序，避免 pairs 顺序造成生产路线抖动。
---@param target_signal SignalID 目标物品或流体信号。
---@param machine_name string 制造机实体原型名。
---@return table candidates 候选项数组，每项的 recipe 字段为配方原型。
local function get_recipe_candidates(target_signal, machine_name)
  if not Util.is_recipe_signal(target_signal) then return nil end
  local target_type = target_signal.type or "item"
  -- 品质不会改变配方原型；同名普通/高品质物品可共用候选列表，减少重复缓存。
  local cache_key = machine_name .. "|" .. target_type .. "|" .. target_signal.name
  local candidates = recipe_candidate_cache[cache_key]
  if not candidates then
    candidates = {}
    for recipe_name, recipe in pairs(prototypes.recipe) do
      if Util.machine_supports(machine_name, recipe)
        and not string.find(recipe_name, "recycling", 1, true) then
        for _, product in pairs(recipe.products) do
          if product.type == target_type and product.name == target_signal.name then
            local main_product = recipe.main_product
            candidates[#candidates + 1] = {
              recipe = recipe,
              primary = main_product and main_product.type == target_type and main_product.name == target_signal.name,
              same_name = recipe.name == target_signal.name
            }
            break
          end
        end
      end
    end
    table.sort(candidates, function(a, b)
      if a.primary ~= b.primary then return a.primary end
      if a.same_name ~= b.same_name then return a.same_name end
      return a.recipe.name < b.recipe.name
    end)
    recipe_candidate_cache[cache_key] = candidates
  end
  return candidates
end

---查找势力已解锁且指定机器能够制造目标信号的配方。
---@param force LuaForce 实体所属势力，用于读取科技解锁状态。
---@param target_signal SignalID 目标物品或流体信号。
---@param machine_name string 制造机实体原型名。
---@return LuaRecipePrototype|nil recipe 找不到时返回 nil。
function Util.find_recipe(force, target_signal, machine_name)
  local candidates = get_recipe_candidates(target_signal, machine_name)
  if not candidates then return nil end
  -- 势力配方的 enabled 会随研究进度变化，不能写进静态缓存；按稳定候选顺序实时选择。
  for _, candidate in ipairs(candidates) do
    local force_recipe = force.recipes[candidate.recipe.name]
    if force_recipe and force_recipe.enabled then return candidate.recipe end
  end
  return nil
end

---查找指定机器能够制造目标信号的配方，不检查当前势力的科技解锁状态。
---用于“配方查询”这类知识查询功能；生产订单仍应调用 find_recipe 遵守科技限制。
---@param target_signal SignalID 目标物品或流体信号。
---@param machine_name string 制造机实体原型名。
---@return LuaRecipePrototype|nil recipe 找不到时返回 nil。
function Util.find_recipe_ignoring_research(target_signal, machine_name)
  local candidates = get_recipe_candidates(target_signal, machine_name)
  return candidates and candidates[1] and candidates[1].recipe or nil
end

---取得配方一次制造对目标信号的平均产量。
---@param recipe LuaRecipePrototype 配方原型。
---@param target_signal SignalID 目标物品或流体信号。
---@return number amount 固定产量，或随机范围与概率折算后的平均产量。
function Util.recipe_product_amount(recipe, target_signal)
  local target_type = target_signal.type or "item"
  for _, product in pairs(recipe.products) do
    if product.type == target_type and product.name == target_signal.name then
      local amount = product.amount
      if not amount then amount = ((product.amount_min or 0) + (product.amount_max or 0)) / 2 end
      return amount * (product.probability or 1)
    end
  end
  return 0
end

---把数值截断并限制到电路网络支持的 int32 范围。
---@param value number 待转换数值。
---@return integer value 安全整数。
function Util.clamp_int32(value)
  return math.max(-2147483648, math.min(2147483647, math.floor(value)))
end

---向输出集合累加一个信号。
---@param outputs table 以 signal_key 为键的输出集合。
---@param signal SignalID 信号标识。
---@param count number 需要增加的数量。
---@return nil
function Util.add_output(outputs, signal, count)
  local key = Util.signal_key(signal)
  if not outputs[key] then
    -- SignalID 只能包含 type、name，以及物品可用的 quality。
    -- comparator 属于条件表达式，不是常量运算器 set_slot 的 SignalID 字段。
    outputs[key] = {signal = Util.make_signal(signal.type, signal.name, signal.quality), count = 0}
  end
  outputs[key].count = Util.clamp_int32(outputs[key].count + count)
end

---把以信号键索引的输出集合转换为稳定排序数组。
---为什么需要：Lua 的 pairs 遍历顺序不固定，排序可避免线路槽位和悬浮显示来回抖动。
---@param outputs table 各模式返回的标准输出集合。
---@return table entries 数组元素格式为 `{key=string, entry=table}`。
function Util.sorted_outputs(outputs)
  local entries = {}
  for key, entry in pairs(outputs) do entries[#entries + 1] = {key = key, entry = entry} end
  table.sort(entries, function(a, b) return a.key < b.key end)
  return entries
end

return Util
