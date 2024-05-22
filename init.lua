-- mod-version:3

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"

local Doc = require "core.doc"
local DocView = require "core.docview"

local autocomplete = require "plugins.autocomplete"

local Timer = require "plugins.lsp.timer"
local util = require "plugins.lsp.util"
local Server = require "plugins.lsp.server"

local lsp = require "plugins.lsp"
local nodejs = require "libraries.nodejs"

local VerticalPanelView = require "plugins.lsp_copilot.verticalpanelview"
local LabelView = require "plugins.lsp_copilot.labelview"

local installed_path = USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "lsp_copilot" .. PATHSEP .. "copilot.vim-1.25.1" .. PATHSEP .. "dist" .. PATHSEP .. "agent.js"

local copilot = {}

local logged_in = false
local initialized = false

local last_panel_id = 0
---@type table<string, plugins.lsp_copilot.verticalpanelview>
local panel_views = setmetatable({}, {__mode = "v"})
---@type table<plugins.lsp_copilot.verticalpanelview, table>
local panels = setmetatable({}, {__mode = "k"})

local function _check_status(result)
  logged_in = false
  if result and result.status == "OK" then
    logged_in = true
  end
end

function copilot.check_status(server, callback)
  -- {["result"]={["status"]="NotSignedIn"},["jsonrpc"]="2.0",["id"]=2}
  -- {["result"]={["user"]="User Name",["status"]="OK"},["jsonrpc"]="2.0",["id"]=4}
  server:push_request("checkStatus", {
    params = {},
    overwrite = true,
    callback = function(_, response)
      _check_status(response.result)
      callback(response.result)
    end
  })
end

