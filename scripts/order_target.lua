-- 生产订单与超市订单共用的根订单解析。
-- 本模块只处理“采用哪个配方、检查哪些产物、库存是否达标”，不读取线路、不管理队列或 GUI。

local Util = require("scripts.common_util")
local OrderTarget = {}

local function product_signal(product, quality)
  if not (product and product.name) then return nil end
  return Util.make_signal(product.type, product.name, product.type == "item" and quality or nil)
end

local function recipe_products(recipe, quality)
  local products, seen = {}, {}
  for _, product in pairs(recipe and recipe.products or {}) do
    local signal = product_signal(product, quality)
    local key = signal and Util.signal_key(signal)
    if key and not seen[key] then products[#products + 1], seen[key] = signal, true end
  end
  table.sort(products, function(a, b) return Util.signal_key(a) < Util.signal_key(b) end)
  return products
end

local function contains(products, wanted)
  local wanted_key = wanted and Util.signal_key(wanted)
  for _, product in ipairs(products) do
    if Util.signal_key(product) == wanted_key then return product end
  end
  return nil
end

local function default_product(order_signal, resolved_signal, recipe, products)
  -- 物品/流体订单明确表达了玩家想生产的目标，即使它不是配方主产物也应保持旧行为。
  if order_signal.type ~= "recipe" then
    local ordered = contains(products, resolved_signal)
    if ordered then return ordered end
  end
  local main = recipe and recipe.main_product
  local main_signal = main and product_signal(main, resolved_signal and resolved_signal.quality)
  return contains(products, main_signal) or products[1]
end

---解析一个输入信号实际采用的配方及库存校验产物。
---机器不兼容和科技未解锁都是可恢复状态；只有配方消失或不再产出目标时才清除配置。
---@param options table|nil ignore_research=true 时用于配方查询，不以科技锁定阻止手动配方。
---@return table target 包含 signal、recipe、products、source_key、manual_recipe。
function OrderTarget.resolve(force, machine_name, order_signal, config, options)
  options = options or {}
  local source_key = Util.signal_key(order_signal)
  local resolved_signal, explicit_recipe = Util.resolve_recipe_input(order_signal, machine_name)
  if not resolved_signal then return {source_key = source_key, products = {}, blocked = true} end

  local settings = type(config and config.order_targets) == "table" and config.order_targets[source_key] or nil
  local configured_recipe
  local requested_manual = order_signal.type ~= "recipe" and settings and type(settings.recipe) == "string"
  if requested_manual then
    configured_recipe = prototypes and prototypes.recipe and prototypes.recipe[settings.recipe]
    -- 模组更新造成的永久失效可以安全清除；机器和科技变化则保留，便于恢复。
    if not configured_recipe or Util.recipe_product_amount(configured_recipe, resolved_signal) <= 0 then
      settings.recipe, configured_recipe, requested_manual = nil, nil, false
    end
  end
  local automatic_recipe = options.ignore_research
    and Util.find_recipe_ignoring_research(resolved_signal, machine_name, explicit_recipe)
    or Util.find_recipe(force, resolved_signal, machine_name, explicit_recipe)
  local machine_supported = configured_recipe and Util.machine_supports(machine_name, configured_recipe) or false
  local force_recipe = configured_recipe and force and force.recipes and force.recipes[configured_recipe.name]
  local unlocked = force_recipe and force_recipe.enabled == true or false
  local explicit_force_recipe = explicit_recipe and force and force.recipes and force.recipes[explicit_recipe.name]
  local explicit_locked = explicit_recipe and not options.ignore_research
    and not (explicit_force_recipe and explicit_force_recipe.enabled)
  local locked = requested_manual and machine_supported and not options.ignore_research and not unlocked
    or explicit_locked
  local machine_unsupported = requested_manual and not machine_supported
  local recipe
  if not locked then
    recipe = configured_recipe and machine_supported and configured_recipe or automatic_recipe
  end
  -- 递归策略在机器、科技和库存检查后传入已选配方；产物条件必须随实际配方解析。
  if options.policy_recipe then
    recipe = prototypes.recipe[options.policy_recipe]
    locked = false
  end
  local manual_valid = recipe ~= nil and recipe == configured_recipe

  local quality = order_signal.type == "item" and Util.quality_name(order_signal.quality)
    or resolved_signal.type == "item" and Util.quality_name(resolved_signal.quality) or nil
  local product_recipe = recipe or configured_recipe or explicit_recipe
  local products = recipe_products(product_recipe, quality)
  if not products[1] then products[1] = Util.make_signal(
    resolved_signal.type, resolved_signal.name, resolved_signal.quality) end

  local selected, selected_keys = {}, {}
  for _, saved in ipairs(settings and settings.products or {}) do
    local saved_signal = Util.make_signal(saved.type, saved.name,
      saved.type == "item" and (quality or saved.quality) or nil)
    local current = contains(products, saved_signal)
    local key = current and Util.signal_key(current)
    if key and not selected_keys[key] then selected[#selected + 1], selected_keys[key] = current, true end
  end
  if not selected[1] then selected[1] = default_product(order_signal, resolved_signal, product_recipe, products) end

  if settings and not machine_unsupported then
    -- 当前机器无法制造时运行期会回退自动配方，但不能用回退配方覆盖玩家原配置。
    settings.products = {}
    for _, product in ipairs(selected) do
      settings.products[#settings.products + 1] = Util.make_signal(product.type, product.name, product.quality)
    end
  end

  local signature_parts = {recipe and recipe.name or "<none>",
    configured_recipe and configured_recipe.name or explicit_recipe and explicit_recipe.name or "<automatic>",
    locked and "locked" or "ready"}
  for _, product in ipairs(selected) do signature_parts[#signature_parts + 1] = Util.signal_key(product) end
  return {
    source_key = source_key,
    signal = Util.make_signal(resolved_signal.type, resolved_signal.name, resolved_signal.quality),
    recipe = recipe,
    products = selected,
    available_products = products,
    automatic_recipe = automatic_recipe,
    manual_recipe = manual_valid and recipe.name or nil,
    configured_recipe = configured_recipe and configured_recipe.name or nil,
    locked_recipe = locked and (configured_recipe or explicit_recipe).name or nil,
    machine_unsupported_recipe = machine_unsupported and configured_recipe.name or nil,
    blocked = locked,
    signature = table.concat(signature_parts, ",")
  }
end

---计算所有选中产物的 AND 库存条件和最大实时缺口。
---库存目标直接使用订单数量，不按配方产出比例换算；配方产量只留给各模式计算原料。
function OrderTarget.inventory_status(products, inventory, target)
  local details, maximum_shortage = {}, 0
  local satisfied = true
  for _, signal in ipairs(products or {}) do
    local stock = math.max(0, inventory[Util.signal_key(signal)] or 0)
    local shortage = math.max(0, math.ceil(target - stock))
    details[#details + 1] = {
      signal = Util.make_signal(signal.type, signal.name, signal.quality),
      target = math.ceil(target), stock = stock, remaining = shortage
    }
    maximum_shortage = math.max(maximum_shortage, shortage)
    if stock < target then satisfied = false end
  end
  return {satisfied = satisfied, remaining = maximum_shortage, products = details}
end

---返回当前机器支持的全部手动候选；其中可以包含尚未由当前势力解锁的配方。
---配方信号自身已经固定配方，不提供候选列表。
function OrderTarget.available_recipes(force, machine_name, order_signal, preferred_name)
  if order_signal.type == "recipe" then return {} end
  return Util.available_recipes(force, order_signal, machine_name, preferred_name)
end

return OrderTarget
