#!/usr/bin/env lua
-- example of how to use local https server with certs 
-- localhost certs can be made with:
--  openssl req -x509 -sha256 -nodes -newkey rsa:2048 -days 365 -keyout localhost.key -out localhost.crt
require 'http.class'{
	addr = 'localhost',
	port = 8000,
	sslport = 8001,
	keyfile = '/path/to/localhost.key',
	certfile = '/path/to/localhost.crt',
	--block = true, -- default false	
	--wsapi = false, -- default true
	log = tonumber((...)) or 0,
}:run()
