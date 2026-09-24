-- “查询模式”：通过 LinkedChestAndPipe 的 share-network-output 读取共享区库存。
-- 本模块不访问另一个模组的 storage；它只使用对方公开给游戏世界的实体行为，避免与内部表结构耦合。

local Util = require("scripts.common_util")
local Config = require("scripts.config")
local Mode = {
  name = "inventory_query",                       -- 模式注册名，必须与 config.lua 的值一致。
  -- 借用已清空默认输出的时间屏幕槽，仅显示带蓝色遮罩的铁箱图标。
  visual_operation = "time",
  visual_revision = 3
}

local REQUIRED_MOD = "LinkedChestAndPipe"
local PROBE_NAME = "share-network-output"
local PROBE_SURFACE = "__market-selector-combinator-query__"
local SURFACE_SIGNAL = "signal-linked-storage-surface"
local MAX_FILTERS = 65535                          -- Factorio LogisticFilterIndex 的 uint16 上限。
local all_query_signals = {}                      -- 原型在一次运行中不变，物品和流体列表分别只构建一次。

---判断信号是否符合当前查询类型。
---@param signal SignalID|nil 待检查信号。
---@param query_type string `fluid`、`item` 或 `all`。
---@return boolean matched 符合限制时为 true。
local function matches_query_type(signal, query_type)
  local signal_type = signal and (signal.type or "item")
  return query_type == Config.query_type.all or signal_type == query_type
end

---判断当前模组组合是否具备共享区查询实体。
---同时检查 active_mods 和实体原型，兼容开发期只重载运行脚本的情况。
---@return boolean available 可用时为 true。
local function is_available()
  return script.active_mods[REQUIRED_MOD] ~= nil and prototypes.entity[PROBE_NAME] ~= nil
end

---判断关联箱是否支持按目标地表查询；旧版本自动退回势力级协议。
local function supports_surface_query()
  return prototypes.virtual_signal and prototypes.virtual_signal[SURFACE_SIGNAL] ~= nil
end

---供超市订单和 GUI 判断关联库存能力是否可用。
---@return boolean available 可用时为 true。
function Mode.is_available()
  return is_available()
end

---取得查询模式的全局持久状态；新版按势力和地表复用探针，旧协议按势力复用。
---@return table state 包含 scopes 映射。
local function state()
  if type(storage.bmsc_inventory_query) ~= "table" then storage.bmsc_inventory_query = {} end
  local root = storage.bmsc_inventory_query
  if root.schema_version ~= 2 then
    -- 旧状态没有地表语义，不能安全继承其结果缓存；实体下次查询时重新创建。
    for _, force_state in pairs(type(root.forces) == "table" and root.forces or {}) do
      if force_state.probe and force_state.probe.valid then force_state.probe.destroy() end
    end
    root.forces = nil
    root.scopes = {}
    root.schema_version = 2
  end
  if type(root.scopes) ~= "table" then root.scopes = {} end
  return root
end

---把信号加入按 SignalID 去重的集合。
---@param signals table 目标集合。
---@param signal SignalID|nil 输入信号。
---@param query_type string 查询类型限制。
---@return nil
local function add_query_signal(signals, signal, query_type)
  -- 库存查询只需要配方产物，不应受其他模式的生产机器配置限制。
  local product_signal = Util.resolve_recipe_input(signal)
  if not product_signal or not matches_query_type(product_signal, query_type) then return end
  local safe_signal = Util.make_signal(product_signal.type, product_signal.name, product_signal.quality)
  signals[Util.signal_key(safe_signal)] = safe_signal
end

---收集一台运算器两色输入中的物品和流体种类；输入数量只用于让信号出现在网络中，不参与查询。
---@param signals table 势力级查询信号集合。
---@param record table 组合器记录。
---@param query_type string 查询类型限制。
---@return nil
local function add_record_inputs(signals, record, query_type)
  for _, connector_id in ipairs({
    defines.wire_connector_id.combinator_input_red,
    defines.wire_connector_id.combinator_input_green
  }) do
    local _, entries = Util.read_network(record.entity, connector_id)
    for _, entry in pairs(entries) do
      add_query_signal(signals, entry.signal, query_type)
    end
  end
end

---收集超市订单配方树实际涉及的产品、原料和库存校验副产品。
---只提交这些信号，不使用查询全部，避免为自动库存校验扫描所有原型。
---@param plan table|nil 超市订单缓存的纯数据配方树。
---@return table signals 按 signal_key 去重的定向查询集合。
function Mode.supermarket_signals(plan)
  local signals = {}
  local function visit(node)
    if not (node and node.signal) then return end
    add_query_signal(signals, node.signal, Config.query_type.all)
    for _, child in ipairs(node.children or {}) do visit(child) end
  end
  for _, root in ipairs(type(plan) == "table" and plan.roots or {}) do
    visit(root)
    for _, product in ipairs(root.validation_products or {}) do
      add_query_signal(signals, product, Config.query_type.all)
    end
  end
  return signals
