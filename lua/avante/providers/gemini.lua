local Utils = require("avante.utils")
local P = require("avante.providers")
local Clipboard = require("avante.clipboard")

---@class AvanteProviderFunctor
local M = {}

---@param tool AvanteLLMTool | AvanteMCPTool -- Allow MCP tool structure
---
---@return GeminiFunctionDeclaration
function M:transform_tool(tool)
  local Utils = require("avante.utils")
  -- Read parameters from tool.param.fields (MCP) or tool.parameters (standard)
  local tool_param_fields = (tool.param and tool.param.fields) or tool.parameters or {}

  local base_description = tool.description or ""
  local enhanced_description = base_description -- Start with the base

  -- Truncate description if it's too long
  local MAX_DESC_LENGTH = 500 -- Adjust as needed
  if #enhanced_description > MAX_DESC_LENGTH then
    enhanced_description = enhanced_description:sub(1, MAX_DESC_LENGTH) .. "..."
    Utils.debug("Gemini: Truncated description for tool:", tool.name)
  end

  -- If the tool definition has no parameters, omit the 'parameters' field entirely
  if vim.tbl_isempty(tool_param_fields) then
    return {
      name = tool.name,
      description = enhanced_description,
      -- No 'parameters' field
    }
  end

  -- Parameters exist, proceed with generating the schema using the correct source
  local properties, generated_required = Utils.llm_tool_param_fields_to_json_schema(tool_param_fields)

  -- For dynamically generated MCP tools, the 'required' list should come directly
  -- from the tool's/template's schema via llm_tool_param_fields_to_json_schema.
  -- No need to override here based on generic names.
  local required = generated_required

  -- Construct the full schema object expected by Gemini
  local parameters_schema = {
    type = "object",
    properties = properties,
    required = required,
  }

  -- Check if the generated properties are empty
  if not properties or vim.tbl_isempty(properties) then
    -- If parameters were defined but schema generation resulted in empty properties,
    -- this indicates an issue, but we must still omit the parameters field for the API.
    Utils.warn(
      "Gemini Provider: Tool '"
        .. tool.name
        .. "' has parameters defined, but generated schema properties are empty. Omitting parameters field.",
      { title = "Avante" }
    )
    return {
      name = tool.name,
      description = tool.description,
      -- No 'parameters' field due to empty properties
    }
  else
    -- Parameters exist AND properties are non-empty, ensure the structure is correct

    -- Ensure 'required' is a list of strings (it should be from the util function, but double-check)
    if not parameters_schema.required then parameters_schema.required = {} end
    if type(parameters_schema.required) ~= "table" or not vim.tbl_islist(parameters_schema.required) then
      Utils.warn(
        "Gemini Provider: Correcting invalid 'required' field for tool '" .. tool.name .. "'.",
        { title = "Avante" }
      )
      local req_strings = {}
      if type(parameters_schema.required) == "table" then -- Attempt recovery if it's a map
        for _, v in pairs(parameters_schema.required) do
          if type(v) == "string" then table.insert(req_strings, v) end
        end
      end
      parameters_schema.required = req_strings -- Reset to list (potentially empty)
    end

    -- Ensure 'properties' is a map (it should be, but double-check)
    if type(parameters_schema.properties) ~= "table" or vim.tbl_islist(parameters_schema.properties) then
      Utils.error(
        "Gemini Provider: Tool '"
          .. tool.name
          .. "' parameters.properties is invalid (not a map or is a list) despite being non-empty.",
        { title = "Avante" }
      )
      -- Fallback: omit parameters to avoid API error
      return { name = tool.name, description = tool.description }
    end

    -- Final check: Ensure the parameters object itself has the required fields
    if not parameters_schema.type or not parameters_schema.properties or not parameters_schema.required then
      Utils.error(
        "Gemini Provider: Invalid final parameters_schema structure for tool '" .. tool.name .. "'",
        { title = "Avante" }
      )
      -- Fallback to omitting parameters
      return { name = tool.name, description = tool.description }
    end

    -- *** Parameter Description Enhancements (Apply generally) ***
    -- We can keep general enhancements, but remove MCP-specific logic tied to the old generic tools.
    if parameters_schema.properties then
      -- Example: Enhance any 'query' parameter description
      if parameters_schema.properties.query and parameters_schema.properties.query.description then
        parameters_schema.properties.query.description = parameters_schema.properties.query.description
          .. " (Provide a concise search query based on the user's request.)"
        Utils.debug("Gemini: Enhanced 'query' parameter description for tool: " .. tool.name)
      end
      -- Example: Enhance any 'path' parameter description
      if parameters_schema.properties.path and parameters_schema.properties.path.description then
        parameters_schema.properties.path.description = parameters_schema.properties.path.description
          .. " (Provide the relative file path within the project.)"
        Utils.debug("Gemini: Enhanced 'path' parameter description for tool: " .. tool.name)
      end
      -- Add more general enhancements as needed...
    end
    -- *** End Parameter Description Enhancements ***

    -- *** View Tool Specific Enhancement for Gemini (Keep this if 'view' tool exists separately) ***
    if
      tool.name == "view"
      and parameters_schema.properties
      and parameters_schema.properties.path
      and parameters_schema.properties.path.description
    then
      parameters_schema.properties.path.description = parameters_schema.properties.path.description
        .. " (**MANDATORY**: You MUST provide the file path, usually mentioned in the user request or previous context.)"
      Utils.debug("Gemini: Enhanced path description for view tool.")
    end
    -- *** End View Enhancement ***

    -- Return the declaration WITH the valid parameters schema
    return {
      name = tool.name,
      description = enhanced_description, -- Use the potentially enhanced description
      parameters = parameters_schema, -- Use the corrected schema
    }
  end
