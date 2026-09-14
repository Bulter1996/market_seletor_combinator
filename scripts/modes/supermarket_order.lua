-- “超市订单”模式。
-- 本文件封装递归展开、订单与原料迟滞、single 选择以及超时轮换，不依赖 GUI。

local Util = require("scripts.common_util")
local Conditions = require("scripts.conditions")
local PLAN_REVISION = 10
local Mode = {
  name = "supermarket_order",                        -- 模式注册名，必须与 config.lua 的值一致。
  -- 原生 select/max 即使关闭 output_networks，仍会计算输入并把结果显示在实体信息的
  -- 原生“输出信号”字段中。把选择索引固定为 int32 最大值，使任何实际输入集合都没有
  -- 对应项，从计算源头得到空结果，同时继续使用 max_symbol_sprites 显示递归图标。
  -- 真实递归计算和线路输出仍全部由本模块及隐藏代理完成。
  visual_parameters = {operation = "select", select_max = true, index_constant = 2147483647}
}

---只清除当前输出选择；订单迟滞状态由 Mode.reset 决定是否一并清除。
local function reset_output_state(record)
  record.selected_recursion_output = nil
  record.recursion_output_signal = nil
  record.recursion_output_target = nil               -- 旧存档兼容字段；新逻辑不再使用固定库存目标。
  record.recursion_output_count = nil
  record.recursion_output_changed_tick = nil
end

---清除超市订单运行状态，但保留玩家参数。
---@param record table control.lua 保存的组合器记录。
---@return nil
function Mode.reset(record)
  reset_output_state(record)
  record.recursion_order_key = nil
  record.supermarket_active_orders = nil
  record.supermarket_order_diagnostics = nil
  record.recursion_timeout_condition_results = nil
end

---让顺序制作在下一轮从第一个订单重新检索。
---@param record table control.lua 保存的组合器记录。
---@return nil
function Mode.restart_sequence(record)
  Mode.reset(record)
  record.supermarket_sequence_index = 1
  record.supermarket_sequence_signature = nil
end

---清除只属于当前机器和订单输入的配方树；机器或科技变化时调用。
---@param record table control.lua 保存的组合器记录。
---@return nil
function Mode.invalidate_plan(record)
  -- 配方树失效也意味着旧的层级选择不再可信（例如研究变化后配方路径发生改变）。
  Mode.reset(record)
  record.supermarket_order_plan = nil
  record.supermarket_sequence_index = nil
  record.supermarket_sequence_signature = nil
end

---导出超市订单的迟滞与超时状态，供 control.lua 重建实体代理时暂存。
---@param record table 组合器记录。
---@return table state 可写入 storage 的纯 Lua 数据。
function Mode.save_state(record)
  return {
    selected_output = record.selected_recursion_output,
    output_count = record.recursion_output_count,
    changed_tick = record.recursion_output_changed_tick,
    order_key = record.recursion_order_key,
    active_orders = record.supermarket_active_orders,
    sequence_index = record.supermarket_sequence_index,
    sequence_signature = record.supermarket_sequence_signature
  }
end

---恢复 save_state 导出的状态。
---@param record table 新建的组合器记录。
---@param saved table|nil 旧运行状态；旧版本缺失时允许为 nil。
---@return nil
function Mode.restore_state(record, saved)
  saved = saved or {}
  record.selected_recursion_output = saved.selected_output
  record.recursion_output_signal = nil
  record.recursion_output_target = nil
  record.recursion_output_count = saved.output_count
  record.recursion_output_changed_tick = saved.changed_tick
  record.recursion_order_key = saved.order_key
  record.supermarket_active_orders = saved.active_orders
  record.supermarket_sequence_index = saved.sequence_index
  record.supermarket_sequence_signature = saved.sequence_signature
end

