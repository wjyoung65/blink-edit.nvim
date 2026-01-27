--- Engine module for blink-edit
--- Implements valve architecture for prediction lifecycle

local M = {}

local config = require("blink-edit.config")
local state = require("blink-edit.core.state")
local context_manager = require("blink-edit.core.context_manager")
local diff = require("blink-edit.core.diff")
local render = require("blink-edit.core.render")
local backend = require("blink-edit.backends")
local transport = require("blink-edit.transport")
local utils = require("blink-edit.utils")
local log = require("blink-edit.log")
local ui = require("blink-edit.ui")

local uv = vim.uv or vim.loop

---@class DebounceTimer
---@field timer userdata|nil
---@field bufnr number

---@type table<number, DebounceTimer>
local debounce_timers = {}

-- Provider cache
local provider_cache = {}

-- =============================================================================
-- Provider Management
-- =============================================================================

--- Get or create provider instance
---@return BlinkEditProvider
local function get_provider()
  local cfg = config.get()
  local name = cfg.llm.provider or "sweep"
  local provider_config = {}

  if cfg.providers and cfg.providers[name] then
    provider_config = cfg.providers[name]
  end

  -- Check cache
  local cached = provider_cache[name]
  if cached and cached.config == provider_config then
    return cached.provider
  end

  -- Create new provider
  local ok, module = pcall(require, "blink-edit.providers." .. name)
  if not ok then
    -- Fallback to generic
    module = require("blink-edit.providers.generic")
    name = "generic"
  end

  local provider
  if type(module.new) == "function" then
    provider = module.new({
      name = name,
      config = provider_config,
      global_config = cfg,
    })
  else
    provider = module
    provider.name = provider.name or name
    provider.config = provider_config
    provider.global_config = cfg
  end

  -- Cache it
  provider_cache[name] = { provider = provider, config = provider_config }

  return provider
end

-- =============================================================================
-- Debounce Management
-- =============================================================================

--- Cancel debounce timer for a buffer
---@param bufnr number
local function cancel_debounce(bufnr)
  local dt = debounce_timers[bufnr]
  if dt and dt.timer and not dt.timer:is_closing() then
    dt.timer:stop()
    dt.timer:close()
  end
  debounce_timers[bufnr] = nil
end

-- =============================================================================
-- Request Lifecycle
-- =============================================================================

--- Start a new prediction request (called when valve opens)
---@param bufnr number
---@param snapshot BlinkEditSnapshot
local function start_request(bufnr, snapshot)
  local cfg = config.get()

  -- Get baseline (captured on InsertEnter)
  local baseline = state.get_baseline(bufnr)
  if not baseline then
    -- No baseline - capture one now as fallback
    state.capture_baseline(bufnr)
    baseline = state.get_baseline(bufnr)
    if not baseline then
      if vim.g.blink_edit_debug then
        log.debug("No baseline available, skipping request", vim.log.levels.WARN)
      end
      return
    end
  end

  -- Skip if nothing changed from baseline (no edit to predict)
  if utils.lines_equal(baseline.lines, snapshot.lines) then
    if vim.g.blink_edit_debug then
      log.debug("Skipping request: no changes from baseline")
    end
    return
  end

  -- Get provider
  local provider = get_provider()

  -- Get provider requirements
  local requirements = provider:get_requirements()

  -- Build context limits from config
  local limits = {
    max_history_tokens = cfg.context.history.max_tokens or 512,
    max_context_tokens = cfg.context.max_tokens or 512,
    max_history_entries = cfg.context.history.max_items or 5,
    max_files = cfg.context.history.max_files or 2,
  }

  -- Collect context based on requirements
  local context_data = context_manager.collect(bufnr, baseline, snapshot, requirements, limits)

  -- Build prompt (provider handles all formatting)
  local prompt, metadata, build_err = provider:build_prompt(context_data, limits)

  if not prompt or not metadata then
    if vim.g.blink_edit_debug then
      log.debug("Failed to build prompt: " .. (build_err or "unknown"))
    end
    return
  end

  if vim.g.blink_edit_debug then
    log.debug(
      string.format(
        "Starting request, window=%d-%d, history=%d",
        metadata.window_start,
        metadata.window_end,
        #context_data.history
      )
    )
  end

  -- Log full prompt at debug level 2
  if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
    log.debug2("=== PROMPT ===\n" .. prompt .. "\n=== END PROMPT ===")
  end

  -- Get stop tokens from provider
  local stop_tokens = provider:get_stop_tokens()

  -- Send request and track it
  local request_id = backend.complete({
    prompt = prompt,
    model = cfg.llm.model,
    max_tokens = cfg.llm.max_tokens,
    temperature = cfg.llm.temperature,
    stop = stop_tokens,
  }, function(err, result)
    -- Schedule callback to run in main loop
    vim.schedule(function()
      on_response(bufnr, err, result, metadata, snapshot, provider)
    end)
  end)

  -- Track in_flight state
  state.set_in_flight(bufnr, request_id)

  -- Show progress indicator
  ui.show_progress()
