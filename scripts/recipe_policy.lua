-- 配方策略是用户配置；当前选中配方是运行状态，二者不能互相覆盖。
local Util = require("scripts.common_util")
local Policy = {}

function Policy.rates(config, entry)
  return entry and entry.demand or config.recursion_material_demand_rate or 1,
    entry and entry.retention or config.recursion_material_retention_rate or 0
end

function Policy.ready(recipe, inventory, rate)
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    local signal = Util.make_signal(ingredient.type, ingredient.name, "normal")
    if (inventory[Util.signal_key(signal)] or 0) <= ingredient.amount * rate then return false end
  end
  return true
end

function Policy.legal(record, recipe, signal)
  if not recipe or not Util.machine_supports(record.config.production_machine, recipe)
    or Util.recipe_product_amount(recipe, signal) <= 0 then return false end
  local unlocked = record.entity.force.recipes[recipe.name]
  if not (unlocked and unlocked.enabled) then return false end
  for _, conditions in ipairs({prototypes.entity[record.config.production_machine].surface_conditions or {},
    recipe.surface_conditions or {}}) do
    for _, condition in pairs(conditions) do
      local surface = record.entity.surface
      local value = surface and surface.get_property and surface.get_property(condition.property)
      if value == nil or condition.min and value < condition.min or condition.max and value > condition.max then
        return false
      end
    end
  end
  return true
end

function Policy.choose(record, signal, inventory, fallback)
  local key = Util.signal_key(signal)
  local candidates = record.config.recipe_policies and record.config.recipe_policies[key]
  if not candidates or not candidates[1] then return fallback end
  local ordered = {}
  for _, entry in ipairs(candidates) do ordered[#ordered + 1] = entry end
  table.sort(ordered, function(a, b)
    if a.priority ~= b.priority then return a.priority > b.priority end
    return a.recipe < b.recipe
  end)
  local first, first_entry
  for _, entry in ipairs(ordered) do
    local recipe = prototypes.recipe[entry.recipe]
    if Policy.legal(record, recipe, signal) then
      first, first_entry = first or recipe, first_entry or entry
      local demand, retention = Policy.rates(record.config, entry)
      if record.selected_recursion_output == Util.signal_key(Util.make_signal("recipe", recipe.name))
        and Policy.ready(recipe, inventory, retention) then return recipe, entry end
    end
  end
  for _, entry in ipairs(ordered) do
    local recipe = prototypes.recipe[entry.recipe]
    if Policy.legal(record, recipe, signal) and Policy.ready(recipe, inventory, Policy.rates(record.config, entry)) then
      return recipe, entry
    end
  end
  -- 没有可启动候选时仍展开首选的材料，才能生成补料请求。
  return first, first_entry
end

return Policy
