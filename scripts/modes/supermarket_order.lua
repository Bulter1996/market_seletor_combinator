-- “超市订单”模式。
-- 本文件封装递归展开、订单与原料迟滞、single 选择以及超时轮换，不依赖 GUI。

local Util = require("scripts.common_util")
local Conditions = require("scripts.conditions")
local OrderTarget = require("scripts.order_target")
local Config = require("scripts.config")
local InventoryQuery = require("scripts.modes.inventory_query")
local Policy = require("scripts.recipe_policy")
local Network = require("scripts.production_network")
local PLAN_REVISION = 20
local Mode = {
  name = "supermarket_order",                        -- 模式注册名，必须与 config.lua 的值一致。
  -- 原生 select/max 即使关闭 output_networks，仍会计算输入并把结果显示在实体信息的
  -- 原生“输出信号”字段中。把选择索引固定为 int32 最大值，使任何实际输入集合都没有
  -- 对应项，从计算源头得到空结果，同时继续使用 max_symbol_sprites 显示递归图标。
  -- 真实递归计算和线路输出仍全部由本模块及隐藏代理完成。
  visual_parameters = {operation = "select", select_max = true, index_constant = 2147483647}
}

---判断机器或配方原型的地表条件是否全部满足。
local function surface_conditions_met(surface, conditions)
  if type(conditions) ~= "table" or not next(conditions) then return true end
  if not (surface and surface.get_property) then return false end
  for _, condition in pairs(conditions) do
    local value = surface.get_property(condition.property)
    if type(value) ~= "number" or condition.min and value < condition.min
      or condition.max and value > condition.max then return false end
  end
  return true
end

---只清除当前输出选择；订单迟滞状态由 Mode.reset 决定是否一并清除。
local function reset_output_state(record)
  record.selected_recursion_output = nil
  record.recursion_output_signal = nil
  record.recursion_output_target = nil               -- 旧存档兼容字段；新逻辑不再使用固定库存目标。
  record.recursion_output_count = nil
  record.recursion_output_changed_tick = nil
  record.recursion_material_wait_tick = nil
  record.recursion_material_wait_output = nil
  record.detail_outputs = nil
end

---清除超市订单运行状态，但保留玩家参数。
---@param record table control.lua 保存的组合器记录。
---@return nil
function Mode.reset(record)
  reset_output_state(record)
  record.recursion_order_key = nil
  record.supermarket_active_orders = nil
  record.supermarket_order_candidates = nil
  record.supermarket_order_diagnostics = nil
  record.supermarket_next_order_key = nil
  record.supermarket_sequence_completed_orders = nil
  record.recursion_timeout_condition_results = nil
  record.recursion_inventory_pending_tick = nil
  record.recursion_inventory_protection_tick = nil
  record.recursion_inventory_shortages = nil
  record.recursion_linked_last_outputs = nil
end

---后移 single 当前订单；顺序模式推进游标，非顺序模式选择下一个有候选输出的订单。
---@param record table 组合器记录。
---@param source_key string 被右键点击的绿色订单信号键。
---@return boolean deferred 当前订单确实被后移时返回 true。
function Mode.defer_current_order(record, source_key)
  local config = type(record.config) == "table" and record.config or {}
  if config.recursion_output_mode ~= "single" or record.recursion_order_key ~= source_key then return false end
  local roots = record.supermarket_order_plan and record.supermarket_order_plan.roots or {}
  for index, root in ipairs(roots) do
    if root.source_key == source_key then
      if config.sequential_production ~= false then
        record.supermarket_sequence_index = index % #roots + 1
        if type(record.supermarket_active_orders) == "table" then
          record.supermarket_active_orders[source_key] = nil
        end
        reset_output_state(record)
        record.recursion_order_key = nil
        return true
      end
      local candidates = type(record.supermarket_order_candidates) == "table"
        and record.supermarket_order_candidates or {}
      for offset = 1, #roots - 1 do
        local next_root = roots[(index + offset - 1) % #roots + 1]
        local next_candidates = candidates[next_root.source_key]
        if next_candidates and next_candidates[1] then
          reset_output_state(record)
          record.selected_recursion_output = next_candidates[1]
          record.recursion_order_key = next_root.source_key
          return true
        end
      end
      return false
    end
  end
  return false
end

---把双击的等待订单提升为 single 当前项。
---@param record table 组合器记录。
---@param source_key string 被双击的绿色订单信号键。
---@return boolean prioritized 目标确实是等待订单时返回 true。
function Mode.prioritize_waiting_order(record, source_key)
  local config = type(record.config) == "table" and record.config or {}
  local diagnostic = type(record.supermarket_order_diagnostics) == "table"
    and record.supermarket_order_diagnostics[source_key] or nil
  if config.recursion_output_mode ~= "single"
    or not diagnostic or diagnostic.kind ~= "waiting_for_order" then return false end
  if config.sequential_production == false then
    local candidates = type(record.supermarket_order_candidates) == "table"
      and record.supermarket_order_candidates[source_key] or nil
    if not (candidates and candidates[1]) then return false end
    reset_output_state(record)
    record.selected_recursion_output = candidates[1]
    record.recursion_order_key = source_key
    return true
  end
  local roots = record.supermarket_order_plan and record.supermarket_order_plan.roots or {}
  for index, root in ipairs(roots) do
    if root.source_key == source_key then
      record.supermarket_sequence_index = index
      record.supermarket_active_orders = {}
      reset_output_state(record)
      record.recursion_order_key = nil
      return true
    end
  end
  return false
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
    network_requests = record.network_requests,
    network_active = record.network_active,
    selected_output = record.selected_recursion_output,
    output_count = record.recursion_output_count,
    changed_tick = record.recursion_output_changed_tick,
    material_wait_tick = record.recursion_material_wait_tick,
    material_wait_output = record.recursion_material_wait_output,
    order_key = record.recursion_order_key,
    active_orders = record.supermarket_active_orders,
    sequence_completed_orders = record.supermarket_sequence_completed_orders,
    sequence_index = record.supermarket_sequence_index,
    sequence_signature = record.supermarket_sequence_signature,
    inventory_pending_tick = record.recursion_inventory_pending_tick,
    inventory_protection_tick = record.recursion_inventory_protection_tick,
    inventory_shortages = record.recursion_inventory_shortages,
    linked_last_outputs = record.recursion_linked_last_outputs
  }
end

---恢复 save_state 导出的状态。
---@param record table 新建的组合器记录。
---@param saved table|nil 旧运行状态；旧版本缺失时允许为 nil。
---@return nil
function Mode.restore_state(record, saved)
  saved = saved or {}
  record.network_requests = saved.network_requests
  record.network_active = saved.network_active
  record.selected_recursion_output = saved.selected_output
  record.recursion_output_signal = nil
  record.recursion_output_target = nil
  record.recursion_output_count = saved.output_count
  record.recursion_output_changed_tick = saved.changed_tick
  record.recursion_material_wait_tick = saved.material_wait_tick
  record.recursion_material_wait_output = saved.material_wait_output
  record.recursion_order_key = saved.order_key
  record.supermarket_active_orders = saved.active_orders
  record.supermarket_sequence_completed_orders = saved.sequence_completed_orders
  record.supermarket_sequence_index = saved.sequence_index
  record.supermarket_sequence_signature = saved.sequence_signature
  record.recursion_inventory_pending_tick = saved.inventory_pending_tick
  record.recursion_inventory_protection_tick = saved.inventory_protection_tick
  record.recursion_inventory_shortages = saved.inventory_shortages
  record.recursion_linked_last_outputs = saved.linked_last_outputs
