-- “配方查询”模式。
-- 红绿输入在本模式中地位相同：输入代表希望查询的产品，输出为制造这些产品所需的直接原料。

local Util = require("scripts.common_util")
local OrderTarget = require("scripts.order_target")
local Mode = {
  name = "recipe_query",                           -- 模式注册名，必须与 config.lua 的值一致。
  -- 使用最小值选择对应的独立素材槽位显示“?”，但把索引设为 int32 最大值。线路中的
  -- 信号种类不可能达到该索引，因此原版选择逻辑不会产生输出；真实查询仍由本模块完成。
  visual_parameters = {operation = "select", select_max = false, index_constant = 2147483647},
  visual_revision = 2                               -- 强制旧存档替换曾保存的 random/default select。
}

---配方查询没有锁定、记忆或超时状态，因此重置只需保持统一模式接口。
---@param record table control.lua 保存的组合器记录。
---@return nil
function Mode.reset(record)
end

---导出空状态，供 control.lua 统一保存各模式状态。
---@param record table 组合器记录。
---@return table state 空状态。
function Mode.save_state(record)
  return {}
end

---配方查询没有需要恢复的运行状态。
---@param record table 新建的组合器记录。
---@param saved table|nil 兼容统一接口的旧状态参数。
---@return nil
function Mode.restore_state(record, saved)
end

---把一份配方按指定制造次数累加到输出。
---@param outputs table 标准输出集合。
---@param recipe LuaRecipePrototype 已选中的配方。
---@param crafts integer 需要制造的完整次数。
---@return nil
local function add_recipe_ingredients(outputs, recipe, crafts)
  for _, ingredient in pairs(recipe.ingredients) do
    local signal = Util.make_signal(ingredient.type, ingredient.name, "normal")
    Util.add_output(outputs, signal, ingredient.amount * crafts)
  end
end

---执行配方查询。
---关闭多配方支持时，只查询排序后的第一个有效输入并输出一份配方原料；开启后会合并
---红绿线路的全部正数输入，并依据每种产品的输入数量向上取整到完整制造次数后汇总原料。
---@param record table 组合器记录，必须包含 entity 和 config。
---@return table outputs 标准输出集合，由 control.lua 统一写入线路。
function Mode.calculate(record)
  local queries = {}
  local connector_ids = {
    defines.wire_connector_id.combinator_input_red,
    defines.wire_connector_id.combinator_input_green
  }
  -- 不区分线路颜色；同一信号同时出现在红绿网络时，其数量会相加后再参与计算。
  for _, connector_id in ipairs(connector_ids) do
    local _, signals = Util.read_network(record.entity, connector_id)
    for _, entry in pairs(signals) do
      if Util.is_recipe_input(entry.signal) and entry.count > 0 then
        Util.add_output(queries, entry.signal, entry.count)
      end
    end
  end

  local outputs = {}
  local sorted_queries = Util.sorted_outputs(queries)
  if not record.config.multiple_recipe_support then
    local first = sorted_queries[1]
    if not first then return outputs end
    local target = OrderTarget.resolve(record.entity.force, record.config.production_machine,
      first.entry.signal, record.config, {ignore_research = true})
    local recipe = target.recipe
    if recipe then add_recipe_ingredients(outputs, recipe, 1) end
    return outputs
  end

  local requirements, by_recipe = {}, {}
  for _, query in ipairs(sorted_queries) do
    local target = OrderTarget.resolve(record.entity.force, record.config.production_machine,
      query.entry.signal, record.config, {ignore_research = true})
    local signal, recipe = target.signal, target.recipe
    if recipe then
      local product_amount = Util.recipe_product_amount(recipe, signal)
      if product_amount > 0 then
        local crafts = math.ceil(query.entry.count / product_amount)
        local requirement = by_recipe[recipe.name]
        if requirement then
          -- 同一配方的多个产物由同一批制造同时满足，取最大制作次数而不是重复累计。
          requirement.crafts = math.max(requirement.crafts, crafts)
        else
          requirement = {recipe = recipe, crafts = crafts}
          by_recipe[recipe.name], requirements[#requirements + 1] = requirement, requirement
        end
      end
    end
  end
  return Util.limit_recipe_materials_by_cache(
    requirements, record.config.recipe_query_cache_grid_number or 0)
end

return Mode
