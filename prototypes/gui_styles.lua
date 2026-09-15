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

function GuiStyles.apply()
  local styles = data.raw["gui-style"].default
  styles.bmsc_signal_diagnostic_filtered = diagnostic_slot({r = 1, g = 0.82, b = 0.12, a = 1})
  -- 库存已满足使用中性灰，避免琥珀色被误认为红线输入。
  styles.bmsc_signal_diagnostic_pending = diagnostic_slot({r = 0.58, g = 0.58, b = 0.58, a = 1})
  -- 红色专用于红线输入；不可用订单改用冷蓝色，避免混淆线路来源和诊断状态。
  styles.bmsc_signal_diagnostic_invalid = diagnostic_slot({r = 0.25, g = 0.65, b = 1, a = 1})
end

return GuiStyles
