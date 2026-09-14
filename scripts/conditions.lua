-- 红绿线路条件的公共读取与判断。
-- 生产订单、超市订单和切换订单共用这一份语义，避免三套比较规则逐渐分叉。

local Util = require("scripts.common_util")
local Conditions = {}

local comparisons = {
  ['<'] = function(a, b) return a < b end, ['>'] = function(a, b) return a > b end,
  ['='] = function(a, b) return a == b end, ['<='] = function(a, b) return a <= b end,
  ['>='] = function(a, b) return a >= b end, ['~='] = function(a, b) return a ~= b end
}

---读取实体的红绿输入，并保留切换订单需要的合并信号。
---@param entity LuaEntity 组合器实体。
---@return table inputs 包含 red、green、entries 和 merged。
function Conditions.read_inputs(entity)
  local inputs = {entries = {}, merged = {}}
  for color, connector_id in pairs({
    red = defines.wire_connector_id.combinator_input_red,
    green = defines.wire_connector_id.combinator_input_green
  }) do
    local totals, entries = Util.read_network(entity, connector_id)
    inputs[color] = totals
    inputs.entries[color] = entries
    for _, entry in pairs(entries) do
      if entry.signal and entry.signal.name then Util.add_output(inputs.merged, entry.signal, entry.count) end
    end
  end
  return inputs
end

local function operand_value(operand, inputs)
  if not (operand and operand.signal and operand.signal.name) then
    return tonumber(operand and operand.constant) or 0
  end
  local key = Util.signal_key(operand.signal)
  local value = 0
  if operand.red ~= false then value = value + (inputs.red[key] or 0) end
  if operand.green ~= false then value = value + (inputs.green[key] or 0) end
  return value
end

---按条件间的“并且/或者”关系计算最终结果，并返回每行状态供 GUI 显示。
---@param conditions table 条件数组。
---@param inputs table read_inputs 的结果。
---@return boolean matched 全部组合后的结果。
---@return table results 每行条件是否满足。
function Conditions.evaluate(conditions, inputs)
  local combined
  local results = {}
  for index, condition in ipairs(conditions or {}) do
    local compare = comparisons[condition.comparator] or comparisons['<']
    local matched = compare(operand_value(condition.first, inputs), operand_value(condition.second, inputs))
    results[index] = matched
    if index == 1 then combined = matched
    elseif condition.relation == "and" then combined = combined and matched
    else combined = combined or matched end
  end
  return combined == true, results
end

---收集会读取指定线路颜色的条件信号；绿色控制信号不会再被误当作订单。
---@param conditions table 条件数组。
---@param color string red 或 green。
---@return table keys 以 signal_key 为键的集合。
function Conditions.signal_keys(conditions, color)
  local keys = {}
  for _, condition in ipairs(conditions or {}) do
    for _, operand in ipairs({condition.first, condition.second}) do
      if operand and operand.signal and operand.signal.name and operand[color] ~= false then
        keys[Util.signal_key(operand.signal)] = true
      end
    end
  end
  return keys
end

return Conditions
