-- 运算模式注册表。
-- 新增模式时只需创建遵守 calculate/reset/save_state/restore_state 接口的模块并在此登记；
-- 若模式缓存了受科技影响的配方数据，可额外实现可选的 invalidate_plan(record) 钩子。
-- 需要汇总多台实体状态的模式还可以实现 prepare(records)，在逐台 calculate 前统一执行。
-- 模块还可以声明 visual_parameters，以合法的原版参数组合选择屏幕符号；
-- 简单模式也可以只声明 visual_operation，由 control.lua 自动包装。

local production_order = require("scripts.modes.production_order")

local supermarket_order = require("scripts.modes.supermarket_order")
local recipe_query = require("scripts.modes.recipe_query")
local inventory_query = require("scripts.modes.inventory_query")
local swap_order = require("scripts.modes.swap_order")

return {
  [production_order.name] = production_order,
  [supermarket_order.name] = supermarket_order,
  [recipe_query.name] = recipe_query,
  [inventory_query.name] = inventory_query,
  [swap_order.name] = swap_order
}
