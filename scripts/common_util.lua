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

---判断信号是否可以作为生产输入；配方信号会在后续解析为其主产物。
---@param signal SignalID|nil 待检查信号。
---@return boolean supported 物品、流体或配方信号返回 true。
function Util.is_recipe_input(signal)
  if not (signal and signal.name) then return false end
  local signal_type = signal.type or "item"
  return signal_type == "item" or signal_type == "fluid" or signal_type == "recipe"
end

---构造规范化的 SignalID。
---品质只属于物品；其他类型不写 quality，避免向 Factorio API 传入无意义字段。
---@param signal_type string|nil 信号类型；nil 按 `item` 处理。
---@param name string 原型名称。
---@param quality LuaQualityPrototype|string|nil 物品品质；流体会忽略此参数。
---@return SignalID signal 可用于电路输出和 signal_key 的信号。
function Util.make_signal(signal_type, name, quality)
  local normalized_type = signal_type or "item"
  local signal = {type = normalized_type, name = name}
  if normalized_type == "item" then signal.quality = Util.quality_name(quality) end
  return signal
end

---把物品、流体或配方输入解析为实际产品；配方输入同时返回指定配方。
---@param signal SignalID 输入信号。
---@param machine_name string|nil 当前生产机器实体原型名；省略时不限制制造类别。
---@return SignalID|nil product_signal 产品信号；配方无产物或不受指定机器支持时为 nil。
---@return LuaRecipePrototype|nil specified_recipe 配方输入指定的配方；普通产品输入为 nil。
function Util.resolve_recipe_input(signal, machine_name)
  if Util.is_recipe_signal(signal) then
    return Util.make_signal(signal.type, signal.name, signal.quality), nil
  end
  if not (signal and signal.type == "recipe") then return nil, nil end
  local recipe = prototypes and prototypes.recipe and prototypes.recipe[signal.name]
  if not recipe or (machine_name and not Util.machine_supports(machine_name, recipe)) then return nil, nil end
  local product = recipe.main_product or (recipe.products and recipe.products[1])
  if not (product and product.name) then return nil, nil end
  return Util.make_signal(product.type, product.name, signal.quality), recipe
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

---读取信号数组中指定信号的合计值。
---@param entries table Factorio 返回的信号条目数组。
---@param wanted SignalID|nil 需要匹配的信号。
---@return number count 同类型、名称和品质信号的数量合计。
function Util.signal_count(entries, wanted)
  if not (wanted and wanted.name) then return 0 end
  local wanted_key = Util.signal_key(wanted)
  local count = 0
  for _, entry in pairs(entries or {}) do
    if entry.signal and Util.signal_key(entry.signal) == wanted_key then count = count + (entry.count or 0) end
  end
  return count
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

