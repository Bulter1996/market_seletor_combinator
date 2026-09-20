-- “切换订单”模式：合并两色输入，并用 101、102……的唯一数值把全排列传给下游选择器。

local Conditions = require("scripts.conditions")
local Mode = {
  name = "swap_order",
  -- 借用 random 的独立屏幕槽位显示蓝色交叉信号。关闭输出线路只能阻止信号发送，
  -- 原版 random 仍会在实体信息中生成输出；把更新周期设为 uint32 上限，从源头阻止
  -- 它在实际游戏周期内完成第一次选择，真实交换输出仍完全由隐藏代理负责。
  visual_parameters = {operation = "random", random_update_interval = 4294967295},
  visual_revision = 2  -- 强制旧存档立即替换此前每 tick 产生原版输出的 random 参数。
}

local function next_permutation(values)
  local pivot = #values - 1
  while pivot > 0 and values[pivot] >= values[pivot + 1] do pivot = pivot - 1 end
  if pivot == 0 then
    for index = 1, math.floor(#values / 2) do
      values[index], values[#values - index + 1] = values[#values - index + 1], values[index]
    end
    return values
  end
  local successor = #values
  while values[successor] <= values[pivot] do successor = successor - 1 end
  values[pivot], values[successor] = values[successor], values[pivot]
  local left, right = pivot + 1, #values
  while left < right do
    values[left], values[right] = values[right], values[left]
    left, right = left + 1, right - 1
  end
  return values
end

Mode.next_permutation = next_permutation

local function is_last_permutation(values)
  for index = 2, #values do
    if values[index - 1] < values[index] then return false end
  end
  return true
end

local function signal_allowed(signal, output_mode)
  local signal_type = signal.type or "item"
  if output_mode == "fluid" then return signal_type == "fluid" end
  if output_mode == "item" then return signal_type == "item" end
  if output_mode == "all" then return signal_type == "item" or signal_type == "fluid" end
  return true
end

Mode.conditions_met = Conditions.evaluate

function Mode.reset(record)
  -- 模式暂时失活时只停止计时；排列只允许由输入变化或玩家清空恢复。
  record.swap_condition_tick = nil
  record.swap_condition_results = nil
end

function Mode.clear(record)
  record.swap_signature = nil
  record.swap_sources = nil
  record.swap_permutation = nil
  record.swap_condition_tick = nil
end

function Mode.save_state(record)
  return {signature = record.swap_signature, sources = record.swap_sources,
    permutation = record.swap_permutation,
    condition_tick = record.swap_condition_tick}
end

function Mode.restore_state(record, saved)
  saved = saved or {}
  record.swap_signature = saved.signature
  record.swap_sources = saved.sources
  record.swap_permutation = saved.permutation
  record.swap_condition_tick = saved.condition_tick
end

function Mode.calculate(record)
  local inputs = Conditions.read_inputs(record.entity)
  local entries = {}
  for key, entry in pairs(inputs.merged) do
    if signal_allowed(entry.signal, record.config.swap_output_mode) then
      entries[#entries + 1] = {key = key, signal = entry.signal, count = entry.count}
    end
  end
  -- 初始排列按输入数量从大到小；数量相同时按稳定信号键排序。线路输出随后改写为
  -- 101、102……的唯一排名值，让下游原版选择运算器能够真正观察到排列变化。
  table.sort(entries, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.key < b.key
  end)
  local signature_parts = {record.config.swap_output_mode}
  local signature_keys = {}
  for _, entry in ipairs(entries) do signature_keys[#signature_keys + 1] = entry.key end
  table.sort(signature_keys)
  for _, key in ipairs(signature_keys) do signature_parts[#signature_parts + 1] = key end
  local signature = table.concat(signature_parts, "|")
  if record.swap_signature ~= signature or #entries ~= #(record.swap_sources or {})
    or #entries ~= #(record.swap_permutation or {}) then
    record.swap_signature = signature
    record.swap_sources = {}
    record.swap_permutation = {}
    for index, entry in ipairs(entries) do
      record.swap_sources[index] = entry.key
      record.swap_permutation[index] = index
    end
    record.swap_condition_tick = nil
  end

  local timeout = tonumber(record.config.swap_timeout) or 0
  local all_conditions_met, condition_results = Conditions.evaluate(record.config.swap_conditions, inputs)
  record.swap_condition_results = condition_results
  -- 默认只遍历一次全排列；到达降序的最后一项后停止计时，输入签名变化时才从头开始。
  -- 开启循环后保留旧行为，由 next_permutation 把最后一项重新折回第一个排列。
  local can_advance = record.config.swap_loop == true
    or not is_last_permutation(record.swap_permutation or {})
  if timeout > 0 and #entries > 1 and all_conditions_met and can_advance then
    record.swap_condition_tick = record.swap_condition_tick or game.tick
    local elapsed_ticks = game.tick - record.swap_condition_tick
    if elapsed_ticks >= timeout * 60 then
      next_permutation(record.swap_permutation)
      record.swap_condition_tick = game.tick
    end
  else
    record.swap_condition_tick = nil
  end

  local outputs = {}
  local entries_by_key = {}
  for _, entry in ipairs(entries) do entries_by_key[entry.key] = entry end
  for output_index, source_index in ipairs(record.swap_permutation or {}) do
    -- 数量变化可能改变 entries 的排序；使用首次建序时保存的信号键保持当前排列不动。
    local entry = entries_by_key[record.swap_sources[source_index]]
    if entry then
      outputs[entry.key] = {signal = entry.signal, count = 100 + output_index,
        sort_priority = #entries - output_index + 1}
    end
  end
  return outputs
end

return Mode
