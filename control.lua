-- Market Selector Combinator 运行阶段主文件。
-- Factorio 加载存档后执行本文件；这里只负责编排实体状态、模式模块、GUI、输出代理和蓝图配置。

local ENTITY = "b-market-selector-combinator"          -- 参数：玩家可放置的主实体原型名。
local PROXY = "b-market-selector-output-proxy"         -- 参数：向线路发送计算结果的隐藏实体原型名。
local DETAIL_PROXY = "b-market-selector-detail-proxy" -- 参数：只在 Alt 模式显示当前订单产品的隐藏实体。
local OUTPUT_PROXY_REVISION = 2                       -- 修改代理连接/写入策略时递增，强制旧存档重建。
local TICK_INTERVAL = settings.startup["bmsc-update-interval"].value
                                                          -- 参数：玩家配置的刷新间隔，默认 30 tick。
local Gui = require("scripts.gui")                     -- GUI 模块：只负责界面，不参与生产计算。
local SignalPicker = require("scripts.signal_picker") -- 条件信号与常量共用的原版风格选择器。
local Config = require("scripts.config")               -- 配置模块：默认值、模式常量和外部数据校验。
local Util = require("scripts.common_util")            -- 通用工具：输出排序等无状态功能。
local OrderTarget = require("scripts.order_target")    -- 两种订单模式共用的配方覆盖与多产物库存目标。
local ProductionNetwork = require("scripts.production_network")
local NetworkGui = require("scripts.network_gui")
local MODES = require("scripts.mode_registry")          -- 模式注册表：统一调度彼此独立的算法模块。
local MODE_PRODUCTION_ORDER = Config.mode.production_order
local MODE_SUPERMARKET_ORDER = Config.mode.supermarket_order
local MODE_RECIPE_QUERY = Config.mode.recipe_query
local MODE_INVENTORY_QUERY = Config.mode.inventory_query
local MODE_SWAP_ORDER = Config.mode.swap_order
local MAX_PROXY_SIGNALS = 65535                    -- Factorio 常量运算器筛选索引的 uint16 上限。
local DOUBLE_CLICK_TICKS = 30                      -- 0.5 秒：等待订单左键双击判定窗口。
local refresh_open_order_targets                    -- 研究事件发生时刷新仍打开的配方选择窗口。


---取得并初始化本模组的持久状态。
---为什么需要：`storage` 会随存档保存，但首次运行时字段不存在，所有入口都通过此函数安全访问。
---@return table state 包含实体记录、当前窗口及玩家级 GUI 偏好。
local function state()
  -- 防御开发期脚本曾写入错误类型的半旧 storage；只依赖 `or {}` 无法修复 truthy 字符串。
  if type(storage.combinators) ~= "table" then storage.combinators = {} end
  if type(storage.player_gui) ~= "table" then storage.player_gui = {} end
  if type(storage.gui_config_open) ~= "table" then storage.gui_config_open = {} end
  if type(storage.signal_clicks) ~= "table" then storage.signal_clicks = {} end
  return storage
end

---配置校验函数的本地别名，让实体生命周期代码保持简洁。
---@type fun(source: table|nil): table
local normalize_config = Config.normalize

---把外部或旧版本配置转换成当前运行阶段可安全使用的配置。
---Config.normalize 只负责纯数据校验；Factorio 原型是否仍存在必须留在 control 层检查，
---这样配置模块不会依赖全局 prototypes，也能处理移除其他模组后失效的机器名称。
---@param source table|nil 存档、蓝图、复制设置或热加载遗留配置。
---@return table config 当前版本且生产机器有效的配置。
local function normalize_runtime_config(source)
  local config = normalize_config(source)
  local machine = prototypes.entity[config.production_machine]
  if not (machine and machine.crafting_categories) then
    local default_machine = Config.default().production_machine
    local fallback = prototypes.entity[default_machine]
    config.production_machine = fallback and fallback.crafting_categories and default_machine or nil
  end
  return config
end

---清除一台组合器的全部模式运行缓存。
---@param record table 组合器记录。
---@return nil
local function reset_all_modes(record)
  for _, mode in pairs(MODES) do mode.reset(record) end
end

---通知所有声明了 invalidate_plan 钩子的模式：Factorio 配方可用性已经变化。
---control 层不需要知道哪些模式缓存了配方树，新增模式也无需再修改研究事件处理器。
---@param record table 组合器记录。
---@return nil
local function invalidate_all_recipe_plans(record)
  for _, mode in pairs(MODES) do
    if mode.invalidate_plan then mode.invalidate_plan(record) end
  end
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
  states = type(states) == "table" and states or {}
  for name, mode in pairs(MODES) do mode.restore_state(record, states[name]) end
end

---取得当前模式写给输入槽位的诊断，避免其他模式显示残留原因。
---@param record table 组合器记录。
---@return table|nil diagnostics 当前模式诊断。
local function current_input_diagnostics(record)
  if record.config.mode == MODE_PRODUCTION_ORDER then return record.production_order_diagnostics end
  if record.config.mode == MODE_SUPERMARKET_ORDER then return record.supermarket_order_diagnostics end
  if record.config.mode == MODE_SWAP_ORDER then return record.swap_order_diagnostics end
  return nil
end

---把模式诊断收敛为运行面板需要的三行快照；GUI 只显示，不重新推导订单或库存。
local function current_work_summary(record)
  local diagnostics = current_input_diagnostics(record) or {}
  local source, next_key = "local", nil
  if record.config.mode == MODE_SUPERMARKET_ORDER and record.network_active then
    for _, task in ipairs(record.network_assignments or {}) do
      if task.key == record.network_active and task.execution then
        diagnostics = task.execution.supermarket_order_diagnostics or {}
        source, next_key = "network", task.execution.supermarket_next_order_key
        break
      end
    end
  elseif record.config.mode == MODE_PRODUCTION_ORDER then
    next_key = record.production_order_next_key
  elseif record.config.mode == MODE_SUPERMARKET_ORDER then
    next_key = record.supermarket_next_order_key
  end
  local current, active_count = nil, 0
  for _, diagnostic in pairs(diagnostics) do
    if diagnostic.kind == "active_output" or diagnostic.kind == "active_fallback"
      or diagnostic.kind == "supermarket_expanding" then
      active_count = active_count + 1
      current = diagnostic
    end
  end
  -- “当前订单”只承载单一工作项；全量输出同时处理多个订单时，避免 pairs 的偶然顺序制造误导。
  if active_count ~= 1 then current = nil end
  local network_orders = {}
  local network_diagnostics = {}
  for _, task in ipairs(record.network_assignments or {}) do
    if task.signal and task.quantity and task.quantity > 0 then
      network_orders[#network_orders + 1] = {signal = Util.make_signal(
        task.signal.type, task.signal.name, task.signal.quality), count = task.quantity}
      local diagnostic = task.execution and task.execution.supermarket_order_diagnostics
      if diagnostic then network_diagnostics[Util.signal_key(task.signal)] = diagnostic[Util.signal_key(task.signal)] end
    end
  end
  local linked_inventory = {}
  local stage = current and current.stage
  if record.config.inventory_validation == Config.inventory_validation.linked and stage and stage.ingredients then
    local requested = {}
    for _, ingredient in ipairs(stage.ingredients) do
      if ingredient.signal then requested[Util.signal_key(ingredient.signal)] = ingredient.signal end
    end
    local shared = MODES[MODE_INVENTORY_QUERY].get_shared_inventory(record.entity.force, requested)
    if shared then
      for _, ingredient in ipairs(stage.ingredients) do
        local signal = ingredient.signal
        if signal then linked_inventory[#linked_inventory + 1] = {
          signal = Util.make_signal(signal.type, signal.name, signal.quality),
          count = math.max(0, shared[Util.signal_key(signal)] or 0)} end
      end
    end
  end
  return {current = current, next = next_key and diagnostics[next_key] or nil, source = source,
    network_orders = network_orders, network_diagnostics = network_diagnostics, linked_inventory = linked_inventory}
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

