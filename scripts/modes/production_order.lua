-- “生产订单”模式。
-- 本文件只实现该模式的选择、记忆与迟滞规则；线路和配方等通用操作来自 common_util。

local Util = require("scripts.common_util")
local Mode = {
  name = "production_order",                         -- 模式注册名，必须与 config.lua 的值一致。
  visual_operation = "count"                         -- 仅借用原版“输入计数”的 # 屏幕动画。
}

---清除生产订单模式的临时运行状态，但不修改玩家配置。
---@param record table control.lua 保存的组合器记录。
---@return nil
function Mode.reset(record)
  record.selected_request = nil
  record.remembered_order = nil
  record.production_order_output_count = nil
  record.production_order_changed_tick = nil
end

---导出需要随存档配置重建保留的模式运行状态。
---@param record table 组合器记录。
---@return table state 不包含实体和玩家配置的纯 Lua 数据。
function Mode.save_state(record)
  return {
    selected_request = record.selected_request,
    remembered_order = record.remembered_order,
    output_count = record.production_order_output_count,
    changed_tick = record.production_order_changed_tick
  }
end

---恢复 save_state 导出的运行状态；缺失字段自然保持 nil，兼容旧存档。
---@param record table 新建的组合器记录。
---@param saved table|nil 旧运行状态。
---@return nil
function Mode.restore_state(record, saved)
  saved = saved or {}
  record.selected_request = saved.selected_request
  record.remembered_order = saved.remembered_order
  record.production_order_output_count = saved.output_count
  record.production_order_changed_tick = saved.changed_tick
end

---检查每种配方原料是否达到当前阶段的阈值。
---@param recipe LuaRecipePrototype 待生产配方。
---@param inventory table 红线库存汇总。
---@param multiplier number 启动倍率或保留倍率。
---@param locked boolean true 表示订单已锁定，应采用保留阶段的停止边界。
---@return boolean enough 所有原料均满足时返回 true。
local function recipe_has_materials(recipe, inventory, multiplier, locked)
  for _, ingredient in pairs(recipe.ingredients) do
    local signal = Util.make_signal(ingredient.type, ingredient.name, "normal")
    -- 红线中不存在对应信号时按库存 0 处理。因此只接绿色订单线不会绕过原料条件；
    -- 必须让配方的每一种原料都通过红线提供足够库存，当前订单才有资格输出。
    local stock = inventory[Util.signal_key(signal)] or 0
    local threshold = ingredient.amount * multiplier
    if locked then
      -- 停止边界是严格小于：库存恰好等于保留阈值时仍允许当前订单运行。
      if stock < threshold then return false end
    else
      -- 启动边界是严格大于：库存恰好等于需求阈值时不能启动新订单。
      if stock <= threshold then return false end
    end
  end
  return true
end