end

---构建查询全部时需要交给 LinkedChestAndPipe 的完整单类信号表。
---@param query_type string `item` 或 `fluid`。
---@return table signals 按 SignalID 稳定排序的数组。
local function get_all_query_signals(query_type)
  if all_query_signals[query_type] then return all_query_signals[query_type] end
  local by_key = {}
  if query_type == Config.query_type.item then
    for item_name in pairs(prototypes.item) do
      for quality_name in pairs(prototypes.quality) do
        add_query_signal(by_key, {type = "item", name = item_name, quality = quality_name}, query_type)
      end
    end
  elseif query_type == Config.query_type.fluid then
    for fluid_name in pairs(prototypes.fluid) do
      add_query_signal(by_key, {type = "fluid", name = fluid_name}, query_type)
    end
  end
  local keys = {}
  for key in pairs(by_key) do keys[#keys + 1] = key end
  table.sort(keys)
  local signals = {}
  for index, key in ipairs(keys) do
    if index > MAX_FILTERS - (supports_surface_query() and 1 or 0) then break end
    signals[index] = by_key[key]
  end
  all_query_signals[query_type] = signals
  return signals
end

---把信号数组合并进按 SignalID 去重的集合。
---@param target table 目标集合。
---@param source table 信号数组。
---@return nil
local function merge_signals(target, source)
  for _, signal in ipairs(source) do target[Util.signal_key(signal)] = signal end
end

---把去重集合转换为稳定数组，并用同一顺序生成变更签名。
---@param by_key table 按 signal_key 保存的信号。
---@return table signals 信号数组。
---@return string signature 查询集合签名。
local function sorted_query_signals(by_key)
  local keys = {}
  for key in pairs(by_key) do keys[#keys + 1] = key end
  table.sort(keys)
  local signals = {}
  for index, key in ipairs(keys) do
    if index > MAX_FILTERS - (supports_surface_query() and 1 or 0) then break end
    signals[index] = by_key[key]
  end
  return signals, table.concat(keys, "|")
end

---生成查询作用域键；旧协议没有地表能力，因此仍按势力合并。
---@param force LuaForce 查询所属势力。
---@param surface LuaSurface 查询目标地表。
local function scope_key(force, surface)
  if supports_surface_query() then return force.index .. ":" .. surface.index end
  return tostring(force.index)
end

---取得或修复一个查询作用域的状态。
---@param force LuaForce 查询所属势力。
---@param surface LuaSurface 查询目标地表。
local function get_scope_state(force, surface)
  local scopes = state().scopes
  local key = scope_key(force, surface)
  local scope_state = scopes[key]
  local surface_index = supports_surface_query() and surface.index or nil
  if type(scope_state) ~= "table" or scope_state.force_name ~= force.name
    or scope_state.surface_index ~= surface_index then
    scope_state = {force_name = force.name, surface_index = surface_index, results = {}}
    scopes[key] = scope_state
  end
  return scope_state
end

---创建或恢复某势力永久复用的 share-network-output 探针。
---使用独立表面避免可见实体占用玩家地块；raise_built 负责让 LinkedChestAndPipe 登记脚本创建的实体。
---@param force LuaForce 探针所属势力。
---@param surface LuaSurface 查询目标地表。
---@param scope_state table get_scope_state 返回的状态。
---@return LuaEntity|nil probe 创建失败时返回 nil。
local function get_probe(force, surface, scope_state)
  local probe = scope_state.probe
  if probe and probe.valid and probe.name == PROBE_NAME and probe.force == force then return probe end

  local probe_surface = game.get_surface(PROBE_SURFACE) or game.create_surface(PROBE_SURFACE)
  local position = {force.index * 2, supports_surface_query() and surface.index * 2 or 0}
  for _, existing in pairs(probe_surface.find_entities_filtered{
    name = PROBE_NAME, force = force, position = position
  }) do
    if existing.valid then probe = existing; break end
  end
  if not probe then
    probe = probe_surface.create_entity{
      name = PROBE_NAME,
      position = position,
      force = force,
      create_build_effect_smoke = false,
      raise_built = true
    }
  end
  if not probe then return nil end
  probe.destructible = false
  probe.minable_flag = false
  probe.operable = false
  scope_state.probe = probe
  -- 新建或重新发现探针时必须重新写筛选条件，不能信任旧 storage 的签名。
  scope_state.signature = nil
  return probe
end

---计算 LinkedChestAndPipe 下一次处理该探针后可以安全读取结果的 tick。
---对方每 12 tick 处理一个 unit_number 余数桶，十个桶构成约 120 tick 的完整刷新周期。
---@param probe LuaEntity 已登记的查询探针。
---@return uint ready_tick 结果最早可读 tick。
local function next_refresh_tick(probe)
  local cycle = math.floor(game.tick / 12) + 1
  local bucket = probe.unit_number % 10
  cycle = cycle + ((bucket - cycle % 10) % 10)
  return cycle * 12 + 1
end

---把新的查询集合写入探针；变更后先清空结果，避免输出上一批信号对应的旧库存。
---@param scope_state table 查询作用域状态。
---@param surface LuaSurface 查询目标地表。
---@param signals table 待查询信号数组。
---@param signature string 查询集合签名。
---@return nil
local function configure_probe(scope_state, surface, signals, signature)
  local probe = scope_state.probe
  local behavior = probe and probe.valid and probe.get_or_create_control_behavior()
  if not behavior then return end
  for section_index = behavior.sections_count, 2, -1 do behavior.remove_section(section_index) end
  local section = behavior.get_section(1) or behavior.add_section("")
  local filters = {}
  local offset = 0
  if #signals > 0 and supports_surface_query() then
    filters[1] = {value = {type = "virtual", name = SURFACE_SIGNAL, comparator = "="}, min = surface.index}
    offset = 1
  end
  for index, signal in ipairs(signals) do
    local value = Util.make_signal(signal.type, signal.name, signal.quality)
    value.quality = Util.quality_name(signal.quality)
    value.comparator = "="
    filters[index + offset] = {value = value, min = 0}
  end
  section.group = ""
  section.active = #filters > 0
  section.filters = filters
  behavior.enabled = #filters > 0
  scope_state.signature = signature
  scope_state.results = {}
  scope_state.requested = {}
  for _, signal in ipairs(signals) do scope_state.requested[Util.signal_key(signal)] = true end
  scope_state.has_results = false
  scope_state.ready_tick = #filters > 0 and next_refresh_tick(probe) or nil
end

---禁用暂时没有查询运算器使用的探针，但保留实体供以后复用。
---@param force_state table 势力查询状态。
---@return nil
local function deactivate_probe(scope_state)
  if scope_state.signature == nil then return end
  configure_probe(scope_state, nil, {}, nil)
end

---读取 LinkedChestAndPipe 已写回 filter.min 的库存值。
---@param force_state table 势力查询状态。
---@return nil
local function refresh_results(force_state)
  if not force_state.ready_tick or game.tick < force_state.ready_tick then return end
  local probe = force_state.probe
  local behavior = probe and probe.valid and probe.get_or_create_control_behavior()
  local section = behavior and behavior.get_section(1)
  if not section then return end
  local results = {}
  for _, filter in pairs(section.filters) do
    local signal = filter.value
    if Util.is_recipe_signal(signal) then
      local safe_signal = Util.make_signal(signal.type, signal.name, signal.quality)
      results[Util.signal_key(safe_signal)] = {signal = safe_signal, count = filter.min or 0}
    end
  end
  force_state.results = results
  force_state.has_results = true
  force_state.generation = (force_state.generation or 0) + 1
  -- 每个探针桶约 120 tick 才会再次产生独立快照；同一缓存不能重复算作新结果。
  force_state.ready_tick = next_refresh_tick(probe)
end

---在逐台 calculate 前汇总所有查询模式运算器，保证同一势力只需要一个共享探针。
---@param records table control.lua 的组合器记录集合。
---@return nil
function Mode.prepare(records)
  if not is_available() then return end
  local requests = {}
  for _, record in pairs(records or {}) do
    if record.entity and record.entity.valid and type(record.config) == "table" then
      local query_type = record.config.query_type or Config.query_type.all
      local force = record.entity.force
      local surface = record.entity.surface
      local query_record = record.config.mode == Mode.name
      local linked_supermarket = record.config.mode == Config.mode.supermarket_order
        and record.config.inventory_validation == Config.inventory_validation.linked
      if query_record or linked_supermarket then
        local key = scope_key(force, surface)
        local request = requests[key]
        if not request then
          request = {force = force, surface = surface, signals = {}}
          requests[key] = request
        end
        if query_record and record.config.query_all then
          if query_type ~= Config.query_type.fluid then request.query_all_items = true end
          if query_type ~= Config.query_type.item then request.query_all_fluids = true end
        elseif query_record then
          add_record_inputs(request.signals, record, query_type)
        elseif record.supermarket_order_plan then
          for key, signal in pairs(Mode.supermarket_signals(record.supermarket_order_plan)) do
            request.signals[key] = signal
          end
        end
        if linked_supermarket then
          for _, task in ipairs(record.network_assignments or {}) do
            local plan = task.execution and task.execution.supermarket_order_plan
            if plan then
              for key, signal in pairs(Mode.supermarket_signals(plan)) do request.signals[key] = signal end
            end
          end
        end
      end
    end
  end

  for key, scope_state in pairs(state().scopes) do
    if scope_state.surface_index and not game.get_surface(scope_state.surface_index) then
      if scope_state.probe and scope_state.probe.valid then scope_state.probe.destroy() end
      state().scopes[key] = nil
    elseif not requests[key] then
      deactivate_probe(scope_state)
    end
  end

  for _, request in pairs(requests) do
    -- “查询全部”仍按每台组合器的查询类型扩展；同势力的条件最后合并到一个探针。
    if request.query_all_items then
      merge_signals(request.signals, get_all_query_signals(Config.query_type.item))
    end
    if request.query_all_fluids then
      merge_signals(request.signals, get_all_query_signals(Config.query_type.fluid))
    end
    local signals, signature = sorted_query_signals(request.signals)
    local scope_state = get_scope_state(request.force, request.surface)
    if #signals == 0 then
      deactivate_probe(scope_state)
    else
      local probe = get_probe(request.force, request.surface, scope_state)
      if probe then
        if scope_state.signature ~= signature or type(scope_state.requested) ~= "table" then
          configure_probe(scope_state, request.surface, signals, signature)
        end
        refresh_results(scope_state)
      end
    end
  end
end

---查询模式没有单台运算器独享的缓存；势力探针由 prepare 统一维护。
---@param record table 组合器记录。
---@return nil
function Mode.reset(record)
end

---导出空状态，势力探针本身已经直接保存在 storage 中。
---@param record table 组合器记录。
---@return table state 空状态。
function Mode.save_state(record)
  return {}
end

---查询模式没有需要随单台运算器重建而恢复的状态。
---@param record table 组合器记录。
---@param saved table|nil 兼容统一模式接口。
---@return nil
function Mode.restore_state(record, saved)
end

---读取一张超市订单配方树对应的共享库存快照。
---查询集合尚未包含全部信号或首份结果未返回时返回 nil，调用方据此保持/暂停输出。
---@param force LuaForce 查询所属势力。
---@param surface LuaSurface 查询目标地表。
---@param requested table supermarket_signals 返回的信号集合。
---@return table|nil inventory 以 signal_key 为键的数量表。
---@return uint|nil generation 独立探针快照编号。
function Mode.get_shared_inventory(force, surface, requested)
  if not is_available() then return nil end
  local scope_state = state().scopes[scope_key(force, surface)]
  if not (scope_state and scope_state.has_results) then return nil end
  for key in pairs(requested or {}) do
    if not (scope_state.requested and scope_state.requested[key]) then return nil end
  end
  local inventory = {}
  for key in pairs(requested or {}) do
    local result = scope_state.results and scope_state.results[key]
    inventory[key] = result and result.count or 0
  end
  return inventory, scope_state.generation
end

---输出共享区库存；query_all=false 时只保留符合查询类型且出现在输入中的信号。
---@param record table 组合器记录，必须包含 entity 和 config。
---@return table outputs 标准输出集合，由 control.lua 统一写入线路。
function Mode.calculate(record)
  if not is_available() then return {} end
  local scope_state = state().scopes[scope_key(record.entity.force, record.entity.surface)]
  if not (scope_state and scope_state.has_results) then return {} end

  local query_type = record.config.query_type or Config.query_type.all
  local outputs = {}
  if record.config.query_all then
    for key, entry in pairs(scope_state.results or {}) do
      if entry.count ~= 0 and matches_query_type(entry.signal, query_type) then
        outputs[key] = {signal = Util.make_signal(entry.signal.type, entry.signal.name, entry.signal.quality),
          count = entry.count}
      end
    end
    return outputs
  end

  local requested = {}
  add_record_inputs(requested, record, query_type)
  for key, signal in pairs(requested) do
    local result = scope_state.results and scope_state.results[key]
    if result and result.count ~= 0 then
      outputs[key] = {signal = Util.make_signal(signal.type, signal.name, signal.quality), count = result.count}
    end
  end
  return outputs
end

return Mode
