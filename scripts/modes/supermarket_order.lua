-- “超市订单”模式。
-- 本文件封装递归展开、single 锁定、目标库存迟滞以及超时轮换，不依赖 GUI。

local Util = require("scripts.common_util")
local Mode = {
  name = "supermarket_order",                        -- 模式注册名，必须与 config.lua 的值一致。
  -- 原生 select/max 即使关闭 output_networks，仍会计算输入并把结果显示在实体信息的
  -- 原生“输出信号”字段中。把选择索引固定为 int32 最大值，使任何实际输入集合都没有
  -- 对应项，从计算源头得到空结果，同时继续使用 max_symbol_sprites 显示递归图标。
  -- 真实递归计算和线路输出仍全部由本模块及隐藏代理完成。
  visual_parameters = {operation = "select", select_max = true, index_constant = 2147483647}
}

---清除超市订单模式的运行缓存，但保留玩家设置的深度、输出模式和超时。
---@param record table control.lua 保存的组合器记录。
---@return nil
function Mode.reset(record)
  record.selected_recursion_output = nil
  record.recursion_output_signal = nil
  record.recursion_output_target = nil
  record.recursion_output_count = nil
  record.recursion_output_changed_tick = nil
end

---导出超市订单的锁定与超时状态，供 control.lua 重建实体代理时暂存。
---@param record table 组合器记录。
---@return table state 可写入 storage 的纯 Lua 数据。
function Mode.save_state(record)
  return {
    selected_output = record.selected_recursion_output,
    output_signal = record.recursion_output_signal,
    output_target = record.recursion_output_target,
    output_count = record.recursion_output_count,
    changed_tick = record.recursion_output_changed_tick
  }
end

---恢复 save_state 导出的状态。
---@param record table 新建的组合器记录。
---@param saved table|nil 旧运行状态；旧版本缺失时允许为 nil。
---@return nil
function Mode.restore_state(record, saved)
  saved = saved or {}
  record.selected_recursion_output = saved.selected_output
  record.recursion_output_signal = saved.output_signal
  record.recursion_output_target = saved.output_target
  record.recursion_output_count = saved.output_count
  record.recursion_output_changed_tick = saved.changed_tick
end

