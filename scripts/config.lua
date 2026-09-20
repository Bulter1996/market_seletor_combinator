-- 市场选择运算器的配置定义与校验模块。
-- 所有模式共用同一份配置入口，新增模式时只需在这里补充默认值和合法值校验。

local Config = {}
Config.schema_revision = 15

Config.mode = {
  production_order = "production_order",
  supermarket_order = "supermarket_order",
  recipe_query = "recipe_query",
  inventory_query = "inventory_query",
  swap_order = "swap_order"
}

Config.query_type = {
  fluid = "fluid",
  item = "item",
  all = "all"
}

Config.inventory_validation = {
  inventory = "inventory",
  linked = "linked",
  none = "none"
}

-- 旧版存档和蓝图使用的模式值；只用于迁移，规范化后统一写为 supermarket_order。
local LEGACY_ORDER_RECURSION = "order_recursion"

local function default_conditions()
  return {{relation = "or", first = {red = true, green = true, constant = 0}, comparator = "<",
    second = {red = true, green = true, constant = 0}}}
end

---复制每个输入信号的共享手动配方和订单模式使用的库存校验产物。
---这里只接受纯 Lua 数据；原型是否仍存在由运行阶段按当前模组、机器和科技重新判断。
local function normalize_order_targets(source)
  local targets = {}
  for source_key, entry in pairs(type(source) == "table" and source or {}) do
    if type(source_key) == "string" and type(entry) == "table" then
      local products, seen = {}, {}
      for _, product in ipairs(type(entry.products) == "table" and entry.products or {}) do
        local signal = Config.normalize_signal(product)
        if signal and (signal.type == "item" or signal.type == "fluid") then
          local key = signal.type .. ":" .. signal.name
            .. (signal.type == "item" and ":" .. (signal.quality or "normal") or "")
          if not seen[key] then products[#products + 1], seen[key] = signal, true end
        end
      end
      local recipe = type(entry.recipe) == "string" and entry.recipe or nil
      if recipe or products[1] then targets[source_key] = {recipe = recipe, products = products} end
    end
  end
  return targets
end

---把 GUI、蓝图或旧存档中的信号配置收敛为可持久化的 SignalID。
---@param signal table|nil 外部信号值。
---@return table|nil normalized 仅保留 type、name 和字符串品质。
function Config.normalize_signal(signal)
  if type(signal) ~= "table" or type(signal.name) ~= "string"
    or (signal.type ~= nil and type(signal.type) ~= "string") then
    return nil
  end
  local normalized = {type = signal.type or "item", name = signal.name}
  local quality_type = type(signal.quality)
  local quality = quality_type == "string" and signal.quality
    or (quality_type == "table" or quality_type == "userdata") and signal.quality.name
  if type(quality) == "string" then normalized.quality = quality end
  return normalized
end

---判断材料启动倍率和停止倍率是否构成有效的迟滞区间。
---只有“启动阈值 > 停止阈值”时，机器才可能先启动、再在较低库存处停止。
---@param demand_rate number 材料需求倍率（启动阈值）。
---@param retention_rate number 原料保留倍率（停止阈值）。
---@return boolean valid true 表示参数关系合法。
function Config.material_rates_valid(demand_rate, retention_rate)
  return type(demand_rate) == "number" and type(retention_rate) == "number"
    and demand_rate > retention_rate
end

---创建互不共享引用的默认配置。
---为什么需要：Lua table 是引用类型，每个实体必须拥有自己的配置表。
---@return table config 新配置。
function Config.default()
  return {
    schema_revision = Config.schema_revision,          -- 内部字段：用于识别热加载遗留的旧配置。
    mode = Config.mode.supermarket_order,          -- 参数：当前操作模式。
    production_machine = "assembling-machine-1", -- 参数：各模式查询配方时使用的制造机。
    order_targets = {},                          -- 参数：输入信号共享配方，以及订单模式的库存校验产物。
    multiple_recipe_support = false,              -- 参数：配方查询是否统计全部输入信号及其数量。
    recipe_query_cache_grid_number = 0,           -- 参数：多配方查询可占用的原料缓存格数。
    query_type = Config.query_type.all,            -- 参数：共享库存查询包含流体、物品或两者。
    query_all = false,                            -- 参数：查询模式是否输出共享区的全部非零库存。
    additional_production_rate = 1,              -- 参数：生产订单的产品库存停止倍率。
    material_demand_rate = 10,                   -- 参数：生产订单启动所需原料倍率。
    material_retention_rate = 1,                 -- 参数：生产订单运行后的原料停止倍率。
    remember_order = true,                       -- 参数：是否记住已启动但从绿线消失的订单。
    production_timeout = 0,                     -- 参数：生产订单库存无变化时的轮换秒数；0 表示禁用。
    production_timeout_monitor_item_changes = true, -- 参数：产品输出数量变化时是否重置生产超时。
    production_timeout_conditions = default_conditions(), -- 参数：满足时重置生产订单超时。
    output_mode = "all",                         -- 参数：生产订单输出产品、原料或两者。
    cache_grid_number = 0,                      -- 参数：分离模式可占用的固体原料格数；0 表示不限制。
    recurise_depth = 0,                          -- 参数：超市订单最大递归深度；0 表示不限制。
    recursion_additional_production_rate = 1,    -- 参数：超市订单成品目标的额外生产倍率。
    recursion_material_demand_rate = 10,         -- 参数：超市订单切入上层配方的原料启动倍率。
    recursion_material_retention_rate = 1,       -- 参数：超市订单当前配方的原料保留倍率。
    recursion_output_mode = "single",            -- 参数：超市订单输出单项或全部结果。
    inventory_validation = Config.inventory_validation.none, -- 参数：超市订单使用的库存校验来源。
    sequential_production = true,                -- 参数：single 模式是否按订单顺序逐个完成。
    recursion_material_wait_time = 0,            -- 参数：single 当前输出被撤销或切换前的保持秒数。
    recursion_timeout = 0,                       -- 参数：single 无变化轮换秒数；0 表示禁用。
    recursion_timeout_monitor_item_changes = true, -- 参数：当前输出数量变化时是否重置超市超时。
    recursion_timeout_conditions = default_conditions(),  -- 参数：满足时重置超市订单超时。
    swap_output_mode = "fluid",                 -- 参数：切换订单输出的信号类型。
    swap_timeout = 0,                            -- 参数：重置条件不满足多久后交换红绿输出；0 表示禁用。
    swap_loop = false,                           -- 参数：首次交换后是否继续在红绿输出间往返。
    swap_conditions = default_conditions()       -- 参数：满足时重置交换计时；relation 表示与前一条的关系。
  }
end

---复制并校验一组线路条件，保证蓝图和设置粘贴得到独立的纯 Lua 数据。
local function normalize_conditions(source)
  local conditions = {}
  for _, condition in ipairs(type(source) == "table" and source or {}) do
    if type(condition) == "table" then
      local first = type(condition.first) == "table" and condition.first or {}
      local second = type(condition.second) == "table" and condition.second or {}
      local comparators = {['<']=true, ['>']=true, ['=']=true, ['<=']=true, ['>=']=true, ['~=']=true}
      conditions[#conditions + 1] = {
        relation = condition.relation == "and" and "and" or "or",
        first = {signal = Config.normalize_signal(first.signal), red = first.red ~= false,
          green = first.green ~= false, constant = tonumber(first.constant) or 0},
        comparator = comparators[condition.comparator] and condition.comparator or "<",
        second = {signal = Config.normalize_signal(second.signal), red = second.red ~= false,
          green = second.green ~= false, constant = tonumber(second.constant) or 0}
      }
    end
  end
  return #conditions > 0 and conditions or default_conditions()
end

---把旧版“绿色信号 > 0”迁移成等价的通用条件。
local function legacy_reset_conditions(signal)
  signal = Config.normalize_signal(signal)
  if not signal then return nil end
  return {{relation = "or", first = {signal = signal, red = false, green = true}, comparator = ">",
    second = {red = true, green = true, constant = 0}}}
end

---校验蓝图、设置复制或旧存档提供的配置。
---未知字段会被忽略，缺失字段使用默认值，数值参数被限制为非负数。
---@param source table|nil 外部配置。
---@return table config 可安全交给模式模块使用的新配置表。
function Config.normalize(source)
  local config = Config.default()
  if type(source) ~= "table" then return config end
  if source.mode == Config.mode.production_order or source.mode == Config.mode.supermarket_order
    or source.mode == Config.mode.recipe_query or source.mode == Config.mode.inventory_query
    or source.mode == Config.mode.swap_order then
    config.mode = source.mode
  elseif source.mode == LEGACY_ORDER_RECURSION then
    config.mode = Config.mode.supermarket_order
  end
  if type(source.production_machine) == "string" then config.production_machine = source.production_machine end
  config.order_targets = normalize_order_targets(source.order_targets)
  if type(source.multiple_recipe_support) == "boolean" then
    config.multiple_recipe_support = source.multiple_recipe_support
  end
  if type(source.recipe_query_cache_grid_number) == "number" then
    config.recipe_query_cache_grid_number = math.max(0, math.floor(source.recipe_query_cache_grid_number))
  end
  if source.query_type == Config.query_type.fluid or source.query_type == Config.query_type.item
    or source.query_type == Config.query_type.all then
    config.query_type = source.query_type
  end
  if type(source.query_all) == "boolean" then config.query_all = source.query_all end
  if type(source.additional_production_rate) == "number" then
    config.additional_production_rate = math.max(0, source.additional_production_rate)
  end
  if type(source.material_demand_rate) == "number" then
    config.material_demand_rate = math.max(0, source.material_demand_rate)
  end
  if type(source.material_retention_rate) == "number" then
    config.material_retention_rate = math.max(0, source.material_retention_rate)
  end
  -- 旧存档、蓝图和设置复制都可能带入相等或倒置的阈值；在统一配置入口修正，
  -- 保证模式计算层永远接收到“需求 > 保留”的有效迟滞区间。
  if not Config.material_rates_valid(config.material_demand_rate, config.material_retention_rate) then
    config.material_demand_rate = config.material_retention_rate + 1
  end
  if type(source.remember_order) == "boolean" then config.remember_order = source.remember_order end
  if type(source.production_timeout) == "number" then
    config.production_timeout = math.max(0, source.production_timeout)
  end
  if type(source.production_timeout_monitor_item_changes) == "boolean" then
    config.production_timeout_monitor_item_changes = source.production_timeout_monitor_item_changes
  end
  config.production_timeout_conditions = normalize_conditions(source.production_timeout_conditions
    or legacy_reset_conditions(source.production_timeout_reset_signal))
  if source.output_mode == "only_item" or source.output_mode == "only_material" or source.output_mode == "all"
    or source.output_mode == "all_separate_signal" then
    config.output_mode = source.output_mode
  end
  if type(source.cache_grid_number) == "number" then
    config.cache_grid_number = math.max(0, math.floor(source.cache_grid_number))
  end
  if type(source.recurise_depth) == "number" then
    config.recurise_depth = math.max(0, math.floor(source.recurise_depth))
  end
  if type(source.recursion_additional_production_rate) == "number" then
    config.recursion_additional_production_rate = math.max(0, source.recursion_additional_production_rate)
  end
  if type(source.recursion_material_demand_rate) == "number" then
    config.recursion_material_demand_rate = math.max(0, source.recursion_material_demand_rate)
  end
  if type(source.recursion_material_retention_rate) == "number" then
    config.recursion_material_retention_rate = math.max(0, source.recursion_material_retention_rate)
  end
  if not Config.material_rates_valid(
    config.recursion_material_demand_rate, config.recursion_material_retention_rate) then
    config.recursion_material_demand_rate = config.recursion_material_retention_rate + 1
  end
  if source.recursion_output_mode == "single" or source.recursion_output_mode == "all" then
    config.recursion_output_mode = source.recursion_output_mode
  end
  if source.inventory_validation == Config.inventory_validation.inventory
    or source.inventory_validation == Config.inventory_validation.linked
    or source.inventory_validation == Config.inventory_validation.none then
    config.inventory_validation = source.inventory_validation
  elseif type(source.recursion_strict_validation) == "boolean" then
    -- 旧布尔开关迁移：勾选沿用库存校验，未勾选采用新的直接输出语义。
    config.inventory_validation = source.recursion_strict_validation
      and Config.inventory_validation.inventory or Config.inventory_validation.none
  end
  if type(source.sequential_production) == "boolean" then
    config.sequential_production = source.sequential_production
  end
  if type(source.recursion_material_wait_time) == "number" then
    config.recursion_material_wait_time = math.max(0, source.recursion_material_wait_time)
  end
  if type(source.recursion_timeout) == "number" then
    config.recursion_timeout = math.max(0, source.recursion_timeout)
  end
  if type(source.recursion_timeout_monitor_item_changes) == "boolean" then
    config.recursion_timeout_monitor_item_changes = source.recursion_timeout_monitor_item_changes
  end
  config.recursion_timeout_conditions = normalize_conditions(source.recursion_timeout_conditions
    or legacy_reset_conditions(source.recursion_timeout_reset_signal))
  if source.swap_output_mode == "fluid" or source.swap_output_mode == "item"
    or source.swap_output_mode == "all" or source.swap_output_mode == "all_with_signals" then
    config.swap_output_mode = source.swap_output_mode
  end
  if type(source.swap_timeout) == "number" then config.swap_timeout = math.max(0, source.swap_timeout) end
  if type(source.swap_loop) == "boolean" then config.swap_loop = source.swap_loop end
  config.swap_conditions = normalize_conditions(source.swap_conditions)
  return config
end

return Config
