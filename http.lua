local HTTP = require 'http.class'

-- using globals allows initializing this via "lua -e 'key=value ...' -lhttp"
-- but using a script wrapper could easily
local http = HTTP{
	port = _G.port or cmdline.port,
	addr = _G.addr or cmdline.addr,
	block = _G.block or cmdline.block,
	wsapi = _G.wsapi or cmdline.wsapi,
	log = _G.log or cmdline.log,
}

http:run()
