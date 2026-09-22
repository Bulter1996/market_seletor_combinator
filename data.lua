-- Market Selector Combinator - 数据定义文件
-- 这个文件定义了市场选择器组合器的实体、物品、配方和技术效果
-- 作者：Bulter
-- 版本：0.1.0

-- 自定义模式的屏幕符号配置独立放在 prototypes 中，避免图形定义与实体、配方耦合。
local ModeSymbols = require("prototypes.mode_symbols")
-- 主体外观也使用独立模块；data.lua 只负责组合各部分原型。
local EntityGraphics = require("prototypes.entity_graphics")
local GuiStyles = require("prototypes.gui_styles")

-- 诊断色只扩展 GUI 样式，不参与实体或模式计算。
GuiStyles.apply()

-- 背包、配方和实体信息界面共同使用的自定义图标。
-- 背包、配方与百科使用横向放大的专用图标；世界实体仍由 EntityGraphics 独立控制。
local ENTITY_ICON = "__market-selector-combinator__/graphics/icons/market-selector-combinator-horizontal.png"
data:extend({{
  type = "shortcut", name = "bmsc-production-network", action = "lua", style = "blue",
  icon = ENTITY_ICON, icon_size = 64, small_icon = ENTITY_ICON, small_icon_size = 64
}})

-- 复制选择器组合器的原型作为基础，然后修改为我们需要的实体
local entity = table.deepcopy(data.raw["selector-combinator"]["selector-combinator"])
-- 设置实体名称为市场选择器组合器
entity.name = "b-market-selector-combinator"
-- 设置可挖掘属性，挖掘时间为0.1秒，结果为市场选择器组合器
entity.minable = {mining_time = 0.1, result = "b-market-selector-combinator"}
-- 在游戏中的排序位置，c[combinators]表示组合器分类，d[b-market-selector-combinator]表示在组合器中的子排序
entity.order = "c[combinators]-d[b-market-selector-combinator]"
-- 可快速替换的组，与基础选择器组合器相同
entity.fast_replaceable_group = "selector-combinator"
-- 使用市场选择运算器自己的背包图标，与原版选择器区分。
entity.icon = ENTITY_ICON
entity.icon_size = 64
-- 替换地面主体；原版阴影、LED、锚点与接线坐标继续保留。
EntityGraphics.apply(entity)
-- 用我们的模式素材替换借用的原版 count/max 屏幕符号。
-- 具体模式通过运行时的 visual_operation 选择此处对应的符号。
ModeSymbols.apply(entity)

-- 定义市场选择器组合器的物品
local item = {
  -- 物品类型
  type = "item",
  -- 物品名称
  name = "b-market-selector-combinator",
  -- 自定义物品图标，同时用于背包、快捷栏及配方结果。
  icon = ENTITY_ICON,
  icon_size = 64,
  -- 物品所属子组：电路网络
  subgroup = "circuit-network",
  -- 在游戏中的排序位置
  order = "c[combinators]-d[b-market-selector-combinator]",
  -- 放置结果为市场选择器组合器
  place_result = "b-market-selector-combinator",
  -- 堆叠大小：50个
  stack_size = 50
}

-- 直接复制“判断运算器”配方，而不是在本模组中重复写死材料。这样基础游戏或其他模组
-- 调整 decider-combinator 的材料、制造时间、制造类别等字段后，本配方仍会保持一致。
-- base 2.1 必定提供该配方；保底分支仅用于开发期数据阶段热加载或异常测试环境。
local decider_recipe = data.raw.recipe["decider-combinator"]
local recipe = decider_recipe and table.deepcopy(decider_recipe) or {
  type = "recipe",
  enabled = false,
  ingredients = {
    {type = "item", name = "copper-cable", amount = 5},
    {type = "item", name = "electronic-circuit", amount = 5}
  }
}
recipe.name = "b-market-selector-combinator"
-- 只替换产物；ingredients、energy_required、category 和 enabled 等制造规则继承判断运算器。
recipe.results = {{type = "item", name = "b-market-selector-combinator", amount = 1}}
-- 清除旧式单产物字段和可能由其他模组写入的判断运算器专用图标，避免覆盖本物品图标。
recipe.result = nil
recipe.result_count = nil
recipe.main_product = "b-market-selector-combinator"
recipe.icon = ENTITY_ICON
recipe.icons = nil
recipe.icon_size = 64
recipe.localised_name = nil
recipe.localised_description = nil

-- 定义输出代理实体（隐藏实体，用于信号传递）
local proxy = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
-- 设置代理实体名称
proxy.name = "b-market-selector-output-proxy"
-- 隐藏实体：不在游戏中显示、不在百科中显示、不能被蓝图复制、不能被拆除
proxy.hidden = true
proxy.hidden_in_factoriopedia = true
proxy.flags = {
  "placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable", "hide-alt-info"
}
-- 不可在游戏中选中
proxy.selectable_in_game = false
-- 碰撞掩码为空，不与其他实体碰撞
proxy.collision_mask = {layers = {}}
-- 碰撞盒子大小为0，不占用空间
proxy.collision_box = {{0, 0}, {0, 0}}
-- 选择盒子大小为0，不可点击选择
proxy.selection_box = {{0, 0}, {0, 0}}
-- 查询全部可能同时输出大量物品品质与流体；使用运行时筛选索引允许的最大槽位数。
proxy.item_slot_count = 65535
-- 创建空白精灵图（因为实体是隐藏的，不需要图形）
local empty_sprite = {filename = "__core__/graphics/empty.png", size = 1}
proxy.sprites = {
  north = empty_sprite,
  east = empty_sprite,
  south = empty_sprite,
  west = empty_sprite
}
-- 不绘制电路连线
proxy.draw_circuit_wires = false
proxy.draw_copper_wires = false

-- 详细信息展示代理不连接线路，只借用常量运算器的 Alt 图标显示当前订单产品。
local detail_proxy = table.deepcopy(proxy)
detail_proxy.name = "b-market-selector-detail-proxy"
for index = #detail_proxy.flags, 1, -1 do
  if detail_proxy.flags[index] == "hide-alt-info" then table.remove(detail_proxy.flags, index) end
end

-- 将所有定义的数据扩展到游戏中：实体、物品、配方及两类代理
data:extend({entity, item, recipe, proxy, detail_proxy})

-- 不猜测科技原型名称，而是查找实际解锁“判断运算器”配方的科技。这样科技树被其他模组
-- 重排或重命名后，市场选择运算器仍与判断运算器同步解锁；若多个科技都提供该解锁，
-- 则逐一加入。插入前检查重复项，避免其他兼容补丁已经添加过相同效果。
for _, technology in pairs(data.raw.technology or {}) do
  local unlocks_decider = false
  local already_unlocks_market_selector = false
  for _, effect in pairs(technology.effects or {}) do
    if effect.type == "unlock-recipe" then
      if effect.recipe == "decider-combinator" then unlocks_decider = true end
      if effect.recipe == "b-market-selector-combinator" then already_unlocks_market_selector = true end
    end
  end
  if unlocks_decider and not already_unlocks_market_selector then
    technology.effects = technology.effects or {}
    technology.effects[#technology.effects + 1] = {
      type = "unlock-recipe",
      recipe = "b-market-selector-combinator"
    }
  end
end
