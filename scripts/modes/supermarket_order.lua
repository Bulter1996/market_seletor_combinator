-- “超市订单”模式。
-- 本文件封装递归展开、single 锁定、目标库存迟滞以及超时轮换，不依赖 GUI。

local Util = require("scripts.common_util")
local PLAN_REVISION = 6
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
  record.recursion_order_key = nil
end

---清除只属于当前机器和订单输入的配方树；机器或科技变化时调用。
---@param record table control.lua 保存的组合器记录。
---@return nil
function Mode.invalidate_plan(record)
  -- 配方树失效也意味着旧的单项锁定不再可信（例如研究变化后配方路径发生改变）。
  Mode.reset(record)
  record.supermarket_order_plan = nil
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
    changed_tick = record.recursion_output_changed_tick,
    order_key = record.recursion_order_key
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
  record.recursion_order_key = saved.order_key
end

---执行超市订单递归计算。
---all 返回全部递归终点；single 锁定一个结果到目标库存满足，避免机械臂抓取原料时
---在父产品和原料之间振荡。timeout 可在输出数量长期不变时轮换到下一个结果。
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
  local observed_inventory = Util.read_network(record.entity, defines.wire_connector_id.combinator_input_red)
  local _, raw_demands = Util.read_network(record.entity, defines.wire_connector_id.combinator_input_green)
  local demands = {}
  for _, demand in pairs(raw_demands or {}) do
    if type(demand) == "table" and Util.is_recipe_signal(demand.signal)
      and type(demand.count) == "number" then
      demands[#demands + 1] = demand
    end
  end
  table.sort(demands, function(a, b) return Util.signal_key(a.signal) < Util.signal_key(b.signal) end)

  ---订单签名只包含会参与计算的正数物品/流体信号；数量或种类变化都会触发重建。
  local signature_parts = {}
  for _, demand in ipairs(demands) do
    if Util.is_recipe_signal(demand.signal) and demand.count > 0 then
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
  local function build_plan_node(signal, amount, level, ancestors)
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
    local recipe = Util.machine_material_layer(normalized, config.production_machine) > 1 and
      Util.find_recipe(record.entity.force, normalized, config.production_machine) or nil
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
    plan = {
      revision = PLAN_REVISION,
      machine = config.production_machine,
      force_index = record.entity.force.index,
      order_signature = order_signature,
      roots = {},
      outputs_by_depth = {},
      terminal_outputs_by_depth = {},
      boundary_outputs_by_depth = {}
    }
    for _, demand in ipairs(demands) do
      if Util.is_recipe_signal(demand.signal) and demand.count > 0 then
        plan.roots[#plan.roots + 1] = build_plan_node(demand.signal, demand.count, 1, {})
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

  -- “顺序制作”仅在 single 输出模式生效。订单根节点已经按信号键稳定排序；从前向后
  -- 找到第一个库存小于订单数量的商品后，本轮只展开它，其余订单暂时忽略。该商品库存
  -- 达标后，下一刷新周期自然选择后一个订单。关闭顺序制作或使用 all 时仍展开全部根。
  local sequential = config.recursion_output_mode == "single" and config.sequential_production ~= false
  local roots_to_resolve = plan.roots
  local active_order_key = "*"
  if sequential then
    roots_to_resolve = {}
    active_order_key = nil
    for _, root in ipairs(plan.roots) do
      local root_key = Util.signal_key(root.signal)
      if (observed_inventory[root_key] or 0) < root.amount then
        roots_to_resolve[1] = root
        active_order_key = root_key
        break
      end
    end
  end
  -- 切换到下一个订单时必须解除上一订单留下的单信号目标锁定，否则旧材料可能继续输出。
  if record.recursion_order_key ~= active_order_key then
    Mode.reset(record)
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
  local function calculate_depth_outputs(depth_limit)
    local inventory = {}
    for key, count in pairs(observed_inventory) do inventory[key] = count end
    local terminal_by_level = {}
    local boundary_outputs = {}
    local ready_outputs = {}

    -- 每个深度快照使用自己的库存副本。同一种材料出现在多条配方分支时，前面分支消费
    -- 后的库存不会被后面分支重复使用，最终得到的是整张订单需要补齐的真实缺口。
    local function consume_inventory(signal, required)
      local key = Util.signal_key(signal)
      local available = math.max(0, inventory[key] or 0)
      local consumed = math.min(available, required)
      inventory[key] = available - consumed
      return required - consumed
    end

    -- required 是当前节点需要的数量。可制造节点按目标平均产量向上取整得到制造次数，
    -- 再把每种 recipe ingredient 的数量乘以制造次数，递归传给下一层。
    local function resolve(node, required)
      if required <= 0 then return true end
      local shortage = consume_inventory(node.signal, required)
      -- true 表示当前库存已经拥有该节点所需数量，父节点可把它视为“材料已就绪”。
      if shortage <= 0 then return true end
      local reaches_limit = depth_limit > 0 and node.level > depth_limit
      -- 没有配方以及祖先链循环都属于“不能继续递归”的终端材料。它们按实际 level
      -- 单独累计，并在任何更深的输出快照中保留，避免增加深度后基础材料消失。
      if node.cyclic or not node.recipe_name then
        local terminal_outputs = terminal_by_level[node.level]
        if not terminal_outputs then terminal_outputs = {}; terminal_by_level[node.level] = terminal_outputs end
        add_depth_output(terminal_outputs, node.signal, math.ceil(shortage), node.level)
        return false
      end
      -- 节点本身有配方，但已经越过用户允许展开的层数：不再拆分，直接作为边界物料。
      if reaches_limit then
        add_depth_output(boundary_outputs, node.signal, math.ceil(shortage), node.level)
        return false
      end
      local crafts = math.ceil(shortage / node.product_amount)
      local all_ingredients_ready = true
      for _, child in ipairs(node.children) do
        if not resolve(child, child.amount * crafts) then all_ingredients_ready = false end
      end
      -- 当前产品还缺，但本次制造需要的全部直接材料已经在红线库存中：此时不能返回空，
      -- 而应输出当前产品让装配机开始合成。这样库存满足后，输出会从底层逐级回退到成品。
      if all_ingredients_ready then
        add_depth_output(ready_outputs, node.signal, math.ceil(shortage), node.level)
      end
      return false
    end

    for _, root in ipairs(roots_to_resolve) do resolve(root, root.amount) end
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
    return depth_outputs, terminal_by_level, boundary_outputs, ready_outputs
  end

  -- 红线库存也是输入数据；订单或库存变化时一次性更新所有深度对应的输出表。
  local calculation_signature = inventory_signature .. "|sequential=" .. tostring(sequential)
    .. "|active-order=" .. tostring(active_order_key)
  if plan.inventory_signature ~= calculation_signature then
    plan.outputs_by_depth = {}
    plan.terminal_outputs_by_depth = {}
    plan.boundary_outputs_by_depth = {}
    plan.ready_outputs_by_depth = {}
    local outputs, terminals, boundary, ready = calculate_depth_outputs(0)
    plan.outputs_by_depth[0] = outputs
    plan.terminal_outputs_by_depth[0] = terminals
    plan.boundary_outputs_by_depth[0] = boundary
    plan.ready_outputs_by_depth[0] = ready
    for depth = 1, plan.maximum_level do
      outputs, terminals, boundary, ready = calculate_depth_outputs(depth)
      plan.outputs_by_depth[depth] = outputs
      plan.terminal_outputs_by_depth[depth] = terminals
      plan.boundary_outputs_by_depth[depth] = boundary
      plan.ready_outputs_by_depth[depth] = ready
    end
    plan.inventory_signature = calculation_signature
  end

  local wanted_depth = math.max(0, math.floor(tonumber(config.recurise_depth) or 0))
  -- maximum_level 是这张订单实际能到达的最深节点。例如树只到第 3 层时，深度 10
  -- 与深度 3 的含义完全相同。必须先钳制到最大有效层，不能直接读取不存在的 [10]。
  -- 深度 0 保留为“不限制”的专用快照；防御性 fallback 只处理旧存档或损坏缓存。
  local maximum_depth = math.max(1, plan.maximum_level or 1)
  local effective_depth = wanted_depth == 0 and 0 or math.min(wanted_depth, maximum_depth)
  local cached_outputs = plan.outputs_by_depth[effective_depth]
    or plan.outputs_by_depth[0]
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
      outputs[selected_key] = {
        signal = record.recursion_output_signal,
        count = math.ceil(remaining),
        depth = outputs[selected_key] and outputs[selected_key].depth or 0,
        sort_priority = outputs[selected_key] and outputs[selected_key].sort_priority or 0
      }
    else
      selected_key = nil
      lock_output(nil)
    end
  end

  if not (selected_key and outputs[selected_key]) then
    local ordered = Util.sorted_outputs(outputs)
    selected_key = ordered[1] and ordered[1].key or nil
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
      for _, value in ipairs(Util.sorted_outputs(outputs)) do keys[#keys + 1] = value.key end
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
