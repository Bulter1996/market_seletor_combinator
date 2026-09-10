-- 各运算模式共用的 Factorio 运行阶段工具集。
-- 本模块不保存 storage 状态，也不了解 GUI；输入相同参数就得到相同结果，方便复用和测试。

local Util = {}

-- Factorio 的 prototypes.recipe / prototypes.entity 是运行阶段只读原型；同一次游戏运行中
-- 配方结构与机器制造类别不会变化。每台机器第一次使用时一次性构建完整的
-- “产品 -> 候选配方 + 材料层级”索引，之后所有运算器共享并通过 key-value 查询。
-- 这是 Lua 模块内存缓存，不写入 storage；加载存档或重载模组后会自然重新构建。
-- 势力解锁状态会随研究变化，因此不能写进静态缓存，仍在 find_recipe 中实时检查。
local machine_recipe_cache = {}

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
  local signals = entity and entity.valid ~= false and entity.get_signals(connector_id) or {}
  for _, entry in pairs(signals) do
    if entry.signal and entry.signal.name and type(entry.count) == "number" then
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
  local machine = prototypes and prototypes.entity and prototypes.entity[machine_name]
  if not (machine and machine.crafting_categories and recipe and type(recipe.categories) == "table") then
    return false
  end
  for _, category in pairs(recipe.categories) do
    if machine.crafting_categories[category] then return true end
  end
  return false
end

---配方索引不区分品质，因为品质不会改变配方结构。
---@param signal_type string|nil 信号类型。
---@param name string 原型名称。
---@return string key 索引键。
local function recipe_product_key(signal_type, name)
  return (signal_type or "item") .. ":" .. tostring(name or "")
end