---生成配方内容签名，用于折叠不同内部名称但生产内容完全相同的模组兼容配方。
---制造类别不参与签名：候选已经按当前机器过滤，同一机器中的等价类别无需重复展示。
local function recipe_content_signature(recipe)
  local function entries_signature(entries)
    local parts = {}
    for _, entry in pairs(entries or {}) do
      parts[#parts + 1] = table.concat({entry.type or "item", entry.name or "",
        tostring(entry.amount or ""), tostring(entry.amount_min or ""),
        tostring(entry.amount_max or ""), tostring(entry.probability or 1),
        tostring(entry.temperature or "")}, ":")
    end
    table.sort(parts)
    return table.concat(parts, ",")
  end
  return entries_signature(recipe.ingredients) .. "->" .. entries_signature(recipe.products)
    .. "@" .. tostring(recipe.energy or recipe.energy_required or "")
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

  cached = {candidates = {}, all_candidates = {}, layers = {}}
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
          local all_candidates = cached.all_candidates[key]
          if not all_candidates then all_candidates = {}; cached.all_candidates[key] = all_candidates end
          all_candidates[#all_candidates + 1] = {recipe = recipe, primary = primary, same_name = same_name}
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
  for _, candidates in pairs(cached.all_candidates) do
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

---列出当前势力已解锁、机器支持且确实产出目标信号的全部配方。
---与自动选择不同，这里允许目标只是副产物：玩家手动指定已经消除了生产意图的歧义。
---@param force LuaForce 实体所属势力。
---@param target_signal SignalID 目标物品或流体。
---@param machine_name string 制造机实体原型名。
---@return table recipes 按稳定优先级排列的 LuaRecipePrototype 数组。
function Util.available_recipes(force, target_signal, machine_name)
  if not (Util.is_recipe_signal(target_signal) and force and force.recipes) then return {} end
  local cache = get_machine_recipe_cache(machine_name)
  local candidates = cache.all_candidates[recipe_product_key(target_signal.type, target_signal.name)] or {}
  local recipes, seen = {}, {}
  for _, candidate in ipairs(candidates) do
    local force_recipe = force.recipes[candidate.recipe.name]
    local signature = recipe_content_signature(candidate.recipe)
    if force_recipe and force_recipe.enabled and candidate.recipe.hidden ~= true
      and Util.machine_supports(machine_name, candidate.recipe) and not seen[signature] then
      recipes[#recipes + 1], seen[signature] = candidate.recipe, true
    end
  end
  return recipes
end

---取得指定机器能够制造目标信号的稳定候选配方列表。
---@param target_signal SignalID 目标物品或流体信号。
---@param machine_name string 制造机实体原型名。
---@param specified_recipe LuaRecipePrototype|nil 配方信号明确指定的配方。
---@return table|nil candidates 候选项数组。
local function get_recipe_candidates(target_signal, machine_name)
  if not Util.is_recipe_signal(target_signal) then return nil end
  local cache = get_machine_recipe_cache(machine_name)
  return cache.candidates[recipe_product_key(target_signal.type, target_signal.name)]
end

---读取目标材料在指定机器制造图中的结构层级。
---@param target_signal SignalID 目标物品或流体信号。
---@param machine_name string 制造机实体原型名。
---@param specified_recipe LuaRecipePrototype|nil 配方信号明确指定的配方。
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
function Util.find_recipe(force, target_signal, machine_name, specified_recipe)
  if specified_recipe then
    local force_recipe = force and force.recipes and force.recipes[specified_recipe.name]
    if force_recipe and force_recipe.enabled and Util.machine_supports(machine_name, specified_recipe)
      and Util.recipe_product_amount(specified_recipe, target_signal) > 0 then
      return specified_recipe
    end
    return nil
  end
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
function Util.find_recipe_ignoring_research(target_signal, machine_name, specified_recipe)
  if specified_recipe then
    if Util.machine_supports(machine_name, specified_recipe)
      and Util.recipe_product_amount(specified_recipe, target_signal) > 0 then
      return specified_recipe
    end
    return nil
  end
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

---按缓存格上限缩放一组配方需求；单个配方时与生产订单原有完整批次算法等价。
---液体和不可装箱物品不占缓存格，始终保留完整需求；多个配方按各自制造次数同比缩放。
---@param requirements table[] 每项包含 recipe 和正整数 crafts。
---@param max_slots integer 允许使用的缓存格数；0 表示不限制。
---@return table outputs 可写入线路的原料集合。
function Util.limit_recipe_materials_by_cache(requirements, max_slots)
  local full_outputs = {}
  local maximum_crafts = 0
  for _, requirement in ipairs(requirements or {}) do
    local crafts = math.max(0, math.floor(tonumber(requirement.crafts) or 0))
    local recipe = requirement.recipe
    if crafts > 0 and recipe then
      maximum_crafts = math.max(maximum_crafts, crafts)
      for _, ingredient in pairs(recipe.ingredients or {}) do
        Util.add_output(full_outputs,
          Util.make_signal(ingredient.type, ingredient.name, "normal"), ingredient.amount * crafts)
      end
    end
  end
  max_slots = math.max(0, math.floor(tonumber(max_slots) or 0))
  if max_slots == 0 then return full_outputs end

  local outputs = {}
  local cacheable, stack_sizes = {}, {}
  for key, entry in pairs(full_outputs) do
    local prototype = (entry.signal.type or "item") == "item"
      and prototypes.item and prototypes.item[entry.signal.name] or nil
    if prototype and not prototype.has_flag("only-in-cursor") then
      cacheable[key] = true
      stack_sizes[key] = prototype.stack_size or 1
    else
      Util.add_output(outputs, entry.signal, entry.count)
    end
  end
  if not next(cacheable) or maximum_crafts == 0 then return outputs end

  local function scaled_outputs(scale)
    local scaled = {}
    for _, requirement in ipairs(requirements or {}) do
      local requested = math.max(0, math.floor(tonumber(requirement.crafts) or 0))
      local crafts = requested > 0 and math.ceil(requested * scale / maximum_crafts) or 0
      for _, ingredient in pairs(requirement.recipe and requirement.recipe.ingredients or {}) do
        local signal = Util.make_signal(ingredient.type, ingredient.name, "normal")
        if cacheable[Util.signal_key(signal)] then
          Util.add_output(scaled, signal, ingredient.amount * crafts)
        end
      end
    end
    return scaled
  end

  local function slots_for(scale)
    local slots = 0
    for key, entry in pairs(scaled_outputs(scale)) do
      slots = slots + math.ceil(entry.count / stack_sizes[key])
    end
    return slots
  end

  local low, high, fitted = 1, maximum_crafts, 0
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if slots_for(middle) <= max_slots then
      fitted = middle
      low = middle + 1
    else
      high = middle - 1
    end
  end
  if fitted > 0 then
    for _, entry in pairs(scaled_outputs(fitted)) do Util.add_output(outputs, entry.signal, entry.count) end
  end
  return outputs
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
