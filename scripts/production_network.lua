-- 每轮先汇总上一轮缺料，再统一分配；calculate 只发布下一轮请求。
-- 原料实物、生产任务、待运输承诺分别核算，承诺绝不进入原料启动判断。
local Util = require("scripts.common_util")
local Conditions = require("scripts.conditions")
local Target = require("scripts.order_target")
local Policy = require("scripts.recipe_policy")
local Network = {}
local MAX_HOPS = 16

local function state()
  storage.bmsc_production_network = storage.bmsc_production_network or {tasks = {}, next_id = 1}
  return storage.bmsc_production_network
end

local function sorted_keys(t)
  local keys = {}
  for key in pairs(t) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local function valid(record)
  return record and record.entity and record.entity.valid and record.config
    and record.config.mode == "supermarket_order"
end

local function pool_key(record)
  local entity = record.entity
  local net = entity.get_circuit_network and entity.get_circuit_network(defines.wire_connector_id.combinator_input_red)
  return entity.force.index .. ":" .. entity.surface.index .. ":" .. (net and "wire:" .. net.network_id
    or "unit:" .. entity.unit_number)
end

local function can_accept(source, provider, task)
  if not valid(provider) or not provider.config.network_accept or source == provider
    or provider.entity.force.index ~= source.entity.force.index then return false end
  if source.entity.surface.index ~= provider.entity.surface.index
    and not (source.config.network_export and provider.config.network_import) then return false end
  -- 配方信号必须先按承接方机器解析成实际产物；直接把 recipe 信号交给
  -- recipe_product_amount 会得到 0，进而把可承接的任务误判为“无配方”。
  local target = Target.resolve(provider.entity.force, provider.config.production_machine, task.signal, provider.config)
  local recipe = Policy.choose(provider, target.signal, provider.network_red or {}, target.recipe)
  return Policy.legal(provider, recipe, target.signal)
end

local function add(t, key, qty) t[key] = (t[key] or 0) + qty end

