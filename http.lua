#!/usr/bin/env lua
local HTTP = require 'http.class'
local cmdline = require 'ext.cmdline'(...)

-- using globals allows initializing this via "lua -e 'key=value ...' -lhttp"
-- but using a script wrapper could easily
local http = HTTP{
	addr = _G.addr or cmdline.addr,
	port = _G.port or cmdline.port,
	sslport = _G.sslport or cmdline.sslport,
	keyfile = _G.keyfile or cmdline.keyfile,
	certfile = _G.certfile or cmdline.certfile,
	block = _G.block or cmdline.block,
	wsapi = _G.wsapi or cmdline.wsapi,
	log = _G.log or cmdline.log,
}

http:run()
