local style = require "core.style"
local common = require "core.common"
local View = require "core.view"

---@class plugins.lsp_copilot.paneldocview : core.view
local LabelView = View:extend()

function LabelView:new(text)
  LabelView.super.new(self)
  self.cursor = "arrow"
  self.scrollable = false
  self.text = text or ""
end

function LabelView:get_scrollable_size()
  local _, nlines = string.gsub(self.text, "\n", "\n")
  return style.padding.y * 2 + style.font:get_height() * (nlines + 1)
end

function LabelView:draw()
  self:draw_background(style.background2)
  local y = self.position.y
  local _, nlines = string.gsub(self.text, "\n", "\n")
  local yoff = self.size.y / (nlines + 1)
  for line in (self.text .. "\n"):gmatch("(.-)\n") do
    common.draw_text(style.font, style.text, line, "left",
      self.position.x + style.padding.x, y,
      self.size.x - style.padding.x, yoff)
    y = y + yoff
  end
end

return LabelView
