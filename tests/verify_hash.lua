
package.path = package.path .. ";./lua/?.lua"
local Utils = require("jovian.utils")

local code1 = "print('hello')\nprint('world')"
local code2 = "print('hello')\n\nprint('world')"
local code3 = "print('hello')\n  \nprint('world')"
local code4 = "print('hello')\n# This is a comment\nprint('world')"
local code5 = "print('hello') # Inline comment\n  print('world')"
local code6 = "print('hello')\nprint(  'world'  )"

local hash1 = Utils.get_cell_hash(code1)
local hash2 = Utils.get_cell_hash(code2)
local hash3 = Utils.get_cell_hash(code3)
local hash4 = Utils.get_cell_hash(code4)
local hash5 = Utils.get_cell_hash(code5)
local hash6 = Utils.get_cell_hash(code6)

print("Hash 1 (Normal): " .. hash1)
print("Hash 2 (Empty Line): " .. hash2)
print("Hash 3 (Whitespace Line): " .. hash3)
print("Hash 4 (Comment Line): " .. hash4)
print("Hash 5 (Inline Comment + Indent): " .. hash5)
print("Hash 6 (Spaces in code): " .. hash6)

if hash1 == hash2 and hash1 == hash3 and hash1 == hash4 and hash1 == hash5 and hash1 == hash6 then
    print("SUCCESS: Hashes match despite formatting differences")
else
    print("FAILURE: Hashes do not match")
end
