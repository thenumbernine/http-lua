#!/usr/bin/env lua
-- TODO how about instead to match namespaces / requires elsewhere
-- how about rename http.class => http.http
-- and rename this file http.http => http.run ?

local HTTP = require 'http.class'
local cmdline = require 'ext.cmdline'(...)

local enableDirectoryListing = _G.enableDirectoryListing
if enableDirectoryListing == nil then enableDirectoryListing = cmdline.enableDirectoryListing end

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
	enableDirectoryListing = enableDirectoryListing,
	allowFrom = _G.allowFrom or cmdline.allowFrom,
}

http:run()
