-- 网络任务查看与递归策略编辑；只把稳定配置写入 record.config。
local Util = require("scripts.common_util")
local Target = require("scripts.order_target")
local Network = require("scripts.production_network")
local SupermarketOrder = require("scripts.modes.supermarket_order") -- 事件回调不得动态 require。
local UI = {name = "bmsc-network-window", tree_name = "bmsc-order-target-window"}

local function views()
  storage.bmsc_network_views = storage.bmsc_network_views or {}
  return storage.bmsc_network_views
end

local function window(player, name, caption)
  local old = player.gui.screen[name]
  if old then old.destroy() end
  local frame = player.gui.screen.add{type = "frame", name = name, direction = "vertical", caption = caption}
  frame.force_auto_center()
  frame.style.maximal_height = math.max(240, math.floor(player.display_resolution.height / player.display_scale * 0.8))
  local bar = frame.add{type = "flow", direction = "horizontal"}
  bar.add{type = "button", caption = {"bmsc-net.refresh"}, tags = {bmsc_net_action = "refresh", window = name}}
  bar.add{type = "button", caption = {"gui.close"}, tags = {bmsc_net_action = "close", window = name}}
  local content = frame.add{type = "scroll-pane", direction = "vertical", horizontal_scroll_policy = "auto"}
  content.style.maximal_height = math.max(180, frame.style.maximal_height - 100)
  player.opened = frame
  return frame, content
end

local function location(records, unit)
  local r = records[unit]
  if r and r.entity.valid then return "#" .. unit .. " @ " .. r.entity.surface.name end
  return unit and "#" .. unit or "—"
end

