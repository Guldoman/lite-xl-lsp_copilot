local core = require "core"
local style = require "core.style"
local config = require "core.config"
local View = require "core.view"

---@class plugins.lsp_copilot.verticalpanelview : core.view
local VerticalPanelView = View:extend()

VerticalPanelView.context = "session"

function VerticalPanelView:new()
  VerticalPanelView.super.new(self)
  self.cursor = "arrow"
  self.scrollable = true

  self.views = {}
end

function VerticalPanelView:get_name()
  return "Panel"
end

local function make_closable(fn)
  return setmetatable({}, {__close = fn})
end

function VerticalPanelView:get_scrollable_size()
  local total = 0
  -- Disable config.scroll_past_end for embedded DocViews, otherwise they'd grow infinitely
  local past_end = config.scroll_past_end
  local restore_past_end <close> = make_closable(function() config.scroll_past_end = past_end end)
  config.scroll_past_end = false
  for _, v in ipairs(self.views) do
    total = total + v:get_scrollable_size() + style.padding.y
  end
  return total
end

function VerticalPanelView:add_view(view)
  table.insert(self.views, view)
end

function VerticalPanelView:on_mouse_moved(x, y, ...)
  self.cursor = "arrow"
  if VerticalPanelView.super.on_mouse_moved(self, x, y, ...) then
    return true
  end
  for _, v in ipairs(self.views) do
    if v.position.y <= y and v.position.y + v.size.y > y then
      v:on_mouse_moved(x, y, ...)
      self.cursor = v.cursor
      break
    end
  end
end

function VerticalPanelView:on_mouse_pressed(button, x, y, ...)
  self.cursor = "arrow"
  if VerticalPanelView.super.on_mouse_pressed(self, button, x, y, ...) then
    return true
  end
  for _, v in ipairs(self.views) do
    if v.position.y <= y and v.position.y + v.size.y > y then
      core.set_active_view(v)
      v:on_mouse_pressed(button, x, y, ...)
      self.cursor = v.cursor
      break
    end
  end
end

function VerticalPanelView:on_mouse_released(button, x, y, ...)
  self.cursor = "arrow"
  if VerticalPanelView.super.on_mouse_released(self, button, x, y, ...) then
    return true
  end
  for _, v in ipairs(self.views) do
    if v.position.y <= y and v.position.y + v.size.y > y then
      v:on_mouse_released(button, x, y, ...)
      self.cursor = v.cursor
      break
    end
  end
end

function VerticalPanelView:update()
  local y = self.position.y - self.scroll.y + style.padding.y
  local past_end = config.scroll_past_end
  config.scroll_past_end = false
  for _, v in ipairs(self.views) do
    v.size = { x = self.size.x, y = v:get_scrollable_size() }
    v.position = { x = self.position.x, y = y }
    y = y + v.size.y + style.padding.y
    v:update()
  end
  config.scroll_past_end = past_end
  VerticalPanelView.super.update(self)
end

function VerticalPanelView:draw()
  self:draw_background(style.background2)
  for _, v in ipairs(self.views) do
    v:draw()
  end
  VerticalPanelView.super.draw(self)
  self:draw_scrollbar()
end

return VerticalPanelView