end

--- Handle response from LLM
---@param bufnr number
---@param err string|table|nil
---@param result table|nil
---@param metadata table
---@param snapshot BlinkEditSnapshot
---@param provider BlinkEditProvider
function on_response(bufnr, err, result, metadata, snapshot, provider)
  -- Clear in_flight state
  state.clear_in_flight(bufnr)

  -- Hide progress indicator
  ui.hide_progress()

  local cfg = config.get()

  -- Check if buffer is still valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Check if there's a pending snapshot in the stack
  if state.has_pending_snapshot(bufnr) then
    -- Discard this response - we have fresher data
    if vim.g.blink_edit_debug then
      log.debug("Discarding stale response, processing stack")
    end

    local pending = state.pop_from_stack(bufnr)
    if pending then
      start_request(bufnr, pending)
    end
    return
  end

  -- Handle error
  if err then
    if type(err) == "table" then
      local err_type = err.type
      local err_message = err.message or "Unknown error"

      if err_type == "connection" or err_type == "curl_error" then
        log.error("Cannot connect to LLM server. Is it running?")
      elseif err_type == "timeout" then
        log.error("Request timed out")
      elseif err_type == "server" then
        log.error("Server error: " .. err_message)
      else
        log.debug("Request failed: " .. err_message, vim.log.levels.WARN)
      end
    else
      log.debug("Request failed: " .. tostring(err), vim.log.levels.WARN)
    end
    return
  end

  -- Handle empty response
  if not result or not result.text then
    if vim.g.blink_edit_debug then
      log.debug("Empty response", vim.log.levels.WARN)
    end
    return
  end

  -- Log full response at debug level 2
  if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
    log.debug2("=== RESPONSE ===\n" .. result.text .. "\n=== END RESPONSE ===")
  end

  -- Parse response using provider
  local predicted_lines, parse_err = provider:parse_response(result.text, snapshot.lines)
  if not predicted_lines then
    if vim.g.blink_edit_debug then
      log.debug("Invalid response: " .. (parse_err or "unknown"))
    end
    return
  end

  local cursor_after = nil
  if cfg.mode == "completion" then
    local merged, after, merge_err = merge_completion(snapshot, predicted_lines)
    if not merged then
      if vim.g.blink_edit_debug then
        log.debug("Invalid completion: " .. (merge_err or "unknown"))
      end
      return
    end
    predicted_lines = merged
    cursor_after = after
  end

  -- Check if prediction is same as current (no changes)
  local has_changes = false
  if #predicted_lines ~= #snapshot.lines then
    has_changes = true
  else
    for i = 1, #predicted_lines do
      if predicted_lines[i] ~= snapshot.lines[i] then
        has_changes = true
        break
      end
    end
  end

  if not has_changes then
    if vim.g.blink_edit_debug then
      log.debug("No changes detected in prediction")
    end
    return
  end

  -- Store prediction with snapshot and predicted lines
  local prediction = {
    predicted_lines = predicted_lines,
    snapshot_lines = snapshot.lines,
    window_start = metadata.window_start,
    window_end = metadata.window_end,
    response_text = result.text,
    created_at = uv.now(),
    cursor_after = cursor_after,
    cursor = snapshot.cursor, -- Cursor position when prediction was made
  }
  state.set_prediction(bufnr, prediction)

  -- Render ghost text
  render.show(bufnr, prediction)

  if vim.g.blink_edit_debug then
    log.debug(
      string.format("Showing prediction: %d snapshot lines -> %d predicted lines", #snapshot.lines, #predicted_lines)
    )
  end
end

--- Merge completion into snapshot (for completion mode)
---@param snapshot BlinkEditSnapshot
---@param completion_lines string[]
---@return string[]|nil merged
---@return table|nil cursor_after
---@return string|nil error
local function merge_completion(snapshot, completion_lines)
  if not completion_lines or #completion_lines == 0 then
    return nil, nil, "empty completion"
  end

  local cursor_line = snapshot.cursor[1]
  local cursor_col = snapshot.cursor[2]
  local window_start = snapshot.window_start

  local cursor_index = cursor_line - window_start + 1
  if cursor_index < 1 or cursor_index > #snapshot.lines then
    return nil, nil, "cursor outside window"
  end

  local current_line = snapshot.lines[cursor_index] or ""
  local prefix = current_line:sub(1, cursor_col)
  local suffix = current_line:sub(cursor_col + 1)

  local merged = {}
  for i = 1, cursor_index - 1 do
    table.insert(merged, snapshot.lines[i])
  end

  if #completion_lines == 1 then
    table.insert(merged, prefix .. completion_lines[1] .. suffix)
  else
    table.insert(merged, prefix .. completion_lines[1])
    for i = 2, #completion_lines - 1 do
      table.insert(merged, completion_lines[i])
    end
    table.insert(merged, (completion_lines[#completion_lines] or "") .. suffix)
  end

  for i = cursor_index + 1, #snapshot.lines do
    table.insert(merged, snapshot.lines[i])
  end

  local cursor_after_line = cursor_line + #completion_lines - 1
  local cursor_after_col
  if #completion_lines == 1 then
    cursor_after_col = #prefix + #completion_lines[1]
  else
    cursor_after_col = #(completion_lines[#completion_lines] or "")
  end

  return merged, { cursor_after_line, cursor_after_col }, nil
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Trigger a prediction (debounced) - called on TextChangedI
---@param bufnr number
function M.trigger(bufnr)
  local cfg = config.get()

  -- Cancel existing debounce timer
  cancel_debounce(bufnr)

  -- Check if buffer is valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Check if plugin is enabled
  if vim.g.blink_edit_enabled == false then
    return
  end

  -- Check filetype
  local ft = vim.bo[bufnr].filetype
  if not config.is_filetype_enabled(ft) then
    return
  end

  -- Create new debounce timer
  local timer = uv.new_timer()
  debounce_timers[bufnr] = {
    timer = timer,
    bufnr = bufnr,
  }

  -- Start debounce timer
  timer:start(cfg.debounce_ms, 0, function()
    -- Timer fired - close it
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    debounce_timers[bufnr] = nil

    -- Run valve logic in main loop
    vim.schedule(function()
      M._on_debounce_fired(bufnr)
    end)
  end)
end

--- Called when debounce timer fires
---@param bufnr number
function M._on_debounce_fired(bufnr)
  local cfg = config.get()

  -- Check if buffer is still valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- 1. Clear existing ghost text
  render.clear(bufnr)

  -- 2. Capture snapshot (current state)
  local snapshot = state.capture_snapshot(bufnr)

  -- 3. Push to stack (replaces any existing)
  state.push_to_stack(bufnr, snapshot)

  -- 4. Check valve state
  if state.is_in_flight(bufnr) then
    if cfg.cancel_in_flight then
      -- Cancel the in-flight request and start new one immediately
      local request_id = state.get_in_flight_request_id(bufnr)
      if request_id then
        transport.cancel(request_id)
      end
      state.clear_in_flight(bufnr)

      if vim.g.blink_edit_debug then
        log.debug("Cancelled in-flight request, starting new")
      end

      -- Pop from stack and start request
      local pending = state.pop_from_stack(bufnr)
      if pending then
        start_request(bufnr, pending)
      end
    else
      -- Valve closed - wait for current request to complete
      if vim.g.blink_edit_debug then
        log.debug("Valve closed, pushed to stack")
      end
    end
  else
    -- Valve open - start request immediately
    local pending = state.pop_from_stack(bufnr)
    if pending then
      start_request(bufnr, pending)
    end
  end
end

--- Trigger a prediction immediately (bypass debounce)
---@param bufnr number
function M.trigger_now(bufnr)
  -- Cancel any existing debounce
  cancel_debounce(bufnr)

  -- Check if buffer is valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Check if plugin is enabled
  if vim.g.blink_edit_enabled == false then
    return
  end

  -- Directly fire the debounce logic
  M._on_debounce_fired(bufnr)
end

--- Cancel pending request for a buffer
---@param bufnr number
function M.cancel(bufnr)
  -- Cancel debounce timer
  cancel_debounce(bufnr)

  -- Cancel in-flight request
  local request_id = state.get_in_flight_request_id(bufnr)
  if request_id then
    transport.cancel(request_id)
    state.clear_in_flight(bufnr)
    ui.hide_progress()
  end

  -- Clear ghost text and prediction
  render.clear(bufnr)
end

--- Accept the current prediction
---@param bufnr number
---@return boolean success
function M.accept(bufnr)
  local prediction = state.get_prediction(bufnr)
  if not prediction then
    return false
  end

  -- Apply the prediction (replaces window with predicted content)
  local success, merged_lines = render.apply(bufnr)
  if not success then
    return false
  end

  local cfg = config.get()
  if cfg.context.enabled and cfg.context.history.enabled and cfg.llm.provider ~= "zeta" then
    -- Add per-hunk history from applied content
    local window_start = prediction.window_start
    local snapshot_lines = prediction.snapshot_lines
    local applied_lines = merged_lines or prediction.predicted_lines

    local cursor_offset = 1
    if prediction.cursor then
      cursor_offset = prediction.cursor[1] - window_start + 1
      cursor_offset = math.max(1, cursor_offset)
    end

    local filepath = utils.normalize_filepath(vim.api.nvim_buf_get_name(bufnr))

    local diff_result = diff.compute(snapshot_lines, applied_lines)
    for _, hunk in ipairs(diff_result.hunks) do
      if hunk.start_old >= cursor_offset then
        local original_text = table.concat(hunk.old_lines or {}, "\n")
        local updated_text = table.concat(hunk.new_lines or {}, "\n")

        local start_old = hunk.count_old > 0 and (window_start + hunk.start_old - 1) or nil
        local end_old = hunk.count_old > 0 and (window_start + hunk.start_old + hunk.count_old - 2) or nil
        local start_new = hunk.count_new > 0 and (window_start + hunk.start_new - 1) or nil
        local end_new = hunk.count_new > 0 and (window_start + hunk.start_new + hunk.count_new - 2) or nil

        local start_line = start_new or start_old
        local end_line = end_new or end_old

        state.add_to_history(bufnr, filepath, original_text, updated_text, {
          start_line = start_line,
          end_line = end_line,
          start_line_old = start_old,
          end_line_old = end_old,
          start_line_new = start_new,
          end_line_new = end_new,
        })
      end
    end
  end

  -- Clear prediction state (render.apply doesn't clear it so we can use it for cursor)
  state.clear_prediction(bufnr)

  -- Clear selection after accepting (user's intent fulfilled)
  state.clear_selection(bufnr)

  -- Update baseline (new starting point for next edit)
  state.update_baseline(bufnr)

  -- Cancel any pending debounce to prevent stale request from TextChangedI
  cancel_debounce(bufnr)

  -- Move cursor to end of last actual change
  local predicted_lines = prediction.predicted_lines
  local snapshot_lines = prediction.snapshot_lines
  local window_start = prediction.window_start
  local target_cursor = prediction.cursor_after
  local end_line
  local end_col

  if target_cursor then
    -- Completion mode: use pre-computed cursor position
    end_line = target_cursor[1]
    end_col = target_cursor[2]
  else
    -- Next-edit mode: find largest meaningful change at/below cursor and position at end of it
    local diff_result = diff.compute(snapshot_lines, predicted_lines)

    -- Calculate cursor offset in window (1-indexed)
    local cursor_offset = 1
    if prediction.cursor then
      cursor_offset = prediction.cursor[1] - window_start + 1
      cursor_offset = math.max(1, cursor_offset)
    end

    if diff_result.has_changes and #diff_result.hunks > 0 then
      -- Find hunk with largest net addition, but ONLY consider hunks at/below cursor
      local best_hunk = nil
      local best_score = -999

      for _, hunk in ipairs(diff_result.hunks) do
        -- Only consider hunks at or below cursor (next-edit semantics)
        if hunk.start_old >= cursor_offset then
          local score = hunk.count_new - hunk.count_old
          if score > best_score then
            best_score = score
            best_hunk = hunk
          end
        end
      end

      if best_hunk then
        if best_hunk.type == "deletion" or best_hunk.count_new == 0 then
          -- Deletion: position at line where deletion occurred
          end_line = window_start + best_hunk.start_new - 1
          end_col = 0
        else
          -- Has new content: end of that content
          local hunk_end = best_hunk.start_new + best_hunk.count_new - 1
          hunk_end = math.max(1, math.min(hunk_end, #predicted_lines))
          end_line = window_start + hunk_end - 1
          end_col = #(predicted_lines[hunk_end] or "")
        end
      else
        -- No hunks at/below cursor, stay at cursor position
        end_line = prediction.cursor[1]
        end_col = prediction.cursor[2]
      end
    else
      -- No changes detected, stay within original window bounds
      end_line = window_start + #snapshot_lines - 1
      end_col = #(snapshot_lines[#snapshot_lines] or "")
    end
  end

  -- Ensure line is valid
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if end_line > line_count then
    end_line = line_count
  end
  if end_line < 1 then
    end_line = 1
  end

  -- Get line content to ensure col is valid
  local ok, line_data = pcall(vim.api.nvim_buf_get_lines, bufnr, end_line - 1, end_line, false)
  local line_content = (ok and line_data[1]) or ""
  if end_col > #line_content then
    end_col = #line_content
  end

  vim.api.nvim_win_set_cursor(0, { end_line, end_col })

  if vim.g.blink_edit_debug then
    log.debug(string.format("Accepted prediction, history=%d", state.get_history_count(bufnr)))
  end

  return true
end

--- Reject the current prediction
---@param bufnr number
function M.reject(bufnr)
  -- Cancel debounce and in-flight
  cancel_debounce(bufnr)

  local request_id = state.get_in_flight_request_id(bufnr)
  if request_id then
    transport.cancel(request_id)
    state.clear_in_flight(bufnr)
  end

  -- Clear ghost text
  render.clear(bufnr)

  if vim.g.blink_edit_debug then
    log.debug("Prediction rejected")
  end
end

--- Check if there's an active prediction
---@param bufnr number
---@return boolean
function M.has_prediction(bufnr)
  return render.has_visible(bufnr)
end

--- Called when cursor moves - check if we should clear prediction
---@param bufnr number
function M.on_cursor_moved(bufnr)
  local prediction = state.get_prediction(bufnr)
  if not prediction then
    return
  end

  -- Get current cursor position
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]

  -- Check if cursor is still within the prediction window
  local start_line = prediction.window_start
  local end_line = prediction.window_start + math.max(#prediction.snapshot_lines, #prediction.predicted_lines) - 1

  -- Allow some tolerance (2 lines above/below)
  if cursor_line < start_line - 2 or cursor_line > end_line + 2 then
    -- Cursor moved away from prediction area - clear it
    M.reject(bufnr)
  end
end

--- Called on InsertEnter - capture baseline
---@param bufnr number
function M.on_insert_enter(bufnr)
  -- Capture baseline (state before user's edits in this insert session)
  state.capture_baseline(bufnr)

  -- If there's a pending snapshot in the stack from a previous session,
  -- we could start a request here, but typically the stack should be empty
  if state.has_pending_snapshot(bufnr) and not state.is_in_flight(bufnr) then
    local pending = state.pop_from_stack(bufnr)
    if pending then
      start_request(bufnr, pending)
    end
  end
end

--- Called on InsertLeave - cleanup
---@param bufnr number
function M.on_insert_leave(bufnr)
  -- Cancel in-flight request
  local request_id = state.get_in_flight_request_id(bufnr)
  if request_id then
    transport.cancel(request_id)
    state.clear_in_flight(bufnr)
  end

  -- Clear ghost text
  render.clear(bufnr)
end

--- Cleanup engine state (called on reset)
function M.cleanup()
  -- Cancel all debounce timers
  for bufnr, _ in pairs(debounce_timers) do
    cancel_debounce(bufnr)
  end
  debounce_timers = {}

  -- Clear provider cache
  provider_cache = {}

  -- Clear all state
  state.clear_all()
end

return M
