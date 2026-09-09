-- 运算模式注册表。
-- 新增模式时只需创建遵守 calculate/reset/save_state/restore_state 接口的模块，并在此登记。
-- 模块还可以声明 visual_parameters，以合法的原版参数组合选择屏幕符号；
-- 简单模式也可以只声明 visual_operation，由 control.lua 自动包装。

local production_order = require("scripts.modes.production_order")
local order_recursion = require("scripts.modes.order_recursion")
local recipe_query = require("scripts.modes.recipe_query")

return {
  [production_order.name] = production_order,
  [order_recursion.name] = order_recursion,
  [recipe_query.name] = recipe_query
}
