-- 市场选择运算器 GUI 模块。
-- 本文件只负责“界面长什么样、如何显隐、如何显示连接状态”，不读取 storage，也不计算生产信号。
-- 这种拆分使业务规则变化时不必修改界面代码，界面调整时也不会影响线路计算。

local Gui = {}
local Config = require("scripts.config")               -- 只读取模式常量，避免 GUI 重复维护内部字符串。
local Util = require("scripts.common_util")            -- 复用稳定信号键，将生产诊断绑定到对应绿色输入。
local NetworkGui = require("scripts.network_gui")     -- Factorio 仅允许在 control.lua 加载阶段 require。

Gui.name = "bmsc-window"                              -- 参数：窗口唯一名称，供 control.lua 识别事件来源。
Gui.config_overlay_name = "bmsc-config-overlay"       -- 窄屏时独立悬浮的参数栏，不挤压运行面板。
Gui.order_target_name = "bmsc-order-target-window"    -- 参数：Shift+左键打开的配方与库存校验子窗口。
Gui.network_info_name = "bmsc-network-info"           -- 参数：网络信息图标名称前缀；实际名称会追加颜色和网络编号。
Gui.network_popup_name = "bmsc-network-popup"         -- 参数：仿原版网络信号悬浮面板的唯一名称。
Gui.production_order = Config.mode.production_order    -- 参数：生产订单模式标识，只用于决定参数区是否可见。
Gui.supermarket_order = Config.mode.supermarket_order  -- 参数：超市订单模式标识，只用于决定参数区是否可见。
Gui.recipe_query = Config.mode.recipe_query            -- 参数：配方查询模式标识，只用于决定参数区是否可见。
Gui.inventory_query = Config.mode.inventory_query      -- 参数：共享库存查询模式标识，只用于决定参数区是否可见。
Gui.swap_order = Config.mode.swap_order                -- 参数：切换订单模式标识，只用于决定参数区是否可见。

local function mode_caption(mode)
  return ({
    [Gui.production_order] = {"bmsc.production-order"},
    [Gui.supermarket_order] = {"bmsc.supermarket-order"},
    [Gui.recipe_query] = {"bmsc.recipe-query"},
    [Gui.inventory_query] = {"bmsc.inventory-query"},
    [Gui.swap_order] = {"bmsc.swap-order"}
  })[mode] or {"bmsc.supermarket-order"}
end

---模式说明只在鼠标停留时出现；配置栏不再为帮助文字预留多行高度。
---@param mode string 当前模式。
---@return LocalisedString tooltip 当前模式的完整说明。
local function mode_tooltip(mode)
  return ({
    [Gui.production_order] = {"bmsc.mode-tooltip-production-order"},
    [Gui.supermarket_order] = {"bmsc.mode-tooltip-supermarket-order"},
    [Gui.recipe_query] = {"bmsc.mode-tooltip-recipe-query"},
    [Gui.inventory_query] = {"bmsc.mode-tooltip-inventory-query"},
    [Gui.swap_order] = {"bmsc.mode-tooltip-swap-order"}
  })[mode] or {"bmsc.mode-tooltip-supermarket-order"}
end

-- 生产订单只为旧存档保留运行兼容，不再作为新配置入口；可选模式集中在这里，
-- 避免 GUI 顺序和 control.lua 的事件映射各自维护一份索引。
local SELECTABLE_MODES = {
  Gui.supermarket_order, Gui.recipe_query, Gui.inventory_query, Gui.swap_order
}

function Gui.mode_from_selected_index(index)
  return SELECTABLE_MODES[index]
end

local function mode_selected_index(mode)
  for index, candidate in ipairs(SELECTABLE_MODES) do
    if candidate == mode then return index end
  end
  return 0
end
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
  ["bmsc-recursion-timeout"] = {0, 5, 10, 30, 60, 120},-- 超时时间：与生产订单使用相同时间档。
  ["bmsc-swap-timeout"] = {0, 5, 10, 30, 60, 120}      -- 切换订单复用相同时间档。
}
-- 超市订单与生产订单共用三项迟滞参数，但使用独立控件名，避免 GUI 树中重名。
Gui.slider_profiles["bmsc-recursion-additional"] = {2, 3, 5, 10, 20, 50}
Gui.slider_profiles["bmsc-recursion-material"] = Gui.slider_profiles["bmsc-material"]
Gui.slider_profiles["bmsc-recursion-material-retention"] = Gui.slider_profiles["bmsc-material-retention"]
Gui.slider_profiles["bmsc-recipe-query-cache-grid-number"] = Gui.slider_profiles["bmsc-cache-grid-number"]
Gui.slider_profiles["bmsc-recursion-material-wait-time"] = Gui.slider_profiles["bmsc-recursion-timeout"]

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

---把信号转换为 GUI 图标的原型交互信息，不改变信号槽本身的展示类型。
---@param signal SignalID 电路信号。
---@return table elem_id Factorio 原型悬浮信息标识。
local function signal_elem_tooltip(signal)
  local signal_type = signal.type or "item"
  if signal_type == "item" then
    local quality = type(signal.quality) == "string" and signal.quality
      or (signal.quality and signal.quality.name)
      or "normal"
    return {type = "item-with-quality", name = signal.name, quality = quality}
  end
  if signal_type == "fluid" then return {type = "fluid", name = signal.name} end
  return {type = "signal", name = signal.name, signal_type = signal_type}
end

---把信号格式化为“图标 + 本地化名称”，供生产订单诊断提示复用。
---@param signal SignalID 信号标识。
---@return LocalisedString label 本地化信号标签。
local function signal_localised_label(signal)
  local signal_type = signal.type or "item"
  local prototype_group = signal_type == "fluid" and prototypes.fluid
    or signal_type == "recipe" and prototypes.recipe or prototypes.item
  local prototype = prototype_group and prototype_group[signal.name]
  return {"", "[img=" .. signal_sprite_path(signal) .. "] ", prototype and prototype.localised_name or signal.name}
end

local function signal_localised_name(signal)
  local group = signal.type == "fluid" and prototypes.fluid
    or signal.type == "virtual" and prototypes.virtual_signal or prototypes.item
  local prototype = group and group[signal.name]
  return prototype and prototype.localised_name or signal.name
end

---按名称查找任意深度的 GUI 子元素；页面分组后，参数控件不再都是内容区直属子元素。
local function find_descendant(parent, name)
  if not parent then return nil end
  if parent.name == name then return parent end
  for _, child in ipairs(parent.children) do
    local found = find_descendant(child, name)
    if found then return found end
  end
end

---用平衡树连接本地化片段，避免逐项追加形成超过 Factorio 20 层限制的深链。
local function join_localised(parts, separator, first, last)
  first = first or 1
  last = last or #parts
  if first > last then return nil end
  if first == last then return parts[first] end
  local middle = math.floor((first + last) / 2)
  return {"", join_localised(parts, separator, first, middle), separator,
    join_localised(parts, separator, middle + 1, last)}
end

