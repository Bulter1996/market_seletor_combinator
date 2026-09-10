-- Market Selector Combinator 运行阶段主文件。
-- Factorio 加载存档后执行本文件；这里只负责编排实体状态、模式模块、GUI、输出代理和蓝图配置。

local ENTITY = "b-market-selector-combinator"          -- 参数：玩家可放置的主实体原型名。
local PROXY = "b-market-selector-output-proxy"         -- 参数：向线路发送计算结果的隐藏实体原型名。
local DETAIL_PROXY = "b-market-selector-detail-proxy" -- 参数：只在 Alt 模式显示当前订单产品的隐藏实体。
local TICK_INTERVAL = settings.startup["bmsc-update-interval"].value
                                                          -- 参数：玩家配置的刷新间隔，默认 30 tick。
local Gui = require("scripts.gui")                     -- GUI 模块：只负责界面，不参与生产计算。
local Config = require("scripts.config")               -- 配置模块：默认值、模式常量和外部数据校验。
local Util = require("scripts.common_util")            -- 通用工具：输出排序等无状态功能。
local MODES = require("scripts.mode_registry")          -- 模式注册表：统一调度彼此独立的算法模块。
local MODE_PRODUCTION_ORDER = Config.mode.production_order
local MODE_SUPERMARKET_ORDER = Config.mode.supermarket_order

---取得并初始化本模组的持久状态。
---为什么需要：`storage` 会随存档保存，但首次运行时字段不存在，所有入口都通过此函数安全访问。
---@return table state 包含 combinators（实体记录）和 player_gui（玩家正在编辑的实体）。
local function state()
  storage.combinators = storage.combinators or {}
  storage.player_gui = storage.player_gui or {}
  return storage
end

---配置校验函数的本地别名，让实体生命周期代码保持简洁。
---@type fun(source: table|nil): table
local normalize_config = Config.normalize

---清除一台组合器的全部模式运行缓存。
---@param record table 组合器记录。
---@return nil
local function reset_all_modes(record)
  for _, mode in pairs(MODES) do mode.reset(record) end
end

---导出所有模式的运行缓存，control.lua 不需要知道各模式包含哪些字段。
---@param record table 组合器记录。
---@return table states 以模式名为键的状态集合。
local function save_mode_states(record)
  local states = {}
  for name, mode in pairs(MODES) do states[name] = mode.save_state(record) end
  return states
end

---恢复各模式自行导出的运行缓存。
---@param record table 新建的组合器记录。
---@param states table|nil save_mode_states 的返回值。
---@return nil
local function restore_mode_states(record, states)
  states = states or {}
  for name, mode in pairs(MODES) do mode.restore_state(record, states[name]) end
end

---销毁某条记录的全部隐藏输出代理。
---record.proxy 是 v0.1.0 的单代理字段，保留清理逻辑以兼容旧存档升级。
---@param record table|nil 组合器运行记录。
---@return nil
local function destroy_proxies(record)
  if not record then return end
  for _, proxy in pairs({record.proxy, record.red_proxy, record.green_proxy, record.detail_proxy}) do
    if proxy and proxy.valid then proxy.destroy() end
  end
end

---把隐藏代理接到主实体指定颜色的输出端。
---为什么需要：选择运算器原生模式不能发送脚本任意生成的一组信号，因此使用隐藏常量运算器发射。
---@param entity LuaEntity 主选择运算器。
---@param proxy LuaEntity 隐藏常量运算器。
---@param wire_color string 输出线路颜色，只接受 `red` 或 `green`。
---@return nil
local function connect_proxy(entity, proxy, wire_color)
  local proxy_connector_id = wire_color == "red" and defines.wire_connector_id.circuit_red
    or defines.wire_connector_id.circuit_green
  local output_connector_id = wire_color == "red" and defines.wire_connector_id.combinator_output_red
    or defines.wire_connector_id.combinator_output_green
  local proxy_connector = proxy.get_wire_connector(proxy_connector_id, true)
  local output_connector = entity.get_wire_connector(output_connector_id, true)
  if proxy_connector and output_connector then
    proxy_connector.connect_to(output_connector, false, defines.wire_origin.script)
  end
end

