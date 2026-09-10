-- 市场选择运算器的模式屏幕素材。
--
-- 这个文件只负责“数据阶段”的图形原型配置，不包含任何运行时运算逻辑。
-- 将素材定义与 data.lua、具体模式算法分离后，新增模式时可以在这里单独登记外观，
-- 不需要修改生产订单或订单递归的计算代码。

local util = require("util")

local ModeSymbols = {}

-- 模组内部路径前缀必须与 info.json 的 name 完全一致。
local GRAPHICS_ROOT = "__market-selector-combinator__/graphics/mode-symbols/"

---读取一个与原版运算器显示区域相同尺寸的模式符号，并启用发光绘制。
---为什么需要：原版所有运算器的小屏幕符号都是 `30×22` 像素，实体原型再通过
---`scale=0.5` 将其显示为约 `15×11` 像素。素材周围保持透明，机器屏幕和外壳由实体
---主体负责绘制，因此不会出现额外面板覆盖原版屏幕的问题。
---@param filename string 相对于 graphics/mode-symbols 的 PNG 文件名。
---@param shift table 屏幕符号相对于实体中心的像素偏移，由 util.by_pixel 创建。
---@return table sprite 可赋给 Sprite4Way 某个朝向的 Sprite 定义。
local function mode_symbol(filename, shift)
  return util.draw_as_glow{
    filename = GRAPHICS_ROOT .. filename,
    width = 30,
    height = 22,
    scale = 0.5,
    shift = shift
  }
end

---构建选择运算器要求的四方向精灵表。
---为什么需要：Sprite4Way 必须分别声明 north/east/south/west。电子屏幕里的符号不需要
---随着机器旋转，因此四个方向读取同一张图，只沿用原版各方向不同的纵向锚点。
---@param filename string 单个 `30×22` 模式符号文件名。
---@return table sprites Factorio 原型可读取的 Sprite4Way。
local function four_way_symbol(filename)
  return {
    north = mode_symbol(filename, util.by_pixel(0, -4.5)),
    east = mode_symbol(filename, util.by_pixel(0, -10.5)),
    south = mode_symbol(filename, util.by_pixel(0, -4.5)),
    west = mode_symbol(filename, util.by_pixel(0, -10.5))
  }
end

---把自定义模式外观安装到复制出来的选择运算器原型。
---`count_symbol_sprites` 对应生产订单模式使用的 operation="count"；
---`max_symbol_sprites` 对应订单递归模式使用的最大值选择；`min_symbol_sprites` 则作为
---配方查询的独立显示槽位，使用蓝色的“?”素材。
---@param entity table 从原版 selector-combinator 深拷贝得到的实体原型。
---@return nil
function ModeSymbols.apply(entity)
  entity.count_symbol_sprites = four_way_symbol("production-order.png")
  entity.max_symbol_sprites = four_way_symbol("order-recursion.png")
  entity.min_symbol_sprites = four_way_symbol("recipe-query.png")
end

return ModeSymbols
