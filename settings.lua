-- 市场选择运算器的启动设置。
-- 启动设置会在进入存档前确定，适合控制所有运算器共用的更新频率。

data:extend({
  {
    type = "int-setting",
    name = "bmsc-update-interval",
    setting_type = "startup",
    default_value = 30, -- 参数：默认每 30 tick 刷新一次；游戏每秒运行 60 tick。
    minimum_value = 1, -- 参数：至少每 tick 刷新一次，避免 on_nth_tick 收到无效的 0。
    maximum_value = 3600,
    order = "a[update-interval]"
  }
})
