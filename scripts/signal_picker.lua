-- 条件专用的信号/常量选择器。
-- Factorio 的 choose-elem-button 只能返回 SignalID，无法暴露原生组合器的“设置常量”；
-- 本模块用原版 GUI 样式补齐这一能力，并把选择结果交还 control.lua。

local Picker = {}
Picker.name = "bmsc-signal-picker"

local CONTENT = "bmsc-signal-picker-content"
local SEARCH = "bmsc-signal-picker-search"
local CONSTANT = "bmsc-signal-picker-constant"
local SLIDER = "bmsc-signal-picker-slider"
local signal_groups

local sprite_prefix = {
  item = "item", fluid = "fluid", virtual = "virtual-signal", entity = "entity",
  ["space-location"] = "space-location", ["asteroid-chunk"] = "asteroid-chunk",
  quality = "quality"
}

local function state()
  if type(storage.bmsc_signal_picker) ~= "table" then storage.bmsc_signal_picker = {} end
  return storage.bmsc_signal_picker
end

local function find_named(parent, name)
  if not parent then return nil end
  if parent.name == name then return parent end
  for _, child in ipairs(parent.children) do
    local found = find_named(child, name)
    if found then return found end
  end
end

local function signal_sprite(signal)
  return (sprite_prefix[signal.type or "item"] or "item") .. "/" .. signal.name
end