---在主实体位置创建只连接一种线路颜色的不可见输出代理。
---@param entity LuaEntity 主选择运算器。
---@param wire_color string|nil 输出线路颜色；nil 表示展示代理不连接线路。
---@param proxy_name string|nil 代理原型名；nil 使用线路输出代理。
---@return LuaEntity|nil proxy 创建失败时返回 nil。
local function create_proxy(entity, wire_color, proxy_name)
  local entity_name = proxy_name or PROXY
  -- `/c game.reload_mods()` 只重载运行脚本时，新数据阶段原型可能尚未注册；此时跳过
  -- 可选展示代理，等待完整重启游戏，不能让真实红绿输出也随之中断。
  if not prototypes.entity[entity_name] then return nil end
  local proxy = entity.surface.create_entity{
    name = entity_name, position = entity.position, force = entity.force, create_build_effect_smoke = false
  }
  if proxy then
    proxy.destructible = false
    proxy.operable = false
    if wire_color then connect_proxy(entity, proxy, wire_color) end
  end
  return proxy
end

---同步实体小屏幕的原版模式外观，同时关闭原生信号输出。
---为什么需要：实体预览直接渲染真实 LuaEntity；修改原生 operation 后，世界实体和 GUI 预览
---会由游戏引擎自动显示对应符号。实际计算仍由模式模块完成，原生行为只承担视觉展示。
---模式可以提供完整的 visual_parameters；旧模式只声明 visual_operation 时仍可兼容。
---@param record table 组合器记录，必须包含 entity 和 config.mode。
---@return nil
local function sync_mode_visual(record)
  if not (record and record.entity and record.entity.valid) then return end
  local behavior = record.entity.get_or_create_control_behavior()
  if not behavior then return end
  local mode = MODES[record.config.mode]
  -- `max`/`min` 并不是合法 operation：它们属于 select 操作的 select_max 参数。
  -- 完整参数表由模式自行声明，能避免把“素材字段名”误当成运行时操作名。
  local visual_parameters = mode and mode.visual_parameters
  behavior.parameters = visual_parameters or {operation = mode and mode.visual_operation or "select"}
  -- 主实体的原生操作仅用于屏幕动画：同时关闭输入读取和输出发送，避免 count 等视觉
  -- 操作保留旧 count_signal 后产生“某物品 ×1”。脚本仍会直接从实体连接器读取网络。
  behavior.input_networks = {red = false, green = false}
  behavior.output_networks = {red = false, green = false}
end

---持续屏蔽主选择运算器的原生线路输入和输出。
---为什么需要：超市订单借用原版 `select max` 来显示购物车图标；实体创建、蓝图还原或
---其他模组改写控制行为后，游戏可能再次启用默认的红绿网络。此时原版最大值会与隐藏
---代理的脚本结果叠加，造成递归输出数量不准确。每轮计算前重新应用开关，既不影响脚本
---直接读取输入连接器，也能保证线路上只存在代理输出。
---@param record table 组合器记录。
---@return nil
local function suppress_native_networks(record)
  if not (record and record.entity and record.entity.valid) then return end
  local behavior = record.entity.get_or_create_control_behavior()
  if not behavior then return end
  behavior.input_networks = {red = false, green = false}
  behavior.output_networks = {red = false, green = false}
end

---注册新建、克隆或从蓝图恢复的主实体。
---@param entity LuaEntity|nil 待注册实体。
---@param tags table|nil 蓝图携带的配置标签。
---@return nil
local function register(entity, tags)
  if not (entity and entity.valid and entity.name == ENTITY) then return end
  destroy_proxies(state().combinators[entity.unit_number])
  local source = tags and tags.bmsc or tags
  local record = {
    entity = entity,
    red_proxy = create_proxy(entity, "red"),
    green_proxy = create_proxy(entity, "green"),
    detail_proxy = create_proxy(entity, nil, DETAIL_PROXY),
    config = normalize_config(source)
  }
  reset_all_modes(record)
  state().combinators[entity.unit_number] = record
  sync_mode_visual(record)
end

---取消注册实体并清理其辅助对象。
---@param entity LuaEntity|nil 被挖掘或摧毁的实体。
---@return nil
local function remove(entity)
  if not (entity and entity.valid and entity.unit_number) then return end
  destroy_proxies(state().combinators[entity.unit_number])
  state().combinators[entity.unit_number] = nil
