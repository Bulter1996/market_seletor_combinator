-- 网络任务查看与递归策略编辑；只把稳定配置写入 record.config。
local Util = require("scripts.common_util")
local Target = require("scripts.order_target")
local Network = require("scripts.production_network")
local SupermarketOrder = require("scripts.modes.supermarket_order") -- 事件回调不得动态 require。
local UI = {
  name = "bmsc-network-window",
  tree_name = "bmsc-order-target-window",
  policy_name = "bmsc-tree-policy-window"
}
local LOCATE_ZOOM = 1 -- 远程定位需保留周边参照，不能以最近视角贴满目标组合器。
local LARGE_ICON = 56
local POLICY_ICON = 42 -- 原版 32px 槽位的约 1.3 倍，和树节点图标区分但不喧宾夺主。
local POLICY_FIELD_WIDTH = 56
local POLICY_PRIORITY_WIDTH = 30
local POLICY_WINDOW_WIDTH = 250 -- 固定紧凑宽度，使右边框能精确锚定鼠标位置。
local POLICY_CURSOR_VERTICAL_OFFSET = 24
local POLICY_OPACITY_SETTING = "bmsc-policy-gui-opacity"
local POLICY_OPACITY_STYLES = {
  ["100"] = "bmsc_policy_frame_100",
  ["80"] = "bmsc_policy_frame_80",
  ["60"] = "bmsc_policy_frame_60",
  ["40"] = "bmsc_policy_frame_40"
}

local function views()
  storage.bmsc_network_views = storage.bmsc_network_views or {}
  return storage.bmsc_network_views
end

local function add_large_slot(parent, spec, size)
  local slot = parent.add(spec)
  slot.style.width = size or LARGE_ICON
  slot.style.height = size or LARGE_ICON
  return slot
end

local function tree_icon_size(view)
  return math.max(1, math.floor(LARGE_ICON * (view.tree_scale or 1) + 0.0001))
end

local function policy_frame_style(player)
  local setting = player.mod_settings and player.mod_settings[POLICY_OPACITY_SETTING]
  return POLICY_OPACITY_STYLES[setting and setting.value] or POLICY_OPACITY_STYLES["60"]
end

local function tree_window_size(player, view)
  local display_width = math.floor(player.display_resolution.width / player.display_scale)
  local display_height = math.floor(player.display_resolution.height / player.display_scale)
  if view.window_scale == 2 then return display_width - 10, display_height - 10 end
  return math.max(360, math.floor(display_width * 2 / 3)), math.max(240, math.floor(display_height / 2))
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

