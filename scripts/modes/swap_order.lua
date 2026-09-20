-- “切换订单”模式：从合并输入锁定前两个信号，并用 101/102 在红绿输出间交换排名。

local Conditions = require("scripts.conditions")
local Mode = {
  name = "swap_order",
  -- 借用 random 的独立屏幕槽位显示蓝色交叉信号。关闭输出线路只能阻止信号发送，
  -- 原版 random 仍会在实体信息中生成输出；把更新周期设为 uint32 上限，从源头阻止
  -- 它在实际游戏周期内完成第一次选择，真实交换输出仍完全由隐藏代理负责。
  visual_parameters = {operation = "random", random_update_interval = 4294967295},
  visual_revision = 2  -- 强制旧存档立即替换此前每 tick 产生原版输出的 random 参数。
}

local STATE_REVISION = 1

local function signal_allowed(signal, output_mode)
  local signal_type = signal.type or "item"
  if output_mode == "fluid" then return signal_type == "fluid" end
  if output_mode == "item" then return signal_type == "item" end
  if output_mode == "all" then return signal_type == "item" or signal_type == "fluid" end
  return true
end

Mode.conditions_met = Conditions.evaluate

function Mode.reset(record)
  -- 模式暂时失活时保留锁定结果和交换方向，只停止计时并清除界面状态。
  record.swap_condition_tick = nil
  record.swap_condition_results = nil
  record.swap_order_diagnostics = nil
end

function Mode.clear(record)
  record.swap_state_revision = nil
  record.swap_signature = nil
  record.swap_sources = nil
  record.swap_permutation = nil -- 迁移清理：旧版本保存的任意长度全排列不再参与运行。
  record.swap_reversed = nil
  record.swap_condition_tick = nil
  record.swap_order_diagnostics = nil
end

function Mode.save_state(record)
  if record.swap_state_revision ~= STATE_REVISION then return {} end
  return {revision = STATE_REVISION, signature = record.swap_signature,
    sources = record.swap_sources, reversed = record.swap_reversed,
    condition_tick = record.swap_condition_tick}
end

function Mode.restore_state(record, saved)
  Mode.clear(record)
  if type(saved) ~= "table" or saved.revision ~= STATE_REVISION then return end
  record.swap_state_revision = STATE_REVISION
  record.swap_signature = saved.signature
  record.swap_sources = saved.sources
  record.swap_reversed = saved.reversed == true
  record.swap_condition_tick = saved.condition_tick
end

local function ranked_output(entry, count)
  if not entry then return {} end
  return {[entry.key] = {signal = entry.signal, count = count, sort_priority = 1}}
end

function Mode.calculate(record)
  local inputs = Conditions.read_inputs(record.entity)
  local entries = {}
  for key, entry in pairs(inputs.merged) do
    -- 两色相抵为零时线路不会产生有效输出，也不应占用两个锁定名额之一。
    if entry.count ~= 0 and signal_allowed(entry.signal, record.config.swap_output_mode) then
      entries[#entries + 1] = {key = key, signal = entry.signal, count = entry.count}
    end
  end
  table.sort(entries, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.key < b.key
  end)

  local signature_keys = {}
  for _, entry in ipairs(entries) do signature_keys[#signature_keys + 1] = entry.key end
  table.sort(signature_keys)
  local signature = record.config.swap_output_mode .. "|" .. table.concat(signature_keys, "|")
  if record.swap_state_revision ~= STATE_REVISION or record.swap_signature ~= signature
    or type(record.swap_sources) ~= "table" or #record.swap_sources > 2 then
    -- 只有信号种类变化或玩家主动重新选择才重排；单纯数量变化继续锁定原来的两个 ID。
    record.swap_state_revision = STATE_REVISION
    record.swap_signature = signature
    record.swap_sources = {}
    for index = 1, math.min(2, #entries) do record.swap_sources[index] = entries[index].key end
    record.swap_reversed = false
    record.swap_condition_tick = nil
  end

  local entries_by_key = {}
  for _, entry in ipairs(entries) do entries_by_key[entry.key] = entry end
  local first = entries_by_key[record.swap_sources[1]]
  local second = entries_by_key[record.swap_sources[2]]

  local timeout = tonumber(record.config.swap_timeout) or 0
  local timeout_reset_active, condition_results = Conditions.evaluate(record.config.swap_conditions, inputs)
  record.swap_condition_results = condition_results
  local can_swap = timeout > 0 and first ~= nil and second ~= nil
    and (record.config.swap_loop == true or record.swap_reversed ~= true)
  if not can_swap then
    record.swap_condition_tick = nil
  elseif timeout_reset_active then
    -- 与生产订单一致：条件满足只负责把超时起点刷新到当前 tick。
    record.swap_condition_tick = game.tick
  else
    record.swap_condition_tick = record.swap_condition_tick or game.tick
    if game.tick - record.swap_condition_tick >= timeout * 60 then
      record.swap_reversed = not record.swap_reversed
      record.swap_condition_tick = record.config.swap_loop == true and game.tick or nil
    end
  end

  local locked = {}
  for _, key in ipairs(record.swap_sources) do locked[key] = true end
  local diagnostics = {}
  for _, entry in ipairs(entries) do
    if not locked[entry.key] then diagnostics[entry.key] = {kind = "swap_discarded", all_colors = true} end
  end
  record.swap_order_diagnostics = diagnostics

  if not first then return {separated = true, red = {}, green = {}} end
  if not second then
    -- 唯一信号在两条输出线路都保持第一名编码，且没有交换计时。
    return {separated = true, red = ranked_output(first, 101), green = ranked_output(first, 101)}
  end
  if record.swap_reversed then first, second = second, first end
  return {separated = true, red = ranked_output(first, 101), green = ranked_output(second, 102)}
end

return Mode
