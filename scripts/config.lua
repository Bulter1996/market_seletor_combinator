-- 市场选择运算器的配置定义与校验模块。
-- 所有模式共用同一份配置入口，新增模式时只需在这里补充默认值和合法值校验。

local Config = {}

Config.mode = {
  production_order = "production_order",
  order_recursion = "order_recursion"
}

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
    mode = Config.mode.production_order,          -- 参数：当前操作模式。
    production_machine = "assembling-machine-1", -- 参数：两个模式查询配方时使用的制造机。
    additional_production_rate = 1,              -- 参数：生产订单的产品库存停止倍率。
    material_demand_rate = 10,                   -- 参数：生产订单启动所需原料倍率。
    material_retention_rate = 1,                 -- 参数：生产订单运行后的原料停止倍率。
    remember_order = true,                       -- 参数：是否记住已启动但从绿线消失的订单。
    production_timeout = 0,                     -- 参数：生产订单库存无变化时的轮换秒数；0 表示禁用。
    output_mode = "all",                         -- 参数：生产订单输出产品、原料或两者。
    recurise_depth = 0,                          -- 参数：订单递归最大深度；0 表示不限制。
    recursion_output_mode = "single",            -- 参数：订单递归输出单项或全部结果。
    recursion_timeout = 0                        -- 参数：single 无变化轮换秒数；0 表示禁用。
  }
end

---校验蓝图、设置复制或旧存档提供的配置。
---未知字段会被忽略，缺失字段使用默认值，数值参数被限制为非负数。
---@param source table|nil 外部配置。
---@return table config 可安全交给模式模块使用的新配置表。
function Config.normalize(source)
  local config = Config.default()
  if type(source) ~= "table" then return config end
  if source.mode == Config.mode.production_order or source.mode == Config.mode.order_recursion then
    config.mode = source.mode
  end
  if type(source.production_machine) == "string" then config.production_machine = source.production_machine end
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
  if source.output_mode == "only_item" or source.output_mode == "only_material" or source.output_mode == "all" then
    config.output_mode = source.output_mode
  end
  if type(source.recurise_depth) == "number" then
    config.recurise_depth = math.max(0, math.floor(source.recurise_depth))
  end
  if source.recursion_output_mode == "single" or source.recursion_output_mode == "all" then
    config.recursion_output_mode = source.recursion_output_mode
  end
  if type(source.recursion_timeout) == "number" then
    config.recursion_timeout = math.max(0, source.recursion_timeout)
  end
  return config
end

return Config
