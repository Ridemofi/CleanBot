# Lua / WoW addon rules

- After changing any .lua file, run `luac -p` on every modified Lua file before returning the final diff.
- Run the unit test suite with `lua spec/run.lua` to ensure all tests pass (0 failures).
- Target Lua 5.1 syntax compatibility for WoW 3.3.5 addons.
- If a syntax check fails, report the exact file and line.
- Keep diffs minimal.
- Always return formatted diffs with real line breaks and file paths.
