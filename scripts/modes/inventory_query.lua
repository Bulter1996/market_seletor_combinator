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

---取得查询模式的全局持久状态；每个势力永久复用一个探针。
---@return table state 包含 forces 映射。
local function state()
  if type(storage.bmsc_inventory_query) ~= "table" then storage.bmsc_inventory_query = {} end
  if type(storage.bmsc_inventory_query.forces) ~= "table" then
    storage.bmsc_inventory_query.forces = {}
  end
  return storage.bmsc_inventory_query
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
    if index > MAX_FILTERS then break end
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
    if index > MAX_FILTERS then break end
    signals[index] = by_key[key]
  end
  return signals, table.concat(keys, "|")
end

---取得或修复某势力的查询状态。
---@param force LuaForce 查询所属势力。
---@return table force_state 势力级探针、签名和结果缓存。
local function get_force_state(force)
  local forces = state().forces
  local force_state = forces[force.index]
  if type(force_state) ~= "table" or force_state.force_name ~= force.name then
    force_state = {force_name = force.name, results = {}}
    forces[force.index] = force_state
  end
  return force_state
end

---创建或恢复某势力永久复用的 share-network-output 探针。
---使用独立表面避免可见实体占用玩家地块；raise_built 负责让 LinkedChestAndPipe 登记脚本创建的实体。
---@param force LuaForce 探针所属势力。
---@param force_state table get_force_state 返回的状态。
---@return LuaEntity|nil probe 创建失败时返回 nil。
local function get_probe(force, force_state)
  local probe = force_state.probe
  if probe and probe.valid and probe.name == PROBE_NAME and probe.force == force then return probe end

  local surface = game.get_surface(PROBE_SURFACE) or game.create_surface(PROBE_SURFACE)
  for _, existing in pairs(surface.find_entities_filtered{name = PROBE_NAME, force = force}) do
    if existing.valid then probe = existing; break end
  end
  if not probe then
    probe = surface.create_entity{
      name = PROBE_NAME,
      position = {force.index * 2, 0},
      force = force,
      create_build_effect_smoke = false,
      raise_built = true
    }
  end
  if not probe then return nil end
  probe.destructible = false
  probe.minable_flag = false
  probe.operable = false
  force_state.probe = probe
  -- 新建或重新发现探针时必须重新写筛选条件，不能信任旧 storage 的签名。
  force_state.signature = nil
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
---@param force_state table 势力查询状态。
---@param signals table 待查询信号数组。
---@param signature string 查询集合签名。
---@return nil
local function configure_probe(force_state, signals, signature)
  local probe = force_state.probe
  local behavior = probe and probe.valid and probe.get_or_create_control_behavior()
  if not behavior then return end
  for section_index = behavior.sections_count, 2, -1 do behavior.remove_section(section_index) end
  local section = behavior.get_section(1) or behavior.add_section("")
  local filters = {}
  for index, signal in ipairs(signals) do
    local value = Util.make_signal(signal.type, signal.name, signal.quality)
    value.quality = Util.quality_name(signal.quality)
    value.comparator = "="
    filters[index] = {value = value, min = 0}
  end
  section.group = ""
  section.active = #filters > 0
  section.filters = filters
  behavior.enabled = #filters > 0
  force_state.signature = signature
  force_state.results = {}
  force_state.ready_tick = #filters > 0 and next_refresh_tick(probe) or nil
end

---禁用暂时没有查询运算器使用的探针，但保留实体供以后复用。
---@param force_state table 势力查询状态。
---@return nil
local function deactivate_probe(force_state)
  if force_state.signature == nil then return end
  configure_probe(force_state, {}, nil)
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
end

---在逐台 calculate 前汇总所有查询模式运算器，保证同一势力只需要一个共享探针。
---@param records table control.lua 的组合器记录集合。
---@return nil
function Mode.prepare(records)
  if not is_available() then return end
  local requests = {}
  for _, record in pairs(records or {}) do
    if record.entity and record.entity.valid and type(record.config) == "table"
      and record.config.mode == Mode.name then
      local query_type = record.config.query_type or Config.query_type.all
      local force = record.entity.force
      local request = requests[force.index]
      if not request then
        request = {force = force, signals = {}}
        requests[force.index] = request
      end
      if record.config.query_all then
        if query_type ~= Config.query_type.fluid then request.query_all_items = true end
        if query_type ~= Config.query_type.item then request.query_all_fluids = true end
      else
        add_record_inputs(request.signals, record, query_type)
      end
    end
  end

  for force_index, force_state in pairs(state().forces) do
    if not requests[force_index] then deactivate_probe(force_state) end
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
    local force_state = get_force_state(request.force)
    if #signals == 0 then
      deactivate_probe(force_state)
    else
      local probe = get_probe(request.force, force_state)
      if probe then
        if force_state.signature ~= signature then configure_probe(force_state, signals, signature) end
        refresh_results(force_state)
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

---输出共享区库存；query_all=false 时只保留符合查询类型且出现在输入中的信号。
---@param record table 组合器记录，必须包含 entity 和 config。
---@return table outputs 标准输出集合，由 control.lua 统一写入线路。
function Mode.calculate(record)
  if not is_available() then return {} end
  local force_state = state().forces[record.entity.force.index]
  if not (force_state and force_state.ready_tick and game.tick >= force_state.ready_tick) then return {} end

  local query_type = record.config.query_type or Config.query_type.all
  local outputs = {}
  if record.config.query_all then
    for key, entry in pairs(force_state.results or {}) do
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
    local result = force_state.results and force_state.results[key]
    if result and result.count ~= 0 then
      outputs[key] = {signal = Util.make_signal(signal.type, signal.name, signal.quality), count = result.count}
    end
  end
  return outputs
end

return Mode