---把信号及指定数量字段格式化为“图标 名称 × 数量”列表。
---@param entries table|nil 信号明细。
---@param count_field string 数量字段名。
---@param positive_only boolean|nil 是否跳过零值。
---@return LocalisedString|nil list 本地化列表。
local function signal_count_localised_list(entries, count_field, positive_only)
  local parts = {}
  for _, entry in ipairs(entries or {}) do
    local count = tonumber(entry[count_field])
    if entry.signal and count ~= nil and (not positive_only or count > 0) then
      parts[#parts + 1] = {"", signal_localised_label(entry.signal), " × ", tostring(count)}
    end
  end
  return join_localised(parts, {"bmsc.production-reason-separator"})
end

local function shortage_localised_list(shortages)
  return signal_count_localised_list(shortages, "count", true)
end

---格式化当前层每种直接原料采用的启动/保持门槛。
local function material_threshold_localised_list(ingredients)
  local parts = {}
  for _, ingredient in ipairs(ingredients or {}) do
    if ingredient.signal and ingredient.start_threshold ~= nil and ingredient.threshold_comparator then
      parts[#parts + 1] = {"", signal_localised_label(ingredient.signal), " ",
        ingredient.threshold_comparator, " ", tostring(ingredient.start_threshold)}
    end
  end
  return join_localised(parts, {"bmsc.production-reason-separator"})
end

---生成“正在处理”订单的详细提示；旧诊断没有结构化明细时仍返回原有短文案。
local function active_order_tooltip(diagnostic)
  if not (diagnostic.order and diagnostic.order.signal and diagnostic.product and diagnostic.product.signal) then
    return diagnostic.kind == "supermarket_expanding"
      and {"bmsc.supermarket-reason-expanding"} or {"bmsc.production-active-order"}
  end

  local lines = {{"bmsc.production-active-title"}}
  local function add_line(line) lines[#lines + 1] = line end
  if diagnostic.unavailable_recipe then
    add_line({"bmsc.production-active-fallback-line",
      signal_localised_label(Util.make_signal("recipe", diagnostic.unavailable_recipe)),
      diagnostic.fallback_recipe and signal_localised_label(
        Util.make_signal("recipe", diagnostic.fallback_recipe)) or {"bmsc.order-target-no-recipe"}})
  end
  local order = diagnostic.order
  local product = diagnostic.product
  add_line({"bmsc.production-active-order-line", signal_localised_label(order.signal), order.count})
  if diagnostic.recipe_name then
    add_line({"bmsc.production-active-recipe-line",
      signal_localised_label(Util.make_signal("recipe", diagnostic.recipe_name)),
      {diagnostic.manual_recipe and "bmsc.order-target-manual" or "bmsc.order-target-automatic"}})
  end
  if (order.signal.type or "item") == "recipe" then
    add_line({"bmsc.production-active-product-line", signal_localised_label(product.signal)})
  end
  local checked_products = type(diagnostic.products) == "table" and diagnostic.products or {product}
  for _, checked in ipairs(checked_products) do
    if checked.signal then
      add_line({"bmsc.production-active-target-line", signal_localised_label(checked.signal),
        checked.target, checked.stock, checked.remaining})
    end
  end

  local outputs = diagnostic.outputs
  if type(outputs) == "table" and outputs[1] then
    local output_lines = {}
    for _, entry in ipairs(outputs) do
      if entry.signal and entry.count then
        output_lines[#output_lines + 1] = {"bmsc.production-active-output-entry",
          signal_localised_label(entry.signal),
          entry.count, entry.depth or 1}
      end
    end
    local output_list = join_localised(output_lines, "\n")
    if output_list then
      add_line({"bmsc.production-active-outputs-line", output_list})
    end
  end

  local stage = diagnostic.stage
  if type(stage) == "table" and stage.signal then
    if (stage.level or 1) > 1 then
      add_line({"bmsc.production-active-stage-line",
        signal_localised_label(stage.signal), stage.output_count or 0, stage.level,
        stage.target or 0, stage.stock or 0})
    else
      add_line({"bmsc.production-active-plan-line", signal_localised_label(stage.signal),
        stage.output_count or 0})
    end

    local ingredients = stage.ingredients
    local required = signal_count_localised_list(ingredients, "required")
    if required then
      local stocks = signal_count_localised_list(ingredients, "stock")
      local shortages = signal_count_localised_list(ingredients, "shortage", true)
      add_line({"bmsc.production-active-materials-line", required})
      if stocks then
        add_line({"bmsc.production-active-material-stocks-line", stocks})
      end
      add_line(shortages
        and {"bmsc.production-active-shortages-line", shortages}
        or {"bmsc.production-active-shortages-none"})

      -- 缺少的直接原料若可由当前机器制造，再展示它的一层配方需求；不递归渲染。
      for _, ingredient in ipairs(ingredients) do
        local production = ingredient.production
        if type(production) == "table" and production.signal and production.count then
          add_line({"bmsc.production-active-substage-line",
            signal_localised_label(production.signal), production.count})
          local submaterials = signal_count_localised_list(production.ingredients, "required")
          local substocks = signal_count_localised_list(production.ingredients, "stock")
          local subshortages = signal_count_localised_list(production.ingredients, "shortage", true)
          if submaterials then
            add_line({"bmsc.production-active-submaterials-line", submaterials})
            if substocks then
              add_line({"bmsc.production-active-submaterial-stocks-line", substocks})
            end
            add_line(subshortages
              and {"bmsc.production-active-subshortages-line", subshortages}
              or {"bmsc.production-active-subshortages-none"})
          end
        end
      end
    end

    local thresholds = material_threshold_localised_list(ingredients)
    if stage.start_ready ~= nil then
      if thresholds then
        add_line({stage.start_ready
          and "bmsc.production-active-gate-ready-line"
          or "bmsc.production-active-gate-waiting-line", thresholds})
      else
        add_line({stage.start_ready
          and "bmsc.production-active-gate-ready"
          or "bmsc.production-active-gate-waiting"})
      end
    end
  end
  return join_localised(lines, "\n")
end

---把订单模式给出的结构化原因转换为附加在原型详情下方的本地化提示。
---@param diagnostic table|nil 输入信号诊断。
---@return LocalisedString|nil tooltip 没有诊断时不追加提示。
function Gui.production_diagnostic_tooltip(diagnostic)
  if not diagnostic then return nil end
  if diagnostic.kind == "active_output" or diagnostic.kind == "active_fallback"
    or diagnostic.kind == "supermarket_expanding" then
    return active_order_tooltip(diagnostic)
  end
  local reason
  if diagnostic.kind == "only_material" then
    reason = {"bmsc.production-reason-only-material"}
  elseif diagnostic.kind == "materials" then
    local shortages = shortage_localised_list(diagnostic.shortages)
    reason = shortages and {"bmsc.production-reason-materials", shortages} or nil
  elseif diagnostic.kind == "stock_sufficient" then
    local products = type(diagnostic.products) == "table" and diagnostic.products or nil
    local stocks = products and signal_count_localised_list(products, "stock")
    reason = stocks and {"bmsc.production-reason-products-sufficient", stocks}
      or {"bmsc.production-reason-stock-sufficient", diagnostic.stock}
  elseif diagnostic.kind == "no_recipe" then
    reason = {"bmsc.production-reason-no-recipe"}
  elseif diagnostic.kind == "recipe_locked" then
    reason = {"bmsc.production-reason-recipe-locked",
      signal_localised_label(Util.make_signal("recipe", diagnostic.recipe_name))}
  elseif diagnostic.kind == "recipe_machine_unsupported" then
    reason = {"bmsc.production-reason-recipe-machine-unsupported",
      signal_localised_label(Util.make_signal("recipe", diagnostic.recipe_name))}
  elseif diagnostic.kind == "surface_conditions" then
    reason = {"bmsc.supermarket-reason-surface-conditions"}
  elseif diagnostic.kind == "inventory_query_pending" then
    reason = {"bmsc.supermarket-reason-inventory-query-pending"}
  elseif diagnostic.kind == "unsupported_signal" then
    reason = {"bmsc.production-reason-unsupported-signal"}
  elseif diagnostic.kind == "non_positive_order" then
    reason = {"bmsc.production-reason-non-positive-order"}
  elseif diagnostic.kind == "waiting_for_order" and diagnostic.signal then
    reason = {"bmsc.production-reason-waiting", signal_localised_label(diagnostic.signal)}
  elseif diagnostic.kind == "supermarket_completed" then
    reason = {"bmsc.supermarket-reason-completed"}
  elseif diagnostic.kind == "swap_discarded" then
    reason = {"bmsc.swap-reason-discarded"}
  end
  return reason and {"bmsc.production-no-output-reason", reason} or nil
end

---按未输出原因选择信号槽底色；悬浮提示仍负责展示完整原因。
---@param color string 信号所属线路颜色。
---@param diagnostic table|nil 订单模式给出的结构化原因。
---@return string style_name GUI 样式名称。
local function diagnostic_signal_style(color, diagnostic)
  if not diagnostic then return color .. "_circuit_network_content_slot" end
  local kind = diagnostic and diagnostic.kind
  if kind == "swap_discarded" then return "bmsc_signal_diagnostic_filtered" end
  if color ~= "green" then return color .. "_circuit_network_content_slot" end
  if kind == "active_output" or kind == "supermarket_expanding" then
    return "green_circuit_network_content_slot" -- 标准绿色：当前正在输出或展开。
  end
  if kind == "waiting_for_order" or kind == "active_fallback"
    or kind == "inventory_query_pending" then
    return "bmsc_signal_diagnostic_filtered"  -- 黄色：有效订单，等待轮到它。
  end
  if kind == "stock_sufficient" or kind == "supermarket_completed" then
    return "bmsc_signal_diagnostic_pending"   -- 灰色：库存已满足，排在最后。
  end
  return "bmsc_signal_diagnostic_invalid"     -- 冷蓝：条件不满足或没有未输出原因。
end

---把输入诊断映射为显示顺序：当前输出、等待、异常/未知、库存充足或已截断。
local function diagnostic_signal_priority(diagnostic)
  local kind = diagnostic and diagnostic.kind
  if kind == "swap_discarded" then return -1 end
  if kind == "active_output" or kind == "active_fallback" or kind == "supermarket_expanding" then return 4 end
  if kind == "waiting_for_order" or kind == "inventory_query_pending" then return 3 end
  if kind == "stock_sufficient" or kind == "supermarket_completed" then return 1 end
  return 2
end

local unavailable_diagnostic_styles = {}

---应用诊断色；仅重载运行脚本而未重载数据阶段时，安全回退到原版线路槽位。
---@param slot LuaGuiElement 信号槽按钮。
---@param color string 信号所属线路颜色。
---@param diagnostic table|nil 订单诊断。
---@return nil
local function apply_diagnostic_signal_style(slot, color, diagnostic)
  local fallback = color .. "_circuit_network_content_slot"
  local style = diagnostic_signal_style(color, diagnostic)
  if style == fallback or unavailable_diagnostic_styles[style] then
    slot.style = fallback
    return
  end
  local applied = pcall(function() slot.style = style end)
  if not applied then
    unavailable_diagnostic_styles[style] = true
    slot.style = fallback
  end
end

---把输入/输出两侧的红绿网络信号合并成稳定排序的槽位数组。
---同一信号在两条线路上只显示一次，数量为两侧相加，避免无意义的重复图标。
---@param networks table `get_side_networks` 返回的网络数组。
---@param diagnostics table|nil 以 Util.signal_key 为键的输入诊断。
---@return table entries 每项包含展示线路、signal、count、sprite 和稳定 key。
local function collect_signal_entries(networks, diagnostics)
  local by_key = {}
  for _, network in ipairs(networks) do
    for _, value in pairs(network.signals) do
      if value.signal and value.signal.name then
        local key = Util.signal_key(value.signal)
        local entry = by_key[key]
        if not entry then
          entry = {signal = value.signal, count = 0, sort_priority = tonumber(value.sort_priority) or 0,
            diagnostic = diagnostics and diagnostics[key] or nil, key = key,
            has_green = false, has_red = false}
          by_key[key] = entry
        end
        entry.count = entry.count + (value.count or 0)
        entry.sort_priority = math.max(entry.sort_priority, tonumber(value.sort_priority) or 0)
        entry.has_green = entry.has_green or network.color == "green"
        entry.has_red = entry.has_red or network.color == "red"
      end
    end
  end
  local entries = {}
  for _, entry in pairs(by_key) do
    -- 交互沿用绿色线路：订单选择、Shift 操作仍能在合并后的槽位正常触发。
    entry.color = entry.has_green and "green" or "red"
    entry.diagnostic_priority = entry.diagnostic and diagnostic_signal_priority(entry.diagnostic) or 0
    entry.sprite = signal_sprite_path(entry.signal)
    entries[#entries + 1] = entry
  end
  table.sort(entries, function(a, b)
    if a.diagnostic_priority ~= b.diagnostic_priority then
      return a.diagnostic_priority > b.diagnostic_priority
    end
    if a.sort_priority ~= b.sort_priority then return a.sort_priority > b.sort_priority end
    return a.key < b.key
  end)
  return entries
end

---更新一个常驻信号子面板。
---只有信号种类、品质或排序变化时才重建槽位；通常的数值变化只写 `number`，
---从而避免周期性 clear/destroy 带来的 GUI 分配、悬浮中断和额外 UPS 消耗。
---@param section LuaGuiElement “输入信号”或“输出信号”的子 frame。
---@param networks table 当前侧的红绿网络。
---@param diagnostics table|nil 以 Util.signal_key 为键的绿色输入诊断。
---@return nil
local function refresh_signal_section(section, networks, diagnostics, source)
  -- 热更新不会重建已打开的旧窗口；旧布局没有新增的来源子框时跳过本轮刷新，
  -- 玩家关闭并重新打开组合器后会按新结构创建，不能因此让 on_nth_tick 中断。
  if not section or section.valid == false then return end
  local entries = collect_signal_entries(networks, diagnostics)
  local signature_parts = {}
  for _, entry in ipairs(entries) do
    -- 优先级也属于布局签名；同一组信号的顺序改变时需要重排槽位，而不只是更新数字。
    signature_parts[#signature_parts + 1] = tostring(entry.diagnostic_priority) .. "|"
      .. tostring(entry.sort_priority) .. "|" .. entry.key
  end
  local signature = table.concat(signature_parts, "\n")
  section.visible = #entries > 0
  local scroll = section["bmsc-signal-scroll"]
  if not (scroll and scroll.valid) then return end
  local slots = scroll["bmsc-signal-slots"]
  if slots and slots.valid and scroll.tags.bmsc_signal_signature == signature then
    for index, entry in ipairs(entries) do
      local slot = slots.children[index]
      local diagnostic = entry.diagnostic
      slot.number = entry.count
      apply_diagnostic_signal_style(slot, entry.color, diagnostic)
      slot.tooltip = Gui.production_diagnostic_tooltip(diagnostic)
    end
    return
  end

  scroll.clear()
  scroll.tags = {bmsc_signal_signature = signature}
  -- 空信号区保持留白；运行表的空行和信号区采用同一“无文字占位”规则。
  if #entries == 0 then return end

  slots = scroll.add{type = "table", name = "bmsc-signal-slots", column_count = 8}
  slots.style.horizontally_stretchable = true
  for _, entry in ipairs(entries) do
    local diagnostic = entry.diagnostic
    -- 合并后以绿色底色表示可操作的订单信号；纯红线信号保持原有红色底色。
    local slot = slots.add{type = "sprite-button", sprite = entry.sprite, number = entry.count,
      style = entry.color .. "_circuit_network_content_slot", elem_tooltip = signal_elem_tooltip(entry.signal),
      tooltip = Gui.production_diagnostic_tooltip(diagnostic),
      tags = {
        bmsc_signal_panel_icon = true,
        bmsc_signal_side = source == "output" and "output" or "input",
        bmsc_signal_source = source,
        bmsc_signal_color = entry.color,
        bmsc_signal_key = Util.signal_key(entry.signal),
        bmsc_signal_type = entry.signal.type or "item",
        bmsc_signal_name = entry.signal.name,
        bmsc_signal_quality = Util.quality_name(entry.signal.quality)
      }}
    apply_diagnostic_signal_style(slot, entry.color, diagnostic)
    local quality = type(entry.signal.quality) == "string" and entry.signal.quality
      or (entry.signal.quality and entry.signal.quality.name)
    if (entry.signal.type or "item") == "item" and quality and quality ~= "normal" then
      slot.quality = quality
    end
  end
end

---打开订单配方和库存校验产物子窗口。
---子窗口成为 player.opened，因此 Esc 只先关闭它；关闭后 control.lua 会恢复后方主窗口。
function Gui.open_order_target(player, order_signal, order_count, target, recipes, options)
  options = options or {}
  local old = player.gui.screen[Gui.order_target_name]
  if old then old.destroy() end

  local frame = player.gui.screen.add{type = "frame", name = Gui.order_target_name, direction = "vertical",
    tags = {bmsc_source_key = target.source_key, bmsc_signal_type = order_signal.type or "item",
      bmsc_signal_name = order_signal.name, bmsc_signal_quality = Util.quality_name(order_signal.quality),
      bmsc_order_count = order_count}}
  frame.style.width = 440
  frame.force_auto_center()
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", caption = {options.show_products == false
    and "bmsc.recipe-selection-title" or "bmsc.order-target-title"}, style = "frame_title"}.drag_target = frame
  local dragger = titlebar.add{type = "empty-widget", style = "draggable_space_header"}
  dragger.style.horizontally_stretchable = true
  dragger.style.height = 24
  dragger.drag_target = frame
  titlebar.add{type = "sprite-button", name = "bmsc-order-target-close", sprite = "utility/close",
    style = "frame_action_button", tooltip = {"gui.close"}}

  local content = frame.add{type = "flow", direction = "vertical"}
  content.style.padding = 8
  content.style.vertical_spacing = 8
  content.add{type = "label", caption = {options.show_products == false
    and "bmsc.recipe-query-target" or "bmsc.order-target-order",
    signal_localised_label(order_signal), order_count}}

  content.add{type = "label", caption = {"bmsc.order-target-recipe"}, style = "heading_2_label"}
  local function recipe_tags(recipe_name)
    return {bmsc_order_target_recipe = recipe_name or false,
      bmsc_signal_type = order_signal.type or "item", bmsc_signal_name = order_signal.name,
      bmsc_signal_quality = Util.quality_name(order_signal.quality), bmsc_order_count = order_count}
  end
  if order_signal.type == "recipe" then
    local recipe = target.recipe or target.locked_recipe and prototypes.recipe[target.locked_recipe]
    if recipe then
      local row = content.add{type = "flow", direction = "horizontal"}
      local unlocked = options.enabled_recipes and options.enabled_recipes[recipe.name]
      row.add{type = "sprite-button", sprite = "recipe/" .. recipe.name,
        style = unlocked and "green_circuit_network_content_slot" or "bmsc_signal_diagnostic_invalid",
        elem_tooltip = {type = "recipe", name = recipe.name}}
      row.add{type = "label", caption = recipe.localised_name}
    else
      content.add{type = "label", caption = {"bmsc.order-target-no-recipe"}}
    end
  else
    content.add{type = "button", name = "bmsc-order-target-auto-recipe",
      caption = {"bmsc.order-target-auto-recipe", target.automatic_recipe
        and target.automatic_recipe.localised_name or {"bmsc.order-target-no-recipe"}},
      style = target.configured_recipe and "button" or "confirm_button", tags = recipe_tags(nil)}
    if target.machine_unsupported_recipe then
      content.add{type = "label", caption = {"bmsc.order-target-machine-unsupported",
        signal_localised_label(Util.make_signal("recipe", target.machine_unsupported_recipe)),
        target.automatic_recipe and signal_localised_label(
          Util.make_signal("recipe", target.automatic_recipe.name)) or {"bmsc.order-target-no-recipe"}}}
    end
    local scroll = content.add{type = "scroll-pane", direction = "vertical",
      horizontal_scroll_policy = "never", vertical_scroll_policy = "auto"}
    scroll.style.horizontally_stretchable = true
    scroll.style.maximal_height = 180
    if not recipes[1] then
      scroll.add{type = "label", caption = {"bmsc.order-target-no-recipe"}}
    end
    for _, recipe in ipairs(recipes or {}) do
      local row = scroll.add{type = "flow", direction = "horizontal"}
      row.style.vertical_align = "center"
      local selected = target.configured_recipe == recipe.name
      local unlocked = options.enabled_recipes and options.enabled_recipes[recipe.name]
      local style = selected and (unlocked and "green_circuit_network_content_slot"
        or "bmsc_signal_diagnostic_invalid")
        or unlocked and "slot_button" or "bmsc_signal_diagnostic_pending"
      row.add{type = "sprite-button", sprite = "recipe/" .. recipe.name,
        style = style,
        elem_tooltip = {type = "recipe", name = recipe.name}, tags = recipe_tags(recipe.name)}
      row.add{type = "label", caption = recipe.localised_name}
    end
  end

  if options.show_products ~= false then
    content.add{type = "label", caption = {"bmsc.order-target-products"}, style = "heading_2_label"}
    local selected = {}
    for _, product in ipairs(target.products or {}) do selected[Util.signal_key(product)] = true end
    local products = content.add{type = "table", column_count = 8}
    for _, product in ipairs(target.available_products or {}) do
      local chosen = selected[Util.signal_key(product)] == true
      local button = products.add{type = "sprite-button", sprite = signal_sprite_path(product),
        style = chosen and "green_circuit_network_content_slot" or "slot_button",
        elem_tooltip = signal_elem_tooltip(product), tooltip = chosen
          and {"bmsc.order-target-selected"} or {"bmsc.order-target-not-selected"},
        tags = {bmsc_order_target_product = true, bmsc_signal_type = product.type or "item",
          bmsc_signal_name = product.name, bmsc_signal_quality = Util.quality_name(product.quality),
          bmsc_order_count = order_count}}
      if product.type == "item" and product.quality and product.quality ~= "normal" then
        button.quality = product.quality
      end
    end
    local help = content.add{type = "label", caption = {"bmsc.order-target-help"}}
    help.style.single_line = false
    help.style.maximal_width = 420
  end
  player.opened = frame
  return frame
end

---关闭订单子窗口；restore_main 为 true 时让下一次 Esc 继续关闭后方主窗口。
function Gui.close_order_target(player, restore_main)
  local frame = player.gui.screen[Gui.order_target_name]
  if frame and frame.valid then frame.destroy() end
  local main = player.gui.screen[Gui.name]
  player.opened = restore_main and main and main.valid and main or nil
end

---销毁留在子窗口后方的主窗口，但不改写 player.opened（它可能已经指向另一个实体）。
function Gui.destroy_background(player)
  Gui.hide_network_popup(player)
  local overlay = player.gui.screen[Gui.config_overlay_name]
  if overlay and overlay.valid then overlay.destroy() end
  local frame = player.gui.screen[Gui.name]
  if frame and frame.valid then frame.destroy() end
end

---创建一个有独立边界、内容可按需纵向滚动的信号子 GUI。
---@param parent LuaGuiElement 信号公共 GUI。
---@param name string 子 GUI 名称。
---@param caption LocalisedString 子 GUI 标题。
---@param maximum_content_height uint 滚动内容的最大高度。
---@return LuaGuiElement section 创建出的子 GUI。
local function add_signal_section(parent, name, caption, maximum_content_height, minimum_content_height)
  local section = parent.add{type = "frame", name = name,
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  section.style.horizontally_stretchable = true
  section.add{type = "label", caption = caption, style = "heading_2_label"}
  local scroll = section.add{type = "scroll-pane", name = "bmsc-signal-scroll",
    direction = "vertical", horizontal_scroll_policy = "never", vertical_scroll_policy = "auto"}
  scroll.style.horizontally_stretchable = true
  scroll.style.vertically_squashable = true
  -- 多来源输入并存时每组保留一行；仅有输入/输出两组的旧布局仍保留两行。
  scroll.style.minimal_height = minimum_content_height or 96
  scroll.style.maximal_height = maximum_content_height
  return section
end

---向指定模式详情容器添加一套公共信号 GUI。
---本函数只依赖父 GUI 和玩家显示尺寸，不读取模式配置、实体或 storage；各模式分别
---调用同一入口完成绑定，后续调整布局无需复制多套实现。
---@param parent LuaGuiElement 当前模式的详情容器。
---@param player LuaPlayer 用于根据分辨率和 UI 缩放限制面板高度。
---@return LuaGuiElement signals 创建出的信号公共面板。
function Gui.add_signal_panel(parent, player)
  local signals = parent.add{type = "frame", name = "bmsc-signals",
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  signals.style.horizontally_stretchable = true

  -- GUI 尺寸使用缩放后的逻辑像素。输入来源按语义分组；空组会隐藏，因此常见布局
  -- 不会为网络订单或关联库存预留空白。
  local display_scale = player.display_scale > 0 and player.display_scale or 1
  local signal_panel_height = math.floor(player.display_resolution.height / display_scale / 2)
  local section_content_height = math.max(48, math.floor((signal_panel_height - 210) / 5))
  signals.style.maximal_height = signal_panel_height
  signals.add{type = "label", caption = {"bmsc.signal-panel-title"}, style = "heading_2_label"}
  add_signal_section(signals, "bmsc-network-order-signals", {"bmsc.network-order-signals"}, section_content_height, 48)
  add_signal_section(signals, "bmsc-local-green-signals", {"bmsc.local-green-signals"}, section_content_height, 48)
  add_signal_section(signals, "bmsc-local-red-signals", {"bmsc.local-red-signals"}, section_content_height, 48)
  local linked = add_signal_section(
    signals, "bmsc-linked-inventory-signals", {"bmsc.linked-inventory-signals"}, section_content_height, 48)
  linked.style.bottom_margin = 8
  add_signal_section(signals, "bmsc-output-signals", {"bmsc.output-signals"}, section_content_height)
  return signals
end

local function add_work_row(grid, name, caption)
  local label = grid.add{type = "label", name = name .. "-kind", caption = caption, style = "heading_2_label"}
  label.style.minimal_width = 104
  local item = grid.add{type = "flow", name = name .. "-item", direction = "horizontal"}
  item.style.minimal_width = 48
  item.style.vertical_align = "center"
  local icon = item.add{type = "sprite-button", name = name .. "-icon", style = "slot_button", visible = false}
  local function value(suffix, tooltip)
    local field = grid.add{type = "label", name = name .. suffix, caption = "", tooltip = tooltip}
    field.style.minimal_width, field.style.horizontal_align = 56, "center"
    return field
  end
  value("-target", {"bmsc.work-target-tooltip"})
  local separator = grid.add{type = "label", name = name .. "-separator-one", caption = "｜"}
  separator.style.horizontal_align = "center"
  value("-remaining", {"bmsc.work-remaining-tooltip"})
  local separator_two = grid.add{type = "label", name = name .. "-separator-two", caption = "｜"}
  separator_two.style.horizontal_align = "center"
  value("-stock", {"bmsc.work-stock-tooltip"})
  local separator_three = grid.add{type = "label", name = name .. "-separator-three", caption = "｜"}
  separator_three.style.horizontal_align = "center"
  local state = grid.add{type = "label", name = name .. "-state", caption = ""}
  state.style.minimal_width = 104
  return {label = label, item = item, icon = icon,
    target = grid[name .. "-target"], separator = separator, remaining = grid[name .. "-remaining"],
    separator_two = separator_two, stock = grid[name .. "-stock"], separator_three = separator_three, state = state}
end

local function add_work_panel(parent)
  local panel = parent.add{type = "frame", name = "bmsc-work-panel",
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  panel.style.horizontally_stretchable = true
  local grid = panel.add{type = "table", name = "bmsc-work-grid", column_count = 9}
  grid.style.horizontal_spacing = 4
  add_work_row(grid, "bmsc-work-production", {"bmsc.work-production"})
  add_work_row(grid, "bmsc-work-order", {"bmsc.work-order"})
  add_work_row(grid, "bmsc-work-next", {"bmsc.work-next"})
  return panel
end

local function work_row_caption(prefix)
  return ({
    ["bmsc-work-production"] = {"bmsc.work-production"},
    ["bmsc-work-order"] = {"bmsc.work-order"},
    ["bmsc-work-next"] = {"bmsc.work-next"}
  })[prefix]
end

local function set_work_row(panel, prefix, product, state_caption, color, state_tooltip)
  local grid = panel and panel["bmsc-work-grid"]
  local row = grid and {
    label = grid[prefix .. "-kind"], item = grid[prefix .. "-item"],
    target = grid[prefix .. "-target"], separator = grid[prefix .. "-separator-one"],
    remaining = grid[prefix .. "-remaining"], separator_two = grid[prefix .. "-separator-two"],
    stock = grid[prefix .. "-stock"], separator_three = grid[prefix .. "-separator-three"], state = grid[prefix .. "-state"]}
  if not row then return end
  row.icon = row.item[prefix .. "-icon"]
  if not (row.label and row.icon and row.target and row.separator and row.remaining
    and row.separator_two and row.stock and row.separator_three and row.state) then return end
  local visible = product and product.signal
  if not visible then
    -- 三行工作摘要始终保留，避免空闲时只留下无法解释的大空框。
    row.label.caption, row.icon.visible = work_row_caption(prefix), false
    for _, field in ipairs({row.target, row.separator, row.remaining, row.separator_two, row.stock, row.separator_three, row.state}) do
      field.caption = ""
    end
    row.state.caption = ({
      ["bmsc-work-production"] = {"bmsc.work-idle-production"},
      ["bmsc-work-order"] = {"bmsc.work-idle-order"},
      ["bmsc-work-next"] = {"bmsc.work-idle-next"}
    })[prefix]
    row.state.tooltip = nil
    return
  end
  row.label.caption = work_row_caption(prefix)
  row.icon.visible, row.icon.sprite, row.icon.elem_tooltip = true, signal_sprite_path(product.signal), signal_elem_tooltip(product.signal)
  row.target.caption = tostring(math.ceil(product.target or 0))
  row.separator.caption = "｜"
  row.remaining.caption = tostring(math.ceil(product.remaining or 0))
  row.separator_two.caption = "｜"
  row.stock.caption = tostring(math.floor(product.stock or 0))
  row.separator_three.caption = "｜"
  row.state.caption = state_caption or ""
  row.state.style.font_color = color or {1, 1, 1}
  row.state.tooltip = state_tooltip
end

local function material_state(stage)
  local ingredients = stage and stage.ingredients or {}
  local complete, ready = true, true
  for _, ingredient in ipairs(ingredients) do
    complete = complete and (ingredient.stock or 0) >= (ingredient.required or 0)
    ready = ready and ingredient.demand_ready == true
  end
  if complete then return {"bmsc.work-material-full"}, {0.4, 1, 0.4} end
  if ready then return {"bmsc.work-material-ready"}, {0.35, 0.7, 1} end
  return {"bmsc.work-material-low"}, {1, 0.35, 0.35}
end

function Gui.refresh_work_panel(panel, work)
  work = work or {}
  local current = work.current
  local stage = current and current.stage
  local production = stage and stage.single_output ~= false and stage.product_output ~= false and stage or nil
  local material, material_color = material_state(production)
  local material_stock = 0
  for _, ingredient in ipairs(production and production.ingredients or {}) do
    material_stock = material_stock + math.max(0, ingredient.stock or 0)
  end
  set_work_row(panel, "bmsc-work-production", production and {
    signal = production.signal, target = production.target, stock = production.stock,
    remaining = math.max(0, (production.target or 0) - (production.stock or 0))} or nil, material, material_color,
    production and {"bmsc.work-material-stock-tooltip", math.floor(material_stock)} or nil)
  set_work_row(panel, "bmsc-work-order", current and current.product,
    current and {work.source == "network" and "bmsc.work-network" or "bmsc.work-local"} or nil)
  set_work_row(panel, "bmsc-work-next", work.next and work.next.product,
    work.next and {work.source == "network" and "bmsc.work-network" or "bmsc.work-local"} or nil)
end

---刷新一套公共信号 GUI 的输入和输出槽位。
---面板构建与数据刷新分离，使各模式只负责绑定容器，不需要了解红绿网络和增量刷新细节。
---@param signals LuaGuiElement `Gui.add_signal_panel` 创建的面板。
---@param input_networks table 输入端红绿网络数据。
---@param output_networks table 输出端红绿网络数据。
---@param input_diagnostics table|nil 生产订单绿色输入信号的未输出原因。
---@return nil
function Gui.refresh_signal_panel(signals, input_networks, output_networks, input_diagnostics, work)
  if not (signals and signals.valid) then return end
  local green, red = {}, {}
  for _, network in ipairs(input_networks or {}) do
    local target = network.color == "green" and green or red
    target[#target + 1] = network
  end
  work = work or {}
  refresh_signal_section(signals["bmsc-network-order-signals"], {
    {color = "green", signals = work.network_orders or {}}
  }, work.network_diagnostics, "network-order")
  refresh_signal_section(signals["bmsc-local-green-signals"], green, input_diagnostics, "local-order")
  refresh_signal_section(signals["bmsc-local-red-signals"], red, nil, "local-stock")
  refresh_signal_section(signals["bmsc-linked-inventory-signals"], {
    {color = "green", signals = work.linked_inventory or {}}
  }, nil, "linked-inventory")
  refresh_signal_section(signals["bmsc-output-signals"], output_networks, nil, "output")
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

---添加带左右数值框的倍率控件。
---左端可作为固定下界（生产倍率）或保留倍率（原料倍率）；滑块始终调整右端值，
---避免为了两端控件引入自定义控件或额外持久化状态。
local function add_rate_range(parent, caption, name, lower_name, lower_value, upper_value, lower_locked, tooltip)
  parent.add{type = "label", caption = caption}
  local controls = parent.add{type = "flow", name = name .. "-controls", direction = "horizontal"}
  controls.style.vertical_align = "center"
  controls.style.horizontal_spacing = 4
  local lower = controls.add{type = "textfield", name = lower_name, style = "short_slider_value_textfield",
    text = tostring(lower_value), numeric = true, allow_decimal = true, allow_negative = false,
    enabled = not lower_locked, tooltip = tooltip}
  lower.style.width = 56
  local values = Gui.slider_profiles[name]
  local slider = controls.add{type = "slider", name = name .. "-slider", style = "notched_slider",
    minimum_value = 1, maximum_value = #values,
    value = nearest_slider_index(upper_value, values), value_step = 1, discrete_values = true,
    tooltip = tooltip, tags = {bmsc_numeric_input = name}}
  slider.style.width = 112
  local upper = controls.add{type = "textfield", name = name, style = "short_slider_value_textfield",
    text = tostring(upper_value), numeric = true, allow_decimal = true, allow_negative = false,
    tooltip = tooltip, tags = {bmsc_numeric_slider = name .. "-slider"}}
  upper.style.width = 56
  return upper
end

---在超时输入框右侧追加同尺寸的只读计时框，三个模式共用同一布局。
local function add_timeout_slider(parent, caption, name, value, allow_decimal, tooltip, visible, label_name)
  local input = add_numeric_slider(
    parent, caption, name, value, allow_decimal, tooltip, visible, label_name)
  local elapsed = input.parent.add{
    type = "textfield", name = name .. "-elapsed", style = "short_slider_value_textfield",
    text = "0.0", enabled = false, tooltip = {"bmsc.timeout-elapsed"}
  }
  elapsed.style.width = 64
  return input
end

---校验当前订单参数区中的两个材料倍率，并同步输入框的红色错误背景。
---无效时保留玩家输入，便于继续编辑；本函数只负责界面状态，不写入实体配置。
---@param source_element LuaGuiElement 任意一个材料倍率输入框或对应滑块。
---@return boolean valid 是否满足“材料需求倍率 > 原料保留倍率”。
---@return number|nil demand 输入框中的需求倍率。
---@return number|nil retention 输入框中的保留倍率。
function Gui.validate_material_rate_inputs(source_element)
  -- 控件位于“表格 → controls flow → 输入框/滑块”；从事件来源就近定位可同时支持
  -- 生产订单和超市订单，无需按当前可见模式维护两套查找代码。
  local controls = source_element and source_element.parent
  local fields = controls and controls.parent
  if not fields then return false, nil, nil end

  local recursion = source_element.name:find("bmsc-recursion-material", 1, true) == 1
  local demand_name = recursion and "bmsc-recursion-material" or "bmsc-material"
  local retention_name = recursion and "bmsc-recursion-material-retention" or "bmsc-material-retention"
  local demand_flow = fields[demand_name .. "-controls"]
  -- 超市订单把保留/需求倍率收在同一双端控件中；生产订单仍保持两条独立行。
  local retention_flow = fields[retention_name .. "-controls"] or demand_flow
  local demand_input = demand_flow and demand_flow[demand_name]
  local retention_input = retention_flow and retention_flow[retention_name]
  if not (demand_input and retention_input) then return false, nil, nil end

  local demand = tonumber(demand_input.text)
  local retention = tonumber(retention_input.text)
  local valid = demand ~= nil and retention ~= nil and Config.material_rates_valid(demand, retention)
  local style = valid and "short_slider_value_textfield" or "invalid_value_short_number_textfield"
  local width = recursion and 56 or 64
  demand_input.style = style
  retention_input.style = style
  demand_input.style.width = width                    -- 切换预设样式会清除自定义宽度，需要重新设置。
  retention_input.style.width = width
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
    if current.name == Gui.name or current.name == Gui.config_overlay_name then return current end
    current = current.parent
  end
  return nil
end

---返回承载配置控件的窗口：宽屏是主窗口，窄屏是独立覆盖层。
---@param window LuaGuiElement|nil 主窗口或覆盖层。
---@return LuaGuiElement|nil
local function config_window(window)
  if window and window.name == Gui.name then
    local overlay = window.parent and window.parent[Gui.config_overlay_name]
    if overlay and overlay.valid then return overlay end
  end
  return window
end

---刷新原版风格状态栏中的“输入/输出：已连接或未连接”。
---调用方传入实体，因此本模块不需要了解组合器记录或 storage 的结构。
---@param player LuaPlayer 拥有此 GUI 的玩家。
---@param entity LuaEntity|nil 正在查看的市场选择运算器。
---@param current_output_networks table|nil control.lua 本轮实际写入输出代理的信号快照。
---@param input_diagnostics table|nil 生产订单绿色输入信号的未输出原因。
---@return nil
function Gui.refresh_connection_status(player, entity, current_output_networks, input_diagnostics, work)
  local frame = player.gui.screen[Gui.name]
  if not (frame and frame.valid and entity and entity.valid) then return end
  local content = frame["bmsc-content"]
  local runtime = content and find_descendant(content, "bmsc-runtime-page")
  local connections = runtime and runtime["bmsc-connections"]
  if not connections then return end
  local input_networks = get_side_networks(entity, "input")
  local output_networks = get_side_networks(entity, "output")
  refresh_side_status(connections["bmsc-input-status"], input_networks)
  refresh_side_status(connections["bmsc-output-status"], output_networks)
  Gui.refresh_work_panel(runtime["bmsc-work-panel"], work)
  if runtime.visible then
    -- 定时计算时优先使用“本轮实际写入代理”的快照，保证 GUI 与线路输出同源。
    -- 打开窗口后的首次刷新还没有传入快照，此时才从代理线路读取已有信号。
    local signal_output_networks = current_output_networks or get_side_networks(entity, "output", true)
    Gui.refresh_signal_panel(runtime["bmsc-signals"], input_networks, signal_output_networks, input_diagnostics, work)
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
  local production_details = find_descendant(content, "bmsc-production-details")
  local network_settings = find_descendant(content, "bmsc-network-settings")
  if network_settings then network_settings.visible = mode == Gui.supermarket_order end
  local recursion_details = find_descendant(content, "bmsc-recursion-details")
  local recipe_query_details = find_descendant(content, "bmsc-recipe-query-details")
  local inventory_query_details = find_descendant(content, "bmsc-inventory-query-details")
  local swap_details = find_descendant(content, "bmsc-swap-details")
  if production_details then production_details.visible = mode == Gui.production_order end
  if recursion_details then recursion_details.visible = mode == Gui.supermarket_order end
  if recipe_query_details then recipe_query_details.visible = mode == Gui.recipe_query end
  if inventory_query_details then inventory_query_details.visible = mode == Gui.inventory_query end
  if swap_details then swap_details.visible = mode == Gui.swap_order end
  local runtime_window = window
  if window and window.name == Gui.config_overlay_name then
    runtime_window = window.parent and window.parent[Gui.name]
  end
  local runtime = runtime_window and find_descendant(runtime_window["bmsc-content"], "bmsc-runtime-page")
  if runtime and runtime["bmsc-runtime-mode"] then
    runtime["bmsc-runtime-mode"].caption = {"bmsc.runtime-mode", mode_caption(mode)}
    runtime["bmsc-runtime-mode"].tooltip = mode_tooltip(mode)
  end
  local mode_select = find_descendant(content, "bmsc-mode")
  if mode_select then mode_select.tooltip = mode_tooltip(mode) end
end

---按配置栏状态切换主窗口的紧凑/展开宽度，并保持窗口中心位置不跳动。
local function set_config_window_width(window, config_visible)
  local tags = window and window.tags or {}
  local compact_width = tags.bmsc_compact_width
  local expanded_width = tags.bmsc_expanded_width
  if not (compact_width and expanded_width) then return end
  local previous_width = config_visible and compact_width or expanded_width
  local target_width = config_visible and expanded_width or compact_width
  if target_width == previous_width then return end
  local location = window.location
  window.style.width = target_width
  if location then
    window.location = {x = location.x - math.floor((target_width - previous_width) / 2), y = location.y}
  end
end

---主窗口被拖动时同步窄屏配置覆盖层，避免两个同生命周期窗口错位。
---@param window LuaGuiElement 可能移动的主窗口。
---@return nil
function Gui.sync_config_overlay_location(window)
  if not (window and window.valid and window.name == Gui.name and window.location) then return end
  local overlay = window.parent and window.parent[Gui.config_overlay_name]
  if overlay and overlay.valid and overlay.visible then
    overlay.location = {x = window.location.x, y = window.location.y + 56}
  end
end

---展开或收起参数栏，同时调整主窗口宽度；纯界面状态由 control.lua 按玩家保存。
---@param source_element LuaGuiElement 参数栏按钮。
---@return boolean 收起后是否需要立即刷新运行栏。
---@return boolean|nil config_open 当前配置栏是否展开；无效页面返回 nil。
function Gui.show_page(source_element, page)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  local runtime = content and find_descendant(content, "bmsc-runtime-page")
  local config_column = content and content["bmsc-config-column"]
  if page ~= "config" then return false, nil end
  local overlay = window and window.parent[Gui.config_overlay_name]
  if overlay then
    overlay.visible = not overlay.visible
    if overlay.visible and window.location then
      overlay.location = {x = window.location.x, y = window.location.y + 56}
    end
    local switcher = window["bmsc-page-switcher"]
    if switcher then switcher["bmsc-page-config"].toggled = overlay.visible end
    return not overlay.visible, overlay.visible
  end
  if not (runtime and config_column) then return false, nil end
  config_column.visible = not config_column.visible
  set_config_window_width(window, config_column.visible)
  runtime.visible = true
  local switcher = window["bmsc-page-switcher"]
  if switcher then
    switcher["bmsc-page-config"].toggled = config_column.visible
  end
  return not config_column.visible, config_column.visible
end

local comparator_items = {"<", ">", "=", "≤", "≥", "≠"}
local comparator_values = {"<", ">", "=", "<=", ">=", "~="}

local function set_condition_operand_style(input, fulfilled)
  input.style = fulfilled and "decider_combinator_fulfilled_signal_select_button"
    or "decider_combinator_signal_select_button"
  input.style.size = 40
  input.style.font_color = {1, 1, 1}
  input.style.hovered_font_color = {1, 1, 1}
  input.style.clicked_font_color = {1, 1, 1}
end

local function add_condition_operand(parent, operand, set_name, index, side, fulfilled)
  local flow = parent.add{type = "flow", direction = "horizontal"}
  flow.style.vertical_align = "center"
  flow.style.horizontal_spacing = 4
  local colors = flow.add{type = "flow", direction = "vertical"}
  colors.style.vertical_spacing = 0
  colors.add{type = "checkbox", caption = {"bmsc.network-color-red"}, state = operand.red ~= false,
    tags = {bmsc_condition_set = set_name, bmsc_swap_condition = index,
      bmsc_swap_side = side, bmsc_swap_color = "red"}}
  colors.add{type = "checkbox", caption = {"bmsc.network-color-green"}, state = operand.green ~= false,
    tags = {bmsc_condition_set = set_name, bmsc_swap_condition = index,
      bmsc_swap_side = side, bmsc_swap_color = "green"}}
  local tags = {bmsc_condition_set = set_name, bmsc_swap_operand = true,
    bmsc_swap_condition = index, bmsc_swap_side = side}
  local input
  if operand.signal and operand.signal.name then
    input = flow.add{type = "sprite-button", style = "decider_combinator_signal_select_button",
      sprite = signal_sprite_path(operand.signal), tags = tags}
  else
    -- 常量与信号占用同一个槽位；白色 caption 居中显示，点击后统一打开信号选择器。
    input = flow.add{type = "button", style = "decider_combinator_signal_select_button",
      caption = tostring(operand.constant or 0), tags = tags}
  end
  set_condition_operand_style(input, fulfilled)
end

---重建条件列表；条件数据归配置所有，GUI 只渲染，因此模式计算不依赖任何 LuaGuiElement。
function Gui.rebuild_conditions(source_element, set_name, conditions, fulfilled_conditions)
  local window = Gui.containing_window(source_element)
  local list = find_descendant(window, "bmsc-" .. set_name .. "-conditions")
  if not list then return end
  list.clear()
  for index, condition in ipairs(conditions) do
    local fulfilled = fulfilled_conditions and fulfilled_conditions[index] == true
    if index > 1 then
      -- 负边距让逻辑按钮占据两条条件之间的缝隙，而不是形成第三条完整内容行。
      local relation = list.add{type = "flow", direction = "horizontal"}
      relation.style.horizontally_stretchable = true
      relation.style.left_padding = 32
      relation.style.top_margin = -18
      relation.style.bottom_margin = -18
      local relation_button = relation.add{type = "button",
        caption = {"bmsc." .. (condition.relation == "and" and "and" or "or")},
        tags = {bmsc_condition_set = set_name, bmsc_swap_relation = index}}
      relation_button.style.width = 60
      relation_button.style.height = 36
    end
    local row = list.add{type = "frame", name = "bmsc-swap-condition-" .. index,
      style = fulfilled and "decider_combinator_fulfilled_condition_frame"
        or "decider_combinator_condition_frame",
      direction = "horizontal", tags = {bmsc_swap_condition_row = index}}
    row.style.vertical_align = "center"
    row.style.horizontally_stretchable = true
    row.style.right_margin = 8                         -- 与外层边框留出空隙，避免删除按钮贴边。
    add_condition_operand(row, condition.first, set_name, index, "first", fulfilled)
    local selected = 1
    for item_index, value in ipairs(comparator_values) do
      if value == condition.comparator then selected = item_index; break end
    end
    local comparator = row.add{type = "drop-down", items = comparator_items, selected_index = selected,
      tags = {bmsc_condition_set = set_name, bmsc_swap_comparator = index}}
    comparator.style.width = 44
    comparator.style.height = 40
    add_condition_operand(row, condition.second, set_name, index, "second", fulfilled)
    local remove = row.add{type = "sprite-button", sprite = "utility/close", style = "tool_button",
      tags = {bmsc_condition_set = set_name, bmsc_swap_delete = index}, tooltip = {"gui.remove"}}
    remove.style.width = 32
    remove.style.height = 40                           -- 与条件操作数等高，完整嵌入条件框。
  end
  local add = list.add{type = "button", name = "bmsc-" .. set_name .. "-add-condition",
    caption = {"bmsc.add-condition"}, tags = {bmsc_condition_set = set_name, bmsc_add_condition = true}}
  add.style.horizontally_stretchable = true
  add.style.height = 36
end

---添加一组与切换订单相同的线路条件编辑器。
local function add_conditions_editor(parent, set_name, caption, conditions, visible)
  parent.add{type = "label", name = "bmsc-" .. set_name .. "-conditions-label",
    caption = caption, style = "heading_2_label", visible = visible ~= false}
  local list = parent.add{type = "scroll-pane", name = "bmsc-" .. set_name .. "-conditions",
    style = "decider_combinator_conditions_scroll_pane", direction = "vertical",
    horizontal_scroll_policy = "never", vertical_scroll_policy = "auto", visible = visible ~= false}
  -- 默认只展示一条条件和“添加条件”；继续添加的内容在本区域内滚动，不再挤占主窗口。
  list.style.horizontally_stretchable = true
  list.style.height = 112                            -- 容纳双线路勾选的一条条件及下方添加按钮。
  Gui.rebuild_conditions(parent, set_name, conditions)
end

local function update_condition_operand_styles(parent, fulfilled)
  for _, child in ipairs(parent.children) do
    local tags = child.tags or {}
    if tags.bmsc_swap_operand then set_condition_operand_style(child, fulfilled) end
    if #child.children > 0 then update_condition_operand_styles(child, fulfilled) end
  end
end

local function refresh_elapsed(fields, timeout_name, elapsed_seconds)
  local controls = fields and fields[timeout_name .. "-controls"]
  local elapsed = controls and controls[timeout_name .. "-elapsed"]
  if not elapsed then return end
  local text = string.format("%.1f", math.max(0, tonumber(elapsed_seconds) or 0))
  if elapsed.text ~= text then elapsed.text = text end
end

---刷新各模式的只读计时框；调用方只传秒数，GUI 不读取任何运行记录。
function Gui.refresh_timeout_elapsed(
  source_element, production_elapsed, material_wait_elapsed, recursion_elapsed, swap_elapsed)
  local window = config_window(Gui.containing_window(source_element))
  local content = window and window["bmsc-content"]
  if not content then return end
  local production = find_descendant(content, "bmsc-production-details")
  local production_settings = production and production["bmsc-production-settings"]
  refresh_elapsed(production_settings and production_settings["bmsc-production-fields"],
    "bmsc-production-timeout", production_elapsed)
  local recursion = find_descendant(content, "bmsc-recursion-details")
  local recursion_timeout = recursion and recursion["bmsc-recursion-timeout-settings"]
  refresh_elapsed(recursion_timeout and recursion_timeout["bmsc-recursion-timeout-fields"],
    "bmsc-recursion-material-wait-time", material_wait_elapsed)
  refresh_elapsed(recursion_timeout and recursion_timeout["bmsc-recursion-timeout-fields"],
    "bmsc-recursion-timeout", recursion_elapsed)
  local swap = find_descendant(content, "bmsc-swap-details")
  local swap_settings = swap and swap["bmsc-swap-settings"]
  refresh_elapsed(swap_settings and swap_settings["bmsc-swap-fields"],
    "bmsc-swap-timeout", swap_elapsed)
end

---刷新切换订单的蓝色条件满足态，不重建玩家正在操作的条件列表。
function Gui.refresh_condition_states(source_element, set_name, fulfilled_conditions)
  local window = config_window(Gui.containing_window(source_element))
  local list = find_descendant(window, "bmsc-" .. set_name .. "-conditions")
  if not (list and list.visible) then return end
  for _, row in ipairs(list.children) do
    local index = (row.tags or {}).bmsc_swap_condition_row
    if index then
      local fulfilled = fulfilled_conditions and fulfilled_conditions[index] == true
      row.style = fulfilled and "decider_combinator_fulfilled_condition_frame"
        or "decider_combinator_condition_frame"
      update_condition_operand_styles(row, fulfilled)
    end
  end
end

---只在超市订单的 single 输出模式下显示顺序制作、原料等待和超时参数。
---@param source_element LuaGuiElement 超市订单输出模式下拉框。
---@param visible boolean true 显示，false 隐藏。
---@return nil
function Gui.set_recursion_single_options_visible(source_element, visible)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  local details = content and find_descendant(content, "bmsc-recursion-details")
  local settings = details and details["bmsc-recursion-settings"]
  local fields = settings and settings["bmsc-recursion-fields"]
  local timeout = details and details["bmsc-recursion-timeout-settings"]
  if not (fields and timeout) then return end
  local sequential = find_descendant(fields, "bmsc-sequential-production")
  if sequential then sequential.visible = visible end
  timeout.visible = visible
end

---只在生产订单的“所有（信号分离）”输出模式下显示缓存格数。
---@param source_element LuaGuiElement 生产订单输出模式下拉框。
---@param visible boolean true 显示，false 隐藏。
---@return nil
function Gui.set_cache_grid_visible(source_element, visible)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  local details = content and find_descendant(content, "bmsc-production-details")
  local settings = details and details["bmsc-production-settings"]
  local fields = settings and settings["bmsc-production-fields"]
  if not fields then return end
  fields["bmsc-cache-grid-number-label"].visible = visible
  fields["bmsc-cache-grid-number-controls"].visible = visible
end

---只在配方查询的“所有”模式下显示缓存格数。
function Gui.set_recipe_query_cache_grid_visible(source_element, visible)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  local details = content and find_descendant(content, "bmsc-recipe-query-details")
  local settings = details and details["bmsc-recipe-query-settings"]
  local fields = settings and settings["bmsc-recipe-query-fields"]
  if not fields then return end
  fields["bmsc-recipe-query-cache-grid-number-label"].visible = visible
  fields["bmsc-recipe-query-cache-grid-number-controls"].visible = visible
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
  local production = find_descendant(content, "bmsc-production-details")
  local recursion = find_descendant(content, "bmsc-recursion-details")
  local recipe_query = find_descendant(content, "bmsc-recipe-query-details")
  local production_settings = production and production["bmsc-production-settings"]
  local recursion_settings = recursion and recursion["bmsc-recursion-settings"]
  local recipe_query_settings = recipe_query and recipe_query["bmsc-recipe-query-settings"]
  local production_fields = production_settings and production_settings["bmsc-production-fields"]
  local recursion_fields = recursion_settings and recursion_settings["bmsc-recursion-fields"]
  local recipe_query_fields = recipe_query_settings and recipe_query_settings["bmsc-recipe-query-fields"]
  if production_fields and production_fields["bmsc-production-machine"] then
    production_fields["bmsc-production-machine"].elem_value = machine_name
  end
  local recursion_machine = find_descendant(recursion_fields, "bmsc-recursion-machine")
  if recursion_machine then recursion_machine.elem_value = machine_name end
  if recipe_query_fields and recipe_query_fields["bmsc-recipe-query-machine"] then
    recipe_query_fields["bmsc-recipe-query-machine"].elem_value = machine_name
  end
end

---构建并打开完整的原版风格配置窗口。
---Factorio API 要点：GUI 必须挂在 `player.gui.screen`；设为 `player.opened` 后 E/Esc 会触发关闭事件。
---@param player LuaPlayer 操作玩家。
---@param entity LuaEntity 用于 entity-preview 的实际实体。
---@param config table 已由业务层校验过的实体配置。
---@param current_output_networks table|nil control.lua 最近一次写入代理的输出快照。
---@param input_diagnostics table|nil 生产订单绿色输入信号的未输出原因。
---@param work table|nil 控制层提供的当前工作快照。
---@param linked_inventory_available boolean|nil 是否显示关联箱自动库存校验选项。
---@param config_open boolean|nil 玩家上次打开窗口时配置栏是否展开。
---@return LuaGuiElement frame 新创建的主窗口。
function Gui.open(player, entity, config, current_output_networks, input_diagnostics, work,
  linked_inventory_available, config_open)
  Gui.hide_network_popup(player)
  Gui.close_order_target(player, false)
  local old = player.gui.screen[Gui.name]
  if old then old.destroy() end
  local old_overlay = player.gui.screen[Gui.config_overlay_name]
  if old_overlay and old_overlay.valid then old_overlay.destroy() end

  local display_scale = player.display_scale > 0 and player.display_scale or 1
  local logical_width = math.floor(player.display_resolution.width / display_scale)
  local maximum_window_width = math.min(1280, math.max(320, logical_width - 80))
  local compact_window_width = math.min(560, maximum_window_width)
  -- 运行栏两侧和双栏中缝都使用 8 px；展开只增加配置栏与这些必要间距。
  local expanded_window_width = math.min(maximum_window_width, compact_window_width + 444)
  local maximum_window_height = math.floor(player.display_resolution.height / display_scale * 2 / 3)
  local show_side_by_side = maximum_window_width >= 1040
  config_open = config_open == true
  local frame = player.gui.screen.add{type = "frame", name = Gui.name, direction = "vertical"}
  frame.tags = {bmsc_compact_width = compact_window_width, bmsc_expanded_width = expanded_window_width}
  frame.style.width = config_open and show_side_by_side and expanded_window_width or compact_window_width
  frame.style.maximal_height = maximum_window_height  -- 整个窗口最多占缩放后屏幕高度的三分之二。
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

  -- 参数栏默认收起；展开后与运行信息并列，调参时无需离开当前订单和信号。
  local pages = frame.add{type = "flow", name = "bmsc-page-switcher", direction = "horizontal"}
  pages.style.horizontal_spacing = 4
  pages.style.left_padding = 8
  pages.style.bottom_padding = 4
  pages.add{type = "button", name = "bmsc-page-config", caption = {"bmsc.config-page"},
    tags = {bmsc_page = "config"}, toggled = config_open}

  -- 宽屏用横向两栏；窄屏把配置栏提升为覆盖层，避免为了并排而压缩任一侧的控件。
  local content = frame.add{type = "flow", name = "bmsc-content", direction = "horizontal"}
  content.style.horizontally_stretchable = true
  content.style.vertically_squashable = true
  content.style.horizontal_spacing = 8
  content.style.left_padding = 8
  content.style.right_padding = 8
  local column_height = math.max(120, maximum_window_height - 40)
  local config_column
  if show_side_by_side then
    config_column = content.add{type = "scroll-pane", name = "bmsc-config-column",
      style = "shallow_scroll_pane", direction = "vertical", visible = config_open,
      horizontal_scroll_policy = "never", vertical_scroll_policy = "auto"}
    config_column.style.minimal_width = 420
    config_column.style.maximal_width = 420
    config_column.style.maximal_height = column_height
    config_column.style.vertically_squashable = true
  end
  local runtime_column = content.add{type = "scroll-pane", name = "bmsc-runtime-column",
    style = "shallow_scroll_pane", direction = "vertical",
    horizontal_scroll_policy = "auto", vertical_scroll_policy = "auto"}
  runtime_column.style.maximal_height = column_height
  runtime_column.style.minimal_width = compact_window_width - 32
  runtime_column.style.maximal_width = compact_window_width - 32
  runtime_column.style.horizontally_stretchable = true
  runtime_column.style.vertically_squashable = true
  local runtime_page = runtime_column.add{type = "flow", name = "bmsc-runtime-page", direction = "vertical"}
  runtime_page.style.horizontally_stretchable = true
  runtime_page.style.minimal_width = 460

  if not show_side_by_side then
    local overlay = player.gui.screen.add{type = "frame", name = Gui.config_overlay_name,
      style = "inside_shallow_frame_with_padding", direction = "vertical", visible = config_open}
    overlay.style.width = math.min(436, maximum_window_width)
    overlay.style.maximal_height = column_height
    if frame.location then overlay.location = {x = frame.location.x, y = frame.location.y + 56} end
    local overlay_content = overlay.add{type = "flow", name = "bmsc-content", direction = "vertical"}
    overlay_content.style.horizontally_stretchable = true
    config_column = overlay_content.add{type = "scroll-pane", name = "bmsc-config-column",
      style = "shallow_scroll_pane", direction = "vertical",
      horizontal_scroll_policy = "never", vertical_scroll_policy = "auto"}
    config_column.style.width = 420
    config_column.style.maximal_height = column_height
    config_column.style.vertically_squashable = true
  end
  local config_page = config_column.add{type = "flow", name = "bmsc-config-page", direction = "vertical"}
  config_page.style.horizontally_stretchable = true

  local connections = runtime_page.add{type = "table", name = "bmsc-connections", column_count = 5}
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

  runtime_page.add{type = "line"}
  local running = runtime_page.add{type = "flow", direction = "horizontal"}
  running.style.vertical_align = "center"
  running.style.horizontal_spacing = 8
  running.style.left_padding = 12
  running.style.top_padding = 4
  running.style.bottom_padding = 4
  -- 直接复用原版工作状态灯精灵；它比文字“●”更小，并自带原版的发光效果。
  running.add{type = "sprite", sprite = "utility/status_working"}
  running.add{type = "label", name = "bmsc-runtime-mode",
    caption = {"bmsc.runtime-mode", mode_caption(config.mode)}, tooltip = mode_tooltip(config.mode)}
  add_work_panel(runtime_page)
  Gui.add_signal_panel(runtime_page, player)

  local mode_area = config_page.add{type = "flow", direction = "vertical"}
  mode_area.style.padding = 8
  local mode_fields = mode_area.add{type = "table", column_count = 2}
  mode_fields.style.horizontally_stretchable = true
  mode_fields.add{type = "label", caption = {"bmsc.mode"}, style = "heading_2_label"}
  mode_fields.add{type = "drop-down", name = "bmsc-mode",
    items = {{"bmsc.supermarket-order"}, {"bmsc.recipe-query"},
      {"bmsc.inventory-query"}, {"bmsc.swap-order"}},
    selected_index = mode_selected_index(config.mode),
    tooltip = mode_tooltip(config.mode)}

  -- 模式固定在最上方；网络、订单和超时分别由自己的 GUI 组件承载。
  NetworkGui.settings(config_page, entity, config)

  local details = config_page.add{type = "flow", name = "bmsc-production-details", direction = "vertical"}
  details.style.horizontally_stretchable = true
  details.visible = config.mode == Gui.production_order
  details.add{type = "line"}
  local settings = details.add{type = "frame", name = "bmsc-production-settings",
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  settings.style.horizontally_stretchable = true
  settings.add{type = "label", caption = {"bmsc.production-order-settings"}, style = "heading_2_label"}
  local fields = settings.add{type = "flow", name = "bmsc-production-fields", direction = "vertical"}
  fields.style.horizontally_stretchable = true
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
  add_timeout_slider(fields, {"bmsc.production-timeout"}, "bmsc-production-timeout",
    config.production_timeout or 0, true, {"bmsc.production-timeout-tooltip"})
  add_labeled(fields, {"bmsc.monitor-item-quantity-changes"}, {
    type = "drop-down", name = "bmsc-production-timeout-monitor-item-changes",
    items = {{"bmsc.yes"}, {"bmsc.no"}},
    selected_index = config.production_timeout_monitor_item_changes ~= false and 1 or 2,
    tooltip = {"bmsc.monitor-item-quantity-changes-tooltip"}})
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
  add_conditions_editor(settings, "production-timeout", {"bmsc.timeout-reset-conditions"},
    config.production_timeout_conditions)
  -- 订单记忆属于运行状态而非配置值，提供独立按钮让玩家随时放弃当前缓存订单。
  settings.add{type = "button", name = "bmsc-clear-order-memory",
    caption = {"bmsc.clear-order-memory"}, tooltip = {"bmsc.clear-order-memory-tooltip"}}
  local recursion_details = config_page.add{type = "flow", name = "bmsc-recursion-details", direction = "vertical"}
  recursion_details.style.horizontally_stretchable = true
  recursion_details.visible = config.mode == Gui.supermarket_order
  local recursion_settings = recursion_details.add{
    type = "frame", name = "bmsc-recursion-settings",
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  recursion_settings.style.horizontally_stretchable = true
  recursion_settings.add{type = "label", caption = {"bmsc.order-params"}, style = "heading_2_label"}
  local recursion_fields = recursion_settings.add{type = "flow", name = "bmsc-recursion-fields", direction = "vertical"}
  recursion_fields.style.horizontally_stretchable = true
  recursion_fields.add{type = "label", caption = {"bmsc.production-machine"}}
  local recursion_machine_controls = recursion_fields.add{type = "flow", direction = "horizontal"}
  recursion_machine_controls.style.vertical_align = "center"
  recursion_machine_controls.style.horizontal_spacing = 12
  local recursion_machine = recursion_machine_controls.add{type = "choose-elem-button",
    name = "bmsc-recursion-machine", elem_type = "entity", entity = config.production_machine,
    tooltip = {"bmsc.production-machine-tooltip"}}
  recursion_machine.style.size = 52                   -- 参数：两个模式使用一致的机器选择按钮尺寸。
  local validation_items = {{"bmsc.inventory-validation"}, {"bmsc.inventory-validation-none"}}
  local validation_values = {Config.inventory_validation.inventory, Config.inventory_validation.none}
  if linked_inventory_available then
    table.insert(validation_items, 2, {"bmsc.inventory-validation-linked"})
    table.insert(validation_values, 2, Config.inventory_validation.linked)
  end
  local selected_validation = 1
  for index, value in ipairs(validation_values) do
    if value == config.inventory_validation then selected_validation = index; break end
  end
  local inventory_validation = recursion_machine_controls.add{type = "drop-down", name = "bmsc-inventory-validation",
    items = validation_items, selected_index = selected_validation,
    tooltip = {"bmsc.inventory-validation-tooltip"}}
  inventory_validation.style.width = 190
  add_rate_range(recursion_fields, {"bmsc.production-rate"}, "bmsc-recursion-additional",
    "bmsc-recursion-additional-min", 1, config.recursion_additional_production_rate, true,
    {"bmsc.recursion-additional-rate-tooltip"})
  add_rate_range(recursion_fields, {"bmsc.material-range"}, "bmsc-recursion-material",
    "bmsc-recursion-material-retention", config.recursion_material_retention_rate or 1,
    config.recursion_material_demand_rate, false, {"bmsc.recursion-material-range-tooltip"})
  add_numeric_slider(recursion_fields, {"bmsc.recursion-depth"}, "bmsc-recursion-depth",
    config.recurise_depth, false, {"bmsc.recursion-depth-tooltip"})
  recursion_fields.add{type = "label", caption = {"bmsc.output-mode"}}
  local output_controls = recursion_fields.add{
    type = "flow", name = "bmsc-recursion-output-controls", direction = "horizontal"}
  output_controls.style.vertical_align = "center"
  output_controls.style.horizontal_spacing = 8
  output_controls.add{type = "drop-down", name = "bmsc-recursion-output",
    items = {{"bmsc.single"}, {"bmsc.all"}}, selected_index = config.recursion_output_mode == "all" and 2 or 1,
    tooltip = {"bmsc.recursion-output-mode-tooltip"}}
  -- 顺序制作是单个输出的附加策略，复选框与输出模式同行且不清空既有选择。
  local timeout_visible = config.recursion_output_mode ~= "all"
  output_controls.add{type = "checkbox", name = "bmsc-sequential-production",
    caption = {"bmsc.sequential-production"}, state = config.sequential_production ~= false,
    tooltip = {"bmsc.sequential-production-tooltip"}, visible = timeout_visible}
  local timeout_settings = recursion_details.add{type = "frame", name = "bmsc-recursion-timeout-settings",
    style = "inside_shallow_frame_with_padding", direction = "vertical", visible = timeout_visible}
  timeout_settings.style.horizontally_stretchable = true
  timeout_settings.add{type = "label", caption = {"bmsc.timeout-settings"}, style = "heading_2_label"}
  local timeout_fields = timeout_settings.add{
    type = "flow", name = "bmsc-recursion-timeout-fields", direction = "vertical"}
  timeout_fields.style.horizontally_stretchable = true
  add_timeout_slider(timeout_fields, {"bmsc.material-wait-time"}, "bmsc-recursion-material-wait-time",
    config.recursion_material_wait_time or 0, true, {"bmsc.material-wait-time-tooltip"})
  local recursion_timeout = add_timeout_slider(timeout_fields, {"bmsc.recursion-timeout"},
    "bmsc-recursion-timeout", config.recursion_timeout or 0, true, {"bmsc.recursion-timeout-tooltip"})
  recursion_timeout.parent.add{
    type = "checkbox", name = "bmsc-recursion-timeout-monitor-item-changes",
    caption = {"bmsc.monitor-quantity"}, state = config.recursion_timeout_monitor_item_changes == true,
    tooltip = {"bmsc.recursion-monitor-quantity-tooltip"}}
  add_conditions_editor(timeout_settings, "recursion-timeout", {"bmsc.timeout-reset-conditions"},
    config.recursion_timeout_conditions)
  local recipe_query_details = config_page.add{type = "flow", name = "bmsc-recipe-query-details", direction = "vertical"}
  recipe_query_details.style.horizontally_stretchable = true
  recipe_query_details.visible = config.mode == Gui.recipe_query
  recipe_query_details.add{type = "line"}
  local recipe_query_settings = recipe_query_details.add{
    type = "frame", name = "bmsc-recipe-query-settings",
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  recipe_query_settings.style.horizontally_stretchable = true
  recipe_query_settings.add{type = "label", caption = {"bmsc.recipe-query-settings"}, style = "heading_2_label"}
  local recipe_query_fields = recipe_query_settings.add{
    type = "flow", name = "bmsc-recipe-query-fields", direction = "vertical"}
  recipe_query_fields.style.horizontally_stretchable = true
  local recipe_query_machine = add_labeled(recipe_query_fields, {"bmsc.recipe-query-machine"}, {
    type = "choose-elem-button", name = "bmsc-recipe-query-machine", elem_type = "entity",
    entity = config.production_machine, tooltip = {"bmsc.recipe-query-machine-tooltip"}})
  recipe_query_machine.style.size = 52                -- 参数：与其他模式保持一致的机器选择按钮尺寸。
  add_labeled(recipe_query_fields, {"bmsc.multiple-recipe-support"}, {
    type = "drop-down", name = "bmsc-multiple-recipe-support",
    items = {{"bmsc.single"}, {"bmsc.all"}}, selected_index = config.multiple_recipe_support and 2 or 1,
    tooltip = {"bmsc.multiple-recipe-support-tooltip"}})
  add_numeric_slider(recipe_query_fields, {"bmsc.cache-grid-number"},
    "bmsc-recipe-query-cache-grid-number", config.recipe_query_cache_grid_number or 0, false,
    {"bmsc.recipe-query-cache-grid-number-tooltip"}, config.multiple_recipe_support,
    "bmsc-recipe-query-cache-grid-number-label")
  local inventory_query_details = config_page.add{
    type = "flow", name = "bmsc-inventory-query-details", direction = "vertical"}
  inventory_query_details.style.horizontally_stretchable = true
  inventory_query_details.visible = config.mode == Gui.inventory_query
  inventory_query_details.add{type = "line"}
  local inventory_query_settings = inventory_query_details.add{
    type = "frame", name = "bmsc-inventory-query-settings",
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  inventory_query_settings.style.horizontally_stretchable = true
  inventory_query_settings.add{
    type = "label", caption = {"bmsc.inventory-query-settings"}, style = "heading_2_label"}
  local inventory_query_fields = inventory_query_settings.add{
    type = "flow", name = "bmsc-inventory-query-fields", direction = "vertical"}
  inventory_query_fields.style.horizontally_stretchable = true
  add_labeled(inventory_query_fields, {"bmsc.query-type"}, {
    type = "drop-down", name = "bmsc-query-type",
    items = {{"bmsc.query-only-fluid"}, {"bmsc.query-only-item"}, {"bmsc.query-unrestricted"}},
    selected_index = ({
      [Config.query_type.fluid] = 1,
      [Config.query_type.item] = 2,
      [Config.query_type.all] = 3
    })[config.query_type] or 3,
    tooltip = {"bmsc.query-type-tooltip"}})
  add_labeled(inventory_query_fields, {"bmsc.query-all"}, {
    type = "drop-down", name = "bmsc-query-all",
    items = {{"bmsc.no"}, {"bmsc.yes"}}, selected_index = config.query_all and 2 or 1,
    tooltip = {"bmsc.query-all-tooltip"}})
  local swap_details = config_page.add{type = "flow", name = "bmsc-swap-details", direction = "vertical"}
  swap_details.style.horizontally_stretchable = true
  swap_details.visible = config.mode == Gui.swap_order
  swap_details.add{type = "line"}
  local swap_settings = swap_details.add{type = "frame", name = "bmsc-swap-settings",
    style = "inside_shallow_frame_with_padding", direction = "vertical"}
  swap_settings.style.horizontally_stretchable = true
  swap_settings.add{type = "label", caption = {"bmsc.swap-order-settings"}, style = "heading_2_label"}
  local swap_fields = swap_settings.add{type = "flow", name = "bmsc-swap-fields", direction = "vertical"}
  swap_fields.style.horizontally_stretchable = true
  add_labeled(swap_fields, {"bmsc.swap-output-mode"}, {type = "drop-down", name = "bmsc-swap-output-mode",
    items = {{"bmsc.swap-only-fluid"}, {"bmsc.swap-only-item"}, {"bmsc.swap-all"},
      {"bmsc.swap-all-with-signals"}},
    selected_index = ({fluid = 1, item = 2, all = 3, all_with_signals = 4})[config.swap_output_mode] or 1})
  add_timeout_slider(swap_fields, {"bmsc.swap-timeout"}, "bmsc-swap-timeout",
    config.swap_timeout or 0, true, {"bmsc.swap-timeout-tooltip"})
  add_labeled(swap_fields, {"bmsc.swap-loop"}, {type = "checkbox", name = "bmsc-swap-loop",
    state = config.swap_loop == true, tooltip = {"bmsc.swap-loop-tooltip"}})
  swap_settings.add{type = "button", name = "bmsc-clear-swap", caption = {"bmsc.clear-swap"},
    tooltip = {"bmsc.clear-swap-tooltip"}}
  add_conditions_editor(swap_settings, "swap", {"bmsc.timeout-reset-conditions"}, config.swap_conditions)
  -- 已保存的说明直接显示在配置界面内；内容支持 Factorio 富文本图标。
  local saved_description = config_page.add{type = "flow", name = "bmsc-saved-description", direction = "vertical"}
  saved_description.style.padding = 8
  saved_description.visible = entity.combinator_description ~= ""
  saved_description.add{type = "label", caption = {"bmsc.description"}, style = "heading_2_label"}
  local saved_description_text = saved_description.add{
    type = "label", name = "bmsc-saved-description-text", caption = entity.combinator_description}
  saved_description_text.style.single_line = false

  local footer = config_page.add{type = "flow", direction = "horizontal"}
  footer.style.padding = 8
  footer.add{type = "button", name = "bmsc-description-toggle", caption = {"bmsc.add-description"}}

  -- 说明编辑器默认隐藏；点击“添加说明”后才展开，减少正常配置时的界面占用。
  local description = config_page.add{type = "flow", name = "bmsc-description-editor", direction = "vertical"}
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
  Gui.refresh_connection_status(player, entity, current_output_networks, input_diagnostics, work)
  return frame
end

---展开说明编辑器，并填入实体当前已有的说明。
---@param source_element LuaGuiElement “添加说明”按钮。
---@param current_text string 实体的 `combinator_description`。
---@return nil
function Gui.show_description_editor(source_element, current_text)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  local editor = content and find_descendant(content, "bmsc-description-editor")
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
  local editor = content and find_descendant(content, "bmsc-description-editor")
  return editor and editor["bmsc-description-text"].text or nil
end

---刷新主窗口中已经保存的说明文字。
---@param source_element LuaGuiElement 保存按钮；用于向上定位主窗口。
---@param value string 新的组合器说明，可包含游戏富文本图标标记。
---@return nil
function Gui.refresh_saved_description(source_element, value)
  local window = Gui.containing_window(source_element)
  local content = window and window["bmsc-content"]
  local display = content and find_descendant(content, "bmsc-saved-description")
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
  local editor = content and find_descendant(content, "bmsc-description-editor")
  if editor then editor.visible = false end
end

---关闭窗口。
---通过清空 `player.opened` 走 Factorio 标准生命周期，使按钮关闭与 E/Esc 行为一致。
---@param player LuaPlayer 操作玩家。
---@return nil
function Gui.close(player)
  Gui.hide_network_popup(player)
  Gui.close_order_target(player, false)
  local overlay = player.gui.screen[Gui.config_overlay_name]
  if overlay and overlay.valid then overlay.destroy() end
  local frame = player.gui.screen[Gui.name]
  player.opened = nil
  if frame and frame.valid then frame.destroy() end
end

return Gui