---执行超市订单递归计算。
---all 返回展开范围内所有层级的缺口；single 使用材料启动/保留阈值稳定当前层级，避免机械臂
---运输原料时在父产品和原料之间振荡。timeout 可在输出数量长期不变时轮换到下一个结果。
---@param record table 组合器记录，必须包含 entity、config 和本模式运行状态。
---@return table outputs 标准输出集合，由 control.lua 统一负责写入线路。
function Mode.calculate(record)
  -- control.lua 正常会先迁移配置；这里仍允许测试桩或热加载中的残缺记录进入，所有缺省
  -- 字段都按最保守语义处理，避免一次坏记录中断同一 on_nth_tick 内其他运算器。
  local config = type(record.config) == "table" and record.config or {}
  -- Factorio 为选择运算器的红、绿输入端提供不同的 connector id：
  --   * 红线表示玩家已经拥有的库存，用于抵扣需求；
  --   * 绿线表示订单，正数物品/流体才进入配方树。
  -- get_signals 可能返回同一信号的多项，Util.read_network 会先按类型、名称、品质合并。
  local inputs = Conditions.read_inputs(record.entity)
  local observed_inventory = inputs.red
  local raw_demands = inputs.entries.green
  local timeout = tonumber(config.recursion_timeout) or 0
  local additional_rate = math.max(0, tonumber(config.recursion_additional_production_rate) or 0)
  local material_demand_rate = math.max(0, tonumber(config.recursion_material_demand_rate) or 1)
  local material_retention_rate = math.max(0, tonumber(config.recursion_material_retention_rate) or 0)
  local timeout_reset_active, condition_results = Conditions.evaluate(config.recursion_timeout_conditions, inputs)
  record.recursion_timeout_condition_results = condition_results
  timeout_reset_active = timeout > 0 and timeout_reset_active
  local reset_keys = Conditions.signal_keys(config.recursion_timeout_conditions, "green")
  local demands = {}
  -- 控制信号只负责刷新超时起点，不参与配方树和订单变化签名。
  for _, demand in pairs(raw_demands or {}) do
    if type(demand) == "table" and demand.signal and demand.signal.name
      and type(demand.count) == "number" and not reset_keys[Util.signal_key(demand.signal)] then
      demands[#demands + 1] = demand
    end
  end
  table.sort(demands, function(a, b) return Util.signal_key(a.signal) < Util.signal_key(b.signal) end)

  ---订单签名只包含会参与计算的正数产品或配方信号；数量或种类变化都会触发重建。
  local signature_parts = {}
  for _, demand in ipairs(demands) do
    if Util.is_recipe_input(demand.signal) and demand.count > 0 then
      signature_parts[#signature_parts + 1] = Util.signal_key(demand.signal) .. "=" .. tostring(demand.count)
    end
  end
  local order_signature = table.concat(signature_parts, "|")

  ---构建一棵不含 LuaRecipePrototype 等运行时原型对象的配方树，确保能够安全写入 storage。
  ---根订单标记为第 1 层。深度 N 表示允许展开 level <= N 的可制造节点；第一次
  ---超过限制的节点（level=N+1）成为边界输出。0 不设边界，一直展开到无配方或循环。
  local maximum_plan_level = 1
  local terminal_nodes_by_level = {}
  local function remember_terminal_node(node)
    local nodes = terminal_nodes_by_level[node.level]
    if not nodes then nodes = {}; terminal_nodes_by_level[node.level] = nodes end
    nodes[#nodes + 1] = node
  end
  local function build_plan_node(signal, amount, level, ancestors, specified_recipe)
    maximum_plan_level = math.max(maximum_plan_level, level)
    local normalized = Util.make_signal(signal.type, signal.name, signal.quality)
    local key = Util.signal_key(normalized)
    local node = {signal = normalized, amount = amount, level = level, children = {}}
    if ancestors[key] then
      node.cyclic = true
      remember_terminal_node(node)
      return node
    end

    -- machine_material_layer 查询“全局机器配方能力表”：若层级为 1，说明选中机器根本
    -- 不能生产该物品，可直接标记为终端；大于 1 时再调用 find_recipe。find_recipe 会用
    -- entity.force.recipes 检查当前势力是否已经研究解锁，避免使用尚不可用的生产路径。
    local recipe = specified_recipe or (Util.machine_material_layer(normalized, config.production_machine) > 1 and
      Util.find_recipe(record.entity.force, normalized, config.production_machine) or nil)
    local product_amount = recipe and Util.recipe_product_amount(recipe, normalized) or 0
    if not recipe or product_amount <= 0 then
      remember_terminal_node(node)
      return node
    end

    -- storage 不能保存 Factorio 的 LuaRecipePrototype，所以节点只保存配方名称、一次
    -- 产量以及从 recipe.ingredients 抄出的普通 Lua 子节点；后续刷新只遍历这份纯数据。
    node.recipe_name = recipe.name
    node.product_amount = product_amount
    ancestors[key] = true
    for _, ingredient in ipairs(recipe.ingredients or {}) do
      if ingredient and ingredient.name and type(ingredient.amount) == "number" and ingredient.amount > 0 then
        node.children[#node.children + 1] = build_plan_node(
          Util.make_signal(ingredient.type, ingredient.name, "normal"), ingredient.amount, level + 1, ancestors)
      end
    end
    ancestors[key] = nil
    return node
  end

  -- 这份 plan 只属于当前运算器。机器、势力或订单任一变化都会重建；单纯改变递归深度
  -- 不重建树，只从 outputs_by_depth 中选择对应快照，因此参数能在下一刷新周期立即生效。
  local plan = record.supermarket_order_plan
  local plan_is_current = type(plan) == "table" and plan.revision == PLAN_REVISION
    and type(plan.roots) == "table" and type(plan.outputs_by_depth) == "table"
    and type(plan.maximum_level) == "number"
  if not plan_is_current or plan.machine ~= config.production_machine
    or plan.force_index ~= record.entity.force.index
    or plan.order_signature ~= order_signature then
    -- 订单、机器或配方结构变化后，旧订单的迟滞状态不能套用到新配方树。
    record.supermarket_active_orders = {}
    reset_output_state(record)
    record.recursion_order_key = nil
    plan = {
      revision = PLAN_REVISION,
      machine = config.production_machine,
      force_index = record.entity.force.index,
      order_signature = order_signature,
      roots = {},
      outputs_by_depth = {},
      terminal_outputs_by_depth = {},
      boundary_outputs_by_depth = {},
      all_shortages_by_depth = {}
    }
    for _, demand in ipairs(demands) do
      if Util.is_recipe_input(demand.signal) and demand.count > 0 then
        local signal, specified_recipe = Util.resolve_recipe_input(demand.signal, config.production_machine)
        specified_recipe = signal and specified_recipe and Util.find_recipe(
          record.entity.force, signal, config.production_machine, specified_recipe) or nil
        if signal and (demand.signal.type ~= "recipe" or specified_recipe) then
          local root = build_plan_node(signal, demand.count, 1, {}, specified_recipe)
          root.source_key = Util.signal_key(demand.signal)
          plan.roots[#plan.roots + 1] = root
        end
      end
    end
    plan.maximum_level = maximum_plan_level
    plan.terminal_nodes_by_level = terminal_nodes_by_level
    record.supermarket_order_plan = plan
  end

  -- 库存参与每一层的逐项抵扣，所以库存数量变化时需要重新计算各深度快照；排序后的
  -- 签名让 pairs 的不稳定遍历顺序不会制造无意义的缓存失效。
  local inventory_parts = {}
  for key, count in pairs(observed_inventory) do
    inventory_parts[#inventory_parts + 1] = key .. "=" .. tostring(count)
  end
  table.sort(inventory_parts)
  local inventory_signature = table.concat(inventory_parts, "|")

  -- “顺序制作”仅在 single 输出模式生效。游标只向后推进；已完成订单即使随后被下一条
  -- 配方消耗、库存再次下降，也不会重新进入队列。订单输入变化或手动重置才会回到开头。
  local sequential = config.recursion_output_mode == "single" and config.sequential_production ~= false
  local roots_to_resolve = {}
  local root_targets = {}
  local active_order_key = sequential and nil or "*"
  local active_order_keys = {}
  local active_orders = type(record.supermarket_active_orders) == "table"
    and record.supermarket_active_orders or {}
  record.supermarket_active_orders = active_orders
  local completed_order_keys = {}
  if sequential then
    if record.supermarket_sequence_signature ~= order_signature then
      record.supermarket_sequence_signature = order_signature
      record.supermarket_sequence_index = 1
      active_orders = {}
      record.supermarket_active_orders = active_orders
    end
    local sequence_index = math.max(1, math.floor(tonumber(record.supermarket_sequence_index) or 1))
    for index = 1, sequence_index - 1 do
      local completed = plan.roots[index]
      if completed then completed_order_keys[completed.source_key] = true end
    end
    while plan.roots[sequence_index] do
      local root = plan.roots[sequence_index]
      local root_key = Util.signal_key(root.signal)
      local stock = observed_inventory[root_key] or 0
      local extended_target = root.amount * (1 + additional_rate)
      local target = active_orders[root.source_key] and extended_target or root.amount
      if stock < target then
        active_orders = {[root.source_key] = true}
        record.supermarket_active_orders = active_orders
        roots_to_resolve[1] = root
        root_targets[root.source_key] = extended_target
        active_order_key = root.source_key
        active_order_keys[root.source_key] = true
        break
      end
      active_orders[root.source_key] = nil
      completed_order_keys[root.source_key] = true
      sequence_index = sequence_index + 1
    end
    record.supermarket_sequence_index = sequence_index
  else
    -- 非顺序模式允许多个订单同时处于迟滞区间：库存低于基础目标时启动，达到扩展目标后退出。
    for _, root in ipairs(plan.roots) do
      local stock = observed_inventory[Util.signal_key(root.signal)] or 0
      local extended_target = root.amount * (1 + additional_rate)
      local target = active_orders[root.source_key] and extended_target or root.amount
      if stock < target then
        active_orders[root.source_key] = true
        active_order_keys[root.source_key] = true
        roots_to_resolve[#roots_to_resolve + 1] = root
        root_targets[root.source_key] = extended_target
      else
        active_orders[root.source_key] = nil
      end
    end
  end
  -- 顺序订单切换时解除上一条生产链的当前输出；同一订单内仍由原料迟滞保持层级稳定。
  if record.recursion_order_key ~= active_order_key then
    reset_output_state(record)
    record.recursion_order_key = active_order_key
  end

  ---向输出集合累加数量并保留该信号出现过的最深递归层级。
  ---同一物品可能来自多条分支；数量相加，排序层级取最大值，确保底层缺口优先。
  ---@param target table 输出集合。
  ---@param signal SignalID 信号。
  ---@param count number 增量。
  ---@param depth uint 当前节点层级。
  local function add_depth_output(target, signal, count, depth)
    local key = Util.signal_key(signal)
    Util.add_output(target, signal, count)
    target[key].depth = math.max(target[key].depth or 0, depth or 0)
    -- 输出管线只认识通用排序优先级，不需要依赖超市订单的 depth 业务字段。
    target[key].sort_priority = target[key].depth
  end

  ---为指定深度生成完整输出快照；终端材料会自然保留在所有更深的快照中。
  ---@param depth_limit uint 0 表示展开到全部终端节点。
  ---@return table depth_outputs 当前深度对应的完整输出集合。
  ---@return table terminal_by_level 已经无法继续递归的材料，按实际层级分组。
  ---@return table boundary_outputs 因当前深度限制而停止的可递归节点。
  ---@return table ready_outputs 直接材料齐备、当前可开始制造的产品。
  ---@return table all_shortages 当前展开范围内每一层的全部缺口。
  local function calculate_depth_outputs(depth_limit)
    local inventory = {}
    for key, count in pairs(observed_inventory) do inventory[key] = count end
    local terminal_by_level = {}
    local boundary_outputs = {}
    local ready_outputs = {}
    local all_shortages = {}

    -- 每个深度快照使用自己的库存副本。同一种材料出现在多条配方分支时，前面分支消费
    -- 后的库存不会被后面分支重复使用，最终得到的是整张订单需要补齐的真实缺口。
    local function consume_inventory(signal, required)
      local key = Util.signal_key(signal)
      local available = math.max(0, inventory[key] or 0)
      local consumed = math.min(available, required)
      inventory[key] = available - consumed
      return required - consumed
    end

    local selected_key = record.selected_recursion_output

    ---判断当前选中的层级在这棵子树内是否仍处于运行阶段；只读库存，不写输出。
    ---这样铜丝已启动但尚未达到扩展目标时，父级电路板不会在铜丝刚越过启动线后抢走输出。
    local function selected_stage_active(node, base_required, expanded_required)
      local key = Util.signal_key(node.signal)
      local stock = math.max(0, observed_inventory[key] or 0)
      if key == selected_key then
        if stock >= expanded_required then return false end
        local reaches_limit = depth_limit > 0 and node.level > depth_limit
        -- 终端/边界信号只是外部补料请求，本模式无法制造它；父配方一旦重新达到
        -- 材料启动阈值就应继续上移，不能把基础原料锁到整条生产链的扩展总量。
        if node.cyclic or not node.recipe_name or reaches_limit then return false end
        for _, child in ipairs(node.children) do
          local child_stock = math.max(0, observed_inventory[Util.signal_key(child.signal)] or 0)
          if child_stock < child.amount * material_retention_rate then return false end
        end
        return true
      end
      if node.cyclic or not node.recipe_name or (depth_limit > 0 and node.level > depth_limit) then
        return false
      end
      local base_crafts = math.ceil(base_required / node.product_amount)
      local expanded_crafts = math.ceil(expanded_required / node.product_amount)
      for _, child in ipairs(node.children) do
        if selected_stage_active(
          child, child.amount * base_crafts, child.amount * expanded_crafts) then return true end
      end
      return false
    end

    -- 每个递归节点都同时携带基础目标和扩展目标。未启动时仅在库存低于基础目标时进入；
    -- 一旦成为当前输出，则保持到扩展目标，或任一直接原料跌破保留倍率。
    local function resolve(node, base_required, expanded_required, suppress_stage_output, force_active)
      if expanded_required <= 0 then return end
      local key = Util.signal_key(node.signal)
      local stock = math.max(0, inventory[key] or 0)
      local base_shortage = math.max(0, base_required - stock)
      local expanded_shortage = consume_inventory(node.signal, expanded_required)
      if expanded_shortage <= 0 then return end
      add_depth_output(all_shortages, node.signal, math.ceil(expanded_shortage), node.level)

      local selected = key == selected_key
      local should_run = selected or force_active or base_shortage > 0
      local reaches_limit = depth_limit > 0 and node.level > depth_limit
      if node.cyclic or not node.recipe_name then
        if should_run and not suppress_stage_output then
          local terminal_outputs = terminal_by_level[node.level]
          if not terminal_outputs then terminal_outputs = {}; terminal_by_level[node.level] = terminal_outputs end
          add_depth_output(terminal_outputs, node.signal, math.ceil(expanded_shortage), node.level)
        end
        return
      end
      if reaches_limit then
        if should_run and not suppress_stage_output then
          add_depth_output(boundary_outputs, node.signal, math.ceil(expanded_shortage), node.level)
        end
        return
      end

      local material_rate = selected and material_retention_rate or material_demand_rate
      local direct_materials_ready = true
      for _, child in ipairs(node.children) do
        local child_stock = math.max(0, inventory[Util.signal_key(child.signal)] or 0)
        local threshold = child.amount * material_rate
        local insufficient = selected and child_stock < threshold or not selected and child_stock <= threshold
        if insufficient then direct_materials_ready = false; break end
      end
      local base_crafts = math.ceil(base_required / node.product_amount)
      local expanded_crafts = math.ceil(expanded_required / node.product_amount)
      local descendant_active = not selected and selected_stage_active(node, base_required, expanded_required)
      local output_current = should_run and direct_materials_ready and not descendant_active
      if output_current and not suppress_stage_output then
        add_depth_output(ready_outputs, node.signal, math.ceil(expanded_shortage), node.level)
      end

      -- 当前层可以运行时，子层只继续统计 all 缺口；当前层不能运行或仍有已启动的子层时，
      -- 继续向下寻找真正需要输出的层级，并为每层沿用同一组基础/扩展目标。
      local suppress_children = suppress_stage_output or output_current
      for _, child in ipairs(node.children) do
        resolve(child, child.amount * base_crafts, child.amount * expanded_crafts,
          suppress_children, false)
      end
    end

    for _, root in ipairs(roots_to_resolve) do
      resolve(root, root.amount, root_targets[root.source_key] or root.amount, false, true)
    end
    -- 当前深度的边界材料与所有此前已经终止的材料共同组成最终输出。终端材料按层级
    -- 独立保存后再合并，确保增加深度时不会因为它没有 children 而从结果中消失。
    local depth_outputs = {}
    for _, entry in pairs(ready_outputs) do
      add_depth_output(depth_outputs, entry.signal, entry.count, entry.depth)
    end
    for _, entry in pairs(boundary_outputs) do
      add_depth_output(depth_outputs, entry.signal, entry.count, entry.depth)
    end
    for _, terminal_outputs in pairs(terminal_by_level) do
      for _, entry in pairs(terminal_outputs) do
        add_depth_output(depth_outputs, entry.signal, entry.count, entry.depth)
      end
    end
    return depth_outputs, terminal_by_level, boundary_outputs, ready_outputs, all_shortages
  end

  -- 红线库存也是输入数据；订单或库存变化时一次性更新所有深度对应的输出表。
  local calculation_signature = inventory_signature .. "|sequential=" .. tostring(sequential)
    .. "|active-order=" .. tostring(active_order_key)
    .. "|selected=" .. tostring(record.selected_recursion_output)
    .. "|additional=" .. tostring(additional_rate)
    .. "|demand=" .. tostring(material_demand_rate)
    .. "|retention=" .. tostring(material_retention_rate)
  if plan.inventory_signature ~= calculation_signature then
    plan.outputs_by_depth = {}
    plan.terminal_outputs_by_depth = {}
    plan.boundary_outputs_by_depth = {}
    plan.ready_outputs_by_depth = {}
    plan.all_shortages_by_depth = {}
    local outputs, terminals, boundary, ready, all_shortages = calculate_depth_outputs(0)
    plan.outputs_by_depth[0] = outputs
    plan.terminal_outputs_by_depth[0] = terminals
    plan.boundary_outputs_by_depth[0] = boundary
    plan.ready_outputs_by_depth[0] = ready
    plan.all_shortages_by_depth[0] = all_shortages
    for depth = 1, plan.maximum_level do
      outputs, terminals, boundary, ready, all_shortages = calculate_depth_outputs(depth)
      plan.outputs_by_depth[depth] = outputs
      plan.terminal_outputs_by_depth[depth] = terminals
      plan.boundary_outputs_by_depth[depth] = boundary
      plan.ready_outputs_by_depth[depth] = ready
      plan.all_shortages_by_depth[depth] = all_shortages
    end
    plan.inventory_signature = calculation_signature
  end

  local wanted_depth = math.max(0, math.floor(tonumber(config.recurise_depth) or 0))
  -- maximum_level 是这张订单实际能到达的最深节点。例如树只到第 3 层时，深度 10
  -- 与深度 3 的含义完全相同。必须先钳制到最大有效层，不能直接读取不存在的 [10]。
  -- 深度 0 保留为“不限制”的专用快照；防御性 fallback 只处理旧存档或损坏缓存。
  local maximum_depth = math.max(1, plan.maximum_level or 1)
  local effective_depth = wanted_depth == 0 and 0 or math.min(wanted_depth, maximum_depth)
  local output_cache = config.recursion_output_mode == "all" and plan.all_shortages_by_depth
    or plan.outputs_by_depth
  local cached_outputs = output_cache[effective_depth]
    or output_cache[0]
    or {}
  if type(cached_outputs) ~= "table" then cached_outputs = {} end
  -- single 模式会改写锁定信号数量，必须复制快照，不能污染缓存表。
  local outputs = {}
  for key, entry in pairs(cached_outputs) do
    outputs[key] = {
      signal = Util.make_signal(entry.signal.type, entry.signal.name, entry.signal.quality),
      count = entry.count,
      depth = entry.depth,
      sort_priority = entry.sort_priority
    }
  end

  ---记录每个绿色订单信号当前未直接输出的原因，供公共信号面板悬浮提示。
  ---@param final_outputs table 本轮实际输出。
  local function update_diagnostics(final_outputs)
    local diagnostics = {}
    local active_signal
    for _, root in ipairs(plan.roots) do
      if root.source_key == active_order_key then active_signal = root.signal; break end
    end
    for _, demand in ipairs(demands) do
      local source_key = Util.signal_key(demand.signal)
      local signal, specified_recipe = Util.resolve_recipe_input(demand.signal, config.production_machine)
      local diagnostic
      if not Util.is_recipe_input(demand.signal) then
        diagnostic = {kind = "unsupported_signal"}
      elseif demand.count <= 0 then
        diagnostic = {kind = "non_positive_order"}
      elseif not signal or (specified_recipe and not Util.find_recipe(
        record.entity.force, signal, config.production_machine, specified_recipe)) then
        diagnostic = {kind = "no_recipe"}
      elseif sequential and completed_order_keys[source_key] then
        diagnostic = {kind = "supermarket_completed"}
      elseif sequential and active_order_key and source_key ~= active_order_key then
        diagnostic = {kind = "waiting_for_order", signal = active_signal}
      elseif active_order_keys[source_key] then
        diagnostic = final_outputs[Util.signal_key(signal)] and {kind = "active_output"}
          or {kind = "supermarket_expanding"}
      elseif not final_outputs[Util.signal_key(signal)] then
        local stock = observed_inventory[Util.signal_key(signal)] or 0
        diagnostic = stock >= demand.count and {kind = "stock_sufficient", stock = stock}
          or {kind = "supermarket_expanding"}
      end
      diagnostics[source_key] = diagnostic
    end
    record.supermarket_order_diagnostics = diagnostics
  end

  if config.recursion_output_mode == "all" then
    reset_output_state(record)
    update_diagnostics(outputs)
    return outputs
  end

  ---选择 single 当前输出。原先的固定库存目标已移除，层级稳定改由材料启动/保留倍率负责。
  local function select_output(key)
    local entry = key and outputs[key]
    record.selected_recursion_output = key
    record.recursion_output_count = entry and entry.count or nil
    record.recursion_output_changed_tick = game.tick
  end

  local selected_key = record.selected_recursion_output
  if not (selected_key and outputs[selected_key]) then
    local ordered = Util.sorted_outputs(outputs)
    selected_key = ordered[1] and ordered[1].key or nil
    select_output(selected_key)
  end
  if not selected_key then
    update_diagnostics({})
    return {}
  end

  local current_count = outputs[selected_key].count
  if record.recursion_output_count ~= current_count then
    record.recursion_output_count = current_count
    record.recursion_output_changed_tick = game.tick
  elseif timeout > 0 then
    if timeout_reset_active then
      record.recursion_output_changed_tick = game.tick
    else
      local unchanged_ticks = game.tick - (record.recursion_output_changed_tick or game.tick)
      if unchanged_ticks >= timeout * 60 then
        local keys = {}
        for _, value in ipairs(Util.sorted_outputs(outputs)) do keys[#keys + 1] = value.key end
        local next_key = keys[1]
        for index, key in ipairs(keys) do
          if key == selected_key then next_key = keys[index + 1] or keys[1]; break end
        end
        selected_key = next_key
        select_output(selected_key)
      end
    end
  end
  local final_outputs = {[selected_key] = outputs[selected_key]}
  update_diagnostics(final_outputs)
  return final_outputs
end

return Mode