function UI.refresh_network(player, records)
  if not player.gui.screen[UI.name] then return end
  local view = views()[player.index] or {}
  local parts = {}
  for _, task in ipairs(Network.tasks(player.force.index)) do
    parts[#parts + 1] = task.id .. ":" .. task.quantity .. ":" .. tostring(task.owner)
      .. ":" .. task.status .. ":" .. tostring(task.current_recipe) .. ":" .. tostring(task.blocked)
  end
  local signature = table.concat(parts, "|")
  if view.network_signature ~= signature then
    UI.open_network(player, records)
    views()[player.index].network_signature = signature
  end
end

function UI.open_network(player, records)
  local view = views()[player.index] or {}
  views()[player.index] = view
  view.folded = view.folded or {}
  local _, content = window(player, UI.name, {"bmsc-net.title"})
  local tasks = Network.tasks(player.force.index)
  local counts, qty = {}, 0
  local by_key = {}
  for _, task in ipairs(tasks) do
    counts[task.status] = (counts[task.status] or 0) + 1
    qty = qty + task.quantity
    by_key[task.key] = task
  end
  content.add{type = "label", caption = {"bmsc-net.summary", #tasks, qty,
    counts.pending or 0, (counts.assigned or 0) + (counts.producing or 0),
    counts.waiting_materials or 0, counts.waiting_transport or 0}}
  local grid = content.add{type = "table", column_count = 8}
  for _, key in ipairs({"task", "product", "quantity", "source", "owner", "recipe", "status", "actions"}) do
    grid.add{type = "label", caption = {"bmsc-net." .. key}, style = "heading_2_label"}
  end
  for _, task in ipairs(tasks) do
    local parent, hidden, depth = task.parent, false, 0
    while parent and by_key[parent] and depth < 16 do
      if view.folded[parent] then hidden = true end
      parent, depth = by_key[parent].parent, depth + 1
    end
    if not hidden then
      grid.add{type = "button", caption = string.rep("  ", depth) .. (view.folded[task.key] and "+ " or "− ") .. task.id,
        tags = {bmsc_net_action = "fold", task = task.key}}
      grid.add{type = "sprite-button", sprite = (task.signal.type or "item") .. "/" .. task.signal.name,
        elem_tooltip = task.signal, number = task.quantity, style = "slot_button"}
      grid.add{type = "label", caption = tostring(task.quantity) .. " / " .. tostring(task.owner and task.quantity or 0)}
      for _, unit in ipairs({task.source, task.owner or 0}) do
        grid.add{type = "button", caption = location(records, unit ~= 0 and unit or nil),
          enabled = records[unit] ~= nil, tags = {bmsc_net_action = "locate", unit = unit}}
      end
      local recipe = task.current_recipe and task.current_recipe:match("^recipe:(.+)$")
      if recipe and prototypes.recipe[recipe] then
        grid.add{type = "sprite-button", sprite = "recipe/" .. recipe, style = "slot_button",
          elem_tooltip = {type = "recipe", name = recipe}}
      else grid.add{type = "label", caption = "—"} end
      grid.add{type = "label", caption = {"bmsc-net." .. (task.blocked or task.status)}}
      grid.add{type = "button", caption = {"bmsc-net.release"}, enabled = task.status == "waiting_transport",
        tooltip = {"bmsc-net.release-help"}, tags = {bmsc_net_action = "release", task = task.key}}
    end
  end
end

local function signal_key_parse(key)
  local kind, name, quality = key:match("^([^:]+):([^:]+):?(.*)$")
  return kind and Util.make_signal(kind, name, quality ~= "" and quality or nil)
end

function UI.open_tree(player, record, signal, count)
  local view = views()[player.index] or {}
  if view.unit ~= record.entity.unit_number or not view.signal or Util.signal_key(view.signal) ~= Util.signal_key(signal) then
    view = {collapsed = {}, initial_tree = true}
  end
  views()[player.index] = view
  view.unit, view.signal, view.count = record.entity.unit_number, signal, count
  view.collapsed = view.collapsed or {}
  local frame, content = window(player, UI.tree_name, {"bmsc-net.tree-title"})
  frame.tags = {bmsc_signal_type = signal.type, bmsc_signal_name = signal.name,
    bmsc_signal_quality = signal.quality, bmsc_order_count = count}
  local roots = record.supermarket_order_plan and record.supermarket_order_plan.roots or {}
  local root
  for _, node in ipairs(roots) do if node.source_key == Util.signal_key(signal) then root = node; break end end
  local selected_node
  local function draw(node, path)
    if view.initial_tree and record.config.recurise_depth > 0 and node.level >= record.config.recurise_depth then
      view.collapsed[path] = true
    end
    local key = Util.signal_key(node.signal)
    if key == view.selected then selected_node = node end
    local row = content.add{type = "flow", direction = "horizontal"}
    row.style.left_padding = math.min(400, (node.level - 1) * 20)
    row.add{type = "button", caption = view.collapsed[path] and "+" or "−", enabled = #node.children > 0,
      tags = {bmsc_net_action = "collapse", path = path}}
    row.add{type = "sprite-button", sprite = node.signal.type .. "/" .. node.signal.name,
      elem_tooltip = node.signal, style = key == view.selected and "green_circuit_network_content_slot" or "slot_button",
      tags = {bmsc_net_action = "select", key = key}}
    if node.recipe_name then
      row.add{type = "sprite-button", sprite = "recipe/" .. node.recipe_name,
        style = "green_circuit_network_content_slot", elem_tooltip = {type = "recipe", name = node.recipe_name},
        tags = {bmsc_net_action = "select", key = key}}
    end
    if node.cyclic then row.add{type = "label", caption = {"bmsc-net.cycle"}} end
    if record.config.recurise_depth > 0 and node.level > record.config.recurise_depth then
      row.add{type = "label", caption = {"bmsc-net.boundary"}}
    end
    if not view.collapsed[path] then
      for i, child in ipairs(node.children) do draw(child, path .. "/" .. i) end
    end
  end
  if root then draw(root, "root") else content.add{type = "label", caption = {"bmsc-net.no-tree"}} end
  view.initial_tree = nil
  -- 无法构树的根仍能编辑候选，以便从失效配置恢复。
  local selected = view.selected and signal_key_parse(view.selected) or root and root.signal
    or select(1, Util.resolve_recipe_input(signal))
  if not selected then return end
  view.selected = Util.signal_key(selected)
  local candidates = Util.available_recipes(record.entity.force, selected, record.config.production_machine)
  local target = Target.resolve(record.entity.force, record.config.production_machine, signal, record.config)
  local chosen = selected_node and selected_node.recipe_name or root and root.recipe_name
  content.add{type = "line"}
  content.add{type = "label", caption = {"bmsc-net.policy-help"}}
  content.add{type = "button", caption = {"bmsc-net.automatic"}, tags = {bmsc_net_action = "automatic"}}
  local grid = content.add{type = "table", column_count = 5}
  for _, key in ipairs({"enabled", "recipe", "priority", "demand", "retention"}) do
    grid.add{type = "label", caption = {"bmsc-net." .. key}}
  end
  local entries = record.config.recipe_policies[view.selected] or {}
  for _, recipe in ipairs(candidates) do
    local saved
    for _, entry in ipairs(entries) do if entry.recipe == recipe.name then saved = entry end end
    grid.add{type = "checkbox", state = saved ~= nil, caption = "",
      tags = {bmsc_net_policy = recipe.name, unit = view.unit, key = view.selected}}
    grid.add{type = "sprite-button", sprite = "recipe/" .. recipe.name,
      style = chosen == recipe.name and "green_circuit_network_content_slot" or "slot_button",
      elem_tooltip = {type = "recipe", name = recipe.name}}
    for _, field in ipairs({"priority", "demand", "retention"}) do
      local value = saved and saved[field] or (field == "priority" and 0
        or field == "demand" and record.config.recursion_material_demand_rate or record.config.recursion_material_retention_rate)
      local input = grid.add{type = "textfield", text = tostring(value), numeric = true,
        allow_decimal = true, allow_negative = field == "priority", enabled = saved ~= nil,
        tags = {bmsc_net_field = field, recipe = recipe.name, unit = view.unit, key = view.selected}}
      input.style.width = 90
    end
  end
  -- 根订单的多产物完成条件保留，策略编辑不能丢掉既有设置。
  if target.available_products and #target.available_products > 1 then
    local row = content.add{type = "flow", direction = "horizontal"}
    row.add{type = "label", caption = {"bmsc.order-target-products"}}
    for _, product in ipairs(target.available_products) do
      local active = false
      for _, current in ipairs(target.products) do if Util.signal_key(current) == Util.signal_key(product) then active = true end end
      row.add{type = "sprite-button", sprite = product.type .. "/" .. product.name, elem_tooltip = product,
        style = active and "green_circuit_network_content_slot" or "slot_button",
        tags = {bmsc_net_action = "product", key = Util.signal_key(product)}}
    end
  end
end

local function refresh_tree(player, records, invalidate)
  local view = views()[player.index]
  local r = view and records[view.unit]
  if not (r and r.entity.valid and r.entity.force == player.force) then return end
  if invalidate then SupermarketOrder.invalidate_plan(r) end
  SupermarketOrder.calculate(r)
  UI.open_tree(player, r, view.signal, view.count)
end

function UI.on_click(event, records)
  local tags = event.element.tags or {}
  local action = tags.bmsc_net_action
  if not action then return false end
  local player = game.get_player(event.player_index)
  local view = views()[player.index] or {}
  if action == "close" then
    local frame = player.gui.screen[tags.window]
    if frame then frame.destroy() end
    player.opened = player.gui.screen["bmsc-window"]
  elseif action == "locate" then
    local r = records[tags.unit]
    if r and r.entity.valid and r.entity.force == player.force then
      player.set_controller{type = defines.controllers.remote, position = r.entity.position, surface = r.entity.surface}
    end
  elseif action == "release" then
    Network.release(tags.task, player.force.index)
    UI.open_network(player, records)
  elseif action == "fold" then
    view.folded[tags.task] = not view.folded[tags.task]
    UI.open_network(player, records)
  elseif action == "refresh" and tags.window == UI.name then UI.open_network(player, records)
  else
    local r = records[view.unit]
    if not r or not r.entity.valid or r.entity.force ~= player.force then return true end
    if action == "select" then view.selected = tags.key end
    if action == "collapse" then view.collapsed[tags.path] = not view.collapsed[tags.path] end
    if action == "automatic" then
      r.config.recipe_policies[view.selected] = nil
      local legacy = r.config.order_targets[view.selected]
      if legacy then legacy.recipe = nil end
    end
    if action == "product" then
      local target = Target.resolve(r.entity.force, r.config.production_machine, view.signal, r.config)
      local products, found = {}, false
      for _, p in ipairs(target.products) do
        if Util.signal_key(p) == tags.key then found = true else products[#products + 1] = p end
      end
      if not found then products[#products + 1] = signal_key_parse(tags.key) end
      if products[1] then
        local key = Util.signal_key(view.signal)
        r.config.order_targets[key] = r.config.order_targets[key] or {}
        r.config.order_targets[key].products = products
      end
    end
    refresh_tree(player, records, action == "automatic" or action == "product")
  end
  return true
end

function UI.on_checked(event, records)
  local tags = event.element.tags or {}
  if not tags.bmsc_net_policy and not tags.bmsc_net_config then return false end
  local r, player = records[tags.unit], game.get_player(event.player_index)
  if not r or not r.entity.valid or r.entity.force ~= player.force then return true end
  if tags.bmsc_net_config then
    local field = tags.bmsc_net_config
    if field == "network_publish" or field == "network_accept" or field == "network_export" or field == "network_import" then
      r.config[field] = event.element.state
      if field == "network_publish" and r.config.inventory_validation == "none" then
        r.config[field], event.element.state = false, false
        player.print({"bmsc-net.requires-inventory"})
      end
    end
  else
    local entries = r.config.recipe_policies[tags.key] or {}
    r.config.recipe_policies[tags.key] = entries
    for i = #entries, 1, -1 do if entries[i].recipe == tags.bmsc_net_policy then table.remove(entries, i) end end
    if event.element.state then entries[#entries + 1] = {recipe = tags.bmsc_net_policy, priority = 0,
      demand = r.config.recursion_material_demand_rate, retention = r.config.recursion_material_retention_rate} end
    if not entries[1] then r.config.recipe_policies[tags.key] = nil end
    refresh_tree(player, records, true)
  end
  return true
end

function UI.on_text(event, records)
  local tags = event.element.tags or {}
  if not tags.bmsc_net_field then return false end
  local r, player = records[tags.unit], game.get_player(event.player_index)
  local value = tonumber(event.element.text)
  if not r or not r.entity.valid or r.entity.force ~= player.force or not value or value ~= value or math.abs(value) == math.huge then return true end
  if tags.bmsc_net_field == "network_priority" then r.config.network_priority = value; return true end
  for _, entry in ipairs(r.config.recipe_policies[tags.key] or {}) do
    if entry.recipe == tags.recipe then
      local field = tags.bmsc_net_field
      local valid = field == "priority" or field == "demand" and value > entry.retention
        or field == "retention" and value >= 0 and value < entry.demand
      event.element.style = valid and "textfield" or "invalid_value_textfield"
      if valid then
        entry[field] = value
        SupermarketOrder.invalidate_plan(r)
      end
    end
  end
  return true
end

function UI.settings(parent, entity, config)
  local group = parent.add{type = "flow", name = "bmsc-network-settings", direction = "vertical"}
  group.visible = config.mode == "supermarket_order"
  group.add{type = "label", caption = {"bmsc-net.title"}, style = "heading_2_label"}
  for _, field in ipairs({"network_publish", "network_accept", "network_export", "network_import"}) do
    group.add{type = "checkbox", caption = {"bmsc-net." .. field}, state = config[field] == true,
      tags = {bmsc_net_config = field, unit = entity.unit_number}}
  end
  local row = group.add{type = "flow", direction = "horizontal"}
  row.add{type = "label", caption = {"bmsc-net.priority"}}
  row.add{type = "textfield", text = tostring(config.network_priority or 0), numeric = true, allow_negative = true,
    tags = {bmsc_net_field = "network_priority", unit = entity.unit_number}}
end

return UI