---执行超市订单递归计算。
---all 返回全部递归终点；single 锁定一个结果到目标库存满足，避免机械臂抓取原料时
---在父产品和原料之间振荡。timeout 可在输出数量长期不变时轮换到下一个结果。
---@param record table 组合器记录，必须包含 entity、config 和本模式运行状态。
---@return table outputs 标准输出集合，由 control.lua 统一负责写入线路。
function Mode.calculate(record)
  local config = record.config
  local observed_inventory = Util.read_network(record.entity, defines.wire_connector_id.combinator_input_red)
  local inventory = {}
  for key, count in pairs(observed_inventory) do inventory[key] = count end
  local _, demands = Util.read_network(record.entity, defines.wire_connector_id.combinator_input_green)
  local outputs = {}
  table.sort(demands, function(a, b) return Util.signal_key(a.signal) < Util.signal_key(b.signal) end)

  ---模拟从共享库存取用物品，防止多个订单重复使用同一批库存。
  ---@param signal SignalID 要取用的信号。
  ---@param required number 当前生产链需要的数量。
  ---@return number shortage 扣除可用库存后仍缺少的数量。
  local function consume_inventory(signal, required)
    local key = Util.signal_key(signal)
    local available = math.max(0, inventory[key] or 0)
    local consumed = math.min(available, required)
    inventory[key] = available - consumed
    return required - consumed
  end

  ---递归展开一个生产需求。
  ---@param signal SignalID 当前需要生产的信号。
  ---@param required number 当前层总需求量。
  ---@param depth uint 当前递归深度，根需求从 0 开始。
  ---@param ancestors table 当前路径，用于阻止循环配方造成无限递归。
  ---@return nil
  local function resolve(signal, required, depth, ancestors)
    if required <= 0 then return end
    local shortage = consume_inventory(signal, required)
    if shortage <= 0 then return end
    local key = Util.signal_key(signal)
    -- 物品和流体使用同一套查配方流程；只有当前机器找不到可用配方时才成为递归末端。
    local recipe = Util.find_recipe(record.entity.force, signal, config.production_machine)
    if not recipe or ancestors[key] or (config.recurise_depth > 0 and depth >= config.recurise_depth) then
      Util.add_output(outputs, signal, math.ceil(shortage))
      return
    end
    local product_amount = Util.recipe_product_amount(recipe, signal)
    if product_amount <= 0 then
      Util.add_output(outputs, signal, math.ceil(shortage))
      return
    end

    local crafts = math.ceil(shortage / product_amount)
    local missing = {}
    local all_materials_available = true
    for _, ingredient in pairs(recipe.ingredients) do
      local ingredient_signal = Util.make_signal(ingredient.type, ingredient.name, "normal")
      local ingredient_shortage = consume_inventory(ingredient_signal, ingredient.amount * crafts)
      if ingredient_shortage > 0 then
        all_materials_available = false
        missing[#missing + 1] = {signal = ingredient_signal, count = ingredient_shortage}
      end
    end
    if all_materials_available then
      Util.add_output(outputs, signal, math.ceil(shortage))
      return
    end
    ancestors[key] = true
    for _, ingredient in ipairs(missing) do resolve(ingredient.signal, ingredient.count, depth + 1, ancestors) end
    ancestors[key] = nil
  end

  for _, demand in ipairs(demands) do
    local signal = demand.signal
    -- 根订单允许物品和流体；虚拟信号没有生产配方，因此不进入超市订单递归。
    if Util.is_recipe_signal(signal) and demand.count > 0 then
      resolve(signal, demand.count, 0, {})
    end
  end

  if config.recursion_output_mode == "all" then
    Mode.reset(record)
    return outputs
  end

  ---锁定一个输出，并把当时的缺口转换为固定目标库存。
  ---@param key string|nil Util.signal_key 生成的输出键；nil 表示解除锁定。
  ---@return nil
  local function lock_output(key)
    local entry = key and outputs[key]
    record.selected_recursion_output = key
    record.recursion_output_signal = entry and
      Util.make_signal(entry.signal.type, entry.signal.name, entry.signal.quality) or nil
    record.recursion_output_target = entry and ((observed_inventory[key] or 0) + entry.count) or nil
    record.recursion_output_count = entry and entry.count or nil
    record.recursion_output_changed_tick = game.tick
  end

  local selected_key = record.selected_recursion_output
  if selected_key and record.recursion_output_signal and record.recursion_output_target then
    local remaining = record.recursion_output_target - (observed_inventory[selected_key] or 0)
    if remaining > 0 then
      outputs[selected_key] = {signal = record.recursion_output_signal, count = math.ceil(remaining)}
    else
      selected_key = nil
      lock_output(nil)
    end
  end

  if not (selected_key and outputs[selected_key]) then
    selected_key = nil
    for key in pairs(outputs) do
      if not selected_key or key < selected_key then selected_key = key end
    end
    lock_output(selected_key)
  elseif not record.recursion_output_target then
    -- 兼容旧存档中只有输出键、没有目标库存的状态。
    lock_output(selected_key)
  end
  if not selected_key then return {} end

  local current_count = outputs[selected_key].count
  local timeout = tonumber(config.recursion_timeout) or 0
  if record.recursion_output_count ~= current_count then
    record.recursion_output_count = current_count
    record.recursion_output_changed_tick = game.tick
  elseif timeout > 0 then
    local unchanged_ticks = game.tick - (record.recursion_output_changed_tick or game.tick)
    if unchanged_ticks >= timeout * 60 then
      local keys = {}
      for key in pairs(outputs) do keys[#keys + 1] = key end
      table.sort(keys)
      local next_key = keys[1]
      for index, key in ipairs(keys) do
        if key == selected_key then next_key = keys[index + 1] or keys[1]; break end
      end
      selected_key = next_key
      lock_output(selected_key)
    end
  end
  return {[selected_key] = outputs[selected_key]}
end

return Mode
