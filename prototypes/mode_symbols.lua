-- 市场选择运算器的模式屏幕素材。
--
-- 这个文件只负责“数据阶段”的图形原型配置，不包含任何运行时运算逻辑。
-- 将素材定义与 data.lua、具体模式算法分离后，新增模式时可以在这里单独登记外观，
-- 不需要修改生产订单或超市订单的计算代码。

local util = require("util")

local ModeSymbols = {}

-- 模组内部路径前缀必须与 info.json 的 name 完全一致。
local GRAPHICS_ROOT = "__market-selector-combinator__/graphics/mode-symbols/"
local BASE_DISPLAY = "__base__/graphics/entity/combinator/combinator-displays.png"

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

---读取 Factorio 原版组合器显示图集中的空白灰色网格屏幕。
---图集左上角的第一个 30×22 区块不含运算符号，正好可作为自定义模式的统一底层。
---@return table sprites Factorio 原版空白屏幕的 Sprite4Way。
local function four_way_base_screen()
  local function screen(shift)
    return util.draw_as_glow{
      filename = BASE_DISPLAY,
      x = 0,
      y = 0,
      width = 30,
      height = 22,
      scale = 0.5,
      shift = shift
    }
  end
  return {
    north = screen(util.by_pixel(0, -4.5)),
    east = screen(util.by_pixel(0, -10.5)),
    south = screen(util.by_pixel(0, -4.5)),
    west = screen(util.by_pixel(0, -10.5))
  }
end

---在 Factorio 原版空白屏幕上叠加自定义图标。
---@param background table 原版空白网格的 Sprite4Way。
---@param foreground table 自定义透明图标的 Sprite4Way。
---@return table sprites 合并后的 Sprite4Way。
local function overlay_four_way(background, foreground)
  local result = {}
  for _, direction in ipairs({"north", "east", "south", "west"}) do
    result[direction] = {
      layers = {
        table.deepcopy(background[direction]),
        foreground[direction]
      }
    }
  end
  return result
end

---把原版 signal-X 虚拟信号缩放到小屏幕中央，并染成与其他自定义模式一致的蓝色。
local function four_way_cross_signal()
  local signal = data.raw["virtual-signal"]["signal-X"]
  local function sprite(shift)
    return util.draw_as_glow{
      filename = signal.icon,
      size = signal.icon_size or 64,
      scale = 0.18,
      shift = shift,
      tint = {r = 0.15, g = 0.85, b = 1, a = 1}
    }
  end
  return {
    north = sprite(util.by_pixel(0, -4.5)), east = sprite(util.by_pixel(0, -10.5)),
    south = sprite(util.by_pixel(0, -4.5)), west = sprite(util.by_pixel(0, -10.5))
  }
end

---把原版铁箱图标缩放到小屏幕中央，并添加蓝色遮罩。
local function four_way_inventory_chest()
  local function sprite(shift)
    return util.draw_as_glow{
      filename = "__base__/graphics/icons/iron-chest.png",
      size = 64,
      scale = 0.17,
      shift = shift,
      tint = {r = 0.25, g = 0.7, b = 1, a = 1}
    }
  end
  return {
    north = sprite(util.by_pixel(0, -4.5)), east = sprite(util.by_pixel(0, -10.5)),
    south = sprite(util.by_pixel(0, -4.5)), west = sprite(util.by_pixel(0, -10.5))
  }
end

---把自定义模式外观安装到复制出来的选择运算器原型。
---`count_symbol_sprites` 对应生产订单模式使用的 operation="count"；
---`max_symbol_sprites` 对应超市订单模式使用的最大值选择；`min_symbol_sprites` 供
---配方查询显示“?”，`time_symbol_sprites` 供共享库存查询显示蓝色铁箱。
---@param entity table 从原版 selector-combinator 深拷贝得到的实体原型。
---@return nil
function ModeSymbols.apply(entity)
  entity.count_symbol_sprites = four_way_symbol("production-order.png")
  entity.max_symbol_sprites = overlay_four_way(
    four_way_base_screen(), four_way_symbol("supermarket-order.png"))
  entity.min_symbol_sprites = four_way_symbol("recipe-query.png")
  entity.random_symbol_sprites = overlay_four_way(four_way_base_screen(), four_way_cross_signal())
  entity.time_symbol_sprites = overlay_four_way(four_way_base_screen(), four_way_inventory_chest())
  -- 查询模式只借用时间操作的显示槽；清空默认信号，从源头禁止原版时间输出。
  entity.default_game_tick_output_signal = nil
  entity.default_day_tick_output_signal = nil
  entity.default_day_length_output_signal = nil
end

return ModeSymbols
