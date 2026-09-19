-- “生产订单”模式。
-- 本文件只实现该模式的选择、记忆与迟滞规则；线路和配方等通用操作来自 common_util。

local Util = require("scripts.common_util")
local Conditions = require("scripts.conditions")
local Mode = {
  name = "production_order",                         -- 模式注册名，必须与 config.lua 的值一致。
  visual_operation = "count"                         -- 仅借用原版“输入计数”的 # 屏幕动画。
}

local function clear_current_order(record)
  record.selected_request = nil
  record.remembered_order = nil
  record.production_order_output_count = nil
  record.production_order_changed_tick = nil
  if record.config and record.config.mode == Mode.name then record.detail_outputs = nil end
end

---清除生产订单模式的临时运行状态，但不修改玩家配置。
---@param record table control.lua 保存的组合器记录。
---@return nil
function Mode.reset(record)
  clear_current_order(record)
  record.production_order_queue = nil
  record.production_order_diagnostics = nil
  record.production_timeout_condition_results = nil
end

---导出需要随存档配置重建保留的模式运行状态。
---@param record table 组合器记录。
---@return table state 不包含实体和玩家配置的纯 Lua 数据。
function Mode.save_state(record)
  return {
    selected_request = record.selected_request,
    remembered_order = record.remembered_order,
    queue = record.production_order_queue,
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
  record.production_order_queue = saved.queue
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

---执行生产订单计算。
---新订单在商品库存低于订单量且原料达到需求阈值时启动；锁定后到商品达到上限或
---原料下降到保留阈值时结束。开启记忆后，绿色订单消失也不会立即取消当前订单；
---production_timeout 大于 0 时，产品输出值长期无变化也会触发订单轮换。
---@param record table 组合器记录，必须包含 entity、config 和本模式运行状态。
---@return table outputs 标准输出集合，由 control.lua 统一写入隐藏代理。
function Mode.calculate(record)
  local config = record.config
  local inputs = Conditions.read_inputs(record.entity)
  local inventory = inputs.red
  local green_signals = inputs.entries.green
  local timeout = tonumber(config.production_timeout) or 0
  local timeout_reset_active, condition_results = Conditions.evaluate(config.production_timeout_conditions, inputs)
  record.production_timeout_condition_results = condition_results
  timeout_reset_active = timeout > 0 and timeout_reset_active
  local reset_keys = Conditions.signal_keys(config.production_timeout_conditions, "green")
  local demands = {}
  -- 条件中启用绿色线路的信号属于控制输入，不能同时生成生产订单。
  for _, demand in pairs(green_signals) do
    if not reset_keys[Util.signal_key(demand.signal)] then demands[#demands + 1] = demand end
  end
  local outputs = {}
  local product_outputs = {}
  local material_crafts = 0
  table.sort(demands, function(a, b) return Util.signal_key(a.signal) < Util.signal_key(b.signal) end)

  -- 队列只保存仍存在的订单键；已有键保持轮转后的顺序，新输入按稳定排序追加。
  local demands_by_key, present, queued = {}, {}, {}
  for _, demand in ipairs(demands) do
    local key = Util.signal_key(demand.signal)
    demands_by_key[key], present[key] = demand, true
  end
  local order_queue = {}
  for _, key in ipairs(type(record.production_order_queue) == "table"
    and record.production_order_queue or {}) do
    if present[key] and not queued[key] then
      order_queue[#order_queue + 1], queued[key] = key, true
    end
  end
  for _, demand in ipairs(demands) do
    local key = Util.signal_key(demand.signal)
    if not queued[key] then order_queue[#order_queue + 1], queued[key] = key, true end
  end
  record.production_order_queue = order_queue

  local function move_order_to_back(key)
    for index, queued_key in ipairs(order_queue) do
      if queued_key == key then table.remove(order_queue, index); break end
    end
    if present[key] then order_queue[#order_queue + 1] = key end
  end

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
  local selected_was_locked = false
  if config.remember_order and record.remembered_order then
    selected_recipe, _, selected_signal = eligible(record.remembered_order, true)
    if selected_recipe then
      selected_demand = record.remembered_order
      selected_was_locked = true
    else
      clear_current_order(record)
    end
  elseif record.selected_request then
    for _, demand in ipairs(demands) do
      if Util.signal_key(demand.signal) == record.selected_request then
        selected_recipe, _, selected_signal = eligible(demand, true)
        if selected_recipe then
          selected_demand = demand
          selected_was_locked = true
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

  -- 超时可选监控最终写入线路的产品数量；关闭后，数量变化只更新比较基准，不刷新计时。
  local selected_output_count
  if selected_demand then
    local selected_key = Util.signal_key(selected_demand.signal)
    selected_output_count = product_output_count(selected_demand)
    local output_changed = record.production_order_output_count ~= selected_output_count
    local reset_by_output = record.production_order_changed_tick == nil
      or output_changed and config.production_timeout_monitor_item_changes ~= false
    if output_changed then
      record.production_order_output_count = selected_output_count
    end
    if reset_by_output then
      record.production_order_changed_tick = game.tick
    elseif timeout > 0 then
      if timeout_reset_active then
        record.production_order_changed_tick = game.tick
      else
        local unchanged_ticks = game.tick - (record.production_order_changed_tick or game.tick)
        if unchanged_ticks >= timeout * 60 then
          move_order_to_back(selected_key)
          clear_current_order(record)
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
    -- 超时订单已经被移到队尾；后续订单即使完成，也继续从队首向后扫描，不会让它插队。
    for _, key in ipairs(order_queue) do
      local demand = demands_by_key[key]
      local recipe, _, signal = eligible(demand, false)
      if recipe then
        selected_demand, selected_recipe, selected_signal = demand, recipe, signal
        selected_was_locked = false
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

  ---为有缺口且可制造的直接原料补充下一层配方明细；只展开一层，避免悬浮信息无限增长。
  local function next_level_production(signal, shortage)
    if shortage <= 0 then return nil end
    local recipe = Util.find_recipe(record.entity.force, signal, config.production_machine)
    local product_amount = recipe and Util.recipe_product_amount(recipe, signal) or 0
    if product_amount <= 0 then return nil end
    local crafts = math.ceil(shortage / product_amount)
    local ingredients = {}
    for _, ingredient in pairs(recipe.ingredients or {}) do
      local child_signal = Util.make_signal(ingredient.type, ingredient.name, "normal")
      local required = ingredient.amount * crafts
      local stock = inventory[Util.signal_key(child_signal)] or 0
      ingredients[#ingredients + 1] = {
        signal = child_signal,
        required = required,
        stock = stock,
        shortage = math.max(0, required - stock)
      }
    end
    table.sort(ingredients, function(a, b)
      return Util.signal_key(a.signal) < Util.signal_key(b.signal)
    end)
    return {
      signal = Util.make_signal(signal.type, signal.name, signal.quality),
      count = math.ceil(crafts * product_amount),
      ingredients = ingredients
    }
  end

  local selected_diagnostic
  if selected_demand then
    local output_count = selected_output_count or product_output_count(selected_demand)
    local output_signal = selected_demand.signal.type == "recipe"
      and Util.make_signal("recipe", selected_demand.signal.name) or selected_signal
    if config.output_mode ~= "only_material" then
      -- 配方订单内部仍按产品计算库存和缺口，但输出保留玩家输入的原配方信号。
      Util.add_output(outputs, output_signal, output_count)
      Util.add_output(product_outputs, output_signal, output_count)
    end
    -- 诊断与线路输出共用同一制造次数，确保“本次需要”和实际材料信号口径一致。
    -- 即使选择“仅产品”，悬浮信息仍展示完成当前缺口需要的全部直接原料。
    local product_amount = Util.recipe_product_amount(selected_recipe, selected_signal)
    local crafts = product_amount > 0 and math.ceil(output_count / product_amount) or 0
    material_crafts = crafts
    local ingredients = {}
    local gate_rate = selected_was_locked and (config.material_retention_rate or 1)
      or config.material_demand_rate
    local gate_ready = true
    for _, ingredient in pairs(selected_recipe.ingredients) do
      local signal = Util.make_signal(ingredient.type, ingredient.name, "normal")
      local count = ingredient.amount * crafts
      local stock = inventory[Util.signal_key(signal)] or 0
      local threshold = ingredient.amount * gate_rate
      local ready = selected_was_locked and stock >= threshold or not selected_was_locked and stock > threshold
      local shortage = math.max(0, count - stock)
      ingredients[#ingredients + 1] = {
        signal = signal,
        required = count,
        stock = stock,
        shortage = shortage,
        start_threshold = threshold,
        threshold_comparator = selected_was_locked and ">=" or ">",
        start_ready = ready,
        production = next_level_production(signal, shortage)
      }
      gate_ready = gate_ready and ready
      if config.output_mode ~= "only_item" then
        Util.add_output(outputs, signal, count)
      end
    end
    table.sort(ingredients, function(a, b)
      return Util.signal_key(a.signal) < Util.signal_key(b.signal)
    end)

    local product_stock = inventory[Util.signal_key(selected_signal)] or 0
    local target = math.ceil(selected_demand.count * (1 + config.additional_production_rate))
    selected_diagnostic = {
      kind = "active_output",
      order = {
        signal = Util.make_signal(selected_demand.signal.type, selected_demand.signal.name,
          selected_demand.signal.quality),
        count = selected_demand.count
      },
      product = {
        signal = Util.make_signal(selected_signal.type, selected_signal.name, selected_signal.quality),
        target = target,
        stock = product_stock,
        remaining = output_count
      },
      stage = {
        -- 订单行已经保留原始配方信号；“当前计划制作”应显示配方实际产出的产品。
        signal = Util.make_signal(selected_signal.type, selected_signal.name, selected_signal.quality),
        level = 1,
        target = target,
        stock = product_stock,
        output_count = output_count,
        ingredients = ingredients,
        gate_kind = selected_was_locked and "retention" or "start",
        start_ready = gate_ready,
        product_output = config.output_mode ~= "only_material",
        material_output = config.output_mode ~= "only_item"
      }
    }
  end

  -- 诊断每个绿色订单信号为什么没有作为产品输出。资格检查与实际选单共用 eligible，
  -- 因此材料阈值、科技和机器限制变化时，悬浮原因不会与线路行为产生两套口径。
  local diagnostics = {}
  local selected_key = selected_demand and Util.signal_key(selected_demand.signal) or nil
  for _, demand in ipairs(demands) do
    local key = Util.signal_key(demand.signal)
    if key == selected_key then
      diagnostics[key] = selected_diagnostic or {kind = "active_output"}
    elseif config.output_mode == "only_material" then
      diagnostics[key] = {kind = "only_material"}
    else
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
    local requirements = selected_recipe and {{recipe = selected_recipe, crafts = material_crafts}} or {}
    local limited_materials = Util.limit_recipe_materials_by_cache(
      requirements, config.cache_grid_number or 0)
    record.detail_outputs = product_outputs
    return {separated = true, red = limited_materials, green = product_outputs}
  end
  -- 仅原料模式的 product_outputs 为空，因此详细信息模式不会显示产品图标。
  record.detail_outputs = product_outputs
  return outputs
end

return Mode