---为一台机器一次性构建全部产品配方和结构层级。
---@param machine_name string 制造机实体原型名。
---@return table cache 机器配方缓存。
local function get_machine_recipe_cache(machine_name)
  -- table 不能使用 nil 作为赋值键。旧蓝图引用已移除机器、或热加载留下空配置时，
  -- 统一落入无制造能力的保底键，而不是在 machine_recipe_cache[nil] 处报错。
  local cache_key = type(machine_name) == "string" and machine_name or "<invalid-machine>"
  local cached = machine_recipe_cache[cache_key]
  if cached then return cached end

  cached = {candidates = {}, layers = {}}
  -- prototypes.recipe 枚举当前模组组合下的全部配方原型。这里先用机器实体原型的
  -- crafting_categories 筛掉机器无法执行的制造类别，再用 products 建立反向索引：
  -- product type+name -> 能生产它的配方。ingredients 为空和 recycling 配方不参与递归。
  for recipe_name, recipe in pairs((prototypes and prototypes.recipe) or {}) do
    local ingredients = type(recipe.ingredients) == "table" and recipe.ingredients or {}
    local products = type(recipe.products) == "table" and recipe.products or {}
    if Util.machine_supports(machine_name, recipe) and #ingredients > 0
      and not string.find(recipe_name, "recycling", 1, true) then
      for _, product in pairs(products) do
        if product and product.name then
          local key = recipe_product_key(product.type, product.name)
          local main_product = recipe.main_product
          local primary = main_product and main_product.type == product.type and main_product.name == product.name
          local same_name = recipe.name == product.name
          -- 多产物配方的普通副产品不能证明机器能“以该物品为目标”继续生产。否则铁板等
          -- 基础材料可能因为某个副产物配方被错误标记为可递归，并在下一深度展开为空。
          -- 单产物配方即使名称不同、未显式声明 main_product，也仍是明确的生产路径。
          if primary or same_name or #products == 1 then
            local candidates = cached.candidates[key]
            if not candidates then candidates = {}; cached.candidates[key] = candidates end
            candidates[#candidates + 1] = {recipe = recipe, primary = primary, same_name = same_name}
          end
        end
      end
    end
  end
  for _, candidates in pairs(cached.candidates) do
    table.sort(candidates, function(a, b)
      if a.primary ~= b.primary then return a.primary end
      if a.same_name ~= b.same_name then return a.same_name end
      return a.recipe.name < b.recipe.name
    end)
  end

  -- 层级只描述机器的静态制造结构：无配方为 1；可继续制造则至少为 2。
  -- 循环边不再向下计层，并打 cyclic 标记，运行时仍由 ancestors 精确截断循环路径。
  local visiting = {}
  local function calculate_layer(key)
    if cached.layers[key] then return cached.layers[key] end
    if visiting[key] then return {level = 1, cyclic = true} end
    local candidates = cached.candidates[key]
    if not (candidates and candidates[1]) then
      cached.layers[key] = {level = 1, cyclic = false}
      return cached.layers[key]
    end
    visiting[key] = true
    local maximum_child_level = 0
    local cyclic = false
    for _, ingredient in pairs(candidates[1].recipe.ingredients or {}) do
      if ingredient and ingredient.name then
        local child = calculate_layer(recipe_product_key(ingredient.type, ingredient.name))
        maximum_child_level = math.max(maximum_child_level, child.level)
        cyclic = cyclic or child.cyclic
      end
    end
    visiting[key] = nil
    cached.layers[key] = {level = math.max(2, maximum_child_level + 1), cyclic = cyclic}
    return cached.layers[key]
  end
  for key in pairs(cached.candidates) do calculate_layer(key) end
  machine_recipe_cache[cache_key] = cached
  return cached
end

---取得指定机器能够制造目标信号的稳定候选配方列表。
---@param target_signal SignalID 目标物品或流体信号。
---@param machine_name string 制造机实体原型名。
---@return table|nil candidates 候选项数组。
local function get_recipe_candidates(target_signal, machine_name)
  if not Util.is_recipe_signal(target_signal) then return nil end
  local cache = get_machine_recipe_cache(machine_name)
  return cache.candidates[recipe_product_key(target_signal.type, target_signal.name)]
end

---读取目标材料在指定机器制造图中的结构层级。
---@param target_signal SignalID 目标物品或流体信号。
---@param machine_name string 制造机实体原型名。
---@return uint level 无配方为 1，可制造产品从 2 开始递增。
function Util.machine_material_layer(target_signal, machine_name)
  if not Util.is_recipe_signal(target_signal) then return 1 end
  local cache = get_machine_recipe_cache(machine_name)
  local key = recipe_product_key(target_signal.type, target_signal.name)
  local layer = cache.layers[key]
  return layer and layer.level or 1
end

---查找势力已解锁且指定机器能够制造目标信号的配方。
---@param force LuaForce 实体所属势力，用于读取科技解锁状态。
---@param target_signal SignalID 目标物品或流体信号。
---@param machine_name string 制造机实体原型名。
---@return LuaRecipePrototype|nil recipe 找不到时返回 nil。
function Util.find_recipe(force, target_signal, machine_name)
  local candidates = get_recipe_candidates(target_signal, machine_name)
  if not (candidates and force and force.recipes) then return nil end
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
  if not (recipe and type(recipe.products) == "table" and target_signal and target_signal.name) then return 0 end
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
---业务模块可在条目上提供通用 sort_priority；数值越大越靠前。没有优先级的模式仍按
---信号键排序。公共模块不解释优先级含义，从而与具体模式解耦。
---@param outputs table 各模式返回的标准输出集合。
---@return table entries 数组元素格式为 `{key=string, entry=table}`。
function Util.sorted_outputs(outputs)
  local entries = {}
  for key, entry in pairs(type(outputs) == "table" and outputs or {}) do
    if type(entry) == "table" and entry.signal and entry.signal.name and type(entry.count) == "number" then
      entries[#entries + 1] = {key = key, entry = entry}
    end
  end
  table.sort(entries, function(a, b)
    local a_priority = tonumber(a.entry.sort_priority) or 0
    local b_priority = tonumber(b.entry.sort_priority) or 0
    if a_priority ~= b_priority then return a_priority > b_priority end
    return a.key < b.key
  end)
  return entries
end

return Util