end

---执行超市订单递归计算。
---all 返回展开范围内所有层级的缺口；single 使用材料启动/保留阈值稳定当前层级，避免机械臂
---运输原料时在父产品和原料之间振荡。timeout 可在输出数量长期不变时轮换到下一个结果。
---@param record table 组合器记录，必须包含 entity、config 和本模式运行状态。
---@return table outputs 标准输出集合，由 control.lua 统一负责写入线路。
local function calculate_local(record)
  -- control.lua 正常会先迁移配置；这里仍允许测试桩或热加载中的残缺记录进入，所有缺省
  -- 字段都按最保守语义处理，避免一次坏记录中断同一 on_nth_tick 内其他运算器。
  local config = type(record.config) == "table" and record.config or {}
  local wanted_depth = math.max(0, math.floor(tonumber(config.recurise_depth) or 0))
  local validation_mode = config.inventory_validation
  if validation_mode ~= Config.inventory_validation.inventory
    and validation_mode ~= Config.inventory_validation.linked
    and validation_mode ~= Config.inventory_validation.none then
    -- 直接调用模式模块的旧测试桩没有经过 Config.normalize；保留旧递归语义只为兼容该入口。
    validation_mode = type(config.recursion_strict_validation) == "boolean"
      and (config.recursion_strict_validation and Config.inventory_validation.inventory or "legacy")
      or "legacy"
  end
  -- 依赖被移除后保留安全语义：继续使用红线库存校验，而不是悄悄放弃校验。
  if validation_mode == Config.inventory_validation.linked and not InventoryQuery.is_available() then
    validation_mode = Config.inventory_validation.inventory
  end
  -- 深度 0 不展开配方，因此也不应读取或校验下层材料库存。
  if wanted_depth == 0 then validation_mode = Config.inventory_validation.none end
  local validates_inventory = validation_mode == Config.inventory_validation.inventory
    or validation_mode == Config.inventory_validation.linked
  -- 计算过程中订单、严格校验或配方树变化可能清除当前选择；先保留上一轮真实输出，
  -- 让统一的等待门在最终切换点决定何时撤销，而不是让各取消分支各自处理。
  local previous_output_key = record.selected_recursion_output
  local previous_output = previous_output_key and record.detail_outputs
    and record.detail_outputs[previous_output_key] or nil
  local previous_wait_tick = record.recursion_material_wait_tick
  local previous_wait_output = record.recursion_material_wait_output
  local function finish_inventory_pause(field)
    local started = record[field]
    if not started then return end
    local paused = game.tick - started
    if record.recursion_output_changed_tick then
      record.recursion_output_changed_tick = record.recursion_output_changed_tick + paused
    end
    if record.recursion_material_wait_tick then
      record.recursion_material_wait_tick = record.recursion_material_wait_tick + paused
    end
    record[field] = nil
  end
  -- Factorio 为选择运算器的红、绿输入端提供不同的 connector id：
  --   * 红线表示玩家已经拥有的库存，用于抵扣需求；
  --   * 绿线表示订单，正数物品/流体才进入配方树。
  -- get_signals 可能返回同一信号的多项，Util.read_network 会先按类型、名称、品质合并。
  local inputs = Conditions.read_inputs(record.entity)
  if record.network_inputs then inputs = record.network_inputs end
  local observed_inventory = inputs.red
  local raw_demands = inputs.entries.green
  local timeout = tonumber(config.recursion_timeout) or 0
  local production_rate = tonumber(config.recursion_additional_production_rate)
  -- 直接调用模式模块的旧测试桩和热加载记录仍可能携带旧版“额外倍率”。
  if (tonumber(config.schema_revision) or 0) < 18 then
    production_rate = math.max(1, (production_rate or 0) + 1)
  else
    production_rate = math.max(2, production_rate or 2)
  end
  local material_demand_rate = math.max(0, tonumber(config.recursion_material_demand_rate) or 1)
  local material_retention_rate = math.max(0, tonumber(config.recursion_material_retention_rate) or 0)
  local timeout_reset_active, condition_results = Conditions.evaluate(config.recursion_timeout_conditions,
    record.network_timeout_inputs or inputs)
  record.recursion_timeout_condition_results = condition_results
  timeout_reset_active = timeout > 0 and timeout_reset_active
  local reset_keys = Conditions.signal_keys(config.recursion_timeout_conditions, "green")
  local demands = {}
  -- 控制信号只负责刷新超时起点，不参与配方树和订单变化签名。
  for _, demand in pairs(raw_demands or {}) do
    if type(demand) == "table" and demand.signal and demand.signal.name
      and type(demand.count) == "number" and (record.network_force_active or not reset_keys[Util.signal_key(demand.signal)]) then
      demands[#demands + 1] = demand
    end
  end
  table.sort(demands, function(a, b) return Util.signal_key(a.signal) < Util.signal_key(b.signal) end)

  ---订单签名只包含会参与计算的正数产品或配方信号；数量或种类变化都会触发重建。
  local signature_parts = {}
  local policy_choices, policy_parts = {}, {}
  for key, entries in pairs(config.recipe_policies or {}) do
    local kind, name, quality = key:match("^([^:]+):([^:]+):?(.*)$")
    if kind and name and entries[1] then
      local signal = Util.make_signal(kind, name, quality ~= "" and quality or nil)
      local recipe, entry = Policy.choose(record, signal,
        validation_mode == Config.inventory_validation.linked and record.policy_inventory or observed_inventory)
      policy_choices[key] = {recipe = recipe, entry = entry}
      policy_parts[#policy_parts + 1] = key .. "=" .. (recipe and recipe.name or "blocked")
        .. ":" .. tostring(entry and entry.demand) .. ":" .. tostring(entry and entry.retention)
    end
  end
  table.sort(policy_parts)
  signature_parts[#signature_parts + 1] = table.concat(policy_parts, "|")
  local resolved_targets = {}
  for _, demand in ipairs(demands) do
    if Util.is_recipe_input(demand.signal) and demand.count > 0 then
      local key = Util.signal_key(demand.signal)
      local target = OrderTarget.resolve(record.entity.force, config.production_machine, demand.signal, config)
      local choice = target.signal and policy_choices[Util.signal_key(target.signal)]
      if choice and demand.signal.type ~= "recipe" then
        if choice.recipe then
          target = OrderTarget.resolve(record.entity.force, config.production_machine, demand.signal, config,
            {policy_recipe = choice.recipe.name})
        end
        target.recipe = choice.recipe
        target.blocked = not choice.recipe
        target.signature = target.signature .. ":policy=" .. (choice.recipe and choice.recipe.name or "blocked")
      end
      resolved_targets[key] = target
      signature_parts[#signature_parts + 1] = key .. "=" .. tostring(demand.count)
        .. "@" .. tostring(target.signature)
    end
  end
  local order_signature = table.concat(signature_parts, "|")

  ---构建一棵不含 LuaRecipePrototype 等运行时原型对象的配方树，确保能够安全写入 storage。
  ---根订单标记为第 1 层。深度 N 表示允许展开 level <= N 的可制造节点；第一次
  ---超过限制的节点（level=N+1）成为边界输出。0 把根订单作为边界，只输出订单物品。
  local maximum_plan_level = 1
  local terminal_nodes_by_level = {}
  local function remember_terminal_node(node)
    local nodes = terminal_nodes_by_level[node.level]
    if not nodes then nodes = {}; terminal_nodes_by_level[node.level] = nodes end
    nodes[#nodes + 1] = node
  end
  local function build_plan_node(signal, amount, level, ancestors, specified_recipe, fixed_recipe)
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
    node.machine_craftable = specified_recipe ~= nil
      or Util.machine_material_layer(normalized, config.production_machine) > 1
    local recipe = specified_recipe or (node.machine_craftable and
      Util.find_recipe(record.entity.force, normalized, config.production_machine) or nil)
    local choice = not fixed_recipe and policy_choices[key] or nil
    if choice then recipe = choice.recipe end
    if choice and choice.entry then
      node.demand_rate, node.retention_rate = choice.entry.demand, choice.entry.retention
    end
    local machine = prototypes.entity[config.production_machine]
    if recipe and config.network_publish and config.network_export
      and (not surface_conditions_met(record.entity.surface, machine and machine.surface_conditions)
        or not surface_conditions_met(record.entity.surface, recipe.surface_conditions)) then
      -- 跨地表发布开启时，当前地表不可执行的配方也作为可委派节点交给其他地表。
      node.network_delegable, node.surface_unsupported, recipe = true, true, nil
    end
    local product_amount = recipe and Util.recipe_product_amount(recipe, normalized) or 0
    if not recipe or product_amount <= 0 then
      -- 当前机器没有该产品的制造路径，但势力存在已解锁配方时，交由订单网络的其他机器补料。
      node.network_delegable = node.network_delegable or not node.machine_craftable
        and Util.has_unlocked_recipe(record.entity.force, normalized)
      remember_terminal_node(node)
      return node
    end

    -- storage 不能保存 Factorio 的 LuaRecipePrototype，所以节点只保存配方名称、一次
    -- 产量以及从 recipe.ingredients 抄出的普通 Lua 子节点；后续刷新只遍历这份纯数据。
    node.recipe_name = recipe.name
    if config.schema_revision and config.schema_revision >= 16 then
      node.output_signal = Util.make_signal("recipe", recipe.name)
    end
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
    record.recursion_inventory_shortages = nil
    record.recursion_inventory_protection_tick = nil
    record.recursion_linked_last_outputs = nil
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
      all_shortages_by_depth = {},
      root_details_by_depth = {}
    }
    for _, demand in ipairs(demands) do
      if Util.is_recipe_input(demand.signal) and demand.count > 0 then
        local target = resolved_targets[Util.signal_key(demand.signal)]
        local signal, specified_recipe = target and target.signal, target and target.recipe
        if signal and not (target and target.blocked)
          and (demand.signal.type ~= "recipe" or specified_recipe) then
          local root = build_plan_node(signal, demand.count, 1, {}, specified_recipe, demand.signal.type == "recipe")
          root.source_key = Util.signal_key(demand.signal)
          root.validation_products = target.products
          root.manual_recipe = target.manual_recipe
          root.machine_unsupported_recipe = target.machine_unsupported_recipe
          -- 库存和递归始终使用产品信号；配方输入及手动选配方的根订单输出配方信号，
          -- 使下游机器能够识别玩家明确指定的制造路径。
          if demand.signal.type == "recipe" then
            root.output_signal = Util.make_signal("recipe", demand.signal.name)
          elseif target.manual_recipe and not policy_choices[Util.signal_key(signal)] then
            root.output_signal = Util.make_signal("recipe", target.manual_recipe)
          end
          plan.roots[#plan.roots + 1] = root
        end
      end
    end
    plan.maximum_level = maximum_plan_level
    plan.terminal_nodes_by_level = terminal_nodes_by_level
    record.supermarket_order_plan = plan
  end

  if validation_mode == Config.inventory_validation.linked then
    local requested = InventoryQuery.supermarket_signals(plan)
    local shared_inventory, generation = InventoryQuery.get_shared_inventory(
      record.entity.force, record.entity.surface, requested)
    if not shared_inventory then
      record.recursion_inventory_pending_tick = record.recursion_inventory_pending_tick or game.tick
      local diagnostics = {}
      for _, demand in ipairs(demands) do
        if Util.is_recipe_input(demand.signal) and demand.count > 0 then
          diagnostics[Util.signal_key(demand.signal)] = {kind = "inventory_query_pending"}
        end
      end
      record.supermarket_order_diagnostics = diagnostics
      local selected = record.selected_recursion_output
      local held = selected and record.detail_outputs and record.detail_outputs[selected]
      return held and {[selected] = held} or record.recursion_linked_last_outputs or {}
    end
    finish_inventory_pause("recursion_inventory_pending_tick")
    local merged = {}
    for key, count in pairs(shared_inventory) do merged[key] = count end
    for key, count in pairs(inputs.red) do merged[key] = math.max(0, (merged[key] or 0) + count) end
    observed_inventory = merged
    record.recursion_inventory_generation = generation
  else
    record.recursion_inventory_pending_tick = nil
    record.recursion_inventory_protection_tick = nil
    record.recursion_inventory_shortages = nil
    record.recursion_inventory_generation = nil
  end
  if record.network_inventory_deductions then
    local available = {}
    for key, count in pairs(observed_inventory) do
      available[key] = math.max(0, count - (record.network_inventory_deductions[key] or 0))
    end
    observed_inventory = available
  end
  record.policy_inventory = observed_inventory
  record.network_observed_inventory = observed_inventory

  -- 库存参与每一层的逐项抵扣，所以库存数量变化时需要重新计算各深度快照；排序后的
  -- 签名让 pairs 的不稳定遍历顺序不会制造无意义的缓存失效。
  local inventory_parts = {}
  for key, count in pairs(observed_inventory) do
    inventory_parts[#inventory_parts + 1] = key .. "=" .. tostring(count)
  end
  table.sort(inventory_parts)
  local inventory_signature = table.concat(inventory_parts, "|")

  -- 库存校验只阻止当前机器本身无法生产的根订单；原料不足必须继续展开为生产请求。
  local active_orders = type(record.supermarket_active_orders) == "table"
    and record.supermarket_active_orders or {}
  record.supermarket_active_orders = active_orders
  local strict_order_diagnostics = {}
  local function strict_order_diagnostic(root)
    if not validates_inventory then return nil end
    -- 订单物品本身无法由所选机器制造时也必须跳过，不能把它当作终端原料输出。
    if not root.recipe_name then
      return root.network_delegable and nil or {kind = "no_recipe"}
    end
    local machine = prototypes.entity[config.production_machine]
    local root_recipe = prototypes.recipe[root.recipe_name]
    if not surface_conditions_met(record.entity.surface, machine and machine.surface_conditions)
      or not surface_conditions_met(record.entity.surface, root_recipe and root_recipe.surface_conditions) then
      return {kind = "surface_conditions"}
    end
    return nil
  end

  -- “顺序制作”仅在 single 输出模式生效。游标从当前项向后扫描，到末尾后回到第一项；
  -- 每轮最多检查一次完整队列，避免全部订单都已满足或校验失败时形成死循环。
  local sequential = config.recursion_output_mode == "single" and config.sequential_production ~= false
  local roots_to_resolve = {}
  local root_targets = {}
  local root_requirements = {}
  local active_order_key = sequential and nil or "*"
  local active_order_keys = {}
  local completed_order_keys = {}
  local function root_status(root, goal)
    return OrderTarget.inventory_status(root.validation_products or {root.signal}, observed_inventory, goal)
  end
  local function remember_root_requirements(root, extended_target)
    local stock = math.max(0, observed_inventory[Util.signal_key(root.signal)] or 0)
    local base = root_status(root, root.amount)
    local extended = root_status(root, extended_target)
    -- 递归层仍以根产品信号表达生产请求；把最大选中产物缺口平移到该信号的当前库存，
    -- 即可复用原有产量与原料展开，而不会把库存目标按副产物比例换算。
    root_requirements[root.source_key] = {
      base = stock + base.remaining,
      extended = stock + extended.remaining,
      status = extended
    }
  end
  ---找出当前阶段因本机不支持且未达到启动/保持门槛而必须委派的材料。
  local function network_material_wait(root, required)
    if not validates_inventory or wanted_depth == 0 then return nil end
    local waiting, by_key = {}, {}
    local function add_wait(node, shortage)
      local key = Util.signal_key(node.signal)
      local entry = by_key[key]
      if not entry then
        entry = {signal = Util.make_signal(node.signal.type, node.signal.name, node.signal.quality), count = 0}
        by_key[key], waiting[#waiting + 1] = entry, entry
      end
      entry.count = entry.count + math.max(0, math.ceil(shortage))
    end
    local function visit(node, node_required, force_active)
      if (node.level or 1) > wanted_depth then return end
      local stock = math.max(0, observed_inventory[Util.signal_key(node.signal)] or 0)
      local missing = math.max(0, node_required - stock)
      if missing <= 0 then return end
      if node.network_delegable then
        if force_active then add_wait(node, missing) end
        return
      end
      if not node.recipe_name or node.cyclic or not node.product_amount or node.product_amount <= 0 then return end
      local selected = Util.signal_key(node.output_signal or node.signal) == record.selected_recursion_output
      local rate = selected and (node.retention_rate or material_retention_rate)
        or (node.demand_rate or material_demand_rate)
      local crafts = math.ceil(node_required / node.product_amount)
      for _, child in ipairs(node.children or {}) do
        local child_stock = math.max(0, observed_inventory[Util.signal_key(child.signal)] or 0)
        local insufficient = child_stock <= child.amount * rate
        if insufficient then visit(child, child.amount * crafts, true) end
      end
    end
    visit(root, required, true)
    table.sort(waiting, function(a, b) return Util.signal_key(a.signal) < Util.signal_key(b.signal) end)
    if not waiting[1] then return nil end
    for _, entry in ipairs(waiting) do
      entry.published = config.network_publish == true
      if entry.published then
        entry.status, entry.owner = Network.request_status(
          record.entity.unit_number, root.source_key, entry.signal)
        entry.status = entry.status or "pending"
      end
    end
    return waiting
  end
  local function blocks_order(diagnostic)
    return diagnostic ~= nil
  end
  if sequential then
    if record.supermarket_sequence_signature ~= order_signature then
      record.supermarket_sequence_signature = order_signature
      record.supermarket_sequence_index = 1
      active_orders = {}
      record.supermarket_active_orders = active_orders
    end
    record.supermarket_sequence_completed_orders = nil -- 旧版一次性顺序状态不再参与循环队列。
    if validates_inventory then
      -- 当前项运行时仍为队列中其他订单保留具体校验原因，避免输入悬浮框退化为“等待中”。
      for _, root in ipairs(plan.roots) do
        local target = (record.network_force_active or active_orders[root.source_key])
          and root.amount * production_rate or root.amount
        if not root_status(root, target).satisfied then
          strict_order_diagnostics[root.source_key] = strict_order_diagnostic(root)
        end
      end
    end
    local root_count = #plan.roots
    local sequence_index = root_count > 0
      and (math.max(1, math.floor(tonumber(record.supermarket_sequence_index) or 1)) - 1) % root_count + 1
      or 1
    local selected
    for _ = 1, root_count do
      local root = plan.roots[sequence_index]
      local extended_target = root.amount * production_rate
      local target = (record.network_force_active or active_orders[root.source_key]) and extended_target or root.amount
      if not root_status(root, target).satisfied then
        local diagnostic = strict_order_diagnostics[root.source_key]
        local requirements = root_requirements[root.source_key]
        local waiting = not diagnostic and network_material_wait(root,
          requirements and requirements.extended or extended_target)
        if waiting then diagnostic = {kind = "network_material_wait", materials = waiting} end
        if blocks_order(diagnostic) then
          -- 网络补料期间保留订单的扩展目标，但不占用本地顺序游标；材料越过门槛后可立即续产。
          active_orders[root.source_key] = diagnostic.kind == "network_material_wait" or nil
          strict_order_diagnostics[root.source_key] = diagnostic
        else
          active_orders = {[root.source_key] = true}
          record.supermarket_active_orders = active_orders
          roots_to_resolve[1] = root
          root_targets[root.source_key] = extended_target
          remember_root_requirements(root, extended_target)
          active_order_key = root.source_key
          active_order_keys[root.source_key] = true
          selected = true
          break
        end
      else
        active_orders[root.source_key] = nil
        completed_order_keys[root.source_key] = true
      end
      sequence_index = sequence_index % root_count + 1
    end
    record.supermarket_sequence_index = selected and sequence_index or 1
  else
    -- 非顺序模式允许多个订单同时处于迟滞区间：库存低于基础目标时启动，达到扩展目标后退出。
    for _, root in ipairs(plan.roots) do
      local extended_target = root.amount * production_rate
      local target = (record.network_force_active or active_orders[root.source_key]) and extended_target or root.amount
      if not root_status(root, target).satisfied then
        local diagnostic = strict_order_diagnostic(root)
        local status = root_status(root, target)
        local stock = math.max(0, observed_inventory[Util.signal_key(root.signal)] or 0)
        local required = stock + status.remaining
        local waiting = not diagnostic and network_material_wait(root, required)
        if waiting then diagnostic = {kind = "network_material_wait", materials = waiting} end
        if blocks_order(diagnostic) then
          active_orders[root.source_key] = diagnostic.kind == "network_material_wait" or nil
          strict_order_diagnostics[root.source_key] = diagnostic
        else
          active_orders[root.source_key] = true
          active_order_keys[root.source_key] = true
          roots_to_resolve[#roots_to_resolve + 1] = root
          root_targets[root.source_key] = extended_target
          remember_root_requirements(root, extended_target)
        end
      else
        active_orders[root.source_key] = nil
      end
    end
  end
  -- 顺序订单切换时解除上一条生产链的当前输出；同一订单内仍由原料迟滞保持层级稳定。
  if sequential and record.recursion_order_key ~= active_order_key then
    reset_output_state(record)
    record.recursion_inventory_shortages = nil
    record.recursion_inventory_protection_tick = nil
    record.recursion_linked_last_outputs = nil
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

  ---根订单保留配方输入作为外部输出；子节点仍输出实际产品或原料信号。
  local function node_output_signal(node)
    return node.output_signal or node.signal
  end

  -- maximum_level 是这张订单实际能到达的最深节点。例如树只到第 3 层时，深度 10
  -- 与深度 3 的含义完全相同。深度 0 使用“不递归”的根订单快照。
  local maximum_depth = math.max(1, plan.maximum_level or 1)
  local effective_depth = math.min(wanted_depth, maximum_depth)

  -- 提前识别“当前可制造节点的直接原料跌破保留阈值”这一常见切换原因。
  -- 其他撤销原因由最终输出处的统一等待门处理。
  local material_wait_seconds = math.max(0, tonumber(config.recursion_material_wait_time) or 0)
  local material_wait_active = false
  local selected_output_key = record.selected_recursion_output
  local selected_materials_insufficient = false
  local function find_selected_material_shortage(node)
    if selected_materials_insufficient then return end
    if Util.signal_key(node_output_signal(node)) == selected_output_key then
      local within_depth = node.level <= effective_depth
      if within_depth and node.recipe_name and not node.cyclic then
        for _, child in ipairs(node.children) do
          local child_stock = math.max(0, observed_inventory[Util.signal_key(child.signal)] or 0)
          if child_stock <= child.amount * (node.retention_rate or material_retention_rate) then
            selected_materials_insufficient = true
            return
          end
        end
      end
    end
    for _, child in ipairs(node.children or {}) do find_selected_material_shortage(child) end
  end
  if config.recursion_output_mode == "single" and material_wait_seconds > 0 and selected_output_key then
    for _, root in ipairs(roots_to_resolve) do find_selected_material_shortage(root) end
    if selected_materials_insufficient then
      if record.recursion_material_wait_output ~= selected_output_key
        or type(record.recursion_material_wait_tick) ~= "number" then
        record.recursion_material_wait_output = selected_output_key
        record.recursion_material_wait_tick = game.tick
      end
      material_wait_active = game.tick - record.recursion_material_wait_tick < material_wait_seconds * 60
    else
      record.recursion_material_wait_tick = nil
      record.recursion_material_wait_output = nil
    end
  else
    record.recursion_material_wait_tick = nil
    record.recursion_material_wait_output = nil
  end

  ---为指定深度生成完整输出快照；终端材料会自然保留在所有更深的快照中。
  ---@param depth_limit uint 0 表示不展开根订单配方。
  ---@return table depth_outputs 当前深度对应的完整输出集合。
  ---@return table terminal_by_level 已经无法继续递归的材料，按实际层级分组。
  ---@return table boundary_outputs 因当前深度限制而停止的可递归节点。
  ---@return table ready_outputs 直接材料齐备、当前可开始制造的产品。
  ---@return table all_shortages 当前展开范围内每一层的全部缺口。
  ---@return table root_details 每根订单独立的输出归属与 single 阶段详情。
  local function calculate_depth_outputs(depth_limit)
    local inventory = {}
    for key, count in pairs(observed_inventory) do inventory[key] = count end
    local terminal_by_level = {}
    local boundary_outputs = {}
    local ready_outputs = {}
    local all_shortages = {}
    local root_details = {}
    local current_root_detail

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

    ---把当前层缺少的可制造原料再展开一层，仅用于悬浮说明，不参与输出计算。
    local function next_level_production(node, shortage)
      if shortage <= 0 or not node.recipe_name or not node.product_amount
        or node.product_amount <= 0 then return nil end
      local crafts = math.ceil(shortage / node.product_amount)
      local ingredients = {}
      for _, child in ipairs(node.children) do
        local stock = math.max(0, observed_inventory[Util.signal_key(child.signal)] or 0)
        local required = child.amount * crafts
        ingredients[#ingredients + 1] = {
          signal = Util.make_signal(child.signal.type, child.signal.name, child.signal.quality),
          required = required,
          stock = stock,
          shortage = math.max(0, required - stock)
        }
      end
      table.sort(ingredients, function(a, b)
        return Util.signal_key(a.signal) < Util.signal_key(b.signal)
      end)
      return {
        signal = Util.make_signal(node.signal.type, node.signal.name, node.signal.quality),
        count = math.ceil(crafts * node.product_amount),
        ingredients = ingredients
      }
    end

    ---记录 single 候选输出的本订单归属；原料数量按本轮线路请求换算，门槛则保持
    ---实际递归判断使用的“启动 >”或“保持 >=”语义。
    local function remember_stage(node, output_signal, output_count, gate_kind)
      local key = Util.signal_key(output_signal)
      local stage = current_root_detail.stages[key]
      if not stage then
        stage = {
          -- 根订单可能是配方信号，但当前制作阶段始终展示实际产品。
          signal = Util.make_signal(node.signal.type, node.signal.name, node.signal.quality),
          level = node.level,
          stock = math.max(0, observed_inventory[Util.signal_key(node.signal)] or 0),
          output_count = 0,
          ingredients = {},
          gate_kind = node.recipe_name and gate_kind or nil,
          start_ready = node.recipe_name and true or nil,
          _ingredients = {}
        }
        current_root_detail.stages[key] = stage
      end
      stage.level = math.max(stage.level, node.level)
      stage.output_count = stage.output_count + output_count
      -- 信号数量为整数，这里展示本轮线路请求完成后的实际停止库存。
      stage.target = stage.stock + stage.output_count
      if not node.recipe_name then return end

      local crafts = math.ceil(output_count / node.product_amount)
      local material_rate = gate_kind == "retention" and (node.retention_rate or material_retention_rate)
        or (node.demand_rate or material_demand_rate)
      local comparator = ">"
      for _, child in ipairs(node.children) do
        local child_key = Util.signal_key(child.signal)
        local stock = math.max(0, observed_inventory[child_key] or 0)
        local threshold = child.amount * material_rate
        local ready = comparator == ">=" and stock >= threshold or stock > threshold
        local ingredient = stage._ingredients[child_key]
        if not ingredient then
          ingredient = {
            signal = Util.make_signal(child.signal.type, child.signal.name, child.signal.quality),
            required = 0,
            stock = stock,
            start_threshold = threshold,
            demand_ready = stock > child.amount * (node.demand_rate or material_demand_rate),
            threshold_comparator = comparator,
            start_ready = true,
            _node = child
          }
          stage._ingredients[child_key] = ingredient
        elseif not ingredient._node.recipe_name and child.recipe_name then
          ingredient._node = child
        end
        ingredient.required = ingredient.required + child.amount * crafts
        ingredient.stock = math.min(ingredient.stock, stock)
        ingredient.start_threshold = math.max(ingredient.start_threshold, threshold)
        ingredient.demand_ready = ingredient.demand_ready
          and stock > child.amount * (node.demand_rate or material_demand_rate)
        ingredient.start_ready = ingredient.start_ready and ready
        stage.start_ready = stage.start_ready and ready
      end
    end

    ---若整单扩展目标尚未达到父级的材料启动线，则只用父配方的单份用量补足门槛。
    ---材料需求倍率不能再乘订单总量，否则会把递归中间产物目标成倍放大。
    local function recursive_expanded_target(node, expanded_required)
      if node.level > 1 and node.recipe_name then
        local material_threshold = node.amount * material_demand_rate
        if material_threshold > expanded_required then
          return node.amount * (1 + material_demand_rate)
        end
      end
      return expanded_required
    end

    ---判断当前选中的层级在这棵子树内是否仍处于运行阶段；只读库存，不写输出。
    ---这样铜丝已启动但尚未达到扩展目标时，父级电路板不会在铜丝刚越过启动线后抢走输出。
    local function selected_stage_active(node, base_required, expanded_required)
      local stage_expanded_required = recursive_expanded_target(node, expanded_required)
      local stock_key = Util.signal_key(node.signal)
      local output_key = Util.signal_key(node_output_signal(node))
      local stock = math.max(0, observed_inventory[stock_key] or 0)
      if output_key == selected_key then
        -- 递归中间产物的停止条件是严格大于扩展目标；最终订单仍在
        -- 达到自身扩展目标时完成。信号数量为整数，因此中间产物需要 floor(目标)+1。
        local stop_target = node.level > 1 and node.recipe_name
          and math.floor(stage_expanded_required) + 1 or stage_expanded_required
        if stock >= stop_target then return false end
        local reaches_limit = node.level > depth_limit
        -- 终端/边界信号只是外部补料请求，本模式无法制造它；父配方一旦重新达到
        -- 材料启动阈值就应继续上移，不能把基础原料锁到整条生产链的扩展总量。
        if node.cyclic or not node.recipe_name or reaches_limit then return false end
        for _, child in ipairs(node.children) do
          local child_stock = math.max(0, observed_inventory[Util.signal_key(child.signal)] or 0)
          if child_stock <= child.amount * (node.retention_rate or material_retention_rate) then return false end
        end
        return true
      end
      if node.cyclic or not node.recipe_name or node.level > depth_limit then
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
    -- 递归中间产物成为当前输出后，保持到严格超过扩展目标，或任一直接原料跌破保留倍率。
    local function resolve(node, base_required, expanded_required, suppress_stage_output, force_active)
      if expanded_required <= 0 then return end
      local stage_expanded_required = recursive_expanded_target(node, expanded_required)
      local output_signal = node_output_signal(node)
      local output_key = Util.signal_key(output_signal)
      local stock = math.max(0, inventory[Util.signal_key(node.signal)] or 0)
      local base_shortage = math.max(0, base_required - stock)
      -- 整单扩展目标不足材料启动线时，中间产物才用“单份用量 ×（1 + 材料需求倍率）”兜底；
      -- single 需要严格大于目标，因此整数信号再加 1，all 则输出到目标本身的精确缺口。
      local output_required = config.recursion_output_mode == "single" and node.level > 1 and node.recipe_name
        and math.floor(stage_expanded_required) + 1 or stage_expanded_required
      local expanded_shortage = consume_inventory(node.signal, output_required)
      if expanded_shortage <= 0 then return end
      local output_count = math.ceil(expanded_shortage)
      local delegated = validates_inventory and node.network_delegable
      if not delegated then
        add_depth_output(all_shortages, output_signal, output_count, node.level)
        add_depth_output(current_root_detail.outputs, output_signal, output_count, node.level)
      end

      -- “不校验”只关心订单产品库存：所有原料视为满足，直接请求根产品或指定配方。
      if validation_mode == Config.inventory_validation.none and node.level == 1 then
        add_depth_output(ready_outputs, output_signal, output_count, node.level)
        current_root_detail.stages[output_key] = {
          signal = Util.make_signal(node.signal.type, node.signal.name, node.signal.quality),
          level = node.level,
          stock = stock,
          output_count = output_count,
          target = stock + output_count,
          ingredients = {},
          start_ready = true,
          _ingredients = {}
        }
        return
      end

      local selected = output_key == selected_key
      local should_run = selected or force_active or base_shortage > 0
      local reaches_limit = node.level > depth_limit
      if node.cyclic or not node.recipe_name then
        if should_run and not suppress_stage_output and not delegated then
          local terminal_outputs = terminal_by_level[node.level]
          if not terminal_outputs then terminal_outputs = {}; terminal_by_level[node.level] = terminal_outputs end
          add_depth_output(terminal_outputs, output_signal, output_count, node.level)
          remember_stage(node, output_signal, output_count, nil)
        end
        return
      end
      if reaches_limit then
        if should_run and not suppress_stage_output then
          add_depth_output(boundary_outputs, output_signal, output_count, node.level)
          remember_stage(node, output_signal, output_count, nil)
        end
        return
      end

      local material_rate = selected and (node.retention_rate or material_retention_rate)
        or (node.demand_rate or material_demand_rate)
      local direct_materials_ready = true
      local insufficient_children = {}
      for _, child in ipairs(node.children) do
        local child_stock = math.max(0, inventory[Util.signal_key(child.signal)] or 0)
        local threshold = child.amount * material_rate
        local insufficient = child_stock <= threshold
        if insufficient then
          direct_materials_ready = false
          insufficient_children[Util.signal_key(child.signal)] = true
        end
      end
      local base_crafts = math.ceil(base_required / node.product_amount)
      local expanded_crafts = math.ceil(expanded_required / node.product_amount)
      local descendant_active = not selected and selected_stage_active(node, base_required, expanded_required)
      local output_current = should_run and (direct_materials_ready or (selected and material_wait_active))
        and not descendant_active
      if output_current and not suppress_stage_output then
        add_depth_output(ready_outputs, output_signal, output_count, node.level)
        remember_stage(node, output_signal, output_count, selected and "retention" or "start")
      end

      -- 当前层可以运行时，子层只继续统计 all 缺口；当前层不能运行或仍有已启动的子层时，
      -- 继续向下寻找真正需要输出的层级，并为每层沿用同一组基础/扩展目标。
      local suppress_children = suppress_stage_output or output_current
      for _, child in ipairs(node.children) do
        resolve(child, child.amount * base_crafts, child.amount * expanded_crafts,
          suppress_children, insufficient_children[Util.signal_key(child.signal)] == true)
      end
    end

    for _, root in ipairs(roots_to_resolve) do
      current_root_detail = {outputs = {}, stages = {}}
      root_details[root.source_key] = current_root_detail
      local requirements = root_requirements[root.source_key]
        or {base = root.amount, extended = root_targets[root.source_key] or root.amount}
      resolve(root, requirements.base, requirements.extended, false, true)
    end
    -- 缓存只保存普通数组，避免 GUI 依赖内部聚合映射，也保证同一订单的输出顺序稳定。
    for _, detail in pairs(root_details) do
      local ordered_outputs = {}
      for _, value in ipairs(Util.sorted_outputs(detail.outputs)) do
        ordered_outputs[#ordered_outputs + 1] = {
          signal = value.entry.signal,
          count = value.entry.count,
          depth = value.entry.depth
        }
      end
      table.sort(ordered_outputs, function(a, b)
        if a.depth ~= b.depth then return a.depth > b.depth end
        return Util.signal_key(a.signal) < Util.signal_key(b.signal)
      end)
      detail.outputs = ordered_outputs
      for _, stage in pairs(detail.stages) do
        local ingredients = {}
        local ingredient_keys = {}
        for key in pairs(stage._ingredients) do ingredient_keys[#ingredient_keys + 1] = key end
        table.sort(ingredient_keys)
        for _, key in ipairs(ingredient_keys) do
          local ingredient = stage._ingredients[key]
          ingredient.shortage = math.max(0, ingredient.required - ingredient.stock)
          ingredient.production = next_level_production(ingredient._node, ingredient.shortage)
          ingredient._node = nil
          ingredients[#ingredients + 1] = ingredient
        end
        stage._ingredients = nil
        stage.ingredients = ingredients
      end
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
    return depth_outputs, terminal_by_level, boundary_outputs, ready_outputs, all_shortages, root_details
  end

  -- 红线库存也是输入数据；订单或库存变化时一次性更新所有深度对应的输出表。
  local calculation_signature = inventory_signature .. "|sequential=" .. tostring(sequential)
    .. "|validation=" .. validation_mode
    .. "|output-mode=" .. tostring(config.recursion_output_mode)
    .. "|active-order=" .. tostring(active_order_key)
    .. "|selected=" .. tostring(record.selected_recursion_output)
    .. "|production-rate=" .. tostring(production_rate)
    .. "|demand=" .. tostring(material_demand_rate)
    .. "|retention=" .. tostring(material_retention_rate)
    .. "|material-wait=" .. tostring(material_wait_active)
  if plan.inventory_signature ~= calculation_signature then
    plan.outputs_by_depth = {}
    plan.terminal_outputs_by_depth = {}
    plan.boundary_outputs_by_depth = {}
    plan.ready_outputs_by_depth = {}
    plan.all_shortages_by_depth = {}
    plan.root_details_by_depth = {}
    local outputs, terminals, boundary, ready, all_shortages, root_details = calculate_depth_outputs(0)
    plan.outputs_by_depth[0] = outputs
    plan.terminal_outputs_by_depth[0] = terminals
    plan.boundary_outputs_by_depth[0] = boundary
    plan.ready_outputs_by_depth[0] = ready
    plan.all_shortages_by_depth[0] = all_shortages
    plan.root_details_by_depth[0] = root_details
    for depth = 1, plan.maximum_level do
      outputs, terminals, boundary, ready, all_shortages, root_details = calculate_depth_outputs(depth)
      plan.outputs_by_depth[depth] = outputs
      plan.terminal_outputs_by_depth[depth] = terminals
      plan.boundary_outputs_by_depth[depth] = boundary
      plan.ready_outputs_by_depth[depth] = ready
      plan.all_shortages_by_depth[depth] = all_shortages
      plan.root_details_by_depth[depth] = root_details
    end
    plan.inventory_signature = calculation_signature
  end

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

  local root_details = plan.root_details_by_depth[effective_depth]
    or plan.root_details_by_depth[0]
    or {}

  -- 非顺序 single 仍只输出一个信号；记录每个根订单此刻真正可选的输出，供点击交互
  -- 在不改变默认“最深缺口优先”算法的前提下切换订单归属。
  local order_candidates = {}
  if config.recursion_output_mode == "single" and not sequential then
    local ordered_outputs = Util.sorted_outputs(outputs)
    for _, root in ipairs(plan.roots) do
      local detail = root_details[root.source_key]
      local candidates = {}
      for _, value in ipairs(ordered_outputs) do
        if detail and detail.stages[value.key] then candidates[#candidates + 1] = value.key end
      end
      if candidates[1] then order_candidates[root.source_key] = candidates end
    end
  end
  record.supermarket_order_candidates = order_candidates

  local function candidate_contains(source_key, output_key)
    for _, key in ipairs(order_candidates[source_key] or {}) do
      if key == output_key then return true end
    end
    return false
  end

  ---记录每个绿色订单信号当前未直接输出的原因，供公共信号面板悬浮提示。
  ---@param final_outputs table 本轮实际输出。
  local function update_diagnostics(final_outputs)
    local diagnostics = {}
    local active_signal
    local current_order_key = active_order_key
    if not sequential and config.recursion_output_mode == "single" then
      local selected_key = record.selected_recursion_output
      current_order_key = candidate_contains(record.recursion_order_key, selected_key)
        and record.recursion_order_key or nil
      if not current_order_key then
        for _, root in ipairs(plan.roots) do
          if candidate_contains(root.source_key, selected_key) then
            current_order_key = root.source_key
            break
          end
        end
      end
      record.recursion_order_key = current_order_key
      active_signal = selected_key and outputs[selected_key] and outputs[selected_key].signal or nil
    end
    local roots_by_source = {}
    for _, root in ipairs(plan.roots) do
      roots_by_source[root.source_key] = root
      if sequential and root.source_key == active_order_key then active_signal = node_output_signal(root) end
    end
    for _, demand in ipairs(demands) do
      local source_key = Util.signal_key(demand.signal)
      local target = resolved_targets[source_key]
      local signal, specified_recipe = target and target.signal, target and target.recipe
      local diagnostic
      if not Util.is_recipe_input(demand.signal) then
        diagnostic = {kind = "unsupported_signal"}
      elseif demand.count <= 0 then
        diagnostic = {kind = "non_positive_order"}
      elseif target and target.locked_recipe then
        diagnostic = {kind = "recipe_locked", recipe_name = target.locked_recipe}
      elseif not signal or (demand.signal.type == "recipe" and not specified_recipe) then
        diagnostic = {kind = "no_recipe"}
      elseif blocks_order(strict_order_diagnostics[source_key]) then
        diagnostic = strict_order_diagnostics[source_key]
      elseif sequential and completed_order_keys[source_key] then
        diagnostic = {kind = "supermarket_completed"}
      elseif sequential and active_order_key and source_key ~= active_order_key then
        diagnostic = {kind = "waiting_for_order", signal = active_signal}
      elseif not sequential and current_order_key and source_key ~= current_order_key
        and order_candidates[source_key] then
        diagnostic = {kind = "waiting_for_order", signal = active_signal}
      elseif active_order_keys[source_key] then
        local root = roots_by_source[source_key]
        local output_key = root and Util.signal_key(node_output_signal(root)) or source_key
        diagnostic = root and root.machine_unsupported_recipe and {kind = "active_fallback",
          unavailable_recipe = root and root.machine_unsupported_recipe,
          fallback_recipe = root and root.recipe_name}
          or final_outputs[output_key] and {kind = "active_output"} or {kind = "supermarket_expanding"}
      elseif not final_outputs[source_key] then
        local status = OrderTarget.inventory_status(target.products, observed_inventory, demand.count)
        diagnostic = status.satisfied and {kind = "stock_sufficient",
          stock = status.products[1] and status.products[1].stock or 0, products = status.products}
          or {kind = "supermarket_expanding"}
      end
      if diagnostic and target and target.products then
        local status = OrderTarget.inventory_status(target.products, observed_inventory, demand.count)
        local product = status.products[1]
        diagnostic.order = {signal = Util.make_signal(demand.signal.type, demand.signal.name, demand.signal.quality),
          count = demand.count}
        diagnostic.product = product and {signal = Util.make_signal(
          product.signal.type, product.signal.name, product.signal.quality),
          target = product.target, stock = product.stock, remaining = product.remaining} or nil
      end
      if diagnostic and (diagnostic.kind == "active_output" or diagnostic.kind == "active_fallback"
        or diagnostic.kind == "supermarket_expanding") then
        local root = roots_by_source[source_key]
        local detail = root_details[source_key]
        if root then
          -- 信号只能输出整数；目标出现小数时展示真正能够解除订单的最小整数库存。
          local product_target = math.ceil(root_targets[source_key] or root.amount * production_rate)
          local status = OrderTarget.inventory_status(
            root.validation_products or {root.signal}, observed_inventory, product_target)
          local product = status.products[1]
          diagnostic.order = {
            signal = Util.make_signal(demand.signal.type, demand.signal.name, demand.signal.quality),
            count = demand.count
          }
          diagnostic.product = {
            signal = Util.make_signal(product.signal.type, product.signal.name, product.signal.quality),
            target = product.target, stock = product.stock, remaining = product.remaining
          }
          diagnostic.products = status.products
          diagnostic.recipe_name = root.recipe_name
          diagnostic.manual_recipe = root.manual_recipe ~= nil
          if config.recursion_output_mode == "all" then
            diagnostic.outputs = detail and detail.outputs or {}
          elseif detail then
            diagnostic.stage = detail.stages[record.selected_recursion_output]
          end
        end
      end
      diagnostics[source_key] = diagnostic
    end
    record.supermarket_order_diagnostics = diagnostics
    record.supermarket_next_order_key = nil
    if sequential and active_order_key then
      local active_index
      for index, root in ipairs(plan.roots) do
        if root.source_key == active_order_key then active_index = index; break end
      end
      if active_index then
        for offset = 1, #plan.roots - 1 do
          local root = plan.roots[(active_index - 1 + offset) % #plan.roots + 1]
          if diagnostics[root.source_key] and diagnostics[root.source_key].kind == "waiting_for_order" then
            record.supermarket_next_order_key = root.source_key
            break
          end
        end
      end
    end
  end

  if config.recursion_output_mode == "all" then
    reset_output_state(record)
    update_diagnostics(outputs)
    if validation_mode == Config.inventory_validation.linked then
      record.recursion_linked_last_outputs = outputs
    end
    return outputs
  end

  -- single 模式已经实际输出过信号后，任何原因造成的撤销或切换都先经过等待时间。
  -- 包括严格校验发现不可制造原料、订单完成、输入变化以及生产链候选改变。
  if material_wait_seconds > 0 and previous_output_key and previous_output
    and not outputs[previous_output_key] then
    local wait_tick = record.recursion_material_wait_output == previous_output_key
      and record.recursion_material_wait_tick
      or previous_wait_output == previous_output_key and previous_wait_tick
      or game.tick
    if game.tick - wait_tick < material_wait_seconds * 60 then
      record.selected_recursion_output = previous_output_key
      record.recursion_output_count = previous_output.count
      record.recursion_output_changed_tick = game.tick
      record.recursion_material_wait_output = previous_output_key
      record.recursion_material_wait_tick = wait_tick
      local held_outputs = {[previous_output_key] = previous_output}
      record.detail_outputs = held_outputs
      update_diagnostics(held_outputs)
      if validation_mode == Config.inventory_validation.linked then
        record.recursion_linked_last_outputs = held_outputs
      end
      return held_outputs
    end
    record.recursion_material_wait_output = nil
    record.recursion_material_wait_tick = nil
  end

  ---选择 single 当前输出。原先的固定库存目标已移除，层级稳定改由材料启动/保留倍率负责。
  local function select_output(key)
    local entry = key and outputs[key]
    if record.selected_recursion_output ~= key then
      record.recursion_material_wait_tick = nil
      record.recursion_material_wait_output = nil
    end
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
    record.detail_outputs = nil
    update_diagnostics({})
    return {}
  end

  local current_count = outputs[selected_key].count
  local output_changed = record.recursion_output_count ~= current_count
  local reset_by_output = record.recursion_output_changed_tick == nil
    or output_changed and config.recursion_timeout_monitor_item_changes ~= false
  if output_changed then
    record.recursion_output_count = current_count
  end
  if reset_by_output then
    record.recursion_output_changed_tick = game.tick
  elseif material_wait_active then
    -- 原料等待是当前输出的最小保留时间，期间不再叠加普通超时轮换。
    record.recursion_output_changed_tick = game.tick
  elseif timeout > 0 then
    if timeout_reset_active then
      record.recursion_output_changed_tick = game.tick
    else
      local unchanged_ticks = game.tick - (record.recursion_output_changed_tick or game.tick)
      if unchanged_ticks >= timeout * 60 then
        if validation_mode == Config.inventory_validation.none and sequential
          and #plan.roots > 1 and Mode.defer_current_order(record, record.recursion_order_key) then
          return calculate_local(record)
        end
        local keys = {}
        for _, value in ipairs(Util.sorted_outputs(outputs)) do keys[#keys + 1] = value.key end
        -- 只有当前一项时，“轮换”不能再次沿用同一锁定项；先解锁并立即重算，
        -- 让它重新通过材料需求倍率，或自然下移到真正缺少的生产链节点。
        if #keys == 1 and keys[1] == selected_key then
          reset_output_state(record)
          return calculate_local(record)
        end
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
  -- 与生产订单一致，只把 single 当前输出写入无线路的详细模式代理。
  record.detail_outputs = final_outputs
  update_diagnostics(final_outputs)
  if validation_mode == Config.inventory_validation.linked then
    record.recursion_linked_last_outputs = final_outputs
  end
  return final_outputs
end

function Mode.calculate(record)
  record.network_reserved = record.network_reserved or {}
  record.network_protected = record.network_protected or {}
  return Network.calculate(record, calculate_local)
end

return Mode
