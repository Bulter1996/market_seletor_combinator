-- 市场选择运算器的主体图形配置。
--
-- 本模块只替换“看得见的身份素材”，并保留原版选择运算器已经校准好的四方向裁切坐标、
-- 锚点、阴影、工作灯和接线点。这样新外观不会影响碰撞、选中范围或线路连接位置。

local EntityGraphics = {}

local MOD_ROOT = "__market-selector-combinator__/"
local BODY = MOD_ROOT .. "graphics/entity/market-selector-combinator/market-selector-combinator.png"

---替换四方向动画中每个方向的主体层文件。
---为什么需要：原版 `make_4way_animation_from_spritesheet` 已经把横向四帧拆成 north/east/
---south/west，每个方向的第一层是实体主体，第二层是阴影。这里只换第一层的 filename，
---因此原版的 width、height、x、y、scale 和 shift 会原样保留。
---@param entity table 从原版 selector-combinator 深拷贝得到的实体原型。
---@return nil
function EntityGraphics.apply(entity)
  for _, direction in pairs({"north", "east", "south", "west"}) do
    local animation = entity.sprites and entity.sprites[direction]
    local body_layer = animation and animation.layers and animation.layers[1]
    if body_layer then
      body_layer.filename = BODY
    end
  end
end

return EntityGraphics