---创建递归配方策略窗口。位置只属于玩家视图，不能写进组合器或蓝图配置。
local function tree_window(player, view, record, signal, count)
  local old = player.gui.screen[UI.tree_name]
  if old then
    local location = old.location
    if location then view.tree_location = {x = location.x, y = location.y} end
    old.destroy()
  end
  local frame = player.gui.screen.add{type = "frame", name = UI.tree_name, direction = "vertical"}
  local width, height = tree_window_size(player, view)
  frame.style.width, frame.style.height = width, height
  if view.tree_location then
    frame.location = view.tree_location
  else
    frame.force_auto_center()
  end

  local titlebar = frame.add{type = "flow", name = "bmsc-tree-titlebar", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", caption = {"bmsc-net.tree-title"}, style = "frame_title"}.drag_target = frame
  local dragger = titlebar.add{type = "empty-widget", style = "draggable_space_header"}
  dragger.style.horizontally_stretchable = true
  dragger.style.height = 24
  dragger.drag_target = frame
  local size_1x = titlebar.add{type = "button", caption = "1x", style = "frame_action_button",
    tooltip = {"bmsc-net.tree-size-1x"}, tags = {bmsc_net_action = "tree-size", tree_window_scale = 1}}
  size_1x.style.width = 36
  size_1x.toggled = view.window_scale ~= 2
  local size_2x = titlebar.add{type = "button", caption = "2x", style = "frame_action_button",
    tooltip = {"bmsc-net.tree-size-2x"}, tags = {bmsc_net_action = "tree-size", tree_window_scale = 2}}
  size_2x.style.width = 36
  size_2x.toggled = view.window_scale == 2
  local pin = titlebar.add{type = "sprite-button", sprite = "utility/enter", style = "frame_action_button",
    tooltip = {view.pinned and "bmsc-net.tree-unpin" or "bmsc-net.tree-pin"}, tags = {bmsc_net_action = "tree-pin"}}
  pin.toggled = view.pinned == true
  titlebar.add{type = "sprite-button", sprite = "utility/close", style = "frame_action_button",
    tooltip = {"gui.close"}, tags = {bmsc_net_action = "close", window = UI.tree_name}}

  local context = frame.add{type = "flow", name = "bmsc-tree-context", direction = "horizontal"}
  context.style.vertical_align = "center"
  local machine = prototypes.entity[record.config.production_machine]
  if machine then
    add_large_slot(context, {type = "sprite-button", sprite = "entity/" .. machine.name, style = "slot_button",
      tooltip = machine.localised_name}
    , 48)
    context.add{type = "label", caption = machine.localised_name}
  end
  frame.add{type = "line"}
  local actions = frame.add{type = "flow", name = "bmsc-tree-actions", direction = "horizontal"}
  actions.style.horizontally_stretchable = true
  actions.style.horizontal_spacing = 0
  actions.add{type = "empty-widget"}.style.horizontally_stretchable = true
  local expand = actions.add{type = "button", caption = "+", style = "frame_action_button",
    tooltip = {"bmsc-net.tree-expand-all"}, tags = {bmsc_net_action = "tree-expand-all"}}
  expand.style.width = 28
  local collapse = actions.add{type = "button", caption = "−", style = "frame_action_button",
    tooltip = {"bmsc-net.tree-collapse-all"}, tags = {bmsc_net_action = "tree-collapse-all"}}
  collapse.style.width = 28
  local tree = frame.add{type = "scroll-pane", name = "bmsc-tree-content", direction = "vertical",
    horizontal_scroll_policy = "auto", vertical_scroll_policy = "auto"}
  -- 缩放只影响树节点；视口尺寸固定，超出部分由滚动条承载，不能带着整个窗口跳动。
  tree.style.width, tree.style.height = width - 24, height - 144
  player.opened = frame
  return frame, tree
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

local refresh_tree

---递归计划只存单次配方用量；树视图在这里按根订单量展开，并在每层制作次数向上取整。
---概率产物的 product_amount 已由公共工具换算为平均产量，必须与实际策略解析共用该值。
local function tree_requirements(root, count)
  local totals = {}
  local function visit(node, required)
    local key = Util.signal_key(node.signal)
    totals[key] = (totals[key] or 0) + required
    if not (node.product_amount and node.product_amount > 0) then return end
    local crafts = math.ceil(required / node.product_amount)
    for _, child in ipairs(node.children or {}) do visit(child, crafts * child.amount) end
  end
  visit(root, math.max(0, tonumber(count) or 0))
  return totals
end

---按叶子跨度排列真实节点；配方本身仍可有多个原料，视觉上不伪造配方节点。
local function binary_layout(root, collapsed)
  local rows, positions, paths, leaves = {}, {}, {}, 0
  local function place(node, level, path)
    rows[level] = rows[level] or {}
    paths[node] = path
    local children = collapsed[path] and {} or node.children or {}
    if not children[1] then
      leaves = leaves + 1
      positions[node] = leaves * 2 - 1
    else
      local first, last
      for index, child in ipairs(children) do
        local position = place(child, level + 1, path .. "." .. index)
        first, last = first or position, position
      end
      positions[node] = math.floor((first + last) / 2)
    end
    rows[level][positions[node]] = node
    return positions[node]
  end
  place(root, 1, "0")
  return rows, positions, paths, math.max(1, leaves * 2 - 1)
end

---切换窗口档位时优先保证当前可见树完整；手动滚轮缩放仍可覆盖这个初始比例。
local function fit_tree_scale(player, view, root)
  local rows, _, _, columns = binary_layout(root, view.collapsed or {})
  local levels = #rows
  local window_width, window_height = tree_window_size(player, view)
  local available_width, available_height = window_width - 40, window_height - 160
  for icon_size = LARGE_ICON * 2, 1, -1 do
    local spacing = math.max(4, math.floor(icon_size / 7))
    local connector_height = math.max(12, math.floor(icon_size / 3))
    local width = columns * icon_size + (columns - 1) * spacing
    local height = levels * icon_size + (levels - 1) * connector_height
    if width <= available_width and height <= available_height then
      view.tree_scale = icon_size / LARGE_ICON
      return
    end
  end
  view.tree_scale = 1 / LARGE_ICON
end

local function tree_root(record, signal)
  local roots = record.supermarket_order_plan and record.supermarket_order_plan.roots or {}
  for _, node in ipairs(roots) do
    if node.source_key == Util.signal_key(signal) then
      local limit = math.max(0, math.floor(tonumber(record.config.recurise_depth) or 0))
      if limit == 0 then return node end
      local function trim(current)
        local visible = {}
        for key, value in pairs(current) do visible[key] = value end
        visible.children = {}
        -- 深度上限的下一层是当前输出边界，显示它但不再展开其原料。
        if (current.level or 1) <= limit then
          for _, child in ipairs(current.children or {}) do visible.children[#visible.children + 1] = trim(child) end
        end
        return visible
      end
      return trim(node)
    end
  end
end

---“收起全部”只改每个节点自身的状态；之后展开父节点时，子节点仍保持各自的收起状态。
local function collapse_tree(node, path, collapsed)
  if not (node.children and node.children[1]) then return end
  collapsed[path] = true
  for index, child in ipairs(node.children) do
    collapse_tree(child, path .. "." .. index, collapsed)
  end
end

---Factorio screen GUI 没有任意坐标画布；在节点层间以原生标签画出紧凑的父子连线。
local function add_tree_connectors(content, parents, positions, paths, collapsed, columns, icon_size, left_padding)
  local horizontal, vertical = {}, {}
  for _, parent in pairs(parents) do
    local children = collapsed[paths[parent]] and {} or parent.children or {}
    if children[1] then
      local first, last = positions[parent], positions[parent]
      vertical[positions[parent]] = true
      for _, child in ipairs(children) do
        local position = positions[child]
        first, last = math.min(first, position), math.max(last, position)
        vertical[position] = true
      end
      for column = first, last do horizontal[column] = true end
    end
  end
  if not next(vertical) then return end
  local row = content.add{type = "table", column_count = columns}
  row.style.horizontal_spacing = math.max(4, math.floor(icon_size / 7))
  row.style.left_padding = left_padding
  for column = 1, columns do
    local glyph = horizontal[column] and (vertical[column] and "┼" or "─") or (vertical[column] and "│" or " ")
    local line = row.add{type = "label", caption = glyph}
    line.style.width = icon_size
    line.style.height = math.max(12, math.floor(icon_size / 3))
    line.style.horizontal_align = "center"
  end
end

local function inventory_for_tree(record, key, required)
  local mode = record.config.inventory_validation
  if mode ~= "inventory" and mode ~= "linked" then return nil end
  -- 关联库存首个快照到达前不能把未知库存伪装为 0；普通红线空输入则是有效的 0。
  if mode == "linked" and record.recursion_inventory_pending_tick then return nil end
  local inventory = record.network_observed_inventory
  if type(inventory) ~= "table" then return nil end
  local stock = inventory[key]
  if type(stock) ~= "number" then stock = 0 end
  return {stock = stock, sufficient = stock >= required}
end

local function tree_candidates(record, node)
  local entries = record.config.recipe_policies[Util.signal_key(node.signal)] or {}
  local text, added = {""}, false
  for _, entry in ipairs(entries) do
    local recipe = prototypes.recipe[entry.recipe]
    if recipe then
      if added then text[#text + 1] = ", " end
      text[#text + 1], added = recipe.localised_name, true
    end
  end
  if not added and node.recipe_name and prototypes.recipe[node.recipe_name] then
    text[#text + 1] = prototypes.recipe[node.recipe_name].localised_name
  end
  return text
end

local function tree_tooltip(record, node, required, inventory)
  local prototype = prototypes[node.signal.type] and prototypes[node.signal.type][node.signal.name]
  local tooltip = {"", prototype and prototype.localised_name or node.signal.name,
    "\n", {"bmsc-net.tree-total-required", math.ceil(required)},
    "\n", {"bmsc-net.tree-current-candidates"}, tree_candidates(record, node),
    "\n", {"bmsc-net.tree-node-help"}}
  if inventory then
    tooltip[#tooltip + 1] = "\n"
    tooltip[#tooltip + 1] = inventory.sufficient and {"bmsc-net.tree-stock-surplus", inventory.stock,
      math.ceil(inventory.stock - required)} or {"bmsc-net.tree-stock-shortage", inventory.stock,
      math.ceil(required - inventory.stock)}
  end
  return tooltip
end

function UI.open_tree(player, record, signal, count)
  local view = views()[player.index] or {}
  if view.unit ~= record.entity.unit_number or not view.signal or Util.signal_key(view.signal) ~= Util.signal_key(signal) then
    view = {tree_location = view.tree_location}
  end
  views()[player.index] = view
  view.unit, view.signal, view.count = record.entity.unit_number, signal, count
  view.collapsed = view.collapsed or {}
  local frame, content = tree_window(player, view, record, signal, count)
  frame.tags = {bmsc_signal_type = signal.type, bmsc_signal_name = signal.name,
    bmsc_signal_quality = signal.quality, bmsc_order_count = count}
  local root = tree_root(record, signal)
  if not root then
    content.add{type = "label", caption = {"bmsc-net.no-tree"}}
    return
  end
  local totals = tree_requirements(root, count)
  local rows, positions, paths, columns = binary_layout(root, view.collapsed)
  local icon_size = tree_icon_size(view)
  local spacing = math.max(4, math.floor(icon_size / 7))
  local tree_width = columns * icon_size + (columns - 1) * spacing
  local window_width = tree_window_size(player, view)
  local left_padding = math.max(0, math.floor((window_width - 24 - tree_width) / 2))
  for level, row_nodes in ipairs(rows) do
    local row = content.add{type = "table", column_count = columns}
    row.style.horizontal_spacing = spacing
    row.style.left_padding = left_padding
    for column = 1, columns do
      local cell = row.add{type = "flow", direction = "vertical"}
      cell.style.width = icon_size
      local node = row_nodes[column]
      if node then
        local key = Util.signal_key(node.signal)
        local required = totals[key] or 0
        local inventory = inventory_for_tree(record, key, required)
        local style = inventory and (inventory.sufficient and "green_circuit_network_content_slot"
          or "red_circuit_network_content_slot") or "slot_button"
        add_large_slot(cell, {type = "sprite-button", sprite = node.signal.type .. "/" .. node.signal.name,
          number = math.ceil(required), style = style, tooltip = tree_tooltip(record, node, required, inventory),
          tags = {bmsc_net_action = "select", key = key, type = node.signal.type, name = node.signal.name,
            quality = node.signal.quality, path = paths[node], has_children = node.children and node.children[1] ~= nil}}, icon_size)
      else
        local spacer = cell.add{type = "empty-widget"}
        spacer.style.width, spacer.style.height = icon_size, icon_size
      end
    end
    if rows[level + 1] then
      add_tree_connectors(content, row_nodes, positions, paths, view.collapsed, columns, icon_size, left_padding)
    end
  end
end

function UI.on_zoom(event, records, delta)
  local player = game.get_player(event.player_index)
  if not (player and event.in_gui and player.gui.screen[UI.tree_name]) then return false end
  if player.gui.screen[UI.policy_name] then return false end
  local view = views()[player.index]
  local record = view and records[view.unit]
  if not (record and record.entity.valid and record.entity.force == player.force) then return false end
  view.tree_scale = math.max(1 / LARGE_ICON, math.min(2, (view.tree_scale or 1) + delta))
  UI.open_tree(player, record, view.signal, view.count)
  return true
end

---树是浏览器，策略编辑使用独立短暂浮层；两者共享同一玩家视图而不互相重建。
function UI.open_policy(player, record, selected, cursor)
  local view = views()[player.index] or {}
  views()[player.index] = view
  local old = player.gui.screen[UI.policy_name]
  local old_location = old and old.location
  if old_location then view.policy_location = {x = old_location.x, y = old_location.y} end
  if old then old.destroy() end
  view.selected = Util.signal_key(selected)
  local frame = player.gui.screen.add{type = "frame", name = UI.policy_name, direction = "vertical",
    style = policy_frame_style(player)}
  frame.style.width = POLICY_WINDOW_WIDTH
  frame.style.maximal_height = math.max(240, math.floor(player.display_resolution.height / player.display_scale * 0.8))
  local location
  if cursor then
    local screen = player.display_resolution
    local scale = player.display_scale
    location = {x = math.max(0, math.min(cursor.x - POLICY_WINDOW_WIDTH, math.floor(screen.width / scale) - POLICY_WINDOW_WIDTH)),
      y = math.max(0, math.min(cursor.y + POLICY_CURSOR_VERTICAL_OFFSET, math.floor(screen.height / scale) - 288))}
  elseif old_location then
    location = old_location
  elseif view.policy_location then
    location = view.policy_location
  end
  if location then
    frame.location = location
    view.policy_location = {x = location.x, y = location.y}
  else
    frame.force_auto_center()
  end
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", caption = {"bmsc-net.policy-editor-title"}, style = "frame_title"}.drag_target = frame
  local dragger = titlebar.add{type = "empty-widget", style = "draggable_space_header"}
  dragger.style.horizontally_stretchable = true
  dragger.style.height = 24
  dragger.drag_target = frame
  titlebar.add{type = "sprite-button", sprite = "utility/close", style = "frame_action_button",
    tooltip = {"gui.close"}, tags = {bmsc_net_action = "close", window = UI.policy_name}}
  local content = frame.add{type = "scroll-pane", direction = "vertical", horizontal_scroll_policy = "never"}
  content.style.maximal_height = math.max(180, frame.style.maximal_height - 40)
  local header = content.add{type = "flow", direction = "horizontal"}
  header.style.vertical_align = "center"
  add_large_slot(header, {type = "sprite-button", sprite = selected.type .. "/" .. selected.name,
    style = "slot_button", elem_tooltip = selected}, POLICY_ICON)
  local prototype = prototypes[selected.type] and prototypes[selected.type][selected.name]
  header.add{type = "label", caption = prototype and prototype.localised_name or selected.name, style = "heading_2_label"}
  header.add{type = "empty-widget"}.style.horizontally_stretchable = true
  header.add{type = "sprite-button", sprite = "utility/refresh", style = "frame_action_button",
    tooltip = {"bmsc-net.automatic"}, tags = {bmsc_net_action = "automatic"}}
  local entries = record.config.recipe_policies[view.selected] or {}
  local default_recipe = not entries[1] and Util.find_recipe(record.entity.force, selected, record.config.production_machine) or nil
  -- 等价配方会被候选列表去重；把自动解析结果作为偏好传入，保证默认绿色项始终可见。
  local candidates = Util.available_recipes(record.entity.force, selected, record.config.production_machine,
    default_recipe and default_recipe.name)
  local grid = content.add{type = "table", column_count = 4}
  for _, recipe in ipairs(candidates) do
    local saved
    for _, entry in ipairs(entries) do if entry.recipe == recipe.name then saved = entry end end
    local is_default = not saved and default_recipe and default_recipe.name == recipe.name
    local current = saved or (is_default and {recipe = recipe.name, priority = 0,
      demand = record.config.recursion_material_demand_rate, retention = record.config.recursion_material_retention_rate})
    add_large_slot(grid, {type = "sprite-button", sprite = "recipe/" .. recipe.name,
      style = current and "green_circuit_network_content_slot" or "slot_button",
      elem_tooltip = {type = "recipe", name = recipe.name}, tooltip = {"bmsc-net.toggle-policy"},
      tags = {bmsc_net_action = "policy", recipe = recipe.name, unit = view.unit, key = view.selected,
        default = is_default == true}}, POLICY_ICON)
    for _, field in ipairs({"demand", "retention", "priority"}) do
      local value = current and current[field] or (field == "priority" and 0
        or field == "demand" and record.config.recursion_material_demand_rate or record.config.recursion_material_retention_rate)
      local input = grid.add{type = "textfield", text = tostring(value), numeric = true,
        allow_decimal = true, allow_negative = field == "priority", enabled = current ~= nil,
        tooltip = {"bmsc-net." .. field .. "-help"},
        tags = {bmsc_net_field = field, recipe = recipe.name, unit = view.unit, key = view.selected,
          default = is_default == true}}
      input.style.width = field == "priority" and POLICY_PRIORITY_WIDTH or POLICY_FIELD_WIDTH
    end
  end
  -- 根订单的多产物完成条件保留在独立浮层中，不能因拆分树视图而丢失既有配置。
  local target = Target.resolve(record.entity.force, record.config.production_machine, view.signal, record.config)
  if target.available_products and #target.available_products > 1 then
    local row = content.add{type = "flow", direction = "horizontal"}
    row.add{type = "label", caption = {"bmsc.order-target-products"}}
    for _, product in ipairs(target.available_products) do
      local active = false
      for _, current in ipairs(target.products) do if Util.signal_key(current) == Util.signal_key(product) then active = true end end
      add_large_slot(row, {type = "sprite-button", sprite = product.type .. "/" .. product.name, elem_tooltip = product,
        style = active and "green_circuit_network_content_slot" or "slot_button",
        tags = {bmsc_net_action = "product", key = Util.signal_key(product)}}, POLICY_ICON)
    end
  end
  player.opened = frame
end

function UI.on_closed(event, records)
  if not (event.element and event.element.valid) then return false end
  local player = game.get_player(event.player_index)
  if event.element.name == UI.policy_name then
    event.element.destroy()
    local view = views()[player.index]
    local tree = player.gui.screen[UI.tree_name]
    if view and view.policy_dirty then
      view.policy_dirty = nil
      refresh_tree(player, records, true)
    else
      player.opened = tree and tree.valid and tree or nil
    end
    return true
  end
  if event.element.name == UI.tree_name then
    local policy = player.gui.screen[UI.policy_name]
    -- 打开独立配置浮层会让 tree 失去 opened 焦点并触发此事件；这不是关闭树。
    if policy and policy.valid then return true end
    local view = views()[player.index]
    if view and view.pinned then return true end
    if policy then policy.destroy() end
    event.element.destroy()
    player.opened = player.gui.screen["bmsc-window"]
    return true
  end
  return false
end

function UI.on_location_changed(event)
  if not (event.element and event.element.valid
    and (event.element.name == UI.tree_name or event.element.name == UI.policy_name)) then return false end
  local location = event.element.location
  if location then
    local view = views()[event.player_index] or {}
    views()[event.player_index] = view
    if event.element.name == UI.tree_name then
      view.tree_location = {x = location.x, y = location.y}
    else
      view.policy_location = {x = location.x, y = location.y}
    end
  end
  return true
end

function refresh_tree(player, records, invalidate)
  local view = views()[player.index]
  local r = view and records[view.unit]
  if not (r and r.entity.valid and r.entity.force == player.force) then return end
  if invalidate then SupermarketOrder.invalidate_plan(r) end
  SupermarketOrder.calculate(r)
  UI.open_tree(player, r, view.signal, view.count)
end

local function set_policy_enabled(record, tags, enabled)
  local entries = record.config.recipe_policies[tags.key] or {}
  record.config.recipe_policies[tags.key] = entries
  for index = #entries, 1, -1 do
    if entries[index].recipe == tags.recipe then table.remove(entries, index) end
  end
  if enabled then
    entries[#entries + 1] = {recipe = tags.recipe, priority = 0,
      demand = record.config.recursion_material_demand_rate, retention = record.config.recursion_material_retention_rate}
  end
  if not entries[1] then record.config.recipe_policies[tags.key] = nil end
end

function UI.on_click(event, records)
  local tags = event.element.tags or {}
  local action = tags.bmsc_net_action
  if not action then return false end
  local player = game.get_player(event.player_index)
  local view = views()[player.index] or {}
  if action == "close" then
    if tags.window == UI.policy_name then
      local policy = player.gui.screen[UI.policy_name]
      if policy then policy.destroy() end
      if view.policy_dirty then
        view.policy_dirty = nil
        refresh_tree(player, records, true)
      else
        player.opened = player.gui.screen[UI.tree_name]
      end
      return true
    end
    if tags.window == UI.tree_name then
      local policy = player.gui.screen[UI.policy_name]
      if policy then policy.destroy() end
    end
    local frame = player.gui.screen[tags.window]
    if frame then frame.destroy() end
    player.opened = player.gui.screen["bmsc-window"]
  elseif action == "locate" then
    local r = records[tags.unit]
    if r and r.entity.valid and r.entity.force == player.force then
      player.set_controller{type = defines.controllers.remote, position = r.entity.position, surface = r.entity.surface}
      player.zoom = LOCATE_ZOOM
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
    if action == "tree-size" then
      view.window_scale = tags.tree_window_scale == 2 and 2 or 1
      local root = tree_root(r, view.signal)
      if root then fit_tree_scale(player, view, root) end
      UI.open_tree(player, r, view.signal, view.count)
      return true
    end
    if action == "tree-pin" then
      view.pinned = not view.pinned
      UI.open_tree(player, r, view.signal, view.count)
      return true
    end
    if action == "tree-expand-all" then
      view.collapsed = {}
      UI.open_tree(player, r, view.signal, view.count)
      return true
    end
    if action == "tree-collapse-all" then
      view.collapsed = {}
      local root = tree_root(r, view.signal)
      if root then collapse_tree(root, "0", view.collapsed) end
      UI.open_tree(player, r, view.signal, view.count)
      return true
    end
    if action == "select" then
      local selected = Util.make_signal(tags.type, tags.name, tags.quality)
      if event.button and event.button == defines.mouse_button_type.right then
        if tags.has_children then
          view.collapsed = view.collapsed or {}
          if view.collapsed[tags.path] then
            view.collapsed[tags.path] = nil
          else
            view.collapsed[tags.path] = true
          end
          UI.open_tree(player, r, view.signal, view.count)
        end
        return true
      end
      if event.alt and event.button == defines.mouse_button_type.left then
        local group = selected.type == "fluid" and prototypes.fluid or prototypes.item
        local prototype = group and group[selected.name]
        if prototype then player.open_factoriopedia_gui(prototype) end
        return true
      end
      view.selected = tags.key
      UI.open_policy(player, r, selected, event.cursor_display_location)
      return true
    end
    if action == "policy" then
      local enabled = false
      local entries = r.config.recipe_policies[tags.key] or {}
      for _, entry in ipairs(entries) do
        if entry.recipe == tags.recipe then enabled = true; break end
      end
      enabled = enabled or (tags.default and not entries[1])
      if enabled and #entries <= 1 then
        player.print({"bmsc-net.policy-at-least-one"})
        return true
      end
      set_policy_enabled(r, tags, not enabled)
    end
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
    refresh_tree(player, records, action == "automatic" or action == "policy" or action == "product")
    if action == "automatic" or action == "policy" or action == "product" then
      UI.open_policy(player, r, signal_key_parse(view.selected))
    end
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
    if not event.element.state and #entries <= 1 then
      event.element.state = true
      player.print({"bmsc-net.policy-at-least-one"})
      return true
    end
    set_policy_enabled(r, {key = tags.key, recipe = tags.bmsc_net_policy}, event.element.state)
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
  local entries = r.config.recipe_policies[tags.key] or {}
  local entry
  for _, current in ipairs(entries) do
    if current.recipe == tags.recipe then entry = current; break end
  end
  if not entry and tags.default then
    set_policy_enabled(r, tags, true)
    entries = r.config.recipe_policies[tags.key] or {}
    entry = entries[#entries]
  end
  if entry then
    local field = tags.bmsc_net_field
    local valid = field == "priority" or field == "demand" and value > entry.retention
      or field == "retention" and value >= 0 and value < entry.demand
    event.element.style = valid and "textfield" or "invalid_value_textfield"
    if valid then
      entry[field] = value
      SupermarketOrder.invalidate_plan(r)
      -- 文本输入每个字符都会触发事件；等 Esc/关闭浮层后统一重建树，避免焦点跳动。
      local view = views()[player.index] or {}
      views()[player.index] = view
      view.policy_dirty = true
    end
  end
  return true
end

function UI.settings(parent, entity, config)
  local group = parent.add{type = "frame", name = "bmsc-network-settings",
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  group.style.horizontally_stretchable = true
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
