-- Market Selector Combinator - 数据定义文件
-- 这个文件定义了市场选择器组合器的实体、物品、配方和技术效果
-- 作者：Bulter
-- 版本：0.1.0

-- 自定义模式的屏幕符号配置独立放在 prototypes 中，避免图形定义与实体、配方耦合。
local ModeSymbols = require("prototypes.mode_symbols")
-- 主体外观也使用独立模块；data.lua 只负责组合各部分原型。
local EntityGraphics = require("prototypes.entity_graphics")

-- 背包、配方和实体信息界面共同使用的自定义图标。
local ENTITY_ICON = "__market-selector-combinator__/graphics/icons/market-selector-combinator.png"

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

-- 定义市场选择器组合器的配方
local recipe = {
  -- 配方类型
  type = "recipe",
  -- 配方名称
  name = "b-market-selector-combinator",
  -- 默认禁用，需要技术解锁
  enabled = false,
  -- 配方所需材料
  ingredients = {
    -- 电子电路：5个
    {type = "item", name = "electronic-circuit", amount = 5},
    -- 高级电路：2个
    {type = "item", name = "advanced-circuit", amount = 2}
  },
  -- 配方结果：1个市场选择器组合器
  results = {{type = "item", name = "b-market-selector-combinator", amount = 1}}
}

-- 定义输出代理实体（隐藏实体，用于信号传递）
local proxy = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
-- 设置代理实体名称
proxy.name = "b-market-selector-output-proxy"
-- 隐藏实体：不在游戏中显示、不在百科中显示、不能被蓝图复制、不能被拆除
proxy.hidden = true
proxy.hidden_in_factoriopedia = true
proxy.flags = {"placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable"}
-- 不可在游戏中选中
proxy.selectable_in_game = false
-- 碰撞掩码为空，不与其他实体碰撞
proxy.collision_mask = {layers = {}}
-- 碰撞盒子大小为0，不占用空间
proxy.collision_box = {{0, 0}, {0, 0}}
-- 选择盒子大小为0，不可点击选择
proxy.selection_box = {{0, 0}, {0, 0}}
-- 设置100个物品槽位（用于存储信号）
proxy.item_slot_count = 100
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

-- 将所有定义的数据扩展到游戏中：实体、物品、配方、代理
data:extend({entity, item, recipe, proxy})

-- 为相关技术添加解锁效果
-- 遍历电路网络和高级组合器技术
for _, technology_name in pairs({"circuit-network", "advanced-combinators"}) do
  -- 获取技术原型
  local technology = data.raw.technology[technology_name]
  -- 如果技术存在，添加解锁效果
  if technology then
    -- 确保技术效果表存在
    technology.effects = technology.effects or {}
    -- 添加解锁配方的效果
    table.insert(technology.effects, {type = "unlock-recipe", recipe = "b-market-selector-combinator"})
    -- 找到一个技术后即可停止（避免重复添加）
    break
  end
end
