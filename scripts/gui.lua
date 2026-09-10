-- 市场选择运算器 GUI 模块。
-- 本文件只负责“界面长什么样、如何显隐、如何显示连接状态”，不读取 storage，也不计算生产信号。
-- 这种拆分使业务规则变化时不必修改界面代码，界面调整时也不会影响线路计算。

local Gui = {}
local Config = require("scripts.config")               -- 只读取模式常量，避免 GUI 重复维护内部字符串。

Gui.name = "bmsc-window"                              -- 参数：窗口唯一名称，供 control.lua 识别事件来源。
Gui.network_info_name = "bmsc-network-info"           -- 参数：网络信息图标名称前缀；实际名称会追加颜色和网络编号。
Gui.network_popup_name = "bmsc-network-popup"         -- 参数：仿原版网络信号悬浮面板的唯一名称。
Gui.production_order = Config.mode.production_order    -- 参数：生产订单模式标识，只用于决定参数区是否可见。
Gui.order_recursion = Config.mode.order_recursion      -- 参数：订单递归模式标识，只用于决定参数区是否可见。
Gui.recipe_query = Config.mode.recipe_query            -- 参数：配方查询模式标识，只用于决定参数区是否可见。
-- 参数：每一种数值参数自己的吸附档位。
-- Factorio 原生离散滑块只能等距吸附，因此滑块内部仍使用 1~6 的索引，再由这里映射实际值。
-- 后续新增参数时，只需在本表增加“输入框名称 → 档位数组”，无需修改通用滑块函数。
Gui.slider_profiles = {
  ["bmsc-additional"] = {0, 0.5, 1, 2, 5, 10},           -- 额外生产倍率：常用的小数及低倍率。
  ["bmsc-material"] = {1, 2, 5, 10, 20, 50},            -- 材料需求倍率：适合批量准备原料。
  ["bmsc-material-retention"] = {0, 0.5, 1, 2, 5, 10},  -- 原料保留倍率：通常接近单次配方需求。
  ["bmsc-production-timeout"] = {0, 5, 10, 30, 60, 120},-- 超时时间：单位为秒，0 表示永不超时。
  ["bmsc-cache-grid-number"] = {0, 1, 2, 5, 10, 20, 48},-- 缓存格数：0 不限制，48 对应钢箱容量。
  ["bmsc-recursion-depth"] = {0, 1, 2, 3, 5, 10},       -- 递归深度：只能使用整数。
  ["bmsc-recursion-timeout"] = {0, 5, 10, 30, 60, 120} -- 超时时间：与生产订单使用相同时间档。
}

