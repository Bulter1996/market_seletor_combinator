-- 市场选择运算器的配置定义与校验模块。
-- 所有模式共用同一份配置入口，新增模式时只需在这里补充默认值和合法值校验。

local Config = {}
Config.schema_revision = 5

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

-- 旧版存档和蓝图使用的模式值；只用于迁移，规范化后统一写为 supermarket_order。
local LEGACY_ORDER_RECURSION = "order_recursion"

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
    multiple_recipe_support = false,              -- 参数：配方查询是否统计全部输入信号及其数量。
    query_type = Config.query_type.all,            -- 参数：共享库存查询包含流体、物品或两者。
    query_all = false,                            -- 参数：查询模式是否输出共享区的全部非零库存。
    additional_production_rate = 1,              -- 参数：生产订单的产品库存停止倍率。
    material_demand_rate = 10,                   -- 参数：生产订单启动所需原料倍率。
    material_retention_rate = 1,                 -- 参数：生产订单运行后的原料停止倍率。
    remember_order = true,                       -- 参数：是否记住已启动但从绿线消失的订单。
    production_timeout = 0,                     -- 参数：生产订单库存无变化时的轮换秒数；0 表示禁用。
    production_timeout_reset_signal = nil,      -- 参数：绿线中为正数时重置生产订单超时。
    output_mode = "all",                         -- 参数：生产订单输出产品、原料或两者。
    cache_grid_number = 0,                      -- 参数：分离模式可占用的固体原料格数；0 表示不限制。
    recurise_depth = 0,                          -- 参数：超市订单最大递归深度；0 表示不限制。
    recursion_output_mode = "single",            -- 参数：超市订单输出单项或全部结果。
    sequential_production = true,                -- 参数：single 模式是否按订单顺序逐个完成。
    recursion_timeout = 0,                       -- 参数：single 无变化轮换秒数；0 表示禁用。
    recursion_timeout_reset_signal = nil,        -- 参数：绿线中为正数时重置超市订单超时。
    swap_output_mode = "fluid",                 -- 参数：切换订单输出的信号类型。
    swap_timeout = 0,                            -- 参数：条件持续满足多久后切换排列；0 表示直通。
    swap_conditions = {{                         -- 参数：切换计时条件；relation 表示与前一条的关系。
      relation = "or",
      first = {red = true, green = true, constant = 0},
      comparator = "<",
      second = {red = true, green = true, constant = 0}
    }}
  }
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
  if type(source.multiple_recipe_support) == "boolean" then
    config.multiple_recipe_support = source.multiple_recipe_support
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
  config.production_timeout_reset_signal = Config.normalize_signal(source.production_timeout_reset_signal)
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
  if source.recursion_output_mode == "single" or source.recursion_output_mode == "all" then
    config.recursion_output_mode = source.recursion_output_mode
  end
  if type(source.sequential_production) == "boolean" then
    config.sequential_production = source.sequential_production
  end
  if type(source.recursion_timeout) == "number" then
    config.recursion_timeout = math.max(0, source.recursion_timeout)
  end
  config.recursion_timeout_reset_signal = Config.normalize_signal(source.recursion_timeout_reset_signal)
  if source.swap_output_mode == "fluid" or source.swap_output_mode == "item"
    or source.swap_output_mode == "all" or source.swap_output_mode == "all_with_signals" then
    config.swap_output_mode = source.swap_output_mode
  end
  if type(source.swap_timeout) == "number" then config.swap_timeout = math.max(0, source.swap_timeout) end
  if type(source.swap_conditions) == "table" then
    config.swap_conditions = {}
    for _, condition in ipairs(source.swap_conditions) do
      if type(condition) == "table" then
        local first = type(condition.first) == "table" and condition.first or {}
        local second = type(condition.second) == "table" and condition.second or {}
        local comparators = {['<']=true, ['>']=true, ['=']=true, ['<=']=true, ['>=']=true, ['~=']=true}
        config.swap_conditions[#config.swap_conditions + 1] = {
          relation = condition.relation == "and" and "and" or "or",
          first = {signal = type(first.signal) == "table" and first.signal or nil,
            red = first.red ~= false, green = first.green ~= false,
            constant = tonumber(first.constant) or 0},
          comparator = comparators[condition.comparator] and condition.comparator or "<",
          second = {signal = type(second.signal) == "table" and second.signal or nil,
            red = second.red ~= false, green = second.green ~= false,
            constant = tonumber(second.constant) or 0}
        }
      end
    end
    if #config.swap_conditions == 0 then config.swap_conditions = Config.default().swap_conditions end
  end
  return config
end

return Config