---执行生产订单计算。
---新订单在商品库存低于订单量且原料达到需求阈值时启动；锁定后到商品达到上限或
---原料下降到保留阈值时结束。开启记忆后，绿色订单消失也不会立即取消当前订单；
---production_timeout 大于 0 时，产品输出值长期无变化也会触发订单轮换。
---@param record table 组合器记录，必须包含 entity、config 和本模式运行状态。
---@return table outputs 标准输出集合，由 control.lua 统一写入隐藏代理。
function Mode.calculate(record)
  local config = record.config
  local inventory = Util.read_network(record.entity, defines.wire_connector_id.combinator_input_red)
  local _, demands = Util.read_network(record.entity, defines.wire_connector_id.combinator_input_green)
  local outputs = {}
  table.sort(demands, function(a, b) return Util.signal_key(a.signal) < Util.signal_key(b.signal) end)

  ---判断一个订单在启动或锁定阶段是否仍可执行。
  ---@param demand Signal 当前需求信号及数量。
  ---@param locked boolean 是否为已经启动的订单。
  ---@return LuaRecipePrototype|nil recipe 满足时返回配方，否则返回 nil。
  local function eligible(demand, locked)
    local signal = demand.signal
    if not ((signal.type == nil or signal.type == "item") and demand.count > 0) then return nil end
    local stock = inventory[Util.signal_key(signal)] or 0
    if locked then
      -- 停止条件：订单一旦启动，就忽略基础订单阈值，继续保持锁定直到扩展目标。
      -- 这样库存处于 [订单量, 扩展目标) 时不会关闭输出后又立刻重新启动。
      -- 达到目标上限时缺口已经为 0，应立即完成当前订单；若仍使用严格大于，
      -- 下游收到 0 后不会继续生产，组合器也就永远无法靠库存增长解除锁定。
      if stock >= demand.count * (1 + config.additional_production_rate) then return nil end
    elseif demand.count <= stock then
      -- 启动条件：只有库存严格小于基础订单量才能选中新订单。
      -- 此处不能使用扩展目标，否则迟滞区间内会反复重新启动，失去防频闪作用。
      return nil
    end
    local recipe = Util.find_recipe(record.entity.force, signal, config.production_machine)
    local material_rate = locked and (config.material_retention_rate or 1) or config.material_demand_rate
    if recipe and recipe_has_materials(recipe, inventory, material_rate, locked) then return recipe end
    return nil
  end

  ---计算产品线路当前应输出的实时生产缺口。
  ---缺口不是“基础订单量 - 库存”，而是“订单量 ×（1 + 额外可生产倍率）- 库存”。
  ---例如订单为 7、倍率为 1、库存为 5，最终目标为 14，输出缺口就是 9。
  ---Factorio 电路信号只能保存整数；目标出现小数时向上取整，才能确保实际库存达到
  ---配置的目标。最后再限制到 int32 范围，使超时比较值与线路实际输出值一致。
  ---@param demand Signal 当前锁定订单。
  ---@return integer count 最终写入产品线路的非负缺口数量。
  local function product_output_count(demand)
    local stock = inventory[Util.signal_key(demand.signal)] or 0
    local target = demand.count * (1 + config.additional_production_rate)
    return Util.clamp_int32(math.max(0, math.ceil(target - stock)))
  end

  local selected_demand, selected_recipe
  if config.remember_order and record.remembered_order then
    selected_recipe = eligible(record.remembered_order, true)
    if selected_recipe then
      selected_demand = record.remembered_order
    else
      Mode.reset(record)
    end
  elseif record.selected_request then
    for _, demand in ipairs(demands) do
      if Util.signal_key(demand.signal) == record.selected_request then
        selected_recipe = eligible(demand, true)
        if selected_recipe then
          selected_demand = demand
          if config.remember_order then
            record.remembered_order = {
              signal = Util.make_signal(demand.signal.type, demand.signal.name, demand.signal.quality),
              count = demand.count
            }
          end
        end
        break
      end
    end
  end

  -- 超时直接监控最终写入线路的产品数量。库存或订单变化只要让该值改变，就重新计时；
  -- 只有输出数值连续 timeout 秒完全不变才释放当前订单并轮换。
  local timed_out_key
  local selected_output_count
  if selected_demand then
    local selected_key = Util.signal_key(selected_demand.signal)
    selected_output_count = product_output_count(selected_demand)
    local timeout = tonumber(config.production_timeout) or 0
    if record.production_order_output_count ~= selected_output_count then
      record.production_order_output_count = selected_output_count
      record.production_order_changed_tick = game.tick
    elseif timeout > 0 then
      local unchanged_ticks = game.tick - (record.production_order_changed_tick or game.tick)
      if unchanged_ticks >= timeout * 60 then
        timed_out_key = selected_key
        Mode.reset(record)
        selected_demand, selected_recipe = nil, nil
      end
    end
  end

  if not selected_demand then
    record.selected_request = nil
    record.production_order_output_count = nil
    record.production_order_changed_tick = nil
    if not config.remember_order then record.remembered_order = nil end
    -- 超时后从当前订单的下一项开始循环；正常完成时仍从排序后的第一项开始。
    local start_index = 1
    if timed_out_key then
      for index, demand in ipairs(demands) do
        if Util.signal_key(demand.signal) == timed_out_key then
          start_index = index % #demands + 1
          break
        end
      end
    end
    for offset = 0, #demands - 1 do
      local demand = demands[(start_index + offset - 1) % #demands + 1]
      local recipe = eligible(demand, false)
      if recipe then
        selected_demand, selected_recipe = demand, recipe
        record.selected_request = Util.signal_key(demand.signal)
        selected_output_count = product_output_count(demand)
        record.production_order_output_count = selected_output_count
        record.production_order_changed_tick = game.tick
        if config.remember_order then
          record.remembered_order = {
            signal = Util.make_signal(demand.signal.type, demand.signal.name, demand.signal.quality),
            count = demand.count
          }
        end
        break
      end
    end
  end

  if selected_demand then
    if config.output_mode ~= "only_material" then
      -- 产品信号表示“额外生产后的目标上限 - 当前库存”的实时缺口。
      Util.add_output(outputs, selected_demand.signal, selected_output_count or product_output_count(selected_demand))
    end
    if config.output_mode ~= "only_item" then
      for _, ingredient in pairs(selected_recipe.ingredients) do
        Util.add_output(outputs, Util.make_signal(ingredient.type, ingredient.name, "normal"),
          ingredient.amount * config.material_demand_rate)
      end
    end
  end
  return outputs
end

return Mode
