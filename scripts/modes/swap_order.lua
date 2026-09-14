-- “切换订单”模式：合并两色输入，并在条件持续成立时按全排列依次改变输出槽位顺序。

local Util = require("scripts.common_util")
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
  record.swap_permutation = nil
  record.swap_condition_tick = nil
end

function Mode.save_state(record)
  return {signature = record.swap_signature, permutation = record.swap_permutation,
    condition_tick = record.swap_condition_tick}
end

function Mode.restore_state(record, saved)
  saved = saved or {}
  record.swap_signature = saved.signature
  record.swap_permutation = saved.permutation
  record.swap_condition_tick = saved.condition_tick
end

function Mode.calculate(record)
  local inputs = Conditions.read_inputs(record.entity)
  local entries, signature_parts = {}, {record.config.swap_output_mode}
  for _, value in ipairs(Util.sorted_outputs(inputs.merged)) do
    signature_parts[#signature_parts + 1] = value.key .. "=" .. tostring(value.entry.count)
    if signal_allowed(value.entry.signal, record.config.swap_output_mode) then
      entries[#entries + 1] = value.entry
    end
  end
  local signature = table.concat(signature_parts, "|")
  if record.swap_signature ~= signature or #entries ~= #(record.swap_permutation or {}) then
    record.swap_signature = signature
    record.swap_permutation = {}
    for index = 1, #entries do record.swap_permutation[index] = index end
    record.swap_condition_tick = nil
  end

  local timeout = tonumber(record.config.swap_timeout) or 0
  local all_conditions_met, condition_results = Conditions.evaluate(record.config.swap_conditions, inputs)
  record.swap_condition_results = condition_results
  if timeout > 0 and #entries > 1 and all_conditions_met then
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
  for output_index, source_index in ipairs(record.swap_permutation or {}) do
    local entry = entries[source_index]
    if entry then
      outputs[Util.signal_key(entry.signal)] = {signal = entry.signal, count = entry.count,
        sort_priority = #entries - output_index + 1}
    end
  end
  return outputs
end

return Mode
