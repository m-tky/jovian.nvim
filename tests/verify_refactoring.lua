package.path = package.path .. ";./lua/?.lua"
local Hosts = require("jovian.hosts")
local Core = require("jovian.core")
local Config = require("jovian.config")

print("Verifying Host Management Refactoring...")

-- Test 1: Load Hosts (should return default if empty)
local data = Hosts.load_hosts()
assert(data.configs.local_default, "local_default should exist")
assert(data.current == "local_default", "current should be local_default")
print("PASS: Load Hosts")

-- Test 2: Add Host
local test_host = { type = "local", python = "python3" }
Hosts.add_host("test_env", test_host)
data = Hosts.load_hosts()
assert(data.configs.test_env, "test_env should exist")
print("PASS: Add Host")

-- Test 3: Use Host
Hosts.use_host("test_env")
data = Hosts.load_hosts()
assert(data.current == "test_env", "current should be test_env")
assert(Config.options.python_interpreter == "python3", "Config should be updated")
print("PASS: Use Host")

-- Test 4: Remove Host
Hosts.remove_host("test_env")
data = Hosts.load_hosts()
assert(data.configs.test_env == nil, "test_env should be removed")
assert(data.current == "local_default", "current should fallback to local_default")
print("PASS: Remove Host")

print("All Refactoring Tests Passed!")
vim.cmd("q")
