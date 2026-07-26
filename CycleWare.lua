-- CycleWare.lua
-- Author: nutellaimw
-- Created: 2026-07-26
-- Simple CycleWare module: manage repeating cycles/timers with a small, portable API.
--
-- Features:
--  - Create a cycle with an interval (milliseconds) and a callback
--  - Non-blocking `tick(dt)` method for embedding in an existing loop
--  - Blocking `run_blocking()` convenience method (uses socket.select if available)
--  - start/stop/reset helpers
--
-- Example:
-- local CycleWare = require("CycleWare")
-- local c = CycleWare.new(1000, function(self) print("tick") end)
-- -- in your main loop call: c:tick(delta_ms)
-- -- or run blocking: c:run_blocking()

local CycleWare = {}
CycleWare.__index = CycleWare
CycleWare.VERSION = "0.1.0"

-- Creates a new cycle object.
-- interval_ms: number, milliseconds between callbacks
-- callback(self): function called when the cycle fires
function CycleWare.new(interval_ms, callback)
  assert(type(interval_ms) == "number" and interval_ms > 0, "interval_ms must be a positive number")
  assert(type(callback) == "function", "callback must be a function")
  local self = setmetatable({
    interval = interval_ms,
    callback = callback,
    running = false,
    _accum = 0,
  }, CycleWare)
  return self
end

-- Advance the cycle by dt milliseconds. Call this from your host's update loop.
function CycleWare:tick(dt)
  if not dt or type(dt) ~= "number" then return end
  self._accum = (self._accum or 0) + dt
  if self._accum >= self.interval then
    local ok, err = pcall(self.callback, self)
    if not ok then
      io.stderr:write("CycleWare callback error: ", tostring(err), "\n")
    end
    self._accum = self._accum % self.interval
  end
end

-- start/stop utilities for bookkeeping when using run_blocking
function CycleWare:start()
  self.running = true
  return self
end

function CycleWare:stop()
  self.running = false
  return self
end

function CycleWare:reset()
  self._accum = 0
  return self
end

-- Blocking runner: repeatedly calls the callback every interval.
-- Uses socket.select for sleeping if LuaSocket is available; otherwise falls back to busy-wait (not recommended).
function CycleWare:run_blocking()
  local ok_socket, socket = pcall(require, "socket")
  local function sleep(sec)
    if ok_socket and socket and socket.select then
      socket.select(nil, nil, sec)
    else
      -- fallback busy-wait (coarse)
      local t0 = os.clock()
      while os.clock() - t0 < sec do end
    end
  end

  self:start()
  while self.running do
    local ok, err = pcall(self.callback, self)
    if not ok then
      io.stderr:write("CycleWare callback error: ", tostring(err), "\n")
    end
    sleep(self.interval / 1000)
  end
  return self
end

-- Convenience module return
return CycleWare
