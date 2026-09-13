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
  record.production_order_diagnostics = nil
  record.detail_outputs = nil
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

---收集尚未达到当前阶段阈值的配方原料及缺口。
---@param recipe LuaRecipePrototype 待生产配方。
---@param inventory table 红线库存汇总。
---@param multiplier number 启动倍率或保留倍率。
---@param locked boolean true 表示订单已锁定，应采用保留阶段的停止边界。
---@return table shortages 每项包含原料 signal 和达到阈值仍缺少的 count。
local function recipe_material_shortages(recipe, inventory, multiplier, locked)
  local shortages = {}
  for _, ingredient in pairs(recipe.ingredients) do
    local signal = Util.make_signal(ingredient.type, ingredient.name, "normal")
    -- 红线中不存在对应信号时按库存 0 处理。因此只接绿色订单线不会绕过原料条件；
    -- 必须让配方的每一种原料都通过红线提供足够库存，当前订单才有资格输出。
    local stock = inventory[Util.signal_key(signal)] or 0
    local threshold = ingredient.amount * multiplier
    local insufficient = locked and stock < threshold or not locked and stock <= threshold
    if insufficient then
      -- 启动边界要求严格大于阈值；恰好相等时仍显示至少缺少 1。
      local missing = locked and math.ceil(threshold - stock)
        or math.max(1, math.ceil(threshold - stock))
      shortages[#shortages + 1] = {signal = signal, count = missing}
    end
  end
  return shortages
end

---计算有限缓存最多能容纳多少个完整配方批次，并同比限制固体原料输出。
---所有固体原料共用同一个批次数，因此不会为了填满剩余格子而破坏配方比例。
---液体与 only-in-cursor 特殊物品不能放入普通箱子，不参与格数统计，始终保留完整需求量。
---@param outputs table 未限制的实际原料需求集合。
---@param minimum_outputs table 制造一份配方所需的最少原料集合。
---@param requested_crafts integer 当前商品缺口实际需要的制造次数。
---@param max_slots integer 可用缓存格数；0 表示不限制。
---@return table limited_outputs 应写入红线的原料需求集合。
local function limit_materials_by_cache(outputs, minimum_outputs, requested_crafts, max_slots)
  if max_slots <= 0 then return outputs end
  local solids = {}
  local limited_outputs = {}
  for key, entry in pairs(outputs) do
    local signal_type = entry.signal.type or "item"
    local prototype = signal_type == "item" and prototypes.item[entry.signal.name] or nil
    local cacheable = prototype and not prototype.has_flag("only-in-cursor")
    if cacheable then
      local stack_size = prototype and prototype.stack_size or 1
      solids[#solids + 1] = {
        key = key,
        entry = entry,
        stack_size = stack_size,
        minimum = minimum_outputs[key]
      }
    else
      Util.add_output(limited_outputs, entry.signal, entry.count)
    end
  end
  table.sort(solids, function(a, b) return a.key < b.key end)
  if #solids == 0 then return limited_outputs end

  if max_slots < #solids then
    -- 连“一种可缓存原料一格”都无法满足时，不输出任何可装箱原料，避免产生
    -- 一个天然无法保持完整配方比例的缓存请求。液体等忽略项已保留在 limited_outputs。
    return limited_outputs
  end

  ---计算指定完整制造次数所需占用的固体缓存格数。
  ---@param crafts integer 待评估的完整制造次数。
  ---@return integer slots 所有固体原料向上取整后的总格数。
  local function slots_for_crafts(crafts)
    local slots = 0
    for _, solid in ipairs(solids) do
      local per_craft = solid.minimum and solid.minimum.count or 0
      slots = slots + math.ceil(per_craft * crafts / solid.stack_size)
    end
    return slots
  end

  -- 二分查找可容纳的最大完整批次数；无法组成下一批时，剩余格子按规则保持空闲。
  local low, high, fitted_crafts = 1, requested_crafts, 0
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if slots_for_crafts(middle) <= max_slots then
      fitted_crafts = middle
      low = middle + 1
    else
      high = middle - 1
    end
  end
  for _, solid in ipairs(solids) do
    local count = solid.minimum and solid.minimum.count * fitted_crafts or 0
    if count > 0 then Util.add_output(limited_outputs, solid.entry.signal, count) end
  end
  return limited_outputs
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
  local _, green_signals = Util.read_network(record.entity, defines.wire_connector_id.combinator_input_green)
  local timeout = tonumber(config.production_timeout) or 0
  local reset_signal = config.production_timeout_reset_signal
  local timeout_reset_active = timeout > 0 and Util.signal_count(green_signals, reset_signal) > 0
  local reset_key = reset_signal and Util.signal_key(reset_signal)
  local demands = {}
  -- 重置信号属于控制输入；即使玩家选择物品或配方信号，也不能同时生成一条生产订单。
  for _, demand in pairs(green_signals) do
    if not reset_key or Util.signal_key(demand.signal) ~= reset_key then demands[#demands + 1] = demand end
  end
  local outputs = {}
  local product_outputs = {}
  local material_outputs = {}
  local minimum_material_outputs = {}
  local material_crafts = 0
  table.sort(demands, function(a, b) return Util.signal_key(a.signal) < Util.signal_key(b.signal) end)

  ---判断一个订单在启动或锁定阶段是否仍可执行。
  ---@param demand Signal 当前需求信号及数量。
  ---@param locked boolean 是否为已经启动的订单。
  ---@return LuaRecipePrototype|nil recipe 满足时返回配方，否则返回 nil。
  ---@return table|nil diagnostic 不满足时返回结构化原因，供绿色输入信号悬浮提示复用。
  local function eligible(demand, locked)
    local signal, specified_recipe = Util.resolve_recipe_input(demand.signal, config.production_machine)
    if not Util.is_recipe_input(demand.signal) then return nil, {kind = "unsupported_signal"} end
    if not signal then return nil, {kind = "no_recipe"} end
    if demand.count <= 0 then return nil, {kind = "non_positive_order"} end
    local stock = inventory[Util.signal_key(signal)] or 0
    if locked then
      -- 停止条件：订单一旦启动，就忽略基础订单阈值，继续保持锁定直到扩展目标。
      -- 这样库存处于 [订单量, 扩展目标) 时不会关闭输出后又立刻重新启动。
      -- 达到目标上限时缺口已经为 0，应立即完成当前订单；若仍使用严格大于，
      -- 下游收到 0 后不会继续生产，组合器也就永远无法靠库存增长解除锁定。
      if stock >= demand.count * (1 + config.additional_production_rate) then
        return nil, {kind = "stock_sufficient", stock = stock}
      end
    elseif demand.count <= stock then
      -- 启动条件：只有库存严格小于基础订单量才能选中新订单。
      -- 此处不能使用扩展目标，否则迟滞区间内会反复重新启动，失去防频闪作用。
      return nil, {kind = "stock_sufficient", stock = stock}
    end
    local recipe = Util.find_recipe(record.entity.force, signal, config.production_machine, specified_recipe)
    if not recipe then return nil, {kind = "no_recipe"} end
    local material_rate = locked and (config.material_retention_rate or 1) or config.material_demand_rate
    local shortages = recipe_material_shortages(recipe, inventory, material_rate, locked)
    if #shortages > 0 then return nil, {kind = "materials", shortages = shortages} end
    return recipe, nil, signal
  end

  ---计算产品线路当前应输出的实时生产缺口。
  ---缺口不是“基础订单量 - 库存”，而是“订单量 ×（1 + 额外可生产倍率）- 库存”。
  ---例如订单为 7、倍率为 1、库存为 5，最终目标为 14，输出缺口就是 9。
  ---Factorio 电路信号只能保存整数；目标出现小数时向上取整，才能确保实际库存达到
  ---配置的目标。最后再限制到 int32 范围，使超时比较值与线路实际输出值一致。
  ---@param demand Signal 当前锁定订单。
  ---@return integer count 最终写入产品线路的非负缺口数量。
  local function product_output_count(demand)
    local signal = Util.resolve_recipe_input(demand.signal, config.production_machine)
    local stock = signal and inventory[Util.signal_key(signal)] or 0
    local target = demand.count * (1 + config.additional_production_rate)
    return Util.clamp_int32(math.max(0, math.ceil(target - stock)))
  end

  local selected_demand, selected_recipe, selected_signal
  if config.remember_order and record.remembered_order then
    selected_recipe, _, selected_signal = eligible(record.remembered_order, true)
    if selected_recipe then
      selected_demand = record.remembered_order
    else
      Mode.reset(record)
    end
  elseif record.selected_request then
    for _, demand in ipairs(demands) do
      if Util.signal_key(demand.signal) == record.selected_request then
        selected_recipe, _, selected_signal = eligible(demand, true)
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
    if record.production_order_output_count ~= selected_output_count then
      record.production_order_output_count = selected_output_count
      record.production_order_changed_tick = game.tick
    elseif timeout > 0 then
      if timeout_reset_active then
        record.production_order_changed_tick = game.tick
      else
        local unchanged_ticks = game.tick - (record.production_order_changed_tick or game.tick)
        if unchanged_ticks >= timeout * 60 then
          timed_out_key = selected_key
          Mode.reset(record)
          selected_demand, selected_recipe = nil, nil
        end
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
      local recipe, _, signal = eligible(demand, false)
      if recipe then
        selected_demand, selected_recipe, selected_signal = demand, recipe, signal
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
    local output_count = selected_output_count or product_output_count(selected_demand)
    if config.output_mode ~= "only_material" then
      -- 产品信号表示“额外生产后的目标上限 - 当前库存”的实时缺口。
      Util.add_output(outputs, selected_signal, output_count)
      Util.add_output(product_outputs, selected_signal, output_count)
    end
    if config.output_mode ~= "only_item" then
      -- 材料需求倍率只用于判断订单能否启动，不参与最终输出数量；这里按商品缺口
      -- 向上取整到完整制造次数，保证缺口小于单次产量时仍至少请求一份配方原料。
      local product_amount = Util.recipe_product_amount(selected_recipe, selected_signal)
      local crafts = product_amount > 0 and math.ceil(output_count / product_amount) or 0
      material_crafts = crafts
      for _, ingredient in pairs(selected_recipe.ingredients) do
        local signal = Util.make_signal(ingredient.type, ingredient.name, "normal")
        local count = ingredient.amount * crafts
        Util.add_output(outputs, signal, count)
        Util.add_output(material_outputs, signal, count)
        Util.add_output(minimum_material_outputs, signal, ingredient.amount)
      end
    end
  end

  -- 诊断每个绿色订单信号为什么没有作为产品输出。资格检查与实际选单共用 eligible，
  -- 因此材料阈值、科技和机器限制变化时，悬浮原因不会与线路行为产生两套口径。
  local diagnostics = {}
  local selected_key = selected_demand and Util.signal_key(selected_demand.signal) or nil
  for _, demand in ipairs(demands) do
    local key = Util.signal_key(demand.signal)
    if config.output_mode == "only_material" then
      diagnostics[key] = {kind = "only_material"}
    elseif key ~= selected_key then
      local _, diagnostic = eligible(demand, false)
      diagnostics[key] = diagnostic or {
        kind = "waiting_for_order",
        signal = selected_demand and Util.make_signal(
          selected_demand.signal.type, selected_demand.signal.name, selected_demand.signal.quality) or nil
      }
    end
  end
  record.production_order_diagnostics = diagnostics

  if config.output_mode == "all_separate_signal" then
    -- 分离模式约定：红线只发送配方原料，绿线只发送当前订单商品。
    local limited_materials = limit_materials_by_cache(
      material_outputs, minimum_material_outputs, material_crafts, config.cache_grid_number or 0)
    record.detail_outputs = product_outputs
    return {separated = true, red = limited_materials, green = product_outputs}
  end
  -- 仅原料模式的 product_outputs 为空，因此详细信息模式不会显示产品图标。
  record.detail_outputs = product_outputs
  return outputs
end

return Mode