---清理主实体位置上未被当前 storage 记录跟踪的历史代理。
---开发期热加载可能丢失 LuaEntity 引用，但旧常量运算器仍留在线路上持续发送旧槽位。
---@param entity LuaEntity 主选择运算器。
---@return nil
local function destroy_proxies_at(entity)
  local position = entity.position
  local area = {
    {position.x - 0.01, position.y - 0.01},
    {position.x + 0.01, position.y + 0.01}
  }
  for _, proxy in pairs(entity.surface.find_entities_filtered{
    area = area, name = {PROXY, DETAIL_PROXY}
  }) do
    proxy.destroy()
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
  record.native_behavior_mode = record.config.mode .. ":" .. tostring(mode and mode.visual_revision or 1)
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
  destroy_proxies_at(entity)
  local source = tags and tags.bmsc or tags
  local record = {
    entity = entity,
    red_proxy = create_proxy(entity, "red"),
    green_proxy = create_proxy(entity, "green"),
    detail_proxy = create_proxy(entity, nil, DETAIL_PROXY),
    config = normalize_runtime_config(source),
    output_proxy_revision = OUTPUT_PROXY_REVISION
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
  for player_index, unit in pairs(state().player_gui) do
    if unit == entity.unit_number then
      local player = game.get_player(player_index)
      if player then Gui.close(player) end
      state().player_gui[player_index] = nil
    end
  end
  destroy_proxies(state().combinators[entity.unit_number])
  state().combinators[entity.unit_number] = nil
end

---调用当前配置所对应的模式模块。
---每个模式遵守相同接口：calculate(record) 计算输出，reset(record) 清理该模式缓存。
---@param record table 当前组合器运行记录。
---@return table outputs 当前模式产生的标准输出集合。
local function calculate(record)
  -- game.reload_mods 等开发期热加载不一定执行完整迁移。配置缺失、版本过旧、模式非法、
  -- 机器原型被其他模组移除或倍率关系损坏时，在进入任何模式算法前统一修复。
  local config = record.config
  local machine = type(config) == "table" and prototypes.entity[config.production_machine]
  if type(config) ~= "table" or config.schema_revision ~= Config.schema_revision
    or not MODES[config.mode] or not (machine and machine.crafting_categories)
    or not Config.material_rates_valid(config.material_demand_rate, config.material_retention_rate)
    or not Config.material_rates_valid(
      config.recursion_material_demand_rate, config.recursion_material_retention_rate) then
    record.config = normalize_runtime_config(config)
  end
  -- 开发期热加载不一定触发实体重建；模式的安全显示参数发生变化后，在下一轮计算时
  -- 同步一次，避免旧存档继续沿用曾经保存的 random 或默认 select 参数。
  local visual_mode = MODES[record.config.mode]
  local visual_key = record.config.mode .. ":" .. tostring(visual_mode and visual_mode.visual_revision or 1)
  if record.native_behavior_mode ~= visual_key then sync_mode_visual(record) end
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
  local function format_entries(entries, signature_prefix)
    local parts, signature_parts = {}, {}
    for _, value in ipairs(Util.sorted_outputs(entries)) do
      local entry = value.entry
      signature_parts[#signature_parts + 1] = signature_prefix .. value.key .. "=" .. tostring(entry.count)
      local signal_type = entry.signal.type or "item"
      local tag_type = signal_type == "virtual" and "virtual-signal" or signal_type
      local quality = signal_type == "item" and Util.quality_name(entry.signal.quality) or nil
      local quality_part = quality and quality ~= "normal" and ",quality=" .. quality or ""
      parts[#parts + 1] = "[" .. tag_type .. "=" .. entry.signal.name
        .. quality_part .. "] " .. entry.count
    end
    return #parts > 0 and table.concat(parts, "  ") or {"bmsc.no-output"}, signature_parts
  end

  local content, signature_parts
  if outputs.separated == true then
    local red, red_signature = format_entries(outputs.red or {}, "red:")
    local green, green_signature = format_entries(outputs.green or {}, "green:")
    content = {"bmsc.output-signals-separated", red, green}
    signature_parts = {"separated"}
    for _, part in ipairs(red_signature) do signature_parts[#signature_parts + 1] = part end
    for _, part in ipairs(green_signature) do signature_parts[#signature_parts + 1] = part end
  else
    content, signature_parts = format_entries(outputs, "")
  end
  local signature = table.concat(signature_parts, "|")
  -- set_tooltip_field 会修改实体运行时状态；输出未变化时直接复用旧字段，避免重复写入。
  if record.tooltip_output_signature == signature then return end
  record.output_tooltip_id = record.entity.set_tooltip_field{
    id = record.output_tooltip_id, name = {"bmsc.output-signals"}, value = content, order = 31
  }
  record.tooltip_output_signature = signature
  record.entity.custom_status = nil
end

---把输出集合整理为实际可写入代理的稳定数组和签名。
---签名只包含最终会上线路的非零信号；同一集合无论 pairs 遍历顺序如何，
---都会得到相同字符串，因此可以安全判断“本轮输出是否真的发生变化”。
---@param outputs table 当前线路的输出集合。
---@return table entries 按信号键排序、过滤后的输出数组。
---@return string signature 用于比较相邻两轮输出的稳定签名。
local function prepare_proxy_outputs(outputs)
  local entries = {}
  local signature_parts = {}
  for _, value in ipairs(Util.sorted_outputs(outputs)) do
    if value.entry.count ~= 0 and #entries < MAX_PROXY_SIGNALS then
      entries[#entries + 1] = value.entry
      signature_parts[#signature_parts + 1] = tostring(value.entry.sort_priority or 0) .. ":"
        .. value.key .. "=" .. tostring(value.entry.count)
    end
  end
  return entries, table.concat(signature_parts, "|")
end

---把一组结果写入指定隐藏代理的常量运算器槽位。
---输出签名未变化时不访问 Factorio 槽位 API；发生变化时一次替换完整筛选列表。
---@param proxy LuaEntity 隐藏常量运算器。
---@param outputs table 当前线路的输出集合。
---@param cache table|nil 上一轮缓存，格式为 `{signature=string, slot_count=integer}`。
---@return table cache 本轮签名和实际槽位数，供下一轮复用。
---@return table entries 本轮实际写入代理的信号数组（已过滤、排序且最多 100 项）。
local function write_proxy_outputs(proxy, outputs, cache)
  local entries, signature = prepare_proxy_outputs(outputs)
  -- 即使线路内容没有变化，也要把 entries 返回给 GUI。GUI 与线路共用这份快照，避免
  -- 在代理刚写入的同一 tick 读取电路网络时拿到 Factorio 尚未传播的上一轮信号。
  if cache and cache.signature == signature then return cache, entries end

  local behavior = proxy.get_or_create_control_behavior()
  -- 代理只使用第一节。若旧版本或异常状态留下额外 section，必须先移除，否则其中的
  -- 信号仍会与第一节一起发送到线路，形成看似无法释放的历史输出。
  for section_index = behavior.sections_count, 2, -1 do
    behavior.remove_section(section_index)
  end
  local section = behavior.get_section(1) or behavior.add_section()
  local filters = {}
  for index, entry in ipairs(entries) do
    -- filters 的 value 是 SignalFilter，而不只是普通 SignalID。当 min 非零时，
    -- Factorio 2.1 要求 quality 明确指定且 comparator 必须为“=”。完整替换列表既支持
    -- 查询模式的全量信号，也能在切回普通模式时一次清除所有旧槽位。
    local signal = entry.signal
    local safe_signal = Util.make_signal(signal.type, signal.name, signal.quality)
    safe_signal.quality = Util.quality_name(signal.quality)
    safe_signal.comparator = "="
    filters[index] = {value = safe_signal, min = entry.count}
  end
  section.filters = filters
  return {signature = signature, slot_count = #entries}, entries
end

---把代理槽位数组复制成 GUI 信号面板使用的网络快照。
---这里故意不让 GUI 再读一次实体输出网络：Factorio 的线路传播发生在脚本写槽位之后，
---同一更新周期内直接读取线路可能还是旧值。复制数据也避免后续计算修改原表。
---@param color string `red` 或 `green`。
---@param entries table write_proxy_outputs 返回的实际槽位数组。
---@return table network 与 scripts/gui.lua 网络数据格式一致的快照。
local function make_gui_output_network(color, entries)
  local signals = {}
  for index, entry in ipairs(entries or {}) do
    signals[index] = {
      signal = Util.make_signal(entry.signal.type, entry.signal.name, entry.signal.quality),
      count = entry.count,
      sort_priority = entry.sort_priority
    }
  end
  return {color = color, signals = signals}
end

---把结果分别写入红、绿隐藏代理，并同步悬浮信息。
---普通模式把同一集合写入两色线路；带 separated 标记的结果可为两色线路分别提供集合。
---@param record table 组合器运行记录。
---@param outputs table 当前输出集合，或 `{separated=true, red=table, green=table}`。
---@return nil
local function write_outputs(record, outputs)
  -- 模式模块按约定应返回 table；热加载期间若新旧模块接口短暂不一致，按空输出处理，
  -- 让代理清掉历史槽位，而不是在读取 outputs.separated 时中断整个 on_nth_tick。
  if type(outputs) ~= "table" then outputs = {} end
  if record.output_proxy_revision ~= OUTPUT_PROXY_REVISION then
    -- 版本迁移不能只清除 storage 中仍有引用的代理；失联代理正是线路保留旧信号的来源。
    destroy_proxies(record)
    destroy_proxies_at(record.entity)
    record.red_proxy = create_proxy(record.entity, "red")
    record.green_proxy = create_proxy(record.entity, "green")
    record.detail_proxy = create_proxy(record.entity, nil, DETAIL_PROXY)
    record.proxy_output_cache = {}
    record.output_proxy_revision = OUTPUT_PROXY_REVISION
  end
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
  local red_entries, green_entries
  record.proxy_output_cache.red, red_entries = write_proxy_outputs(
    record.red_proxy, red_outputs or {}, record.proxy_output_cache.red)
  record.proxy_output_cache.green, green_entries = write_proxy_outputs(
    record.green_proxy, green_outputs or {}, record.proxy_output_cache.green)
  -- 信号 GUI 展示的必须是本轮真正写入两个输出代理的内容，而不是线路传播前的旧值。
  record.gui_output_networks = {
    make_gui_output_network("red", red_entries),
    make_gui_output_network("green", green_entries)
  }
  -- 展示代理没有线路连接，只负责在 Alt 详细信息模式显示当前订单产品。
  if record.detail_proxy then
    record.proxy_output_cache.detail = write_proxy_outputs(
      record.detail_proxy, record.detail_outputs or {}, record.proxy_output_cache.detail)
  end

  update_hover_tooltip(record, outputs)
end

local function timeout_elapsed_seconds(start_tick, timeout, active)
  timeout = tonumber(timeout) or 0
  if not (active and start_tick and timeout > 0) then return 0 end
  return math.min(timeout, math.max(0, (game.tick - start_tick) / 60))
end

local function refresh_timeout_display(player, record)
  local mode = record.config.mode
  Gui.refresh_timeout_elapsed(
    player.gui.screen[Gui.name],
    timeout_elapsed_seconds(record.production_order_changed_tick, record.config.production_timeout,
      mode == MODE_PRODUCTION_ORDER and record.production_order_output_count ~= nil),
    timeout_elapsed_seconds(record.recursion_material_wait_tick, record.config.recursion_material_wait_time,
      mode == MODE_SUPERMARKET_ORDER and record.recursion_material_wait_output ~= nil),
    timeout_elapsed_seconds(record.recursion_output_changed_tick, record.config.recursion_timeout,
      mode == MODE_SUPERMARKET_ORDER and record.recursion_output_count ~= nil),
    timeout_elapsed_seconds(record.swap_condition_tick, record.config.swap_timeout,
      mode == MODE_SWAP_ORDER))
end

local function refresh_open_timeout_displays()
  for player_index, unit in pairs(state().player_gui) do
    local player = game.get_player(player_index)
    local record = state().combinators[unit]
    if player and record then refresh_timeout_display(player, record) end
  end
end

---定时更新所有市场选择运算器，并清除已经失效的实体记录。
---@return nil
local function update_all()
  -- 需要跨实体协作的模式可在 calculate 前统一准备势力级状态；普通模式没有此钩子。
  -- 查询模式借此合并同一势力的查询信号，只维护一个 LinkedChestAndPipe 探针。
  for _, mode in pairs(MODES) do
    if mode.prepare then mode.prepare(state().combinators) end
  end
  for _, record in pairs(state().combinators) do
    if record.config and record.config.schema_revision ~= Config.schema_revision then
      record.config = normalize_runtime_config(record.config)
    end
  end
  ProductionNetwork.prepare(state().combinators)
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
  for _, player in pairs(game.connected_players) do
    if player.gui.screen[NetworkGui.name] and game.tick % 60 == 0 then
      NetworkGui.refresh_network(player, state().combinators)
    end
  end
  for player_index, unit in pairs(state().player_gui) do
    local player = game.get_player(player_index)
    local record = state().combinators[unit]
    if player and record then
      Gui.refresh_connection_status(
        player, record.entity, record.gui_output_networks, current_input_diagnostics(record), current_work_summary(record))
      Gui.refresh_condition_states(player.gui.screen[Gui.name], "production-timeout",
        record.production_timeout_condition_results)
      Gui.refresh_condition_states(player.gui.screen[Gui.name], "recursion-timeout",
        record.recursion_timeout_condition_results)
      Gui.refresh_condition_states(player.gui.screen[Gui.name], "swap", record.swap_condition_results)
    end
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

-- 科技完成、撤销或整体重算都可能改变 force.recipes[name].enabled。机器的静态能力索引
-- 无需重建，但对应势力已生成的订单树必须失效，下一刷新周期会重新选择可用配方。
local research_events = {defines.events.on_research_finished}
local research_reversed = defines.events.on_research_reversed
local technology_effects_reset = defines.events.on_technology_effects_reset
if research_reversed then research_events[#research_events + 1] = research_reversed end
if technology_effects_reset then research_events[#research_events + 1] = technology_effects_reset end
script.on_event(research_events, function(event)
  local force = event.force or (event.research and event.research.force)
  if not force then return end
  for _, record in pairs(state().combinators) do
    if record.entity and record.entity.valid and record.entity.force == force then
      invalidate_all_recipe_plans(record)
    end
  end
  if refresh_open_order_targets then refresh_open_order_targets(force) end
end)

-- GUI 事件：拦截原版选择运算器窗口，改为本模组自己的参数窗口。
script.on_event(defines.events.on_gui_opened, function(event)
  if event.entity and event.entity.valid and event.entity.name == ENTITY then
    local player = game.get_player(event.player_index)
    player.opened = nil
    local record = state().combinators[event.entity.unit_number]
    if not record then register(event.entity); record = state().combinators[event.entity.unit_number] end
    -- 热加载可能保留旧 schema 的 record；GUI 创建会直接读取全部字段，因此打开前也要
    -- 做一次迁移，不能只依赖下一次定时计算来修复配置。
    record.config = normalize_runtime_config(record.config)
    Gui.open(
      player, event.entity, record.config, record.gui_output_networks, current_input_diagnostics(record),
      current_work_summary(record), MODES[MODE_INVENTORY_QUERY].is_available(),
      state().gui_config_open[player.index] == true)
    Gui.refresh_condition_states(player.gui.screen[Gui.name], "production-timeout",
      record.production_timeout_condition_results)
    Gui.refresh_condition_states(player.gui.screen[Gui.name], "recursion-timeout",
      record.recursion_timeout_condition_results)
    Gui.refresh_condition_states(player.gui.screen[Gui.name], "swap", record.swap_condition_results)
    refresh_timeout_display(player, record)
    state().player_gui[player.index] = event.entity.unit_number
  end
end)
script.on_event(defines.events.on_gui_closed, function(event)
  if NetworkGui.on_closed(event, state().combinators) then return end
  if event.element and event.element.valid and event.element.name == NetworkGui.name then
    event.element.destroy()
    return
  end
  if SignalPicker.on_closed(event) then return end
  if event.element and event.element.valid and event.element.name == Gui.order_target_name then
    local player = game.get_player(event.player_index)
    -- Esc/E 会把 opened 清空；若玩家正在打开别的实体，则不把后方主窗口抢回前台。
    local restore_main = player.opened == nil or player.opened == event.element
    Gui.close_order_target(player, restore_main)
    if not restore_main then
      Gui.destroy_background(player)
      state().player_gui[event.player_index] = nil
    end
    return
  end
  if not (event.element and event.element.valid and event.element.name == Gui.name) then return end

  -- 条件选择器和订单目标子窗口都会暂时替换 player.opened；主窗口留在后方继续编辑。
  local player = game.get_player(event.player_index)
  local order_target = player and player.gui.screen[Gui.order_target_name]
  if SignalPicker.is_open(player) or order_target and order_target.valid then return end

  -- player.opened 使 E、Esc、打开其他实体等操作都会进入这里，行为与原版实体窗口一致。
  state().player_gui[event.player_index] = nil
  Gui.hide_network_popup(player)
  event.element.destroy()
end)
script.on_event(defines.events.on_gui_location_changed, function(event)
  NetworkGui.on_location_changed(event)
  Gui.sync_config_overlay_location(event.element)
end)
-- custom-input 属于数据阶段。热重载 control.lua 而未完整重启游戏时原型尚不存在，
-- 此处跳过注册以避免 Unknown event；完整重启后会按 event_id 正常启用滚轮缩放。
local function register_tree_zoom_input(name, delta)
  local input = prototypes.custom_input and prototypes.custom_input[name]
  if input then
    script.on_event(input.event_id, function(event)
      NetworkGui.on_zoom(event, state().combinators, delta)
    end)
  end
end
register_tree_zoom_input("bmsc-tree-zoom-in", 0.25)
register_tree_zoom_input("bmsc-tree-zoom-out", -0.25)

---根据玩家索引取得其当前正在编辑的组合器记录。
---@param player_index uint 玩家索引。
---@return table|nil record。
local function current_record(player_index)
  local unit = state().player_gui[player_index]
  return unit and state().combinators[unit]
end

local function signal_from_tags(tags)
  return tags and type(tags.bmsc_signal_name) == "string" and Util.make_signal(
    tags.bmsc_signal_type, tags.bmsc_signal_name, tags.bmsc_signal_quality) or nil
end

---按玩家记录上次普通左键点击，避免多人同时查看同一运算器时互相触发双击。
---@param player_index uint 玩家索引。
---@param record table 组合器记录。
---@param signal_key string 被点击的订单信号键。
---@return boolean double_clicked 同一玩家在时限内再次点击同一订单时返回 true。
local function signal_double_clicked(player_index, record, signal_key)
  local clicks = state().signal_clicks
  local previous = clicks[player_index]
  local double_clicked = previous and previous.unit_number == record.entity.unit_number
    and previous.signal_key == signal_key and game.tick - previous.tick <= DOUBLE_CLICK_TICKS
  clicks[player_index] = double_clicked and nil
    or {unit_number = record.entity.unit_number, signal_key = signal_key, tick = game.tick}
  return double_clicked == true
end

local function order_target_entry(record, source_key)
  if type(record.config.order_targets) ~= "table" then record.config.order_targets = {} end
  local entry = record.config.order_targets[source_key]
  if type(entry) ~= "table" then entry = {products = {}}; record.config.order_targets[source_key] = entry end
  if type(entry.products) ~= "table" then entry.products = {} end
  return entry
end

local function copy_products(products)
  local result = {}
  for _, product in ipairs(products or {}) do
    result[#result + 1] = Util.make_signal(product.type, product.name, product.quality)
  end
  return result
end

local function open_order_target(player, record, order_signal, order_count, network_task)
  if record.config.mode == MODE_SUPERMARKET_ORDER then
    if not network_task then MODES[MODE_SUPERMARKET_ORDER].calculate(record) end
    NetworkGui.open_tree(player, record, order_signal, order_count, network_task)
    return
  end
  local recipe_query = record.config.mode == MODE_RECIPE_QUERY
  local target = OrderTarget.resolve(
    record.entity.force, record.config.production_machine, order_signal, record.config,
    recipe_query and {ignore_research = true} or nil)
  local recipes = OrderTarget.available_recipes(
    record.entity.force, record.config.production_machine, order_signal, target.configured_recipe)
  local enabled = {}
  for _, recipe in ipairs(recipes) do
    local force_recipe = record.entity.force.recipes[recipe.name]
    enabled[recipe.name] = force_recipe and force_recipe.enabled == true or false
  end
  if order_signal.type == "recipe" then
    local force_recipe = record.entity.force.recipes[order_signal.name]
    enabled[order_signal.name] = force_recipe and force_recipe.enabled == true or false
  end
  Gui.open_order_target(player, order_signal, order_count, target, recipes,
    {show_products = not recipe_query, enabled_recipes = enabled})
end

refresh_open_order_targets = function(force)
  for player_index, unit_number in pairs(state().player_gui) do
    local record = state().combinators[unit_number]
    local player = game.get_player(player_index)
    local popup = player and player.gui.screen[Gui.order_target_name]
    if record and record.entity and record.entity.valid and record.entity.force == force
      and popup and popup.valid then
      local order_signal = signal_from_tags(popup.tags)
      if order_signal then open_order_target(player, record, order_signal, popup.tags.bmsc_order_count or 0) end
    end
  end
end

---订单目标改变后只失效真正依赖配方树的超市缓存；生产订单下一次计算可直接读取新配置。
local function apply_order_target_change(player, record, order_signal, order_count)
  MODES[MODE_SUPERMARKET_ORDER].invalidate_plan(record)
  local mode = MODES[record.config.mode]
  if mode then write_outputs(record, mode.calculate(record)) end
  Gui.refresh_connection_status(
    player, record.entity, record.gui_output_networks, current_input_diagnostics(record), current_work_summary(record))
  open_order_target(player, record, order_signal, order_count)
end

local function select_order_recipe(player, record, order_signal, order_count, recipe_name)
  local entry = order_target_entry(record, Util.signal_key(order_signal))
  entry.recipe = recipe_name
  -- 切换配方时只保留新配方仍拥有的产物；全部失效则由共享解析回退到订单产品。
  local target = OrderTarget.resolve(
    record.entity.force, record.config.production_machine, order_signal, record.config)
  entry.products = copy_products(target.products)
  apply_order_target_change(player, record, order_signal, order_count)
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
  if event.element.name ~= "bmsc-production-machine" and event.element.name ~= "bmsc-recursion-machine"
    and event.element.name ~= "bmsc-recipe-query-machine" then return end
  local record = current_record(event.player_index)
  local machine = event.element.elem_value
  local prototype = machine and prototypes.entity[machine]
  if record and prototype and prototype.crafting_categories then
    local machine_changed = record.config.production_machine ~= machine
    record.config.production_machine = machine
    Gui.sync_machine_buttons(event.element, machine)
    if machine_changed then
      -- 生产机器决定哪些配方能够被查询。各模式都可能保存基于旧机器得到的锁定项、
      -- 目标库存和超时状态，因此不能只修改配置字段；必须统一清除运行缓存。
      -- 订单记忆代表玩家已经接受的订单，不是配方查询缓存；切换机器时先暂存它，
      -- 清理派生状态后再恢复，使绿线订单已经消失时仍能由新机器重新验证并继续执行。
      local remembered_order = record.config.remember_order and record.remembered_order or nil
      reset_all_modes(record)
      record.remembered_order = remembered_order
      Gui.close_order_target(game.get_player(event.player_index), true)
      -- 参数和相关运行缓存已经立即更新；线路结果统一留到下一次全局刷新周期重算。
    end
  end
end)

local function reset_swap_timer(record)
  record.swap_condition_tick = nil
end

local condition_config_fields = {
  ["production-timeout"] = "production_timeout_conditions",
  ["recursion-timeout"] = "recursion_timeout_conditions",
  swap = "swap_conditions"
}

local timeout_monitor_fields = {
  ["bmsc-production-timeout-monitor-item-changes"] = {
    config = "production_timeout_monitor_item_changes", condition_set = "production-timeout"},
  ["bmsc-recursion-timeout-monitor-item-changes"] = {
    config = "recursion_timeout_monitor_item_changes", condition_set = "recursion-timeout"}
}

local function conditions_for(record, set_name)
  local field = condition_config_fields[set_name]
  return field and record.config[field] or nil
end

local function reset_condition_timer(record, set_name)
  if set_name == "production-timeout" then
    record.production_order_output_count = nil
    record.production_order_changed_tick = nil
  elseif set_name == "recursion-timeout" then
    record.recursion_output_count = nil
    record.recursion_output_changed_tick = nil
  else
    reset_swap_timer(record)
  end
end

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
  if element_name == "bmsc-recursion-additional" then
    record.config.recursion_additional_production_rate = value
    return true
  end
  if element_name == "bmsc-recursion-material" then
    if not Config.material_rates_valid(value, record.config.recursion_material_retention_rate) then return false end
    record.config.recursion_material_demand_rate = value
    return true
  end
  if element_name == "bmsc-recursion-material-retention" then
    if not Config.material_rates_valid(record.config.recursion_material_demand_rate, value) then return false end
    record.config.recursion_material_retention_rate = value
    return true
  end
  if element_name == "bmsc-production-timeout" then record.config.production_timeout = value; return true end
  if element_name == "bmsc-swap-timeout" then record.config.swap_timeout = value; return true end
  if element_name == "bmsc-cache-grid-number" then
    -- 缓存格数必须是非负整数；即使未来有调用方绕过 GUI，也不能写入负值或小数。
    record.config.cache_grid_number = math.max(0, math.floor(value))
    return true
  end
  if element_name == "bmsc-recipe-query-cache-grid-number" then
    record.config.recipe_query_cache_grid_number = math.max(0, math.floor(value))
    return true
  end
  if element_name == "bmsc-recursion-material-wait-time" then
    record.config.recursion_material_wait_time = value
    return true
  end
  if element_name == "bmsc-recursion-depth" then record.config.recurise_depth = math.floor(value); return true end
  if element_name == "bmsc-recursion-timeout" then record.config.recursion_timeout = value; return true end
  return false
end

---数值参数保存后，让依赖旧值的运行状态立即失效；线路计算仍由全局刷新统一执行。
---@param record table 当前组合器记录。
---@param element_name string 已更新的数值输入框名称。
---@return nil
local function invalidate_numeric_runtime_state(record, element_name)
  if element_name == "bmsc-recursion-depth" or element_name == "bmsc-recursion-additional"
    or element_name == "bmsc-recursion-material" or element_name == "bmsc-recursion-material-retention" then
    -- 深度或迟滞参数变化后重新选择递归层级，不能沿用旧阈值下的运行状态。
    MODES[MODE_SUPERMARKET_ORDER].reset(record)
  elseif element_name == "bmsc-production-timeout" then
    -- 修改超时时间后从下个刷新周期重新计时，不能沿用旧参数下累计的静止时间。
    record.production_order_output_count = nil
    record.production_order_changed_tick = nil
  elseif element_name == "bmsc-recursion-timeout" then
    record.recursion_output_count = nil
    record.recursion_output_changed_tick = nil
  elseif element_name == "bmsc-recursion-material-wait-time" then
    record.recursion_material_wait_tick = nil
    record.recursion_material_wait_output = nil
  elseif element_name == "bmsc-swap-timeout" then
    reset_swap_timer(record)
  end
end

script.on_event(defines.events.on_gui_text_changed, function(event)
  if NetworkGui.on_text(event, state().combinators) then return end
  if SignalPicker.on_text_changed(event) then return end
  local record = current_record(event.player_index)
  local value = tonumber(event.element.text)
  if not record then return end
  if event.element.name == "bmsc-material" or event.element.name == "bmsc-material-retention"
    or event.element.name == "bmsc-recursion-material"
    or event.element.name == "bmsc-recursion-material-retention" then
    local valid, demand, retention = Gui.validate_material_rate_inputs(event.element)
    if valid then
      -- 两个输入框作为一个参数组同时提交，避免修改顺序受到旧配置值影响。
      if event.element.name:find("bmsc-recursion-", 1, true) == 1 then
        record.config.recursion_material_demand_rate = demand
        record.config.recursion_material_retention_rate = retention
        invalidate_numeric_runtime_state(record, event.element.name)
      else
        record.config.material_demand_rate = demand
        record.config.material_retention_rate = retention
      end
      Gui.sync_numeric_slider(event.element, value)
    end
    return
  end
  if not (value and value >= 0) then return end
  local accepted = update_numeric_config(record, event.element.name, value)
  -- 输入任意值时只移动滑块到最近档位，不改写玩家输入的精确数值。
  if accepted then
    Gui.sync_numeric_slider(event.element, value)
    invalidate_numeric_runtime_state(record, event.element.name)
  end
end)

script.on_event(defines.events.on_gui_value_changed, function(event)
  if SignalPicker.on_value_changed(event) then return end
  if not event.element.tags.bmsc_numeric_input then return end
  local record = current_record(event.player_index)
  if not record then return end
  -- slider_value 是离散档位索引；GUI 模块根据具体参数映射为倍率、秒数或递归深度。
  local textfield, value = Gui.apply_numeric_slider(event.element)
  if not (textfield and value) then return end
  if textfield.name == "bmsc-material" or textfield.name == "bmsc-material-retention"
    or textfield.name == "bmsc-recursion-material"
    or textfield.name == "bmsc-recursion-material-retention" then
    local valid, demand, retention = Gui.validate_material_rate_inputs(textfield)
    if valid then
      if textfield.name:find("bmsc-recursion-", 1, true) == 1 then
        record.config.recursion_material_demand_rate = demand
        record.config.recursion_material_retention_rate = retention
        invalidate_numeric_runtime_state(record, textfield.name)
      else
        record.config.material_demand_rate = demand
        record.config.material_retention_rate = retention
      end
    end
    return
  end
  local accepted = update_numeric_config(record, textfield.name, value)
  if accepted then invalidate_numeric_runtime_state(record, textfield.name) end
end)
script.on_event(defines.events.on_gui_selection_state_changed, function(event)
  if NetworkGui.on_selection(event, state().combinators) then return end
  local event_tags = event.element.tags or {}
  if event_tags.bmsc_swap_comparator and event_tags.bmsc_condition_set then
    local record = current_record(event.player_index)
    local conditions = record and conditions_for(record, event_tags.bmsc_condition_set)
    local condition = conditions and conditions[event_tags.bmsc_swap_comparator]
    if condition then
      condition.comparator = ({"<", ">", "=", "<=", ">=", "~="})[event.element.selected_index] or "<"
      reset_condition_timer(record, event_tags.bmsc_condition_set)
    end
    return
  end
  local timeout_monitor = timeout_monitor_fields[event.element.name]
  if timeout_monitor then
    local record = current_record(event.player_index)
    if record then
      record.config[timeout_monitor.config] = event.element.selected_index == 1
      reset_condition_timer(record, timeout_monitor.condition_set)
    end
    return
  end
  if event.element.name == "bmsc-mode" then
    local record = current_record(event.player_index)
    if not record then return end
    record.config.mode = ({MODE_PRODUCTION_ORDER, MODE_SUPERMARKET_ORDER, MODE_RECIPE_QUERY,
      MODE_INVENTORY_QUERY, MODE_SWAP_ORDER})
      [event.element.selected_index] or MODE_PRODUCTION_ORDER
    reset_all_modes(record)
    sync_mode_visual(record)
    Gui.close_order_target(game.get_player(event.player_index), true)

    -- 模式参数属于同一个窗口；像原版一样随下拉选项即时出现或隐藏。
    Gui.show_mode_details(event.element, record.config.mode)
    return
  end
  if event.element.name == "bmsc-multiple-recipe-support" then
    local record = current_record(event.player_index)
    if not record then return end
    -- 第一项为“单个”、第二项为“所有”；缓存格数只在所有模式下参与输出限制。
    record.config.multiple_recipe_support = event.element.selected_index == 2
    MODES[MODE_RECIPE_QUERY].reset(record)
    Gui.set_recipe_query_cache_grid_visible(event.element, record.config.multiple_recipe_support)
    return
  end
  if event.element.name == "bmsc-query-all" then
    local record = current_record(event.player_index)
    if not record then return end
    -- 第一项为“否”、第二项为“是”；切换后下一轮会重配共享探针并等待对方模组刷新。
    record.config.query_all = event.element.selected_index == 2
    return
  end
  if event.element.name == "bmsc-query-type" then
    local record = current_record(event.player_index)
    if not record then return end
    -- 显示顺序为仅流体、仅物体、不限制；查询全部和按输入查询共用同一过滤配置。
    record.config.query_type = ({Config.query_type.fluid, Config.query_type.item, Config.query_type.all})
      [event.element.selected_index] or Config.query_type.all
    return
  end
  if event.element.name == "bmsc-swap-output-mode" then
    local record = current_record(event.player_index)
    if record then
      record.config.swap_output_mode = ({"fluid", "item", "all", "all_with_signals"})
        [event.element.selected_index] or "fluid"
      -- 类型过滤会改变候选集合；立即重新选择并刷新面板，不能暂留旧类型的线路输出。
      MODES[MODE_SWAP_ORDER].clear(record)
      write_outputs(record, MODES[MODE_SWAP_ORDER].calculate(record))
      Gui.refresh_connection_status(game.get_player(event.player_index), record.entity,
        record.gui_output_networks, current_input_diagnostics(record), current_work_summary(record))
    end
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
    Gui.set_recursion_single_options_visible(event.element, record.config.recursion_output_mode == "single")
    return
  end
  if event.element.name == "bmsc-inventory-validation" then
    local record = current_record(event.player_index)
    if not record then return end
    local available = MODES[MODE_INVENTORY_QUERY].is_available()
    local values = available
      and {Config.inventory_validation.inventory, Config.inventory_validation.linked,
        Config.inventory_validation.none}
      or {Config.inventory_validation.inventory, Config.inventory_validation.none}
    record.config.inventory_validation = values[event.element.selected_index]
      or Config.inventory_validation.inventory
    MODES[MODE_SUPERMARKET_ORDER].reset(record)
    -- 库存来源会改变整张订单能否输出；立即清空旧代理，等待下一轮按新来源重算。
    write_outputs(record, {})
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
  if NetworkGui.on_click(event, state().combinators) then return end
  local player = game.get_player(event.player_index)
  local record = current_record(event.player_index)

  local picker_consumed, picker_result = SignalPicker.on_click(event)
  if picker_consumed then
    if picker_result and record then
      local target = picker_result.target
      local conditions = target and conditions_for(record, target.set_name)
      local condition = conditions and conditions[target.condition]
      local operand = condition and condition[target.side]
      if operand then
        if picker_result.signal then
          operand.signal = picker_result.signal
        else
          operand.signal = nil
          operand.constant = picker_result.constant or 0
        end
        Gui.rebuild_conditions(player.gui.screen[Gui.name], target.set_name, conditions)
        reset_condition_timer(record, target.set_name)
      end
    end
    return
  end

  -- 仅处理主 GUI 输入/输出面板中的信号图标；不改变槽位控件和数字角标布局。
  -- 普通 sprite-button 不会自动执行工厂百科快捷操作，因此显式补上原版 Alt+左键行为。
  local tags = event.element.tags or {}
  if tags.bmsc_page then
    local switched, config_open = Gui.show_page(event.element, tags.bmsc_page)
    if config_open ~= nil then state().gui_config_open[event.player_index] = config_open end
    if switched and record then
      -- 收起参数栏时立刻显示本轮已有的输出快照。
      Gui.refresh_connection_status(
        player, record.entity, record.gui_output_networks, current_input_diagnostics(record), current_work_summary(record))
    end
    return
  end
  if event.element.name == "bmsc-order-target-close" then
    Gui.close_order_target(player, true)
    return
  end
  if event.element.name == "bmsc-order-target-auto-recipe" or tags.bmsc_order_target_recipe then
    local order_signal = signal_from_tags(tags)
    if record and order_signal then
      select_order_recipe(player, record, order_signal, tags.bmsc_order_count or 0,
        tags.bmsc_order_target_recipe or nil)
    end
    return
  end
  if tags.bmsc_order_target_product then
    local popup = player.gui.screen[Gui.order_target_name]
    local order_signal = popup and popup.valid and signal_from_tags(popup.tags)
    local product = signal_from_tags(tags)
    if not (record and order_signal and product) then return end
    local target = OrderTarget.resolve(
      record.entity.force, record.config.production_machine, order_signal, record.config)
    local clicked_key = Util.signal_key(product)
    local selected, clicked_selected = {}, false
    for _, current in ipairs(target.products) do
      if Util.signal_key(current) == clicked_key then
        clicked_selected = true
      else
        selected[#selected + 1] = current
      end
    end
    -- 零个库存条件会让订单无条件完成，因此最后一个选中项不能取消。
    if not clicked_selected then selected[#selected + 1] = product end
    if selected[1] then
      local entry = order_target_entry(record, target.source_key)
      entry.products = copy_products(selected)
      apply_order_target_change(player, record, order_signal, popup.tags.bmsc_order_count or 0)
    end
    return
  end
  if tags.bmsc_swap_operand and tags.bmsc_condition_set and record then
    local conditions = conditions_for(record, tags.bmsc_condition_set)
    local condition = conditions and conditions[tags.bmsc_swap_condition]
    local operand = condition and condition[tags.bmsc_swap_side]
    if operand then
      SignalPicker.open(player,
        {set_name = tags.bmsc_condition_set, condition = tags.bmsc_swap_condition,
          side = tags.bmsc_swap_side}, operand)
    end
    return
  end
  if tags.bmsc_swap_relation and tags.bmsc_condition_set and record then
    local conditions = conditions_for(record, tags.bmsc_condition_set)
    local condition = conditions and conditions[tags.bmsc_swap_relation]
    if condition then condition.relation = condition.relation == "and" and "or" or "and" end
    Gui.rebuild_conditions(event.element, tags.bmsc_condition_set, conditions)
    reset_condition_timer(record, tags.bmsc_condition_set)
    return
  end
  if tags.bmsc_swap_delete and tags.bmsc_condition_set and record then
    local conditions = conditions_for(record, tags.bmsc_condition_set)
    if conditions and #conditions > 1 then
      table.remove(conditions, tags.bmsc_swap_delete)
      Gui.rebuild_conditions(event.element, tags.bmsc_condition_set, conditions)
      reset_condition_timer(record, tags.bmsc_condition_set)
    end
    return
  end
  if tags.bmsc_signal_panel_icon then
    if event.shift and event.button == defines.mouse_button_type.left
      and tags.bmsc_signal_side == "input" and record
      and (((tags.bmsc_signal_source == "local-order" or tags.bmsc_signal_source == "network-order")
        and (record.config.mode == MODE_PRODUCTION_ORDER or record.config.mode == MODE_SUPERMARKET_ORDER))
        or (tags.bmsc_signal_source == "local-order" or tags.bmsc_signal_source == "local-stock")
          and record.config.mode == MODE_RECIPE_QUERY) then
      local order_signal = signal_from_tags(tags)
      if order_signal and Util.is_recipe_input(order_signal) then
        local network_task
        if tags.bmsc_signal_source == "network-order" then
          for _, task in ipairs(record.network_assignments or {}) do
            if task.key == record.network_active and Util.signal_key(task.signal) == tags.bmsc_signal_key then
              network_task = task.key
              break
            end
          end
          if not network_task then
            for _, task in ipairs(record.network_assignments or {}) do
              if Util.signal_key(task.signal) == tags.bmsc_signal_key then network_task = task.key; break end
            end
          end
        end
        open_order_target(player, record, order_signal, event.element.number or 0, network_task)
      end
    elseif event.button == defines.mouse_button_type.right and tags.bmsc_signal_side == "input"
      and tags.bmsc_signal_source == "local-order"
      and record and record.config.mode == MODE_SUPERMARKET_ORDER
      and MODES[MODE_SUPERMARKET_ORDER].defer_current_order(record, tags.bmsc_signal_key) then
      -- defer_current_order 已先清除旧输出选择，因此这次重算不会进入原料等待门。
      write_outputs(record, MODES[MODE_SUPERMARKET_ORDER].calculate(record))
      Gui.refresh_connection_status(
        player, record.entity, record.gui_output_networks, current_input_diagnostics(record), current_work_summary(record))
    elseif event.button == defines.mouse_button_type.left and not event.alt
      and not event.control and not event.shift and tags.bmsc_signal_side == "input"
      and tags.bmsc_signal_source == "local-order"
      and record and record.config.mode == MODE_SUPERMARKET_ORDER
      and signal_double_clicked(event.player_index, record, tags.bmsc_signal_key)
      and MODES[MODE_SUPERMARKET_ORDER].prioritize_waiting_order(record, tags.bmsc_signal_key) then
      -- 与右键后移一样立即重算，双击选中的等待订单不继承旧输出的原料等待。
      write_outputs(record, MODES[MODE_SUPERMARKET_ORDER].calculate(record))
      Gui.refresh_connection_status(
        player, record.entity, record.gui_output_networks, current_input_diagnostics(record), current_work_summary(record))
    elseif event.alt and event.button == defines.mouse_button_type.left then
      local prototype_group = tags.bmsc_signal_type == "fluid" and prototypes.fluid
        or tags.bmsc_signal_type == "virtual" and prototypes.virtual_signal
        or prototypes.item
      local prototype = prototype_group and prototype_group[tags.bmsc_signal_name]
      if prototype then player.open_factoriopedia_gui(prototype) end
    end
    return
  end

  if event.element.name == "bmsc-clear-order-memory" then
    if record then
      MODES[MODE_PRODUCTION_ORDER].reset(record)
      write_outputs(record, {})
    end
    return
  end
  if event.element.name == "bmsc-restart-sequence" then
    if record then
      MODES[MODE_SUPERMARKET_ORDER].restart_sequence(record)
      write_outputs(record, {})
    end
    return
  end
  if tags.bmsc_add_condition and tags.bmsc_condition_set and record then
    local conditions = conditions_for(record, tags.bmsc_condition_set)
    conditions[#conditions + 1] = {
      relation = "or", first = {red = true, green = true, constant = 0}, comparator = "<",
      second = {red = true, green = true, constant = 0}}
    Gui.rebuild_conditions(event.element, tags.bmsc_condition_set, conditions)
    reset_condition_timer(record, tags.bmsc_condition_set)
    return
  end
  if event.element.name == "bmsc-clear-swap" and record then
    MODES[MODE_SWAP_ORDER].clear(record)
    write_outputs(record, MODES[MODE_SWAP_ORDER].calculate(record))
    Gui.refresh_connection_status(
      player, record.entity, record.gui_output_networks, current_input_diagnostics(record), current_work_summary(record))
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

script.on_event(defines.events.on_gui_checked_state_changed, function(event)
  if NetworkGui.on_checked(event, state().combinators) then return end
  if event.element.name == "bmsc-sequential-production" then
    local record = current_record(event.player_index)
    if not record then return end
    record.config.sequential_production = event.element.state == true
    -- 顺序策略改变后，旧的单信号锁定可能属于已经被忽略的另一个订单。
    MODES[MODE_SUPERMARKET_ORDER].reset(record)
    MODES[MODE_SUPERMARKET_ORDER].invalidate_plan(record)
    Gui.set_sequence_restart_visible(event.element, record.config.sequential_production)
    return
  end
  if event.element.name == "bmsc-swap-loop" then
    local record = current_record(event.player_index)
    if record then
      record.config.swap_loop = event.element.state
      reset_swap_timer(record)
    end
    return
  end
  local tags = event.element.tags or {}
  if not (tags.bmsc_swap_condition and tags.bmsc_condition_set) then return end
  local record = current_record(event.player_index)
  local conditions = record and conditions_for(record, tags.bmsc_condition_set)
  local condition = conditions and conditions[tags.bmsc_swap_condition]
  local operand = condition and condition[tags.bmsc_swap_side]
  if operand and (tags.bmsc_swap_color == "red" or tags.bmsc_swap_color == "green") then
    operand[tags.bmsc_swap_color] = event.element.state
    reset_condition_timer(record, tags.bmsc_condition_set)
  end
end)

-- 蓝图和设置复制事件：保证配置能随蓝图以及 Shift+右键/左键复制。
script.on_event(defines.events.on_player_setup_blueprint, function(event)
  -- Ctrl+C 使用临时蓝图时 event.stack 可以为空；此时配置应写入可写 record，最后才回退
  -- 到玩家当前正在设置的蓝图栈。三者都提供相同的实体标签读写接口。
  local blueprint
  if event.stack and event.stack.valid_for_read and event.stack.is_blueprint then
    blueprint = event.stack
  elseif event.record and event.record.valid and event.record.type == "blueprint"
    and event.record.valid_for_write then
    blueprint = event.record
  else
    local player = game.get_player(event.player_index)
    local pending = player and player.blueprint_to_setup
    if pending and pending.valid_for_read and pending.is_blueprint then blueprint = pending end
  end
  if not blueprint then return end
  for number, entity in pairs(event.mapping.get()) do
    if entity.valid and entity.name == ENTITY then
      local record = state().combinators[entity.unit_number]
      if record then
        local tags = blueprint.get_blueprint_entity_tags(number) or {}
        tags.bmsc = normalize_runtime_config(record.config)
        blueprint.set_blueprint_entity_tags(number, tags)
      end
    end
  end
end)

local function apply_pasted_config(destination, source_config)
  if not (destination and source_config) then return end
  destination.config = normalize_runtime_config(source_config)
  sync_mode_visual(destination)
  reset_all_modes(destination)
  write_outputs(destination, {})
  -- 设置粘贴可以发生在目标窗口仍打开时；立即重建，避免界面继续显示旧参数。
  for player_index, unit in pairs(state().player_gui) do
    if unit == destination.entity.unit_number then
      local player = game.get_player(player_index)
      if player then
        Gui.open(player, destination.entity, destination.config, {}, nil,
          current_work_summary(destination), MODES[MODE_INVENTORY_QUERY].is_available(),
          state().gui_config_open[player.index] == true)
        state().player_gui[player_index] = unit
      end
    end
  end
end

script.on_event(defines.events.on_entity_settings_pasted, function(event)
  if event.destination.name ~= ENTITY then return end
  local destination = state().combinators[event.destination.unit_number]
  local source = event.source.name == ENTITY and state().combinators[event.source.unit_number]
  if destination and source then
    -- table.deepcopy 只在数据阶段（data.lua）由 Factorio 提供，运行阶段（control.lua）不存在。
    -- normalize_config 会创建一张全新的配置表，并逐项复制、校验来源配置，因此也能避免
    -- 两台运算器意外共用同一张 table；其效果等同于这里真正需要的“安全深拷贝”。
    apply_pasted_config(destination, source.config)
  end
end)

-- 把蓝图拖放到已经存在的实体上时不会触发建造事件，应直接应用蓝图携带的标签。
if defines.events.on_blueprint_settings_pasted then
  script.on_event(defines.events.on_blueprint_settings_pasted, function(event)
    local entity = event.entity
    if not (entity and entity.valid and entity.name == ENTITY and event.tags and event.tags.bmsc) then return end
    apply_pasted_config(state().combinators[entity.unit_number], event.tags.bmsc)
  end)
end

-- 运算间隔也是 30 时用同一个处理器顺序刷新，避免为同一周期重复注册。
script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name == "bmsc-production-network" then
    local player = game.get_player(event.player_index)
    local frame = player.gui.screen[NetworkGui.name]
    if frame then frame.destroy() else NetworkGui.open_network(player, state().combinators) end
  end
end)

if TICK_INTERVAL == 30 then
  script.on_nth_tick(30, function()
    update_all()
    refresh_open_timeout_displays()
  end)
else
  script.on_nth_tick(TICK_INTERVAL, update_all)
  script.on_nth_tick(30, refresh_open_timeout_displays)
end