local function build_index()
  if signal_groups then return signal_groups end
  local by_group = {}
  local placed_by_item = {}
  for _, prototype in pairs(prototypes.item or {}) do
    if prototype.place_result then placed_by_item[prototype.place_result.name] = true end
  end
  local sources = {
    item = prototypes.item, fluid = prototypes.fluid, virtual = prototypes.virtual_signal,
    entity = prototypes.entity, ["space-location"] = prototypes.space_location,
    ["asteroid-chunk"] = prototypes.asteroid_chunk, quality = prototypes.quality
  }
  for signal_type, source in pairs(sources) do
    for name, prototype in pairs(source or {}) do
      -- 可放置实体已经由对应物品表示，重复加入 entity 会让每个图标出现两次。
      if not prototype.hidden and not (signal_type == "entity" and placed_by_item[name]) then
        local subgroup = prototype.subgroup
        local group = subgroup and subgroup.group
        local group_name = group and group.name or ("bmsc-" .. signal_type)
        local bucket = by_group[group_name]
        if not bucket then
          bucket = {name = group_name, order = group and group.order or "z[" .. signal_type .. "]",
            caption = group and group.localised_name or signal_type, entries = {}}
          by_group[group_name] = bucket
        end
        bucket.entries[#bucket.entries + 1] = {
          signal = {type = signal_type, name = name, quality = signal_type == "item" and "normal" or nil},
          order = (subgroup and subgroup.order or "") .. "|" .. (prototype.order or "")
            .. "|" .. signal_type .. "|" .. name,
          tooltip = prototype.localised_name
        }
      end
    end
  end
  signal_groups = {}
  for _, group in pairs(by_group) do
    table.sort(group.entries, function(a, b) return a.order < b.order end)
    signal_groups[#signal_groups + 1] = group
  end
  table.sort(signal_groups, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)
  return signal_groups
end

local function group_sprite(group)
  return prototypes.item_group[group.name] and "item-group/" .. group.name or "utility/questionmark"
end

local function matches(entry, term)
  if term == "" then return true end
  return string.find(string.lower(entry.signal.name), term, 1, true) ~= nil
end

local function rebuild_content(player)
  local frame = player.gui.screen[Picker.name]
  local context = state()[player.index]
  local content = frame and frame[CONTENT]
  if not (content and context) then return end
  content.clear()
  content.style.minimal_width = 412
  local groups = build_index()
  local tabs = content.add{type = "table", column_count = 6}
  tabs.style.horizontal_spacing = 0
  for index, group in ipairs(groups) do
    local tab = tabs.add{type = "sprite-button", sprite = group_sprite(group),
      style = "filter_group_button_tab_slightly_larger",
      tooltip = group.caption, tags = {bmsc_picker_group = index}}
    tab.toggled = index == context.group
  end

  local pane = content.add{type = "scroll-pane", style = "shallow_scroll_pane",
    vertical_scroll_policy = "auto", horizontal_scroll_policy = "never"}
  pane.style.minimal_height = 360
  pane.style.maximal_height = 520
  pane.style.horizontally_stretchable = true
  local grid = pane.add{type = "table", column_count = 10, style = "filter_slot_table"}
  local group = groups[context.group] or groups[1]
  local term = string.lower(context.search or "")
  if group then
    for _, entry in ipairs(group.entries) do
      if matches(entry, term) then
        local button = grid.add{type = "sprite-button", sprite = signal_sprite(entry.signal), style = "slot_button",
          tooltip = entry.tooltip, tags = {bmsc_picker_signal = entry.signal}}
        button.style.size = 40
      end
    end
  end
end

local function close(player)
  state()[player.index] = nil
  local frame = player.gui.screen[Picker.name]
  if frame then frame.destroy() end
  local main = player.gui.screen["bmsc-window"]
  if main then player.opened = main end
end

function Picker.is_open(player)
  return player and player.gui.screen[Picker.name] ~= nil
end

function Picker.open(player, target, operand)
  close(player)
  local groups = build_index()
  local selected_group = 1
  if operand.signal and operand.signal.name then
    for group_index, group in ipairs(groups) do
      for _, entry in ipairs(group.entries) do
        if entry.signal.type == (operand.signal.type or "item") and entry.signal.name == operand.signal.name then
          selected_group = group_index
          break
        end
      end
    end
  end
  state()[player.index] = {target = target, group = selected_group, search = "",
    constant = math.floor(tonumber(operand.constant) or 0)}
  local frame = player.gui.screen.add{type = "frame", name = Picker.name, direction = "vertical"}
  local title = frame.add{type = "flow", direction = "horizontal"}
  title.drag_target = frame
  title.add{type = "label", caption = {"gui.select-signal"}, style = "frame_title"}.drag_target = frame
  local dragger = title.add{type = "empty-widget", style = "draggable_space_header"}
  dragger.style.horizontally_stretchable = true
  dragger.style.height = 24
  dragger.drag_target = frame
  local search = title.add{type = "textfield", name = SEARCH, visible = false}
  search.style.width = 180
  title.add{type = "sprite-button", sprite = "utility/search", style = "frame_action_button",
    tags = {bmsc_picker_search_toggle = true}}
  title.add{type = "sprite-button", sprite = "utility/close", style = "frame_action_button",
    tags = {bmsc_picker_close = true}}

  frame.add{type = "flow", name = CONTENT, direction = "vertical"}
  local constant_frame = frame.add{type = "frame", style = "inside_shallow_frame", direction = "vertical"}
  constant_frame.style.horizontally_stretchable = true
  local padding = constant_frame.add{type = "flow", direction = "vertical"}
  padding.style.padding = 8
  padding.style.vertical_spacing = 6
  padding.add{type = "label", caption = {"gui.or-set-a-constant"}, style = "heading_2_label"}
  local row = padding.add{type = "flow", direction = "horizontal"}
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 8
  local slider = row.add{type = "slider", name = SLIDER, minimum_value = 0, maximum_value = 100,
    value_step = 1, value = math.max(0, math.min(100, state()[player.index].constant))}
  slider.style.horizontally_stretchable = true
  local field = row.add{type = "textfield", name = CONSTANT, text = tostring(state()[player.index].constant),
    numeric = true, allow_decimal = false, allow_negative = true}
  field.style.width = 110
  row.add{type = "button", caption = {"gui.set-constant"}, style = "confirm_button",
    tags = {bmsc_picker_set_constant = true}}

  player.opened = frame
  rebuild_content(player)
  frame.force_auto_center()
  frame.bring_to_front()
end

function Picker.on_click(event)
  local tags = event.element.tags or {}
  local player = game.get_player(event.player_index)
  local context = state()[event.player_index]
  if not context then return false end
  if tags.bmsc_picker_group then
    context.group = tags.bmsc_picker_group
    rebuild_content(player)
    return true
  end
  if tags.bmsc_picker_search_toggle then
    local field = find_named(player.gui.screen[Picker.name], SEARCH)
    field.visible = not field.visible
    if field.visible then field.focus() end
    return true
  end
  if tags.bmsc_picker_signal then
    local result = {target = context.target, signal = tags.bmsc_picker_signal}
    close(player)
    return true, result
  end
  if tags.bmsc_picker_set_constant then
    local constant = math.max(-2147483648, math.min(2147483647, context.constant))
    local result = {target = context.target, constant = constant}
    close(player)
    return true, result
  end
  if tags.bmsc_picker_close then close(player); return true end
  return event.element.name == Picker.name
end

function Picker.on_text_changed(event)
  local context = state()[event.player_index]
  if not context then return false end
  if event.element.name == SEARCH then
    context.search = event.element.text
    rebuild_content(game.get_player(event.player_index))
    return true
  end
  if event.element.name == CONSTANT then
    local value = tonumber(event.element.text)
    if value then context.constant = math.floor(value) end
    return true
  end
  return false
end

function Picker.on_value_changed(event)
  local context = state()[event.player_index]
  if not (context and event.element.name == SLIDER) then return false end
  context.constant = math.floor(event.element.slider_value)
  local frame = game.get_player(event.player_index).gui.screen[Picker.name]
  local field = find_named(frame, CONSTANT)
  if field then field.text = tostring(context.constant) end
  return true
end

function Picker.on_closed(event)
  if not (event.element and event.element.name == Picker.name) then return false end
  if state()[event.player_index] then close(game.get_player(event.player_index)) end
  return true
end

return Picker