local function update_panel_texts(panel_view)
  local panel = panels[panel_view]

  while #panel_view.views < #panel.completions * 2 or #panel_view.views < 1 do
    local v
    if #panel_view.views % 2 == 0 then
      v = LabelView()
    else
      v = DocView(Doc(nil, nil, true))
      v.doc.syntax = panel.syntax
    end
    panel_view:add_view(v)
  end

  if panel.done and #panel.completions == 0 then
    if panel.done == "OK" then
      panel_view.views[1].text = string.format("No solutions available.", panel.error_message)
    else
      panel_view.views[1].text = string.format("No solutions loaded: %s", panel.error_message)
    end
    return
  end

  for i, c in ipairs(panel.completions) do
    local l_idx = i * 2 - 1
    local c_idx = i * 2
    local label = panel_view.views[l_idx]
    local dv = panel_view.views[c_idx]

    local text = ""
    if l_idx == 1 then
      if panel.done then
        text = string.format("Loaded all solutions: %s.\n\n", panel.done)
      else
        text = string.format("Loading solutions %d/%d...\n\n", #panel.completions, panel.target)
      end
    end
    local score_text = ""
    if c.score > 0 then
      score_text = string.format(" - Score %f", c.score)
    end
    label.text = string.format("%sSolution %d%s:", text, i, score_text)

    if not dv then break end
    dv.doc:set_selection(0, 0, math.huge, math.huge)
    dv.doc:text_input(c.completionText)
    dv.copilot_response = c
    dv.copilot_original_doc = panel.doc
    core.redraw = true
  end
end

lsp.add_server(common.merge({
  name = "copilot.vim",
  language = "Any",
  file_patterns = { ".*" },
  command = { nodejs.path_bin, installed_path, "--stdio" },
  verbose = false,
  on_start = function(server)
    server:add_event_listener("initialized", function(_)
      initialized = true
      copilot.check_status(server, function(result)
        if result.status == "NotSignedIn" then
          core.warn("[LSP/Copilot] Not signed in! Call the command \"Copilot: Sign In\" to begin using Copilot.")
        elseif result.status == "OK" then
          core.log("[LSP/Copilot] Welcome %s.", result.user)
        else
          core.error("[LSP/Copilot] Unknown status: [%s].", result.status)
        end
      end)
    end)

    server:add_message_listener("PanelSolution", function(server, response)
      local pdv = panel_views[response.panelId]
      if not pdv then return end

      local panel = panels[pdv]

      if panel.done then
        core.warn("[LSP/Copilot] The Panel was marked as done, but more completions arrived.")
      end
      for _, v in ipairs(panel.completions) do
        if v.solutionId == response.solutionId then
          core.warn("[LSP/Copilot] Duplicate Panel solution received.")
          return
        end
      end

      table.insert(panel.completions, response)
      update_panel_texts(pdv)
    end)

    server:add_message_listener("PanelSolutionsDone", function(server, response)
      local pdv = panel_views[response.panelId]
      if not pdv then return end

      local panel = panels[pdv]

      if panel.done then
        core.warn("[LSP/Copilot] The Panel was marked as done multiple times.")
      end

      panel.done = response.status
      if response.status ~= "OK" then
        panel.error_message = response.message
      end

      update_panel_texts(pdv)
    end)
  end
}, config.plugins.lsp_copilot or {}))


function copilot.get_server()
  return lsp.servers_running["copilot.vim"]
end

function copilot.is_logged_in()
  return logged_in
end

-- TODO: expose from LSP
local function apply_edit(server, doc, text_edit, _, update_cursor_position)
  local range = nil

  if text_edit.range then
    range = text_edit.range
  end

  if not range then return false end

  local text = text_edit.newText
  local line1, col1, line2, col2

  if
    not server.capabilities.positionEncoding
    or
    server.capabilities.positionEncoding == Server.position_encoding_kind.UTF16
  then
    line1, col1, line2, col2 = util.toselection(range, doc)
  else
    line1, col1, line2, col2 = util.toselection(range)
    core.error(
      "[LSP] Unsupported position encoding: ",
      server.capabilities.positionEncoding
    )
  end

  doc:remove(line1, col1, line2, col2)

  doc:insert(line1, col1, text)
  if update_cursor_position then
    doc:move_to_cursor(doc.last_selection, #text)
  end

  return true
end

-- TODO: expose from LSP
local function get_buffer_position_params(doc, line, col)
  return {
    textDocument = {
      uri = doc.filename and util.touri(core.project_absolute_path(doc.filename)),
    },
    position = {
      line = line - 1,
      character = util.doc_utf8_to_utf16(doc, line, col) - 1
    }
  }
end

---@param code integer
---@return string error_name
local function error_code_to_name(code)
  local icode = tonumber(code)
  if not code then
    return string.format("Unknown - %s", code)
  end

  for k, v in pairs(Server.error_code) do
    if v == icode then return k end
  end
  return string.format("Unknown - %d", icode)
end

local function get_doc_param(doc, line1, col1)
  if not line1 then
    line1, col1, _, _ = doc:get_selection()
  end
  local request = get_buffer_position_params(doc, line1, col1)
  local indent_type, indent_size, _ = doc:get_indent_info()
  return {
    position = {
      line = request.position.line,
      character = request.position.character,
    },
    uri = request.textDocument.uri,
    version = doc.lsp_version or 1,
    insertSpaces = indent_type == "soft",
    tabSize = indent_size,
    indentSize = indent_size
    --[[
    languageId = copilot#doc#LanguageForFileType(getbufvar(bufnr, '&filetype')),
  --]]
  }
end

local function make_closable(fn)
  return setmetatable({}, {__close = fn})
end

-- `update_suggestions` in `autocomplete` filters out our completions with `common.fuzzy_match`.
-- We don't want that, as we're using the displayText as label for entries, and in some cases
-- they get filtered out (for example while writing, in the middle of a word).
local function autocomplete_complete_with_fix(...)
  local fuzzy_fn = common.fuzzy_match
  local restore_fuzzy_fn <close> = make_closable(function() common.fuzzy_match = fuzzy_fn end)
  common.fuzzy_match = function(items) return items end
  autocomplete.complete(...)
end

local autocomplete_is_copilot = false
function copilot.get_completions(server, doc)
  if not doc.lsp_open then
    return
  end
  local line1, col1, line2, col2 = doc:get_selection()
  if line1 == line2 and col1 == col2 then
    server:push_request("getCompletionsCycling", {
      params = {
        doc = get_doc_param(doc, line1, col1)
      },
      overwrite = true,
      callback = function(_, response)
        if response.error then
          core.error("[LSP/Copilot] Error while getting completions: %s\n%s",
            error_code_to_name(response.error.code), response.error.message)
          return
        end
        local result = response.result

        local symbols = {
          name = lsp.servers_running[server.name].name,
          files = lsp.servers_running[server.name].file_patterns,
          items = {}
        }

        local accepted_uuid = false
        -- Try to match the first line
        -- TODO: maybe "^(.+)$" is better? it matches the first non-empty line
        local title_regex = regex.compile("^(.*)$", "m")
        for i, symbol in ipairs(result.completions) do
          ---@cast title_regex -?
          local label = regex.match(title_regex, (symbol.displayText or symbol.text))
          if type(label) ~= "string" then
            label = i
          end
          symbol.newText = symbol.text

          symbols.items[label] = {
            info = "Copilot",
            desc = symbol.text,
            data = {
              server = server, completion_item = symbol, uuid = symbol.uuid
            },
            onselect = function(_, item)
              autocomplete_is_copilot = false
              accepted_uuid = item.data.uuid
              apply_edit(item.data.server, doc, item.data.completion_item, false, true)
              server:push_request("notifyAccepted", {
                params = { uuid = item.data.uuid }
              })
              return true
            end
          }
        end

        -- Only use our completions if others are unavailable
        if autocomplete.is_open() and not autocomplete_is_copilot then
          -- When the active completion gets dismissed, trigger ours again
          local old_on_close = autocomplete.on_close
          autocomplete.on_close = function(...)
            if old_on_close then old_on_close(...) end
            copilot.get_timer(doc):restart()
          end
          return
        end

        autocomplete_complete_with_fix(symbols, function()--(doc, item)
          autocomplete_is_copilot = false
          local uuids = {}
          for _, sym in pairs(symbols.items) do
            if sym.data.uuid and sym.data.uuid ~= accepted_uuid then
              table.insert(uuids, sym.data.uuid)
            end
          end
          if #uuids == 0 then return end
          server:push_request("notifyRejected", {
            params = { uuids = uuids }
          })
        end)
        autocomplete_is_copilot = true
      end
    })
  end
end

function copilot.get_panel_completions(server, doc)
  local panel_id = last_panel_id + 1
  last_panel_id = last_panel_id + 1
  local line1, col1, _, _ = doc:get_selection()
  local doc_param = get_doc_param(doc, line1, col1)
  server:push_request("getPanelCompletions", {
    params = {
      doc = doc_param,
      position = {
        line = doc_param.position.line,
        character = doc_param.position.character,
      },
      panelId = tostring(panel_id)
    },
    overwrite = true,
    callback = function(_, response)
      if response.error then
        core.error("[LSP/Copilot] Error while getting completions: %s\n%s",
          error_code_to_name(response.error.code), response.error.message)
        return
      end
      local result = response.result
      core.log("[LSP/Copilot] Looking for %d completions.", result.solutionCountTarget)
      local node = core.root_view:get_active_node()
      node = node:split("right")
      local pdv = VerticalPanelView()
      pdv.get_name = function() return string.format("Panel - %s", doc.filename) end
      node:add_view(pdv)
      panel_views[tostring(panel_id)] = pdv
      panels[pdv] = {
        doc = doc,
        completions = { },
        done = false,
        target = result.solutionCountTarget,
        comment = doc.syntax.comment and doc.syntax.comment .. " " or "",
        syntax = doc.syntax,
        error_message = ""
      }
      update_panel_texts(pdv)
    end
  })
end

command.add(function() return initialized and not copilot.is_logged_in() end, {
  ["copilot:sign-in"] = function()
    local server = copilot.get_server()

    -- {["result"]={["verificationUri"]="https://github.com/login/device",["userCode"]="ABCD-1234",["interval"]=5,["status"]="PromptUserDeviceFlow",["expiresIn"]=899},["jsonrpc"]="2.0",["id"]=3}
    server:push_request("signInInitiate", {
      params = {},
      overwrite = true,
      callback = function(_, response)
        local uri = response.result["verificationUri"]
        local code = response.result["userCode"]
        core.command_view:enter("Login code", {
          text = code,
          select_text = true,
          typeahead = false,
          suggest = function()
            return {
              string.format("Or manually go to %s and enter code [%s]", uri, code),
              string.format("Press enter to automatically open your default browser and copy the code"),
            }
          end,
          submit = function()
            core.log("[LSP/Copilot] Use code [%s] in %s to login. The browser will automatically open in a few seconds and the code will be copied.", code, uri)
            system.set_clipboard(code)
            if PLATFORM == "Windows" then
              system.exec("start " .. uri)
            else
              system.exec(string.format("xdg-open %q", uri))
            end
          end
        })

        server:push_request("signInConfirm", {
          timeout = 120,
          params = {},
          overwrite = true,
          callback = function(_, response)
            _check_status(response.result)
            if logged_in then
              core.log("[LSP/Copilot] Successfully logged in! Welcome %s.", response.result.user)
            end
          end
        })
      end
    })
  end
})

command.add(copilot.is_logged_in, {
  ["copilot:sign-out"] = function()
    local server = copilot.get_server()

    server:push_request("signOut", {
      timeout = 20,
      params = {},
      overwrite = true,
      callback = function(_, response)
        _check_status(response.result)
        if not logged_in then
          core.log("[LSP/Copilot] Successfully signed out.")
        end
      end
    })
  end
})

command.add(function()
    local av = core.active_view
    if not av or not av:is(DocView) then return false end
    local doc = av.doc
    if not doc.lsp_open then return false end
    if not copilot.is_logged_in() then return false end
    return true, doc
  end, {
  ["copilot:get-completions"] = function(doc)
    local server = copilot.get_server()
    copilot.get_completions(server, doc)
  end,
  ["copilot:get-panel-completions"] = function(doc)
    local server = copilot.get_server()
    copilot.get_panel_completions(server, doc)
  end
})

command.add(function()
  local av = core.active_view
  if not av or not av:is(DocView) or not av.copilot_response then return false end
  return true, av
end, {
  ["copilot:accept-panel-solution"] = function(vpv)
    apply_edit(copilot.get_server(), vpv.copilot_original_doc, {
      range = vpv.copilot_response.range,
      newText = vpv.copilot_response.completionText
    }, nil, true)
  end
})

local doc = require "core.doc"

local doc_timers = setmetatable({}, { __mode="k" })

function copilot.get_timer(doc)
  if not doc_timers[doc] then
    local t = Timer(100, true)
    doc_timers[doc] = t
    function t:on_timer()
      if copilot.is_logged_in() then
        copilot.get_completions(copilot.get_server(), doc)
      end
    end
  end
  return doc_timers[doc]
end

local doc_raw_insert = doc.raw_insert
function doc:raw_insert(...)
  copilot.get_timer(self):restart()
  return doc_raw_insert(self, ...)
end


local doc_raw_remove = doc.raw_remove
function doc:raw_remove(...)
  copilot.get_timer(self):restart()
  return doc_raw_remove(self, ...)
end

local doc_set_selections = doc.set_selections
function doc:set_selections(...)
  copilot.get_timer(self):restart()
	return doc_set_selections(self, ...)
end

return copilot