function Network.prepare(records)
  local s = state()
  local units = sorted_keys(records)
  local enabled = next(s.tasks) ~= nil
  for _, r in pairs(records) do
    if valid(r) and (r.config.network_publish or r.config.network_accept) then enabled = true; break end
  end
  if not enabled then
    for _, r in pairs(records) do
      r.network_assignments, r.network_reserved, r.network_protected = {}, {}, {}
    end
    return
  end
  local pools = {}
  for _, unit in ipairs(units) do
    local r = records[unit]
    r.network_assignments, r.network_reserved = {}, {}
    if valid(r) then
      local inputs = Conditions.read_inputs(r.entity)
      r.network_red, r.network_pool = inputs.red, pool_key(r)
      local pool = pools[r.network_pool] or {stock = inputs.red, protected = {}, committed = {}}
      pools[r.network_pool] = pool
      local control_keys = Conditions.signal_keys(r.config.recursion_timeout_conditions, "green")
      r.network_local_orders = {}
      for _, demand in ipairs(inputs.entries.green) do
        if demand.count > 0 and Util.is_recipe_input(demand.signal) and not control_keys[Util.signal_key(demand.signal)] then
          r.network_local_orders[Util.signal_key(demand.signal)] = true
          local target = Target.resolve(r.entity.force, r.config.production_machine, demand.signal, r.config)
          for _, signal in ipairs(target.products or {}) do
            local key = Util.signal_key(signal)
            -- 同库存池重复读到同一本地库存目标，按最大目标保护，不能逐组合器相加。
            pool.protected[key] = math.max(pool.protected[key] or 0,
              math.ceil(demand.count * (r.config.recursion_additional_production_rate or 2)))
          end
        end
      end
    end
  end
  -- 快照去重：同一发布源、根订单和材料只有一项活动任务。
  local requests = {}
  for _, unit in ipairs(units) do
    local r = records[unit]
    if valid(r) and r.config.network_publish and r.config.inventory_validation ~= "none" then
      for key, request in pairs(r.network_requests or {}) do
        local parent = request.parent and s.tasks[request.parent]
        if (not request.parent and r.network_local_orders[request.root])
          or (parent and parent.owner == unit and parent.status ~= "waiting_transport") then
          requests[key] = request
        end
      end
    end
  end
  local remaining, existing = {}, {}
  for key, request in pairs(requests) do remaining[key] = request.quantity end
  for _, task in pairs(s.tasks) do existing[#existing + 1] = task end
  table.sort(existing, function(a, b)
    if (a.status == "waiting_transport") ~= (b.status == "waiting_transport") then
      return a.status == "waiting_transport"
    end
    return a.id < b.id
  end)
  for _, task in ipairs(existing) do
    local request_key = task.request_key or task.key
    local request = requests[request_key]
    local needed = remaining[request_key] or 0
    if not request or needed <= 0 then
      s.tasks[task.key] = nil
    else
      -- 待运输承诺只能缩减，不能凭新增需求扩充成尚未生产的货物。
      -- 增量另建生产任务，已离开生产端的旧货物不会因此再生产一次。
      task.quantity = task.status == "waiting_transport" and math.min(task.quantity, needed) or needed
      remaining[request_key] = needed - task.quantity
      task.request_key = request_key
      task.lineage, task.parent = request.lineage, request.parent
      task.blocked = request.blocked
    end
  end
  for _, key in ipairs(sorted_keys(requests)) do
    if remaining[key] > 0 then
      local request = requests[key]
      local task_key = s.tasks[key] and key .. "/part:" .. s.next_id or key
      s.tasks[task_key] = {id = s.next_id, key = task_key, request_key = key, source = request.source, root = request.root,
        signal = request.signal, quantity = remaining[key], lineage = request.lineage,
        parent = request.parent, blocked = request.blocked, status = "pending", created_tick = game.tick}
      s.next_id = s.next_id + 1
    end
  end
  local tasks = {}
  for _, task in pairs(s.tasks) do tasks[#tasks + 1] = task end
  table.sort(tasks, function(a, b)
    local pa = records[a.source] and records[a.source].config.network_publish_priority or 5
    local pb = records[b.source] and records[b.source].config.network_publish_priority or 5
    if pa ~= pb then return pa > pb end
    return a.id < b.id
  end)
  -- 待运输货物可能已离开生产端。保留原库存池承诺，不因拆除或库存下降重新派单。
  local transport_stock = {}
  for _, task in ipairs(tasks) do
    local source, owner = records[task.source], records[task.owner]
    task.priority = valid(source) and (source.config.network_publish_priority or 5) or 5
    if task.status ~= "waiting_transport" and task.owner and (not valid(source) or not can_accept(source, owner, task)) then
      task.owner, task.pool, task.execution = nil, nil, nil
      task.status = "pending"
    end
    if task.owner then
      local pool = pools[task.pool]
      if pool then
        local key = Util.signal_key(task.signal)
        if task.status == "waiting_transport" then
          transport_stock[task.pool] = transport_stock[task.pool] or {}
          local taken = transport_stock[task.pool]
          task.stock_reserved = math.min(task.stock_reserved or task.quantity, task.quantity,
            math.max(0, (pool.stock[key] or 0) - (pool.protected[key] or 0) - (taken[key] or 0)))
          add(taken, key, task.stock_reserved)
        end
        -- 请求端的在途承诺一直保留；生产端已离库的数量不再占用新生产的库存。
        add(pool.committed, key, task.status == "waiting_transport" and task.stock_reserved or task.quantity)
      end
      if valid(owner) then owner.network_assignments[#owner.network_assignments + 1] = task end
    end
  end
  for _, task in ipairs(tasks) do
    local source = records[task.source]
    if not task.owner and not task.blocked and valid(source) then
      local best
      for _, unit in ipairs(units) do
        local r = records[unit]
        if can_accept(source, r, task) and (not best
          or (r.config.network_accept_priority or 5) > (best.config.network_accept_priority or 5)
          or (r.config.network_accept_priority or 5) == (best.config.network_accept_priority or 5)
            and #r.network_assignments < #best.network_assignments) then best = r end
      end
      if best then
        task.owner, task.pool, task.status = best.entity.unit_number, best.network_pool, "assigned"
        best.network_assignments[#best.network_assignments + 1] = task
        add(pools[task.pool].committed, Util.signal_key(task.signal), task.quantity)
      end
    end
  end
  local allocated = {}
  for _, task in ipairs(tasks) do
    if task.status == "waiting_transport" and task.pool then
      allocated[task.pool] = allocated[task.pool] or {}
      add(allocated[task.pool], Util.signal_key(task.signal), task.stock_reserved or task.quantity)
    end
  end
  for _, task in ipairs(tasks) do
    if task.owner and task.status ~= "waiting_transport" then
      local r, pool = records[task.owner], pools[task.pool]
      if valid(r) and pool then
        local key = Util.signal_key(task.signal)
        allocated[task.pool] = allocated[task.pool] or {}
        local base = (pool.protected[key] or 0) + (allocated[task.pool][key] or 0)
        add(allocated[task.pool], key, task.quantity)
        task.reserved_before = base
        task.production_target = math.ceil(task.quantity * (r.config.recursion_additional_production_rate or 2))
        if (pool.stock[key] or 0) >= base + task.production_target then
          task.status, task.execution, task.finished_tick = "waiting_transport", nil, game.tick
          task.stock_reserved = task.quantity
        end
      end
    end
  end
  for _, unit in ipairs(units) do
    local r = records[unit]
    local pool = pools[r.network_pool]
    if pool then
      r.network_reserved, r.network_protected = pool.committed, pool.protected
    end
  end
end

-- 遍历真实配方树发布终端缺口，即使严格库存校验使原算法暂时没有输出，也能补料。
local function publish(record, execution, parent, destination)
  if not record.config.network_publish or record.config.inventory_validation == "none" then return end
  local inventory = execution.network_observed_inventory or execution.policy_inventory
  if not inventory then return end
  local plan = execution.supermarket_order_plan
  if not plan then return end
  local depth_limit = math.max(0, math.floor(tonumber(record.config.recurise_depth) or 0))
  for _, root in ipairs(plan.roots) do
    local lineage = {}
    for _, key in ipairs(parent and parent.lineage or {}) do lineage[#lineage + 1] = key end
    local root_key = parent and parent.key or root.source_key
    local available = {}
    for key, qty in pairs(inventory) do available[key] = qty end
    local function visit(node, required, path)
      -- 本机递归的边界输出不等同于网络缺料请求；不能绕过玩家设定的展开深度。
      if (node.level or 1) > depth_limit then return end
      local key = Util.signal_key(node.signal)
      local stock = math.max(0, available[key] or 0)
      available[key] = math.max(0, stock - required)
      local missing = math.max(0, math.ceil(required - stock))
      if missing == 0 then return end
      if not node.recipe_name or node.cyclic then
        if execution.config.recursion_network_publish_nodes
          and execution.config.recursion_network_publish_nodes[key] == false then return end
        local blocked = node.cyclic and "cycle" or nil
        for _, ancestor in ipairs(path) do if ancestor == key then blocked = "cycle" end end
        if #path >= MAX_HOPS then blocked = "depth_limit" end
        local request_key = record.entity.unit_number .. "/" .. root_key .. "/" .. key
        local existing = destination[request_key]
        if existing then
          existing.quantity = existing.quantity + missing
          existing.blocked = existing.blocked or blocked
          return
        end
        local next_path = {}
        for _, ancestor in ipairs(path) do next_path[#next_path + 1] = ancestor end
        next_path[#next_path + 1] = key
        destination[request_key] = {source = record.entity.unit_number, root = root.source_key,
          signal = node.signal, quantity = missing, parent = parent and parent.key,
          lineage = next_path, blocked = blocked}
        return
      end
      local next_path = {}
      for _, ancestor in ipairs(path) do next_path[#next_path + 1] = ancestor end
      -- 根目标已在上游路径末尾登记，不重复登记；本地递归仍保留完整路径。
      if next_path[#next_path] ~= key then next_path[#next_path + 1] = key end
      local crafts = math.ceil(missing / node.product_amount)
      for _, child in ipairs(node.children) do
        visit(child, math.max(child.amount * crafts,
          math.floor(child.amount * (node.demand_rate or record.config.recursion_material_demand_rate or 1)) + 1), next_path)
      end
    end
    local expanded = execution.supermarket_active_orders and execution.supermarket_active_orders[root.source_key]
    local goal = parent and parent.production_target or expanded
      and root.amount * (record.config.recursion_additional_production_rate or 2) or root.amount
    local status = Target.inventory_status(root.validation_products or {root.signal}, inventory, goal)
    visit(root, (inventory[Util.signal_key(root.signal)] or 0) + status.remaining, lineage)
  end
end

local function executable(outputs)
  for _, entry in pairs(outputs or {}) do if entry.signal.type == "recipe" and entry.count > 0 then return true end end
  return false
end

local function active_order(diagnostics, source_key)
  local diagnostic = diagnostics and diagnostics[source_key]
  return diagnostic and (diagnostic.kind == "active_output" or diagnostic.kind == "active_fallback"
    or diagnostic.kind == "supermarket_expanding")
end

---取得合并网络槽位代表的最高调度顺位等待任务。
function Network.waiting_task(record, signal_key)
  local best
  for _, task in ipairs(record.network_assignments or {}) do
    if task.key == record.network_active and Util.signal_key(task.signal) == signal_key then return nil end
    if task.key ~= record.network_active and task.status == "assigned" and task.execution
      and Util.signal_key(task.signal) == signal_key
      and (not best or task.priority > best.priority
        or task.priority == best.priority and task.id < best.id) then best = task end
  end
  return best
end

function Network.calculate(record, calculate)
  if not record.config.network_publish and not record.config.network_accept then
    record.network_requests, record.network_active, record.network_manual_target = nil, nil, nil
    return calculate(record)
  end
  local requests, previous = {}, record.network_active
  local old_local_key = not previous and record.selected_recursion_output or nil
  local inputs = Conditions.read_inputs(record.entity)
  record.network_inventory_deductions = record.network_reserved
  record.network_inputs = inputs
  local local_output = calculate(record)
  record.network_inputs = nil
  record.network_inventory_deductions = nil
  publish(record, record, nil, requests)
  local selected, selected_task, previous_selected, previous_task
  local candidates = {}
  for _, task in ipairs(record.network_assignments or {}) do
    if task.status ~= "waiting_transport" then
      local execution = task.execution or {}
      task.execution = execution
      execution.entity, execution.config = record.entity, record.config
      local deductions = {}
      for key, count in pairs(record.network_reserved) do deductions[key] = count end
      for key, count in pairs(record.network_protected) do add(deductions, key, count) end
      local key = Util.signal_key(task.signal)
      deductions[key] = task.reserved_before or 0
      execution.network_inventory_deductions = deductions
      execution.network_force_active = true
      execution.network_timeout_inputs = inputs
      execution.network_inputs = {red = inputs.red, green = {[key] = task.quantity},
        entries = {red = inputs.entries.red, green = {{signal = task.signal, count = task.quantity}}}, merged = inputs.merged}
      local old_key = execution.selected_recursion_output
      local outputs = calculate(execution)
      execution.network_inputs = nil
      execution.network_timeout_inputs = nil
      publish(record, execution, task, requests)
      task.current_recipe = execution.selected_recursion_output
      task.status = executable(outputs) and "producing" or "waiting_materials"
      if executable(outputs) then
        candidates[#candidates + 1] = {task = task, outputs = outputs}
        if previous == task.key and old_key and outputs[old_key] then
          previous_selected, previous_task = outputs, task
        end
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.task.priority ~= b.task.priority then return a.task.priority > b.task.priority end
    return a.task.id < b.task.id
  end)

  -- 手动双击只覆盖跨来源仲裁，不合并本地与网络各自的队列。根订单完成、消失或
  -- 失去可执行输出时清除锁定，然后立即回到原有自动优先级。
  local manual = record.network_manual_target
  if manual and manual.source == "local" and executable(local_output)
    and active_order(record.supermarket_order_diagnostics, manual.source_key) then
    selected = local_output
  elseif manual and manual.source == "network" then
    for _, candidate in ipairs(candidates) do
      if candidate.task.key == manual.task_key
        and active_order(candidate.task.execution.supermarket_order_diagnostics, manual.source_key) then
        selected, selected_task = candidate.outputs, candidate.task
        break
      end
    end
  end
  if manual and not selected then record.network_manual_target = nil end
  if not selected and previous_selected then selected, selected_task = previous_selected, previous_task end
  if not selected then
    if executable(local_output) and (old_local_key and local_output[old_local_key]
      or not candidates[1] or candidates[1].task.priority <= (record.config.network_accept_priority or 5)) then selected = local_output
    elseif candidates[1] then selected, selected_task = candidates[1].outputs, candidates[1].task end
  end
  record.network_requests = requests
  record.network_active = selected_task and selected_task.key or nil
  record.detail_outputs = selected or local_output
  -- 未被选中的影子计算不能保留“已启动”资格，否则下次会绕过启动阈值。
  for _, candidate in ipairs(candidates) do
    if candidate.task ~= selected_task then
      candidate.task.status = "assigned"
      candidate.task.execution.selected_recursion_output = nil
    end
  end
  if selected_task then record.selected_recursion_output = nil end
  return selected or local_output
end

function Network.tasks(force_index)
  local result = {}
  for _, task in pairs(state().tasks) do
    local source = storage.combinators and storage.combinators[task.source]
    if source and source.entity.valid and source.entity.force.index == force_index then result[#result + 1] = task end
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

---取得某个请求方根订单中特定材料的当前网络状态，供本地订单诊断复用。
function Network.request_status(source_unit, root_key, signal)
  local wanted = Util.signal_key(signal)
  local best_status, owner
  local priorities = {pending = 1, assigned = 2, waiting_materials = 3, producing = 4, waiting_transport = 5}
  for _, task in pairs(state().tasks) do
    if task.source == source_unit and task.root == root_key and Util.signal_key(task.signal) == wanted
      and (not best_status or (priorities[task.status] or 0) > (priorities[best_status] or 0)) then
      best_status, owner = task.status, task.owner
    end
  end
  return best_status, owner
end

function Network.release(key, force_index)
  for _, task in ipairs(Network.tasks(force_index)) do
    if task.key == key then
      -- 重新分配只撤销网络承诺；不能假定旧生产方尚未实际开始制造。
      task.owner, task.pool, task.execution, task.finished_tick, task.current_recipe = nil, nil, nil, nil, nil
      task.reserved_before, task.production_target, task.stock_reserved = nil, nil, nil
      task.status = "pending"
      return true
    end
  end
  return false
end

return Network
