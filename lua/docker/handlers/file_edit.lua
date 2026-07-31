--- Edits a file inside a container with Neovim.
---
--- The file is pulled into a temporary area with `docker cp` and opened in a buffer named
--- `docker://<container>/<path>`. Saving is intercepted with `BufWriteCmd` and written back with `docker cp`.
--- When the write back fails, `modified` is left set (so that changes are not lost).
local cli = require("docker.adapters.docker.cli")
local notify = require("docker.notify")

local M = {}

--- buffer number -> write-back destination
---@type table<integer, { id: string, label: string, path: string, local_path: string }>
local targets = {}

local augroup = vim.api.nvim_create_augroup("DockerNvimFileEdit", { clear = true })

--- For tests. Discards the mappings of opened buffers.
function M._reset()
  targets = {}
end

--- Builds the name under which a path inside the container is copied to the temporary area.
--- The ID is mixed in so that opening the same path in a different container does not collide.
---@param id string
---@param path string
---@return string
local function local_path_for(id, path)
  local safe = path:gsub("[^%w%-_.]", "_")
  return ("%s/docker-nvim-%s-%s"):format(vim.fn.stdpath("cache"), id:sub(1, 12), safe)
end

--- The buffer whose name matches exactly. `vim.fn.bufnr` matches by pattern, so it would grab
--- a different buffer such as `docker://web/etc/hosts.orig`.
---@param name string
---@return integer|nil
local function buffer_named(name)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(bufnr) == name then
      return bufnr
    end
  end
  return nil
end

--- The window showing the buffer in the current tab page.
---@param bufnr integer
---@return integer|nil
local function window_showing(bufnr)
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(winid) == bufnr then
      return winid
    end
  end
  return nil
end

--- Cleanup for when the buffer is closed.
---@param bufnr integer
function M._on_buffer_closed(bufnr)
  local target = targets[bufnr]
  if not target then
    return
  end
  targets[bufnr] = nil
  vim.fn.delete(target.local_path)
  -- `:bdelete` keeps the buffer number around, so the interception is released too. Leaving it
  -- in place would attach BufWriteCmd twice when the file is opened again.
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_clear_autocmds, { group = augroup, buffer = bufnr })
  end
end

--- Writes the buffer back.
---@param bufnr integer
function M.write(bufnr)
  local target = targets[bufnr]
  if not target then
    return
  end

  -- Dump the buffer contents into the temporary file before sending them.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  vim.fn.writefile(lines, target.local_path)

  cli.run({ "cp", target.local_path, ("%s:%s"):format(target.id, target.path) }, function(result)
    if not result.ok then
      -- On failure keep modified set. Clearing it would make the changes look lost.
      notify.error(result.error or "Failed to write back to the container")
      return
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.bo[bufnr].modified = false
    end
    notify.info(("Saved %s:%s"):format(target.label, target.path))
  end)
end

--- Opens a file inside the container. No buffer is opened when the extraction fails.
---@param id string
---@param label string
---@param path string
---@param on_done fun(bufnr: integer|nil)|nil
function M.open(id, label, path, on_done)
  local function done(bufnr)
    if on_done then
      on_done(bufnr)
    end
  end

  local local_path = local_path_for(id, path)
  cli.run({ "cp", ("%s:%s"):format(id, path), local_path }, function(result)
    if not result.ok then
      notify.error(result.error or ("Could not copy %s out of the container"):format(path))
      return done(nil)
    end

    -- Given a directory, `docker cp` pulls the whole thing down. A buffer cannot handle that,
    -- so the pulled contents are discarded before refusing. Keeping them would pile the
    -- container's directory tree up in the cache.
    if vim.fn.isdirectory(local_path) == 1 then
      vim.fn.delete(local_path, "rf")
      notify.error(("%s is a directory, so it cannot be edited"):format(path))
      return done(nil)
    end

    -- `acwrite` is the buffer type meaning "saving is handled by an autocmd".
    -- With bufadd + bufload the type gets reset because a nonexistent path is read,
    -- so the buffer is created here and then given its name and type.
    -- When the same file is opened twice, the existing buffer is reused.
    -- Creating a new one and giving it the same name would fail with E95 (duplicate buffer name).
    local name = ("docker://%s%s"):format(label, path)
    local bufnr = buffer_named(name)
    if not bufnr then
      bufnr = vim.api.nvim_create_buf(true, false)
      local named = pcall(vim.api.nvim_buf_set_name, bufnr, name)
      if not named then
        vim.api.nvim_buf_delete(bufnr, { force = true })
        notify.error(("Could not open %s (the buffer name conflicts)"):format(path))
        return done(nil)
      end
    end
    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].swapfile = false
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.fn.readfile(local_path))
    vim.bo[bufnr].modified = false

    -- For a buffer already being managed the autocmds are not attached again. Attaching them
    -- on top of each other would run the write back several times for a single save.
    local already_managed = targets[bufnr] ~= nil
    targets[bufnr] = { id = id, label = label, path = path, local_path = local_path }

    if not already_managed then
      -- Intercept saving and write back to docker.
      vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = augroup,
        buffer = bufnr,
        desc = "docker.nvim: write back to the file in the container",
        callback = function()
          M.write(bufnr)
        end,
      })

      -- On wipeout, release the mapping and delete the extracted contents as well.
      vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
        group = augroup,
        buffer = bufnr,
        once = true,
        desc = "docker.nvim: clean up the edit buffer",
        callback = function()
          M._on_buffer_closed(bufnr)
        end,
      })
    end

    -- The list is a float window, and swapping the buffer while it has focus wipes out the
    -- list buffer, which is bufhidden=wipe. Always open a new window (a full-width split at
    -- the bottom of the screen, same as terminal).
    -- If the file is already displayed, go back to it instead of adding another window.
    local shown = window_showing(bufnr)
    if shown then
      vim.api.nvim_set_current_win(shown)
    else
      vim.api.nvim_open_win(bufnr, true, { split = "below", win = -1 })
    end
    done(bufnr)
  end)
end

return M