end

---调用当前配置所对应的模式模块。
---每个模式遵守相同接口：calculate(record) 计算输出，reset(record) 清理该模式缓存。
---@param record table 当前组合器运行记录。
---@return table outputs 当前模式产生的标准输出集合。
local function calculate(record)
  -- 防御旧运行状态：即使存档尚未经过配置迁移，也不允许相等/倒置阈值进入模式算法。
  if not Config.material_rates_valid(record.config.material_demand_rate, record.config.material_retention_rate) then
    record.config = normalize_config(record.config)
  end
  local active = MODES[record.config.mode]
  for _, mode in pairs(MODES) do
    if mode ~= active then mode.reset(record) end
  end
  return active and active.calculate(record) or {}
end

---更新鼠标悬浮信息卡中的输出信号字段。
---@param record table 组合器运行记录；保存 tooltip 字段编号，避免每次刷新都新增一行。
---@param outputs table 当前输出集合。
---@return nil
local function update_hover_tooltip(record, outputs)
  local parts = {}
  local signature_parts = {}
  for _, value in ipairs(Util.sorted_outputs(outputs)) do
    local entry = value.entry
    signature_parts[#signature_parts + 1] = value.key .. "=" .. tostring(entry.count)
    local signal_type = entry.signal.type or "item"
    local tag_type = signal_type == "virtual" and "virtual-signal" or signal_type
    local quality = signal_type == "item" and Util.quality_name(entry.signal.quality) or nil
    local quality_part = quality and quality ~= "normal" and ",quality=" .. quality or ""
    parts[#parts + 1] = "[" .. tag_type .. "=" .. entry.signal.name
      .. quality_part .. "] " .. entry.count
  end
  local signature = table.concat(signature_parts, "|")
  -- set_tooltip_field 会修改实体运行时状态；输出未变化时直接复用旧字段，避免重复写入。
  if record.tooltip_output_signature == signature then return end
  local content = #parts > 0 and table.concat(parts, "  ") or {"bmsc.no-output"}
  record.output_tooltip_id = record.entity.set_tooltip_field{
    id = record.output_tooltip_id, name = {"bmsc.output-signals"}, value = content, order = 31
  }
  record.tooltip_output_signature = signature
  record.entity.custom_status = nil
end

---把输出集合整理为实际可写入代理的稳定数组和签名。
---签名只包含最终会上线路的前 100 个非零信号；同一集合无论 pairs 遍历顺序如何，
---都会得到相同字符串，因此可以安全判断“本轮输出是否真的发生变化”。
---@param outputs table 当前线路的输出集合。
---@return table entries 按信号键排序、过滤后的输出数组。
---@return string signature 用于比较相邻两轮输出的稳定签名。
local function prepare_proxy_outputs(outputs)
  local entries = {}
  local signature_parts = {}
  for _, value in ipairs(Util.sorted_outputs(outputs)) do
    if value.entry.count ~= 0 and #entries < 100 then
      entries[#entries + 1] = value.entry
      signature_parts[#signature_parts + 1] = value.key .. "=" .. tostring(value.entry.count)
    end
  end
  return entries, table.concat(signature_parts, "|")
end

---把一组结果写入指定隐藏代理的常量运算器槽位。
---输出签名未变化时不访问 Factorio 槽位 API；发生变化时只清理上一轮多出来的槽位。
---@param proxy LuaEntity 隐藏常量运算器。
---@param outputs table 当前线路的输出集合。
---@param cache table|nil 上一轮缓存，格式为 `{signature=string, slot_count=integer}`。
---@return table cache 本轮签名和实际槽位数，供下一轮复用。
local function write_proxy_outputs(proxy, outputs, cache)
  local entries, signature = prepare_proxy_outputs(outputs)
  if cache and cache.signature == signature then return cache end

  local behavior = proxy.get_or_create_control_behavior()
  -- 代理只使用第一节。若旧版本或异常状态留下额外 section，必须先移除，否则其中的
  -- 信号仍会与第一节一起发送到线路，形成看似无法释放的历史输出。
  for section_index = behavior.sections_count, 2, -1 do
    behavior.remove_section(section_index)
  end
  local section = behavior.get_section(1) or behavior.add_section()
  for index, entry in ipairs(entries) do
    -- set_slot 的 value 是 SignalFilter，而不只是普通 SignalID。当 min 非零时，
    -- Factorio 2.1 要求 quality 明确指定且 comparator 必须为“=”。
    local signal = entry.signal
    local safe_signal = Util.make_signal(signal.type, signal.name, signal.quality)
    safe_signal.quality = Util.quality_name(signal.quality)
    safe_signal.comparator = "="
    section.set_slot(index, {value = safe_signal, min = entry.count})
  end
  -- 新建或从旧版本接管的代理没有可信缓存，首次最多清理 100 格；之后只清理
  -- “新槽位数 + 1”到“旧槽位数”，避免每轮固定执行 100 次 clear_slot。
  local previous_slot_count = cache and cache.slot_count or 100
  for slot_index = #entries + 1, previous_slot_count do section.clear_slot(slot_index) end
  return {signature = signature, slot_count = #entries}
end

---把结果分别写入红、绿隐藏代理，并同步悬浮信息。
---普通模式把同一集合写入两色线路；带 separated 标记的结果可为两色线路分别提供集合。
---@param record table 组合器运行记录。
---@param outputs table 当前输出集合，或 `{separated=true, red=table, green=table}`。
---@return nil
local function write_outputs(record, outputs)
  record.proxy_output_cache = record.proxy_output_cache or {}
  if not (record.red_proxy and record.red_proxy.valid) then
    record.red_proxy = create_proxy(record.entity, "red")
    record.proxy_output_cache.red = nil
  end
  if not (record.green_proxy and record.green_proxy.valid) then
    record.green_proxy = create_proxy(record.entity, "green")
    record.proxy_output_cache.green = nil
  end
  if not (record.detail_proxy and record.detail_proxy.valid) then
    record.detail_proxy = create_proxy(record.entity, nil, DETAIL_PROXY)
    record.proxy_output_cache.detail = nil
  end
  if not (record.red_proxy and record.green_proxy) then return end

  local separated = outputs.separated == true
  local red_outputs = separated and outputs.red or outputs
  local green_outputs = separated and outputs.green or outputs
  record.proxy_output_cache.red = write_proxy_outputs(
    record.red_proxy, red_outputs or {}, record.proxy_output_cache.red)
  record.proxy_output_cache.green = write_proxy_outputs(
    record.green_proxy, green_outputs or {}, record.proxy_output_cache.green)
  -- 展示代理没有线路连接，只负责在 Alt 详细信息模式显示当前订单产品。
  if record.detail_proxy then
    record.proxy_output_cache.detail = write_proxy_outputs(
      record.detail_proxy, record.detail_outputs or {}, record.proxy_output_cache.detail)
  end

  local tooltip_outputs = outputs
  if separated then
    tooltip_outputs = {}
    for _, wire_outputs in pairs({red_outputs or {}, green_outputs or {}}) do
      for _, entry in pairs(wire_outputs) do
        Util.add_output(tooltip_outputs, entry.signal, entry.count)
      end
    end
  end
  update_hover_tooltip(record, tooltip_outputs)
end

---定时更新所有市场选择运算器，并清除已经失效的实体记录。
---@return nil
local function update_all()
  for unit, record in pairs(state().combinators) do
    if record.entity and record.entity.valid then
      -- 原生 select/max 在超市订单模式下本身会产生一个最大值信号；必须先重新屏蔽，
      -- 再写代理结果，避免它与脚本计算值在同一输出网络中相加。
      suppress_native_networks(record)
      write_outputs(record, calculate(record))
    else
      destroy_proxies(record)
      state().combinators[unit] = nil
    end
  end
  for player_index, unit in pairs(state().player_gui) do
    local player = game.get_player(player_index)
    local record = state().combinators[unit]
    if player and record then Gui.refresh_connection_status(player, record.entity) end
  end
end

---配置迁移时重建所有代理，同时保留玩家配置和当前锁定产品。
---@return nil
local function rebuild_all()
  local saved = {}
  for unit, record in pairs(state().combinators) do
    saved[unit] = {
      config = record.config,
      mode_states = save_mode_states(record),
      output_tooltip_id = record.output_tooltip_id
    }
    destroy_proxies(record)
  end
  -- 开发期热重载或旧版本异常中断可能留下已不受 storage 跟踪的隐藏代理。
  -- 重建时按本模组专用原型名统一清理，避免旧槽位继续向线路发送滞留信号。
  local proxy_names = {PROXY}
  if prototypes.entity[DETAIL_PROXY] then proxy_names[#proxy_names + 1] = DETAIL_PROXY end
  for _, surface in pairs(game.surfaces) do
    for _, proxy in pairs(surface.find_entities_filtered{name = proxy_names}) do proxy.destroy() end
  end
  storage.combinators = {}
  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered{name = ENTITY}) do
      local old = saved[entity.unit_number]
      register(entity, old and {bmsc = old.config} or nil)
      if old then
        local record = storage.combinators[entity.unit_number]
        restore_mode_states(record, old.mode_states)
        record.output_tooltip_id = old.output_tooltip_id
      end
    end
  end
end

-- 生命周期事件：初始化新存档，或在模组版本/配置变化后迁移旧存档。
script.on_init(function() state(); rebuild_all() end)
script.on_configuration_changed(rebuild_all)

-- 建造/移除事件：所有建造来源统一注册，所有销毁来源统一清理。
script.on_event({defines.events.on_built_entity, defines.events.on_robot_built_entity,
  defines.events.script_raised_built, defines.events.script_raised_revive, defines.events.on_entity_cloned}, function(event)
  register(event.created_entity or event.entity or event.destination, event.tags)
end)
script.on_event({defines.events.on_player_mined_entity, defines.events.on_robot_mined_entity,
  defines.events.on_entity_died, defines.events.script_raised_destroy}, function(event) remove(event.entity) end)

-- GUI 事件：拦截原版选择运算器窗口，改为本模组自己的参数窗口。
script.on_event(defines.events.on_gui_opened, function(event)
  if event.entity and event.entity.valid and event.entity.name == ENTITY then
    local player = game.get_player(event.player_index)
    player.opened = nil
    local record = state().combinators[event.entity.unit_number]
    if not record then register(event.entity); record = state().combinators[event.entity.unit_number] end
    Gui.open(player, event.entity, record.config)
    state().player_gui[player.index] = event.entity.unit_number
  end
end)
script.on_event(defines.events.on_gui_closed, function(event)
  if not (event.element and event.element.valid and event.element.name == Gui.name) then return end

  -- player.opened 使 E、Esc、打开其他实体等操作都会进入这里，行为与原版实体窗口一致。
  state().player_gui[event.player_index] = nil
  Gui.hide_network_popup(game.get_player(event.player_index))
  event.element.destroy()
end)

---根据玩家索引取得其当前正在编辑的组合器记录。
---@param player_index uint 玩家索引。
---@return table|nil record。
local function current_record(player_index)
  local unit = state().player_gui[player_index]
  return unit and state().combinators[unit]
end

-- 网络信息悬浮事件：GUI 模块负责生成/销毁信号槽面板，控制层只提供当前实体。
script.on_event(defines.events.on_gui_hover, function(event)
  if not Gui.is_network_info(event.element) then return end
  local record = current_record(event.player_index)
  if record then Gui.show_network_popup(game.get_player(event.player_index), event.element, record.entity) end
end)
script.on_event(defines.events.on_gui_leave, function(event)
  if Gui.is_network_info(event.element) then
    Gui.hide_network_popup(game.get_player(event.player_index))
  end
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
  if event.element.name ~= "bmsc-production-machine" and event.element.name ~= "bmsc-recursion-machine" then return end
  local record = current_record(event.player_index)
  local machine = event.element.elem_value
  local prototype = machine and prototypes.entity[machine]
  if record and prototype and prototype.crafting_categories then
    local machine_changed = record.config.production_machine ~= machine
    record.config.production_machine = machine
    Gui.sync_machine_buttons(event.element, machine)
    if machine_changed then
      -- 生产机器决定哪些配方能够被查询。两种模式都可能保存基于旧机器得到的锁定项、
      -- 目标库存和超时状态，因此不能只修改配置字段；必须统一清除运行缓存。
      -- 订单记忆代表玩家已经接受的订单，不是配方查询缓存；切换机器时先暂存它，
      -- 清理派生状态后再恢复，使绿线订单已经消失时仍能由新机器重新验证并继续执行。
      local remembered_order = record.config.remember_order and record.remembered_order or nil
      reset_all_modes(record)
      record.remembered_order = remembered_order
      -- GUI 参数变更后立即用新机器重新查配方并覆盖代理输出，不必等待下一个 10 tick。
      -- 若新机器不支持当前产品，calculate 返回空集合，旧输出也会立刻被清除。
      write_outputs(record, calculate(record))
    end
  end
end)
---把一个已经校验的数值写入其对应配置字段。
---文本框和滑块共用这个入口，避免两类 GUI 事件分别维护一套参数名称映射。
---@param record table 当前组合器记录。
---@param element_name string 数值输入框的 GUI 名称。
---@param value number 非负参数值。
---@return boolean accepted 是否接受该数值；材料倍率关系无效时返回 false。
local function update_numeric_config(record, element_name, value)
  if element_name == "bmsc-additional" then record.config.additional_production_rate = value; return true end
  if element_name == "bmsc-material" then
    if not Config.material_rates_valid(value, record.config.material_retention_rate) then return false end
    record.config.material_demand_rate = value
    return true
  end
  if element_name == "bmsc-material-retention" then
    if not Config.material_rates_valid(record.config.material_demand_rate, value) then return false end
    record.config.material_retention_rate = value
    return true
  end
  if element_name == "bmsc-production-timeout" then record.config.production_timeout = value; return true end
  if element_name == "bmsc-cache-grid-number" then
    -- 缓存格数必须是非负整数；即使未来有调用方绕过 GUI，也不能写入负值或小数。
    record.config.cache_grid_number = math.max(0, math.floor(value))
    return true
  end
  if element_name == "bmsc-recursion-depth" then record.config.recurise_depth = math.floor(value); return true end
  if element_name == "bmsc-recursion-timeout" then record.config.recursion_timeout = value; return true end
  return false
end

script.on_event(defines.events.on_gui_text_changed, function(event)
  local record = current_record(event.player_index)
  local value = tonumber(event.element.text)
  if not record then return end
  if event.element.name == "bmsc-material" or event.element.name == "bmsc-material-retention" then
    local valid, demand, retention = Gui.validate_material_rate_inputs(event.element)
    if valid then
      -- 两个输入框作为一个参数组同时提交，避免修改顺序受到旧配置值影响。
      record.config.material_demand_rate = demand
      record.config.material_retention_rate = retention
      Gui.sync_numeric_slider(event.element, value)
    end
    return
  end
  if not (value and value >= 0) then return end
  local accepted = update_numeric_config(record, event.element.name, value)
  -- 输入任意值时只移动滑块到最近档位，不改写玩家输入的精确数值。
  if accepted then Gui.sync_numeric_slider(event.element, value) end
end)

script.on_event(defines.events.on_gui_value_changed, function(event)
  if not event.element.tags.bmsc_numeric_input then return end
  local record = current_record(event.player_index)
  if not record then return end
  -- slider_value 是离散档位索引；GUI 模块根据具体参数映射为倍率、秒数或递归深度。
  local textfield, value = Gui.apply_numeric_slider(event.element)
  if not (textfield and value) then return end
  if textfield.name == "bmsc-material" or textfield.name == "bmsc-material-retention" then
    local valid, demand, retention = Gui.validate_material_rate_inputs(textfield)
    if valid then
      record.config.material_demand_rate = demand
      record.config.material_retention_rate = retention
    end
    return
  end
  update_numeric_config(record, textfield.name, value)
end)
script.on_event(defines.events.on_gui_selection_state_changed, function(event)
  if event.element.name == "bmsc-mode" then
    local record = current_record(event.player_index)
    if not record then return end
    record.config.mode = event.element.selected_index == 2 and MODE_SUPERMARKET_ORDER or MODE_PRODUCTION_ORDER
    reset_all_modes(record)
    sync_mode_visual(record)

    -- 模式参数属于同一个窗口；像原版一样随下拉选项即时出现或隐藏。
    Gui.show_mode_details(event.element, record.config.mode)
    return
  end
  if event.element.name == "bmsc-remember-order" then
    local record = current_record(event.player_index)
    if not record then return end
    -- 下拉框第一项为“是”、第二项为“否”。关闭记忆时立即丢弃缓存，恢复绿线实时控制。
    record.config.remember_order = event.element.selected_index == 1
    if not record.config.remember_order then MODES[MODE_PRODUCTION_ORDER].reset(record) end
    return
  end
  if event.element.name == "bmsc-recursion-output" then
    local record = current_record(event.player_index)
    if not record then return end
    record.config.recursion_output_mode = event.element.selected_index == 2 and "all" or "single"
    -- 改变输出策略时解除旧锁定，下一运算周期会按新策略重新选择结果。
    MODES[MODE_SUPERMARKET_ORDER].reset(record)
    Gui.set_recursion_timeout_visible(event.element, record.config.recursion_output_mode == "single")
    return
  end
  if event.element.name ~= "bmsc-output" then return end
  local record = current_record(event.player_index)
  if record then
    record.config.output_mode = ({"only_item", "only_material", "all", "all_separate_signal"})[event.element.selected_index]
    Gui.set_cache_grid_visible(event.element, record.config.output_mode == "all_separate_signal")
  end
end)
script.on_event(defines.events.on_gui_click, function(event)
  local player = game.get_player(event.player_index)
  local record = current_record(event.player_index)

  if event.element.name == "bmsc-clear-order-memory" then
    if record then
      MODES[MODE_PRODUCTION_ORDER].reset(record)
      write_outputs(record, {})
    end
    return
  end
  if event.element.name == "bmsc-description-toggle" then
    if record and record.entity.valid then
      -- combinator_description 是 Factorio 为组合器提供的原生说明字段，会显示并随蓝图保存。
      Gui.show_description_editor(event.element, record.entity.combinator_description)
    end
    return
  end
  if event.element.name == "bmsc-description-save" then
    local description = Gui.get_description(event.element)
    if record and record.entity.valid and description then record.entity.combinator_description = description end
    -- 写入实体后立即刷新当前窗口，不必关闭再打开才能看到新说明。
    if description then Gui.refresh_saved_description(event.element, description) end
    Gui.hide_description_editor(event.element)
    return
  end
  if event.element.name == "bmsc-description-cancel" then
    Gui.hide_description_editor(event.element)
    return
  end
  if event.element.name == "bmsc-close" then
    Gui.close(player)
    state().player_gui[event.player_index] = nil
  end
end)

-- 蓝图和设置复制事件：保证配置能随蓝图以及 Shift+右键/左键复制。
script.on_event(defines.events.on_player_setup_blueprint, function(event)
  local blueprint = event.stack
  if not (blueprint and blueprint.valid_for_read and blueprint.is_blueprint) then return end
  for number, entity in pairs(event.mapping.get()) do
    if entity.valid and entity.name == ENTITY then
      local record = state().combinators[entity.unit_number]
      if record then blueprint.set_blueprint_entity_tags(number, {bmsc = record.config}) end
    end
  end
end)
script.on_event(defines.events.on_entity_settings_pasted, function(event)
  if event.destination.name ~= ENTITY then return end
  local destination = state().combinators[event.destination.unit_number]
  local source = event.source.name == ENTITY and state().combinators[event.source.unit_number]
  if destination and source then
    -- table.deepcopy 只在数据阶段（data.lua）由 Factorio 提供，运行阶段（control.lua）不存在。
    -- normalize_config 会创建一张全新的配置表，并逐项复制、校验来源配置，因此也能避免
    -- 两台运算器意外共用同一张 table；其效果等同于这里真正需要的“安全深拷贝”。
    destination.config = normalize_config(source.config)
    sync_mode_visual(destination)

    -- 运行缓存不属于配置，粘贴后由各模式自己的 reset 接口统一清除。
    reset_all_modes(destination)
    -- write_outputs 是上方定义的局部函数；传入空集合会清空代理槽位及悬浮信号。
    -- 项目中并没有 clear_outputs，调用它时 Lua 会将其视为值为 nil 的全局变量。
    write_outputs(destination, {})
  end
end)

script.on_nth_tick(TICK_INTERVAL, update_all)
