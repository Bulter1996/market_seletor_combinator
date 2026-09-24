-- 订单输入诊断的信号槽样式；只改变槽位底色，信号图标和线路来源保持原样。

local GuiStyles = {}
local GUI_ATLAS = "__core__/graphics/gui.png"

local function graphical_set(x, tint)
  return {
    border = 1,
    filename = GUI_ATLAS,
    position = {x, 0},
    size = 36,
    scale = 1,
    tint = tint
  }
end

local function diagnostic_slot(tint)
  return {
    type = "button_style",
    parent = "compact_slot",
    default_graphical_set = graphical_set(111, tint),
    hovered_graphical_set = graphical_set(148, tint),
    clicked_graphical_set = graphical_set(185, tint)
  }
end

---从原版 frame 样式复制背景图形，并把每个贴图统一降到指定不透明度。
---图形颜色使用预乘 alpha，因此 RGB 也必须同步乘以 opacity。
local function transparent_frame(source, opacity)
  local style = table.deepcopy(source)
  local function tint_sprites(value)
    if type(value) ~= "table" then return end
    -- 原版 GUI 图集图层多数只给 position，使用默认 tileset，并不带 filename。
    if value.filename or value.position then
      local tint = value.tint or {}
      local r, g, b, a = tint.r or tint[1] or 1, tint.g or tint[2] or 1, tint.b or tint[3] or 1, tint.a or tint[4] or 1
      value.tint = {r = r * opacity, g = g * opacity, b = b * opacity, a = a * opacity}
    end
    for _, child in pairs(value) do tint_sprites(child) end
  end
  tint_sprites(style)
  return style
end

function GuiStyles.apply()
  local styles = data.raw["gui-style"].default
  styles.bmsc_signal_diagnostic_filtered = diagnostic_slot({r = 1, g = 0.82, b = 0.12, a = 1})
  -- 库存已满足使用中性灰，避免琥珀色被误认为红线输入。
  styles.bmsc_signal_diagnostic_pending = diagnostic_slot({r = 0.58, g = 0.58, b = 0.58, a = 1})
  -- 红色专用于红线输入；不可用订单改用冷蓝色，避免混淆线路来源和诊断状态。
  styles.bmsc_signal_diagnostic_invalid = diagnostic_slot({r = 0.25, g = 0.65, b = 1, a = 1})
  -- 运行时设置只能切换样式名，因此在数据阶段预置可选透明度档位。
  for _, percent in ipairs({100, 80, 60, 40}) do
    styles["bmsc_policy_frame_" .. percent] = transparent_frame(styles.frame, percent / 100)
  end
end

return GuiStyles