---读取主实体某一侧连接的玩家可见电路网络。
---Factorio API：`get_wire_connector` 取得指定接线端，`connection_count` 是该端已有连线数量。
---@param entity LuaEntity 市场选择运算器实体。
---@param side string `input` 表示输入端，`output` 表示输出端。
---@param include_internal boolean|nil 输出端是否包含只连接隐藏输出代理的内部网络。
---@return table networks 网络数组；每项包含颜色、网络编号和当前信号。
local function get_side_networks(entity, side, include_internal)
  local red_id = side == "input" and defines.wire_connector_id.combinator_input_red
    or defines.wire_connector_id.combinator_output_red
  local green_id = side == "input" and defines.wire_connector_id.combinator_input_green
    or defines.wire_connector_id.combinator_output_green
  local red = entity.get_wire_connector(red_id, false)
  local green = entity.get_wire_connector(green_id, false)
  local internal_connections = side == "output" and not include_internal and 1 or 0
  local result = {}

  -- get_circuit_network 返回连接器所在的电路网络；network_id 就是原版 GUI 展示的网络编号。
  if red and red.connection_count > internal_connections then
    local network = entity.get_circuit_network(red_id)
    if network then
      result[#result + 1] = {color = "red", id = network.network_id, signals = entity.get_signals(red_id) or {}}
    end
  end
  if green and green.connection_count > internal_connections then
    local network = entity.get_circuit_network(green_id)
    if network then
      result[#result + 1] = {color = "green", id = network.network_id, signals = entity.get_signals(green_id) or {}}
    end
  end
  return result
end

---为网络拓扑生成稳定签名；只有连线发生变化时才重建状态栏。
---为什么需要：原先每 10 tick 清空状态栏会销毁正在被鼠标悬浮的信息图标，导致自定义面板闪烁。
---@param networks table `get_side_networks` 返回的网络数组。
---@return string signature 例如 `red:4|green:5`；信号数值变化不会改变此签名。
local function network_signature(networks)
  local parts = {}
  for _, network in ipairs(networks) do
    parts[#parts + 1] = network.color .. ":" .. network.id
  end
  return table.concat(parts, "|")
end

---重建某一侧的连接状态控件。
---为什么重建：线路和信号会实时变化，动态创建每个信息图标才能为不同网络设置各自的 tooltip。
---@param flow LuaGuiElement 输入端或输出端的 horizontal flow。
---@param networks table `get_side_networks` 返回的网络数组。
---@return nil
local function refresh_side_status(flow, networks)
  local signature = network_signature(networks)
  if #flow.children > 0 and flow.tags.bmsc_network_signature == signature then return end
  flow.clear()
  flow.tags = {bmsc_network_signature = signature}
  if #networks == 0 then
    flow.add{type = "label", caption = {"bmsc.not-connected"}}
    return
  end

  flow.add{type = "label", caption = {"bmsc.connected-to-label"}}
  for _, network in ipairs(networks) do
    -- 编号和信息图标交替排列，效果为“4 ⓘ 5 ⓘ”，与原版状态栏相同。
    local network_id = flow.add{type = "label", caption = tostring(network.id)}
    network_id.style.font_color = network.color == "red" and {1, 0.25, 0.25} or {0.2, 1, 0.45}
    -- `raise_hover_events` 让控制层收到 on_gui_hover/on_gui_leave；网络编号保存在 tags 中，
    -- 悬浮发生时再读取实时信号，避免把每 10 tick 变化的数据复制进 GUI 元素。
    -- 同一个输入/输出侧可能同时存在红、绿两个网络。Factorio 不允许同一父元素下出现
    -- 两个同名的具名子元素，因此名称必须包含颜色和网络编号，不能都叫 bmsc-network-info。
    local info_name = Gui.network_info_name .. "-" .. network.color .. "-" .. tostring(network.id)
    local info = flow.add{type = "label", name = info_name, caption = "ⓘ",
      raise_hover_events = true,
      tags = {bmsc_network_info = true, bmsc_network_color = network.color, bmsc_network_id = network.id}}
    info.style.font_color = {0.3, 0.8, 1}
  end
end

---判断 GUI 元素是否为网络状态栏中的信息图标。
---为什么使用 tag：图标名称为了避免重名会携带动态网络编号，不能再用固定名称比较。
---@param element LuaGuiElement|nil GUI 事件提供的来源元素。
---@return boolean is_network_info true 表示该元素由 refresh_side_status 创建。
function Gui.is_network_info(element)
  return element ~= nil and element.valid and element.tags.bmsc_network_info == true
end

---把运行时 SignalID 转换为 sprite-button 能识别的 SpritePath。
---@param signal SignalID 信号标识；`type` 可能为 item、fluid、virtual。
---@return string sprite_path 例如 `item/iron-plate` 或 `virtual-signal/signal-A`。
local function signal_sprite_path(signal)
  local sprite_type = signal.type == "virtual" and "virtual-signal" or (signal.type or "item")
  return sprite_type .. "/" .. signal.name
end

---把电路 SignalID 转换为 GUI `elem_tooltip` 所需的 ElemID。
---ElemID 固定使用 type="signal"，原信号类型必须放在 signal_type 字段，二者不能混用。
---@param signal SignalID 电路信号。
---@return table elem_id Factorio 原型悬浮信息标识。
local function signal_elem_tooltip(signal)
  local signal_type = signal.type or "item"
  local elem_id = {type = "signal", name = signal.name, signal_type = signal_type}
  local quality = type(signal.quality) == "string" and signal.quality
    or (signal.quality and signal.quality.name)
  if signal_type == "item" and quality then elem_id.quality = quality end
  return elem_id
end

---把输入/输出两侧的红绿网络信号展开成稳定排序的槽位数组。
---同一信号同时出现在红、绿网络时保留两个槽位，以不同线路底色明确区分来源。
---@param networks table `get_side_networks` 返回的网络数组。
---@return table entries 每项包含 color、signal、count、sprite 和稳定 key。
local function collect_signal_entries(networks)
  local entries = {}
  for _, network in ipairs(networks) do
    for _, value in pairs(network.signals) do
      if value.signal and value.signal.name then
        local quality = type(value.signal.quality) == "string" and value.signal.quality
          or (value.signal.quality and value.signal.quality.name)
        local sprite = signal_sprite_path(value.signal)
        entries[#entries + 1] = {
          color = network.color,
          signal = value.signal,
          count = value.count,
          sprite = sprite,
          key = network.color .. "|" .. sprite .. "|" .. (quality or "normal")
        }
      end
    end
  end
  table.sort(entries, function(a, b) return a.key < b.key end)
  return entries
end

---更新一个常驻信号子面板。
---只有信号种类、品质或线路颜色变化时才重建槽位；通常的数值变化只写 `number`，
---从而避免周期性 clear/destroy 带来的 GUI 分配、悬浮中断和额外 UPS 消耗。
---@param section LuaGuiElement “输入信号”或“输出信号”的子 frame。
---@param networks table 当前侧的红绿网络。
---@return nil
local function refresh_signal_section(section, networks)
  local entries = collect_signal_entries(networks)
  local by_color = {red = {}, green = {}}
  local signature_parts = {}
  for _, entry in ipairs(entries) do
    signature_parts[#signature_parts + 1] = entry.key
    by_color[entry.color][#by_color[entry.color] + 1] = entry
  end
  local signature = table.concat(signature_parts, "\n")
  local scroll = section["bmsc-signal-scroll"]
  if not (scroll and scroll.valid) then return end
  local red_slots = scroll["bmsc-red-signal-slots"]
  local green_slots = scroll["bmsc-green-signal-slots"]

  local rows_intact = (#by_color.red == 0 or (red_slots and red_slots.valid))
    and (#by_color.green == 0 or (green_slots and green_slots.valid))
  if rows_intact and scroll.tags.bmsc_signal_signature == signature then
    for _, color in ipairs({"red", "green"}) do
      local slots = color == "red" and red_slots or green_slots
      for index, entry in ipairs(by_color[color]) do
        -- 每种颜色各自保持稳定排序，因此常规刷新只更新数字。
        slots.children[index].number = entry.count
      end
    end
    return
  end

  scroll.clear()
  scroll.tags = {bmsc_signal_signature = signature}
  if #entries == 0 then
    scroll.add{type = "label", caption = {"bmsc.no-output"}}
    return
  end

  for _, color in ipairs({"red", "green"}) do
    if #by_color[color] > 0 then
      -- 红色和绿色使用两个独立表格；即使上一色不足八格，下一色也一定从新行开始。
      local slots = scroll.add{type = "table", name = "bmsc-" .. color .. "-signal-slots", column_count = 8}
      slots.style.horizontally_stretchable = true
      if color == "green" and #by_color.red > 0 then slots.style.top_margin = 4 end
      for _, entry in ipairs(by_color[color]) do
        -- elem_tooltip 提供完整悬浮信息，并让游戏接管 Q 键吸取/复制以及
        -- Option(Alt)+左键打开工厂百科；槽位样式提供对应线路颜色遮罩。
        local slot = slots.add{type = "sprite-button", sprite = entry.sprite, number = entry.count,
          style = color .. "_circuit_network_content_slot", elem_tooltip = signal_elem_tooltip(entry.signal)}
        local quality = type(entry.signal.quality) == "string" and entry.signal.quality
          or (entry.signal.quality and entry.signal.quality.name)
        if (entry.signal.type or "item") == "item" and quality and quality ~= "normal" then
          slot.quality = quality
        end
      end
    end
  end
end

---创建一个有独立边界、内容可按需纵向滚动的信号子 GUI。
---@param parent LuaGuiElement 信号公共 GUI。
---@param name string 子 GUI 名称。
---@param caption LocalisedString 子 GUI 标题。
---@param maximum_content_height uint 滚动内容的最大高度。
---@return LuaGuiElement section 创建出的子 GUI。
local function add_signal_section(parent, name, caption, maximum_content_height)
  local section = parent.add{type = "frame", name = name,
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  section.style.horizontally_stretchable = true
  section.add{type = "label", caption = caption, style = "heading_2_label"}
  local scroll = section.add{type = "scroll-pane", name = "bmsc-signal-scroll",
    direction = "vertical", horizontal_scroll_policy = "never", vertical_scroll_policy = "auto"}
  scroll.style.horizontally_stretchable = true
  scroll.style.vertically_squashable = true
  scroll.style.maximal_height = maximum_content_height
  return section
end

---向指定模式详情容器添加一套公共信号 GUI。
---本函数只依赖父 GUI 和玩家显示尺寸，不读取模式配置、实体或 storage；生产订单和
---订单递归分别调用同一入口完成绑定，后续调整布局无需复制两套实现。
---@param parent LuaGuiElement 生产订单或订单递归的详情容器。
---@param player LuaPlayer 用于根据分辨率和 UI 缩放限制面板高度。
---@return LuaGuiElement signals 创建出的信号公共面板。
function Gui.add_signal_panel(parent, player)
  local signals = parent.add{type = "frame", name = "bmsc-signals",
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  signals.style.horizontally_stretchable = true

  -- GUI 尺寸使用缩放后的逻辑像素。信号公共区最高占半个屏幕；扣除标题、内边距和
  -- 两个子面板标题后，剩余高度由输入、输出各自的滚动区均分。
  local display_scale = player.display_scale > 0 and player.display_scale or 1
  local signal_panel_height = math.floor(player.display_resolution.height / display_scale / 2)
  local section_content_height = math.max(48, math.floor((signal_panel_height - 118) / 2))
  signals.style.maximal_height = signal_panel_height
  signals.add{type = "label", caption = {"bmsc.signal-panel-title"}, style = "heading_2_label"}
  local input_signals = add_signal_section(
    signals, "bmsc-input-signals", {"bmsc.input-signals"}, section_content_height)
  input_signals.style.bottom_margin = 8
  add_signal_section(signals, "bmsc-output-signals", {"bmsc.output-signals"}, section_content_height)
  return signals
end

---刷新一套公共信号 GUI 的输入和输出槽位。
---面板构建与数据刷新分离，使各模式只负责绑定容器，不需要了解红绿网络和增量刷新细节。
---@param signals LuaGuiElement `Gui.add_signal_panel` 创建的面板。
---@param input_networks table 输入端红绿网络数据。
---@param output_networks table 输出端红绿网络数据。
---@return nil
function Gui.refresh_signal_panel(signals, input_networks, output_networks)
  if not (signals and signals.valid) then return end
  refresh_signal_section(signals["bmsc-input-signals"], input_networks)
  refresh_signal_section(signals["bmsc-output-signals"], output_networks)
end

---让一个 GUI 元素及其全部子元素不参与鼠标命中。
---@param element LuaGuiElement 悬浮展示面板或其子元素。
---@return nil
local function ignore_interaction_tree(element)
  element.ignored_by_interaction = true
  for _, child in pairs(element.children) do ignore_interaction_tree(child) end
end

---关闭玩家当前显示的网络悬浮面板。
---@param player LuaPlayer 需要关闭面板的玩家。
---@return nil
function Gui.hide_network_popup(player)
  local popup = player.gui.screen[Gui.network_popup_name]
  if popup and popup.valid then popup.destroy() end
end

---悬浮网络信息图标时构建仿原版的信号面板。
---关键点：普通 `tooltip` 只能接收 LocalisedString，无法给富文本图标添加原版信号槽底框；
---这里改用真实 sprite-button，并直接复用原版 `*_circuit_network_content_slot` 样式。
---@param player LuaPlayer 当前玩家；面板挂到其 `gui.screen`。
---@param source_element LuaGuiElement 被悬浮的“ⓘ”标签，tags 中保存网络颜色和编号。
---@param entity LuaEntity 当前窗口对应的市场选择运算器。
---@return nil
function Gui.show_network_popup(player, source_element, entity)
  if not (source_element and source_element.valid and entity and entity.valid) then return end
  Gui.hide_network_popup(player)

  local tags = source_element.tags
  local wanted_color = tags.bmsc_network_color
  local wanted_id = tags.bmsc_network_id
  local selected
  for _, side in ipairs({"input", "output"}) do
    for _, network in ipairs(get_side_networks(entity, side)) do
      if network.color == wanted_color and network.id == wanted_id then selected = network; break end
    end
    if selected then break end
  end
  if not selected then return end

  local popup = player.gui.screen.add{type = "frame", name = Gui.network_popup_name,
    style = "tooltip_frame", direction = "vertical"}
  -- 悬浮面板可能覆盖在“ⓘ”图标上。如果面板参与鼠标命中，游戏会认为鼠标已经离开图标，
  -- on_gui_leave 随即销毁面板；图标重新露出后又触发 on_gui_hover，最终形成频闪。
  -- 面板构建完成后会递归设置 ignored_by_interaction，让鼠标事件穿过整个控件树。
  popup.add{type = "label", caption = {"bmsc.network-title", selected.id}, style = "tooltip_title_label"}
  popup.add{type = "label", caption = {"bmsc.signals"}, style = "tooltip_label"}
  popup.add{type = "label", caption = {"bmsc.network-color-line", {"bmsc.network-color-" .. selected.color}, selected.id},
    style = "tooltip_label"}

  local entries = {}
  for _, entry in pairs(selected.signals) do
    if entry.signal and entry.signal.name then entries[#entries + 1] = entry end
  end
  table.sort(entries, function(a, b)
    return signal_sprite_path(a.signal) < signal_sprite_path(b.signal)
  end)

  if #entries == 0 then
    popup.add{type = "label", caption = {"bmsc.no-output"}, style = "tooltip_label"}
  else
    local slots = popup.add{type = "table", column_count = 8}
    local slot_style = selected.color .. "_circuit_network_content_slot"
    for _, entry in ipairs(entries) do
      local slot = slots.add{type = "sprite-button", sprite = signal_sprite_path(entry.signal),
        number = entry.count, style = slot_style}
      -- 品质角标只对物品信号有意义；普通品质无需额外显示。
      local quality = type(entry.signal.quality) == "string" and entry.signal.quality
        or (entry.signal.quality and entry.signal.quality.name)
      if entry.signal.type == "item" and quality and quality ~= "normal" then
        slot.quality = quality
      end
    end
  end

  -- on_gui_hover 没有光标屏幕坐标，因此把面板稳定放在窗口状态栏附近；视觉位置接近原版，
  -- 同时刻意与信息图标错开，避免光标进入新面板后立刻触发 on_gui_leave。
  local window = player.gui.screen[Gui.name]
  local location = window and window.valid and window.location or {x = 0, y = 0}
  popup.location = {x = location.x + 220, y = location.y + 58}
  ignore_interaction_tree(popup)
end

---向两列表格添加一行“名称 + 控件”。
---为什么需要：所有参数行结构相同，集中创建可保持对齐并减少重复代码。
---@param parent LuaGuiElement Factorio 的 table GUI 元素。
---@param caption LocalisedString 左侧本地化标签。
---@param definition table 传给 `LuaGuiElement.add` 的控件定义。
---@return LuaGuiElement element 新创建的右侧控件。
local function add_labeled(parent, caption, definition)
  parent.add{type = "label", caption = caption}
  return parent.add(definition)
end

---查找最接近当前数值的滑块档位。
---输入框允许任意非负数；若输入值不在当前参数的吸附点上，滑块仅停在最近点，文本值不会被改写。
---@param value number 当前输入框数值。
---@param values number[] 当前参数的吸附值数组。
---@return uint index `values` 中距离最近的索引。
local function nearest_slider_index(value, values)
  local nearest = 1
  local distance = math.abs(value - values[1])
  for index = 2, #values do
    local candidate = math.abs(value - values[index])
    if candidate < distance then nearest, distance = index, candidate end
  end
  return nearest
end

---添加一行原版风格的“离散滑块 + 短输入框”数值参数。
---为什么构建此函数：各模式有多个数值参数，集中创建可保证尺寸、吸附规则和事件 tags 完全一致。
---@param parent LuaGuiElement 两列表格，左列显示参数名，右列显示输入控件。
---@param caption LocalisedString 参数名称。
---@param name string 文本框名称；滑块名称会自动追加 `-slider`。
---@param value number 当前配置值。
---@param allow_decimal boolean 是否允许文本框输入小数。
---@param tooltip LocalisedString 鼠标悬停在滑块或输入框时显示的参数解释。
---@param visible boolean|nil 是否显示整行；nil 按 true 处理。
---@param label_name string|nil 标签元素名称；需要动态显隐时传入。
---@return LuaGuiElement textfield 新创建的短输入框。
local function add_numeric_slider(parent, caption, name, value, allow_decimal, tooltip, visible, label_name)
  local values = Gui.slider_profiles[name]
  local row_visible = visible ~= false
  parent.add{type = "label", name = label_name, caption = caption, visible = row_visible}
  local controls = parent.add{
    type = "flow", name = name .. "-controls", direction = "horizontal", visible = row_visible
  }
  controls.style.vertical_align = "center"
  controls.style.horizontal_spacing = 8

  local slider = controls.add{
    type = "slider", name = name .. "-slider", style = "notched_slider",
    minimum_value = 1, maximum_value = #values,
    value = nearest_slider_index(value, values), value_step = 1, discrete_values = true,
    tooltip = tooltip, tags = {bmsc_numeric_input = name}
  }
  slider.style.width = 150                            -- 参数：缩短滑块，减少参数区右侧空白。

  local textfield = controls.add{
    type = "textfield", name = name, style = "short_slider_value_textfield", text = tostring(value),
    numeric = true, allow_decimal = allow_decimal, allow_negative = false,
    tooltip = tooltip, tags = {bmsc_numeric_slider = name .. "-slider"}
  }
  textfield.style.width = 64                          -- 参数：可容纳常用数值，同时进一步压缩横向尺寸。
  return textfield
end

---校验生产订单界面中的两个材料倍率，并同步输入框的红色错误背景。
---无效时保留玩家输入，便于继续编辑；本函数只负责界面状态，不写入实体配置。
---@param source_element LuaGuiElement 任意一个材料倍率输入框或对应滑块。
---@return boolean valid 是否满足“材料需求倍率 > 原料保留倍率”。
---@return number|nil demand 输入框中的需求倍率。
---@return number|nil retention 输入框中的保留倍率。
function Gui.validate_material_rate_inputs(source_element)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  local details = content and content["bmsc-production-details"]
  local settings = details and details["bmsc-production-settings"]
  local fields = settings and settings["bmsc-production-fields"]
  if not fields then return false, nil, nil end

  -- 使用稳定名称查找控件，不依赖参数行顺序，后续插入新参数不会破坏校验逻辑。
  local demand_flow = fields["bmsc-material-controls"]
  local retention_flow = fields["bmsc-material-retention-controls"]
  local demand_input = demand_flow and demand_flow["bmsc-material"]
  local retention_input = retention_flow and retention_flow["bmsc-material-retention"]
  if not (demand_input and retention_input) then return false, nil, nil end

  local demand = tonumber(demand_input.text)
  local retention = tonumber(retention_input.text)
  local valid = demand ~= nil and retention ~= nil and Config.material_rates_valid(demand, retention)
  local style = valid and "short_slider_value_textfield" or "invalid_value_short_number_textfield"
  demand_input.style = style
  retention_input.style = style
  demand_input.style.width = 64                       -- 切换预设样式会清除自定义宽度，需要重新设置。
  retention_input.style.width = 64
  return valid, demand, retention
end

---文本框变化后，把同一行滑块移动到距离该值最近的吸附点。
---@param textfield LuaGuiElement 带 `bmsc_numeric_slider` tag 的数值文本框。
---@param value number 已经通过业务层校验的非负数。
---@return nil
function Gui.sync_numeric_slider(textfield, value)
  local slider_name = textfield.tags.bmsc_numeric_slider
  local slider = slider_name and textfield.parent[slider_name]
  local values = Gui.slider_profiles[textfield.name]
  if slider and slider.valid and values then slider.slider_value = nearest_slider_index(value, values) end
end

---把玩家选择的滑块档位写回同一行输入框。
---@param slider LuaGuiElement 带 `bmsc_numeric_input` tag 的 slider。
---@return LuaGuiElement|nil textfield 对应输入框。
---@return number|nil value 档位映射后的真实参数值。
function Gui.apply_numeric_slider(slider)
  local input_name = slider.tags.bmsc_numeric_input
  local textfield = input_name and slider.parent[input_name]
  local values = input_name and Gui.slider_profiles[input_name]
  local value = values and values[math.floor(slider.slider_value + 0.5)]
  if not (textfield and textfield.valid and value) then return nil, nil end
  textfield.text = tostring(value)
  return textfield, value
end

---沿 GUI 父子树向上查找本模组主窗口。
---@param element LuaGuiElement|nil 事件来源控件。
---@return LuaGuiElement|nil window 找不到时返回 nil。
function Gui.containing_window(element)
  local current = element
  while current and current.valid do
    if current.name == Gui.name then return current end
    current = current.parent
  end
  return nil
end

---刷新原版风格状态栏中的“输入/输出：已连接或未连接”。
---调用方传入实体，因此本模块不需要了解组合器记录或 storage 的结构。
---@param player LuaPlayer 拥有此 GUI 的玩家。
---@param entity LuaEntity|nil 正在查看的市场选择运算器。
---@return nil
function Gui.refresh_connection_status(player, entity)
  local frame = player.gui.screen[Gui.name]
  if not (frame and frame.valid and entity and entity.valid) then return end
  local content = frame["bmsc-content"]
  local connections = content and content["bmsc-connections"]
  if not connections then return end
  local input_networks = get_side_networks(entity, "input")
  local output_networks = get_side_networks(entity, "output")
  refresh_side_status(connections["bmsc-input-status"], input_networks)
  refresh_side_status(connections["bmsc-output-status"], output_networks)
  -- 两个模式分别绑定公共面板；只刷新当前可见实例，避免为隐藏模式做重复 GUI 更新。
  local signal_output_networks
  for _, details_name in ipairs({"bmsc-production-details", "bmsc-recursion-details"}) do
    local details = content[details_name]
    if details and details.visible then
      -- 即使输出端还没有接外部电线，也要展示隐藏代理当前正在发送的真实输出。
      signal_output_networks = signal_output_networks or get_side_networks(entity, "output", true)
      Gui.refresh_signal_panel(details["bmsc-signals"], input_networks, signal_output_networks)
    end
  end
end

---根据操作模式切换对应的参数区。
---@param source_element LuaGuiElement 模式下拉框；从它向上定位窗口。
---@param mode string 当前选中的内部模式标识。
---@return nil
function Gui.show_mode_details(source_element, mode)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  if not content then return end
  local production_details = content["bmsc-production-details"]
  local recursion_details = content["bmsc-recursion-details"]
  local recipe_query_details = content["bmsc-recipe-query-details"]
  if production_details then production_details.visible = mode == Gui.production_order end
  if recursion_details then recursion_details.visible = mode == Gui.supermarket_order end
  if recipe_query_details then recipe_query_details.visible = mode == Gui.recipe_query end

end

---只在超市订单的 single 输出模式下显示超时输入框。
---@param source_element LuaGuiElement 超市订单输出模式下拉框。
---@param visible boolean true 显示，false 隐藏。
---@return nil
function Gui.set_recursion_timeout_visible(source_element, visible)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  local details = content and content["bmsc-recursion-details"]
  local settings = details and details["bmsc-recursion-settings"]
  local fields = settings and settings["bmsc-recursion-fields"]
  if not fields then return end
  fields["bmsc-recursion-timeout-label"].visible = visible
  fields["bmsc-recursion-timeout-controls"].visible = visible
end

---只在生产订单的“所有（信号分离）”输出模式下显示缓存格数。
---@param source_element LuaGuiElement 生产订单输出模式下拉框。
---@param visible boolean true 显示，false 隐藏。
---@return nil
function Gui.set_cache_grid_visible(source_element, visible)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  local details = content and content["bmsc-production-details"]
  local settings = details and details["bmsc-production-settings"]
  local fields = settings and settings["bmsc-production-fields"]
  if not fields then return end
  fields["bmsc-cache-grid-number-label"].visible = visible
  fields["bmsc-cache-grid-number-controls"].visible = visible
end

---同步各模式参数区里的生产机器按钮。
---为什么需要：三个模式共用同一配置值，玩家切换模式后不应看到旧的机器名称。
---@param source_element LuaGuiElement 触发修改的生产机器选择按钮。
---@param machine_name string 新选择的制造机原型名。
---@return nil
function Gui.sync_machine_buttons(source_element, machine_name)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  if not content then return end
  local production = content["bmsc-production-details"]
  local recursion = content["bmsc-recursion-details"]
  local recipe_query = content["bmsc-recipe-query-details"]
  local production_settings = production and production["bmsc-production-settings"]
  local recursion_settings = recursion and recursion["bmsc-recursion-settings"]
  local recipe_query_settings = recipe_query and recipe_query["bmsc-recipe-query-settings"]
  local production_fields = production_settings and production_settings["bmsc-production-fields"]
  local recursion_fields = recursion_settings and recursion_settings["bmsc-recursion-fields"]
  local recipe_query_fields = recipe_query_settings and recipe_query_settings["bmsc-recipe-query-fields"]
  if production_fields and production_fields["bmsc-production-machine"] then
    production_fields["bmsc-production-machine"].elem_value = machine_name
  end
  if recursion_fields and recursion_fields["bmsc-recursion-machine"] then
    recursion_fields["bmsc-recursion-machine"].elem_value = machine_name
  end
  if recipe_query_fields and recipe_query_fields["bmsc-recipe-query-machine"] then
    recipe_query_fields["bmsc-recipe-query-machine"].elem_value = machine_name
  end
end

---构建并打开完整的原版风格配置窗口。
---Factorio API 要点：GUI 必须挂在 `player.gui.screen`；设为 `player.opened` 后 E/Esc 会触发关闭事件。
---@param player LuaPlayer 操作玩家。
---@param entity LuaEntity 用于 entity-preview 的实际实体。
---@param config table 已由业务层校验过的实体配置。
---@return LuaGuiElement frame 新创建的主窗口。
function Gui.open(player, entity, config)
  Gui.hide_network_popup(player)
  local old = player.gui.screen[Gui.name]
  if old then old.destroy() end

  local frame = player.gui.screen.add{type = "frame", name = Gui.name, direction = "vertical"}
  frame.style.width = 480                              -- 参数：进一步缩小宽度，使左右内容留白接近原版。
  frame.force_auto_center()

  -- 自定义标题栏模仿原版：标题、可拖动空白区域、右上角关闭按钮。
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", caption = {"bmsc.gui-title"}, style = "frame_title"}.drag_target = frame
  local dragger = titlebar.add{type = "empty-widget", style = "draggable_space_header"}
  dragger.style.horizontally_stretchable = true
  dragger.style.height = 24                            -- 参数：与原版标题栏操作区高度一致。
  dragger.drag_target = frame
  titlebar.add{type = "sprite-button", name = "bmsc-close", sprite = "utility/close",
    hovered_sprite = "utility/close_black", clicked_sprite = "utility/close_black",
    style = "frame_action_button", tooltip = {"gui.close"}}

  local content = frame.add{type = "frame", name = "bmsc-content",
    style = "inside_shallow_frame", direction = "vertical"}
  content.style.horizontally_stretchable = true

  local connections = content.add{type = "table", name = "bmsc-connections", column_count = 5}
  connections.style.horizontally_stretchable = true
  connections.style.horizontal_spacing = 8
  connections.style.left_padding = 12
  connections.style.right_padding = 12
  connections.style.top_padding = 6
  connections.style.bottom_padding = 6
  connections.style.vertical_align = "center"
  connections.add{type = "label", caption = {"bmsc.input"}, style = "heading_2_label"}
  connections.add{type = "flow", name = "bmsc-input-status", direction = "horizontal"}
  connections.add{type = "empty-widget"}.style.horizontally_stretchable = true
  connections.add{type = "label", caption = {"bmsc.output"}, style = "heading_2_label"}
  connections.add{type = "flow", name = "bmsc-output-status", direction = "horizontal"}

  content.add{type = "line"}
  local running = content.add{type = "flow", direction = "horizontal"}
  running.style.vertical_align = "center"
  running.style.horizontal_spacing = 8
  running.style.left_padding = 12
  running.style.top_padding = 4
  running.style.bottom_padding = 4
  -- 直接复用原版工作状态灯精灵；它比文字“●”更小，并自带原版的发光效果。
  running.add{type = "sprite", sprite = "utility/status_working"}
  running.add{type = "label", caption = {"bmsc.normal-operation"}}

  -- entity-preview 让游戏引擎渲染真实实体，方向、动画和品质都无需模组自行绘制。
  local preview_frame = content.add{type = "frame", style = "inside_deep_frame"}
  preview_frame.style.horizontally_stretchable = true
  preview_frame.style.height = 160                     -- 参数：同步压缩预览区，保持窗口整体比例协调。
  local preview = preview_frame.add{type = "entity-preview"}
  preview.style.horizontally_stretchable = true
  preview.style.vertically_stretchable = true
  preview.entity = entity

  local mode_area = content.add{type = "flow", direction = "vertical"}
  mode_area.style.padding = 8                          -- 参数：缩小区域留白，让操作模式部分更紧凑。
  local mode_fields = mode_area.add{type = "table", column_count = 2}
  mode_fields.style.horizontally_stretchable = true
  -- 原版选择运算器使用醒目的“操作模式”标题；直接复用原版粗体标题样式。
  mode_fields.add{type = "label", caption = {"bmsc.mode"}, style = "heading_2_label"}
  mode_fields.add{type = "drop-down", name = "bmsc-mode",
    items = {{"bmsc.production-order"}, {"bmsc.supermarket-order"}, {"bmsc.recipe-query"}},
    selected_index = ({[Gui.production_order] = 1, [Gui.supermarket_order] = 2, [Gui.recipe_query] = 3})[config.mode] or 1,

    tooltip = {"bmsc.mode-tooltip"}}

  -- 功能说明紧跟操作模式，位置与原版对当前模式的解释文字一致。
  local mode_description = mode_area.add{type = "label", caption = {"bmsc.wiring-help"}}
  mode_description.style.single_line = false
  mode_description.style.top_margin = 8

  local details = content.add{type = "flow", name = "bmsc-production-details", direction = "vertical"}
  details.style.horizontally_stretchable = true
  details.visible = config.mode == Gui.production_order
  details.add{type = "line"}
  local settings = details.add{type = "frame", name = "bmsc-production-settings",
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  settings.add{type = "label", caption = {"bmsc.production-order-settings"}, style = "heading_2_label"}
  local fields = settings.add{type = "table", name = "bmsc-production-fields", column_count = 2}
  -- tooltip 是 Factorio GUI 元素的原生属性；鼠标停留在右侧输入控件时游戏自动显示说明。
  local production_machine = add_labeled(fields, {"bmsc.production-machine"}, {type = "choose-elem-button",
    name = "bmsc-production-machine", elem_type = "entity", entity = config.production_machine,
    tooltip = {"bmsc.production-machine-tooltip"}})
  production_machine.style.size = 52                  -- 参数：突出机器选择，使其与普通参数控件形成层级。
  add_numeric_slider(fields, {"bmsc.additional-rate"}, "bmsc-additional",
    config.additional_production_rate, true, {"bmsc.additional-rate-tooltip"})
  add_numeric_slider(fields, {"bmsc.material-rate"}, "bmsc-material",
    config.material_demand_rate, true, {"bmsc.material-rate-tooltip"})
  add_numeric_slider(fields, {"bmsc.material-retention-rate"}, "bmsc-material-retention",
    config.material_retention_rate or 1, true, {"bmsc.material-retention-rate-tooltip"})
  add_numeric_slider(fields, {"bmsc.production-timeout"}, "bmsc-production-timeout",
    config.production_timeout or 0, true, {"bmsc.production-timeout-tooltip"})
  add_labeled(fields, {"bmsc.output-mode"}, {type = "drop-down", name = "bmsc-output",
    items = {{"bmsc.only-item"}, {"bmsc.only-material"}, {"bmsc.all"}, {"bmsc.all-separate-signal"}},
    selected_index = ({only_item = 1, only_material = 2, all = 3, all_separate_signal = 4})[config.output_mode] or 3,
    tooltip = {"bmsc.output-mode-tooltip"}})
  local cache_visible = config.output_mode == "all_separate_signal"
  add_numeric_slider(fields, {"bmsc.cache-grid-number"}, "bmsc-cache-grid-number",
    config.cache_grid_number or 0, false, {"bmsc.cache-grid-number-tooltip"}, cache_visible,
    "bmsc-cache-grid-number-label")
  -- 订单记忆放在参数列表末尾，使它和紧随其后的“清空订单记忆”按钮形成一组。
  add_labeled(fields, {"bmsc.remember-order"}, {type = "drop-down", name = "bmsc-remember-order",
    items = {{"bmsc.yes"}, {"bmsc.no"}}, selected_index = config.remember_order and 1 or 2,
    tooltip = {"bmsc.remember-order-tooltip"}})
  -- 订单记忆属于运行状态而非配置值，提供独立按钮让玩家随时放弃当前缓存订单。
  settings.add{type = "button", name = "bmsc-clear-order-memory",
    caption = {"bmsc.clear-order-memory"}, tooltip = {"bmsc.clear-order-memory-tooltip"}}
  -- 生产订单模式绑定公共信号面板。
  Gui.add_signal_panel(details, player)

  local recursion_details = content.add{type = "flow", name = "bmsc-recursion-details", direction = "vertical"}
  recursion_details.style.horizontally_stretchable = true
  recursion_details.visible = config.mode == Gui.supermarket_order
  recursion_details.add{type = "line"}
  local recursion_settings = recursion_details.add{
    type = "frame", name = "bmsc-recursion-settings",
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  recursion_settings.add{type = "label", caption = {"bmsc.supermarket-order-settings"}, style = "heading_2_label"}
  local recursion_fields = recursion_settings.add{type = "table", name = "bmsc-recursion-fields", column_count = 2}
  local recursion_machine = add_labeled(recursion_fields, {"bmsc.production-machine"}, {type = "choose-elem-button",
    name = "bmsc-recursion-machine", elem_type = "entity", entity = config.production_machine,
    tooltip = {"bmsc.production-machine-tooltip"}})
  recursion_machine.style.size = 52                   -- 参数：两个模式使用一致的机器选择按钮尺寸。
  add_numeric_slider(recursion_fields, {"bmsc.recursion-depth"}, "bmsc-recursion-depth",
    config.recurise_depth, false, {"bmsc.recursion-depth-tooltip"})
  add_labeled(recursion_fields, {"bmsc.output-mode"}, {type = "drop-down", name = "bmsc-recursion-output",
    items = {{"bmsc.single"}, {"bmsc.all"}}, selected_index = config.recursion_output_mode == "all" and 2 or 1,
    tooltip = {"bmsc.recursion-output-mode-tooltip"}})
  -- 超时只属于 single 模式；为标签和输入框命名，切换输出模式时可以同时显隐。
  local timeout_visible = config.recursion_output_mode ~= "all"
  recursion_fields.add{type = "label", name = "bmsc-recursion-timeout-label",
    caption = {"bmsc.recursion-timeout"}, visible = timeout_visible}
  -- 此参数需要随 single/all 模式显隐，因此保留带名称的标签，并将整个滑块控件 flow 命名。
  local timeout_controls = recursion_fields.add{type = "flow", name = "bmsc-recursion-timeout-controls",
    direction = "horizontal", visible = timeout_visible}
  timeout_controls.style.vertical_align = "center"
  timeout_controls.style.horizontal_spacing = 8
  local timeout_slider = timeout_controls.add{type = "slider", name = "bmsc-recursion-timeout-slider",
    style = "notched_slider", minimum_value = 1,
    maximum_value = #Gui.slider_profiles["bmsc-recursion-timeout"],
    value = nearest_slider_index(config.recursion_timeout or 0,
      Gui.slider_profiles["bmsc-recursion-timeout"]), value_step = 1, discrete_values = true,
    tooltip = {"bmsc.recursion-timeout-tooltip"}, tags = {bmsc_numeric_input = "bmsc-recursion-timeout"}}
  timeout_slider.style.width = 150
  local timeout_input = timeout_controls.add{type = "textfield", name = "bmsc-recursion-timeout",
    style = "short_slider_value_textfield", text = tostring(config.recursion_timeout or 0),
    numeric = true, allow_decimal = true, allow_negative = false,
    tooltip = {"bmsc.recursion-timeout-tooltip"},
    tags = {bmsc_numeric_slider = "bmsc-recursion-timeout-slider"}}
  timeout_input.style.width = 64
  -- 订单递归模式独立绑定同一个公共信号面板函数。
  Gui.add_signal_panel(recursion_details, player)

  local recipe_query_details = content.add{type = "flow", name = "bmsc-recipe-query-details", direction = "vertical"}
  recipe_query_details.visible = config.mode == Gui.recipe_query
  recipe_query_details.add{type = "line"}
  local recipe_query_settings = recipe_query_details.add{
    type = "frame", name = "bmsc-recipe-query-settings",
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  recipe_query_settings.add{type = "label", caption = {"bmsc.recipe-query-settings"}, style = "heading_2_label"}
  local recipe_query_fields = recipe_query_settings.add{
    type = "table", name = "bmsc-recipe-query-fields", column_count = 2}
  local recipe_query_machine = add_labeled(recipe_query_fields, {"bmsc.recipe-query-machine"}, {
    type = "choose-elem-button", name = "bmsc-recipe-query-machine", elem_type = "entity",
    entity = config.production_machine, tooltip = {"bmsc.recipe-query-machine-tooltip"}})
  recipe_query_machine.style.size = 52                -- 参数：与其他模式保持一致的机器选择按钮尺寸。
  add_labeled(recipe_query_fields, {"bmsc.multiple-recipe-support"}, {
    type = "drop-down", name = "bmsc-multiple-recipe-support",
    items = {{"bmsc.no"}, {"bmsc.yes"}}, selected_index = config.multiple_recipe_support and 2 or 1,
    tooltip = {"bmsc.multiple-recipe-support-tooltip"}})

  -- 已保存的说明直接显示在配置界面内；内容支持 Factorio 富文本图标。
  local saved_description = content.add{type = "flow", name = "bmsc-saved-description", direction = "vertical"}
  saved_description.style.padding = 8
  saved_description.visible = entity.combinator_description ~= ""
  saved_description.add{type = "label", caption = {"bmsc.description"}, style = "heading_2_label"}
  local saved_description_text = saved_description.add{
    type = "label", name = "bmsc-saved-description-text", caption = entity.combinator_description}
  saved_description_text.style.single_line = false

  local footer = content.add{type = "flow", direction = "horizontal"}
  footer.style.padding = 8
  footer.add{type = "button", name = "bmsc-description-toggle", caption = {"bmsc.add-description"}}

  -- 说明编辑器默认隐藏；点击“添加说明”后才展开，减少正常配置时的界面占用。
  local description = content.add{type = "flow", name = "bmsc-description-editor", direction = "vertical"}
  description.visible = false
  description.style.padding = 8
  -- icon_selector=true 是 Factorio 2.1 的原生图标选择按钮，插入结果会作为富文本保存。
  local text = description.add{type = "text-box", name = "bmsc-description-text", icon_selector = true}
  text.style.horizontally_stretchable = true
  text.style.height = 90                             -- 参数：提供约三至四行说明的编辑高度。
  local actions = description.add{type = "flow", direction = "horizontal"}
  actions.add{type = "button", name = "bmsc-description-save", caption = {"bmsc.save-description"}, style = "confirm_button"}
  actions.add{type = "button", name = "bmsc-description-cancel", caption = {"gui.cancel"}}

  player.opened = frame
  Gui.refresh_connection_status(player, entity)
  return frame
end

---展开说明编辑器，并填入实体当前已有的说明。
---@param source_element LuaGuiElement “添加说明”按钮。
---@param current_text string 实体的 `combinator_description`。
---@return nil
function Gui.show_description_editor(source_element, current_text)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  local editor = content and content["bmsc-description-editor"]
  if not editor then return end
  editor["bmsc-description-text"].text = current_text or ""
  editor.visible = true
  editor["bmsc-description-text"].focus()
end

---读取说明编辑器文本。
---@param source_element LuaGuiElement 保存按钮。
---@return string|nil description 找不到编辑器时返回 nil。
function Gui.get_description(source_element)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  local editor = content and content["bmsc-description-editor"]
  return editor and editor["bmsc-description-text"].text or nil
end

---刷新主窗口中已经保存的说明文字。
---@param source_element LuaGuiElement 保存按钮；用于向上定位主窗口。
---@param value string 新的组合器说明，可包含游戏富文本图标标记。
---@return nil
function Gui.refresh_saved_description(source_element, value)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  local display = content and content["bmsc-saved-description"]
  if not display then return end
  display["bmsc-saved-description-text"].caption = value or ""
  display.visible = value ~= nil and value ~= ""
end

---收起说明编辑器；取消时业务层不写实体属性，因此原说明保持不变。
---@param source_element LuaGuiElement 保存或取消按钮。
---@return nil
function Gui.hide_description_editor(source_element)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  local editor = content and content["bmsc-description-editor"]
  if editor then editor.visible = false end
end

---关闭窗口。
---通过清空 `player.opened` 走 Factorio 标准生命周期，使按钮关闭与 E/Esc 行为一致。
---@param player LuaPlayer 操作玩家。
---@return nil
function Gui.close(player)
  Gui.hide_network_popup(player)
  local frame = player.gui.screen[Gui.name]
  player.opened = nil
  if frame and frame.valid then frame.destroy() end
end

return Gui
