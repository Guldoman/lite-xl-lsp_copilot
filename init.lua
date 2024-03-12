-- mod-version: 3
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"

local DocView = require "core.docview"

local autocomplete = require "plugins.autocomplete"
local translate = require "core.doc.translate"

local Timer = require "plugins.lsp.timer"
local util = require "plugins.lsp.util"
local Server = require "plugins.lsp.server"

local lsp = require "plugins.lsp"
local nodejs = require "libraries.nodejs"

local installed_path = USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "lsp_copilot" .. PATHSEP .. "copilot.vim-1.25.1" .. PATHSEP .. "dist" .. PATHSEP .. "agent.js"

local logged_in = false
local initialized = false

local last_panel_id = 0
local panels = setmetatable({}, {__mode = "v"})

local function _check_status(result)
  logged_in = false
  if result.status == "OK" then
    logged_in = true
  end
end

local function check_status(server, callback)
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

lsp.add_server(common.merge({
  name = "copilot.vim",
  language = "Any",
  file_patterns = { ".*" },
  command = { nodejs.path_bin, installed_path, "--stdio" },
  verbose = true,
  on_start = function(server)
    server:add_event_listener("initialized", function(_)
      initialized = true
      check_status(server, function(result)
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
      if panels[response.panelId] then
        local dv = panels[response.panelId]
        dv.doc:text_input(string.format("Score: %d\n\n%s\n\n--------------------------------------\n", response.score, response.completionText))
      end
    end)

    server:add_message_listener("PanelSolutionsDone", function(server, response)
      if panels[response.panelId] then
        local dv = panels[response.panelId]
        dv.doc:text_input(string.format("Done with message %s.", response.status))
      end
    end)
  end
}, config.plugins.lsp_copilot or {}))


local function get_server()
  return lsp.servers_running["copilot.vim"]
end

local function is_logged_in()
  return logged_in
end

-- TODO: expose from LSP
local function apply_edit(server, doc, text_edit, _, update_cursor_position)
  local range = nil

  if text_edit.range then
    range = text_edit.range
  elseif text_edit.insert then
    range = text_edit.insert
  elseif text_edit.replace then
    range = text_edit.replace
  end

  if not range then return false end

  local text = text_edit.newText
  local line1, col1, line2, col2
  local current_text = ""

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

  if lsp.in_trigger then
    local cline2, ccol2 = doc:get_selection()
    local cline1, ccol1 = doc:position_offset(line2, col2, translate.start_of_word)
    current_text = doc:get_text(cline1, ccol1, cline2, ccol2)
  end

  doc:remove(line1, col1, line2, col2+#current_text)

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

local function get_completions(server, doc)
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

        local accepted = false
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
              accepted = true
              local applied = apply_edit(item.data.server, doc, item.data.completion_item, false, true)
              server:push_request("notifyAccepted", {
                params = { uuid = item.data.uuid }
              })
              return applied
            end
          }
        end

        autocomplete.complete(symbols, function()--(doc, item)
          if not accepted then
            local uuids = {}
            for _, sym in pairs(symbols.items) do
              table.insert(uuids, sym.data.uuid)
            end
            if #uuids == 0 then return end
            server:push_request("notifyRejected", {
              params = { uuids = uuids }
            })
          end
        end)
      end
    })
  end
end

local function get_panel_completions(server, doc)
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
      node:split("right")
      local dv = core.root_view:open_doc(core.open_doc())
      panels[tostring(panel_id)] = dv
    end
  })
end

command.add(function() return initialized and not is_logged_in() end, {
  ["copilot:sign-in"] = function()
    local server = get_server()

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
              string.format("Press enter to automatically open you default browser and copy the code"),
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

command.add(is_logged_in, {
  ["copilot:sign-out"] = function()
    local server = get_server()

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
    return true, doc
  end, {
  ["copilot:get-panel-completions"] = function(doc)
    local server = get_server()
    get_panel_completions(server, doc)
  end
})

local doc = require "core.doc"

local doc_timers = setmetatable({}, { __mode="k" })

local function get_timer(doc)
  if not doc_timers[doc] then
    local t = Timer(2 * 1000, true)
    doc_timers[doc] = t
    function t:on_timer()
      if is_logged_in() then
        get_completions(get_server(), doc)
      end
    end
  end
  return doc_timers[doc]
end

local doc_raw_insert = doc.raw_insert
function doc:raw_insert(...)
  get_timer(self):restart()
  return doc_raw_insert(self, ...)
end


local doc_raw_remove = doc.raw_remove
function doc:raw_remove(...)
  get_timer(self):restart()
  return doc_raw_remove(self, ...)
end

local doc_set_selections = doc.set_selections
function doc:set_selections(...)
  get_timer(self):restart()
	return doc_set_selections(self, ...)
end