end

M.api_key_name = "GEMINI_API_KEY"
M.role_map = {
  user = "user",
  assistant = "model",
}
-- M.tokenizer_id = "google/gemma-2b"

function M:is_disable_stream() return false end

---@param opts AvantePromptOptions
---@return GeminiContent[], GeminiPart | nil -- contents, system_instruction
function M:parse_messages(opts)
  ---@type GeminiContent[]
  local contents = {}
  ---@type GeminiPart | nil
  local system_instruction = nil
  local last_role = nil

  -- Helper to add a message, handling consecutive roles if needed
  local function add_content(role, parts)
    if role == last_role then
      -- Gemini doesn't strictly require alternating roles, but it's good practice
      -- If the same role repeats, insert a placeholder from the opposite role
      if role == M.role_map.user then
        table.insert(contents, { role = M.role_map.assistant, parts = { { text = "Okay." } } })
      else
        table.insert(contents, { role = M.role_map.user, parts = { { text = "Understood." } } })
      end
    end
    table.insert(contents, { role = role, parts = parts })
    last_role = role
  end

  -- Process System Prompt first
  if opts.system_prompt and opts.system_prompt ~= "" then
    -- Gemini uses a top-level system_instruction field
    -- It requires the 'parts' structure, similar to 'contents'
    system_instruction = { parts = { { text = opts.system_prompt } } }
  end

  -- Process regular messages
  for _, message in ipairs(opts.messages) do
    local role = M.role_map[message.role] or message.role -- Map user/assistant to user/model
    if role == "system" then -- Should have been handled above, but catch just in case
      -- Ensure correct structure if found here unexpectedly
      if not system_instruction then system_instruction = { parts = { { text = message.content } } } end
      goto continue -- Skip adding system prompts to 'contents'
    end

    local parts = {}
    local content_items = message.content

    if type(content_items) == "string" then
      table.insert(parts, { text = content_items })
    elseif type(content_items) == "table" then
      for _, item in ipairs(content_items) do
        if type(item) == "string" then
          table.insert(parts, { text = item })
        elseif item.type == "text" then
          table.insert(parts, { text = item.text })
        elseif item.type == "image" then
          table.insert(parts, { inline_data = { mime_type = "image/png", data = item.source.data } })
        -- tool_use and tool_result are handled separately below via tool_histories
        elseif item.type == "thinking" then
          -- Gemini doesn't have a direct equivalent, maybe include as text?
          table.insert(parts, { text = "<thinking>" .. item.thinking .. "</thinking>" })
        end
      end
    end
    if #parts > 0 then add_content(role, parts) end
    ::continue::
  end

  -- Append image paths if provided (usually attached to the last user message)
  if Clipboard.support_paste_image() and opts.image_paths and #opts.image_paths > 0 then
    local last_content = contents[#contents]
    if last_content and last_content.role == M.role_map.user then
      for _, image_path in ipairs(opts.image_paths) do
        local image_data = Clipboard.get_base64_content(image_path)
        if image_data then
          table.insert(last_content.parts, { inline_data = { mime_type = "image/png", data = image_data } })
        else
          Utils.warn("Could not read or encode image: " .. image_path)
        end
      end
    else
      -- If last message wasn't user, add a new user message with images? Or log warning?
      Utils.warn("Cannot attach images: Last message was not from user.")
    end
  end

  -- Process Tool Histories (Function Calling)
  if opts.tool_histories and #opts.tool_histories > 0 then
    -- 1. Collect function *responses* AND their corresponding *calls* in a single pass
    local function_responses = {}
    local corresponding_function_calls = {} -- Store the calls that have responses

    for _, history in ipairs(opts.tool_histories) do
      -- Ensure both use and result exist for this history entry to be considered a completed pair for this turn
      if history.tool_use and history.tool_result then
        -- Add the response part
        local result_content = history.tool_result.content
          or (history.tool_result.is_error and "Error executing tool" or "")
        table.insert(function_responses, {
          functionResponse = {
            name = history.tool_use.name, -- Use the name from the original call
            response = { content = result_content }, -- Result content nested under response
          },
        })

        -- Add the corresponding call part
        local args = vim.fn.json_decode(history.tool_use.input_json or "{}") -- Gemini expects object
        table.insert(corresponding_function_calls, {
          functionCall = { name = history.tool_use.name, args = args },
        })
      end
    end

    -- 2. Add the assistant ('model') message containing ALL the function *calls* that have responses
    if #corresponding_function_calls > 0 then add_content(M.role_map.assistant, corresponding_function_calls) end

    -- 3. Add the 'function' message containing ALL the corresponding function *responses*
    if #function_responses > 0 then
      -- This check should ideally always pass with the new logic, but good for safety
      if #corresponding_function_calls ~= #function_responses then
        Utils.error(
          "Internal Error: Mismatch between collected function calls and responses in Gemini provider. History may be inconsistent.",
          { title = "Avante" }
        )
        -- Avoid sending potentially corrupted history back to Gemini
      else
        add_content("function", function_responses) -- Add ONE function turn with ALL responses
      end
    end
  end

  return contents, system_instruction
end

---@param ctx table Response context (can be used to store state across chunks)
---@param data_stream string Raw data chunk from the stream
---@param event_state table Persistent state for the current request (e.g., collected content, tool calls)
---@param opts AvanteHandlerOptions Callbacks (on_chunk, on_stop)
function M:parse_response(ctx, data_stream, event_state, opts)
  local ok, decoded = pcall(vim.json.decode, data_stream)
  if not ok or not decoded then
    Utils.debug("Gemini: Failed to decode JSON chunk:", data_stream)
    -- Don't stop yet, might be partial JSON; wait for more data or final signal
    return
  end

  -- Initialize state if first chunk
  if not event_state then event_state = {} end -- Ensure event_state exists
  if not event_state.content then event_state.content = "" end
  if not event_state.tool_use_list then event_state.tool_use_list = {} end

  -- Check for errors reported by the API
  if decoded.promptFeedback and decoded.promptFeedback.blockReason then
    local reason = decoded.promptFeedback.blockReason
    local safety_ratings = vim.inspect(decoded.promptFeedback.safetyRatings)
    local error_msg = "Gemini API Error: Blocked due to " .. reason .. ". SafetyRatings: " .. safety_ratings
    Utils.error(error_msg)
    opts.on_stop({ reason = "error", error = error_msg })
    return
  end

  if not decoded.candidates or #decoded.candidates == 0 then
    Utils.debug("Gemini: Received chunk with no candidates:", data_stream)
    -- Might be the final chunk with usage metadata, check finishReason later
    -- Check if it's just usage metadata without candidates
    if decoded.usageMetadata then
      -- If we already have content or tool calls, this might be the end.
      -- But Gemini usually sends finishReason, so rely on that.
      Utils.debug("Gemini: Received usage metadata chunk.")
    end
    return
  end

  local candidate = decoded.candidates[1]

  -- Process content parts (text or function calls)
  if candidate.content and candidate.content.parts then
    for _, part in ipairs(candidate.content.parts) do
      if part.text then
        local chunk = part.text
        event_state.content = event_state.content .. chunk
        if opts.on_chunk then opts.on_chunk(chunk) end
      elseif part.functionCall then
        local func_call = part.functionCall
        Utils.debug("Gemini: Detected function call raw args:", func_call.args) -- <<< ADD THIS DEBUG LINE
        Utils.debug("Gemini: Detected function call:", func_call)
        -- Gemini provides 'args' as a JSON object. Encode to string for consistency.
        local input_json_str = vim.fn.json_encode(func_call.args or {})
        -- Generate a unique-ish ID for llm.lua processing
        local tool_use_id = func_call.name .. "_" .. os.time() .. "_" .. #event_state.tool_use_list
        table.insert(event_state.tool_use_list, {
          id = tool_use_id,
          name = func_call.name,
          input_json = input_json_str,
        })
        event_state.has_tool_call = true -- Flag that we need to stop for tool use
      end
    end
  end

  -- Check finish reason to determine if the stream should stop
  if candidate.finishReason then
    local reason = candidate.finishReason
    Utils.debug("Gemini: Finish Reason:", reason)
    if reason == "STOP" then
      -- Normal completion, but check if it was actually a tool call stop
      if event_state.has_tool_call then
        opts.on_stop({ reason = "tool_use", tool_use_list = event_state.tool_use_list })
      else
        opts.on_stop({ reason = "complete" })
      end
    elseif reason == "MAX_TOKENS" then
      opts.on_stop({ reason = "max_tokens" })
    elseif reason == "SAFETY" then
      local safety_ratings = vim.inspect(candidate.safetyRatings)
      local error_msg = "Gemini API Error: Stopped due to SAFETY. Ratings: " .. safety_ratings
      Utils.error(error_msg)
      opts.on_stop({ reason = "error", error = error_msg })
    elseif reason == "RECITATION" then
      local error_msg = "Gemini API Error: Stopped due to RECITATION."
      Utils.error(error_msg)
      opts.on_stop({ reason = "error", error = error_msg })
    elseif reason == "TOOL_CODE_EXECUTING" or reason == "TOOL_CODE" or event_state.has_tool_call then -- Gemini might use TOOL_CODE_EXECUTING or just TOOL_CODE
      -- Stop because the model wants to use a tool
      opts.on_stop({ reason = "tool_use", tool_use_list = event_state.tool_use_list })
    else -- OTHER, UNSPECIFIED, etc.
      opts.on_stop({ reason = "error", error = "Gemini stream stopped with reason: " .. reason })
    end
  end
end

function M:parse_curl_args(prompt_opts)
  local provider_conf, request_body = P.parse_config(self)

  -- Explicitly remove the API key name field if it exists in the config body
  if M.api_key_name then request_body[M.api_key_name] = nil end

  request_body = vim.tbl_deep_extend("force", request_body, {
    generationConfig = {
      temperature = request_body.temperature,
      maxOutputTokens = request_body.max_tokens,
    },
  })
  request_body.temperature = nil
  request_body.max_tokens = nil

  local api_key = self.parse_api_key()
  if not api_key then error("Cannot get the Gemini API key (" .. M.api_key_name .. ")!") end

  -- Parse messages and system instruction
  local contents, system_instruction = self:parse_messages(prompt_opts)

  -- Add system instruction if present
  if system_instruction then request_body.system_instruction = system_instruction end

  -- Dynamically generate tool definitions including specific MCP tools/resources
  local all_tools_for_gemini = {}

  -- 1. Add standard Avante tools (excluding the generic MCP ones if they were passed)
  -- Define standard Avante tools that might be redundant with MCP tools
  local redundant_avante_tools = {
    ls = { "filesystem_list_directory", "neovim_list_directory" },
    view = { "filesystem_read_file", "neovim_read_file" },
    grep = { "filesystem_search_files" }, -- Assuming MCP search is preferred over grep
    python = {}, -- No direct MCP equivalent shown, keep for now
    bash = { "neovim_execute_command" },
    rename_file = { "filesystem_move_file", "neovim_move_item" },
    delete_file = { "filesystem_delete_item", "neovim_delete_item" }, -- Assuming MCP delete covers files
    create_dir = { "filesystem_create_directory" },
    rename_dir = { "filesystem_move_file", "neovim_move_item" }, -- Assuming MCP move covers dirs
    delete_dir = { "filesystem_delete_item", "neovim_delete_item" }, -- Assuming MCP delete covers dirs
    write_file = { "filesystem_write_file", "neovim_write_file" },
    replace_in_file = { "filesystem_edit_file", "neovim_replace_in_file" },
    fetch = { "fetch_fetch" }, -- Add fetch redundancy
    -- Add other potential redundancies here
  }
  local mcp_tools_added_map = {} -- Keep track of which MCP tools were added

  -- 1. Add standard Avante tools, filtering out the old generic 'mcp' tool explicitly
  if prompt_opts.tools then
    for _, tool in ipairs(prompt_opts.tools) do
      -- Skip the old generic MCP tool and the specific MCP actions if they somehow slip through
      if tool.name ~= "mcp" and tool.name ~= "use_mcp_tool" and tool.name ~= "access_mcp_resource" then
        local transformed = self:transform_tool(tool)
        if transformed then table.insert(all_tools_for_gemini, transformed) end
      end
    end
  end

  -- 2. Add dynamically generated MCP tools and resource templates
  local mcp_ok, mcphub = pcall(require, "mcphub")
  if mcp_ok and mcphub then
    local hub = mcphub.get_hub_instance()
    if hub and hub:is_ready() then
      -- Add MCP Tools
      local mcp_tools = hub:get_tools() or {}
      Utils.debug("Gemini: Found MCP Tools from Hub:", #mcp_tools)
      for _, mcp_tool in ipairs(mcp_tools) do
        -- Simplify server name for the tool name generation
        local server_alias = mcp_tool.server_name or "unknown"
        -- Attempt to extract the last part of the path/URL
        local alias_match = server_alias:match(".*/([^/]+)$") or server_alias:match("([^%.]+)$") -- Basic attempt
        if alias_match and alias_match ~= "" then server_alias = alias_match end
        -- Sanitize further
        server_alias = server_alias:gsub("[^%w_]", "_")

        -- Create a Gemini-specific tool definition with simplified name
        local tool_name = server_alias .. "_" .. mcp_tool.name
        local description = string.format(
          "MCP Tool (from %s server): %s",
          server_alias, -- Use the shorter alias in description too
          mcp_tool.description or "No description"
        )
        -- Use transform_tool to handle parameter schema generation, but pass the specific MCP tool schema
        local transformed = self:transform_tool({
          name = tool_name, -- Use the generated unique name
          description = description,
          parameters = mcp_tool.inputSchema and mcp_tool.inputSchema.fields or {}, -- Adapt based on actual MCP tool schema structure
          -- Store original info for potential later use if needed
          _mcp_original_server = mcp_tool.server_name,
          _mcp_original_tool = mcp_tool.name,
          _mcp_type = "tool",
        })
        if transformed then
          table.insert(all_tools_for_gemini, transformed)
          mcp_tools_added_map[transformed.name] = true -- Mark this MCP tool as added
        end
      end
      -- Resource templates are not directly exposed as tools in this version.
    else
      Utils.debug("Gemini: MCP Hub not ready or not available for dynamic tool generation.")
    end
  else
    Utils.debug("Gemini: MCP Hub module not found.")
  end

  -- 3. Filter out redundant standard Avante tools if corresponding MCP tools were added
  local final_tools_for_gemini = {}
  local removed_standard_tools = {}
  for _, tool_def in ipairs(all_tools_for_gemini) do
    local is_redundant = false
    -- Check if this is a standard tool that has an MCP equivalent added
    if redundant_avante_tools[tool_def.name] then
      for _, mcp_equivalent_name in ipairs(redundant_avante_tools[tool_def.name]) do
        if mcp_tools_added_map[mcp_equivalent_name] then
          is_redundant = true
          table.insert(removed_standard_tools, tool_def.name)
          break
        end
      end
    end

    if not is_redundant then table.insert(final_tools_for_gemini, tool_def) end
  end

  if #removed_standard_tools > 0 then
    Utils.debug("Gemini: Removed redundant standard tools:", removed_standard_tools)
  end

  -- Add the combined list of tools to the request body if any exist
  if #final_tools_for_gemini > 0 then
    request_body.tools = { { functionDeclarations = final_tools_for_gemini } }
    Utils.debug("Gemini: Sending final tool definitions:", request_body.tools)
  end

  -- Add contents (the main conversation history)
  request_body.contents = contents

  return {
    url = Utils.url_join(
      provider_conf.endpoint,
      provider_conf.model .. ":streamGenerateContent?alt=sse&key=" .. api_key
    ),
    proxy = provider_conf.proxy,
    insecure = provider_conf.allow_insecure,
    headers = { ["Content-Type"] = "application/json" },
    body = request_body, -- Use the constructed body
  }
end

return M
