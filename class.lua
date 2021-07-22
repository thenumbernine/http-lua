local lfs = require 'lfs'
local table = require 'ext.table'
local class = require 'ext.class'
local string = require 'ext.string'
local io = require 'ext.io'
local os = require 'ext.os'
local socket = require'socket'
local url = require 'socket.url'
local http = require 'socket.http'
local MIMETypes = require 'mimetypes'


local HTTP = class()

--[[
args:
	port = port to use, default 8000
	addr = address to bind to, default *
	block = whether to use blocking, default true
	wsapi = whether to use wsapi emulation
	config = where to store the mimetypes file
	log = log level.  level 0 = none, 1 = only most serious, 2 3 etc = more and more information, all the way to infinity.
--]]
function HTTP:init(args)
	args = args or {}


	local config = args.config or (os.getenv'HOME' or os.getenv'USERPROFILE')..'/.http.lua.conf'
	self.mime = MIMETypes(config)


	self.loglevel = args.log or 0


	local port = args.port or 8000
	local addr = args.addr or '*'
	self.server = assert(socket.bind(addr, port))
	self.addr, self.port = self.server:getsockname()
	self:log(1, 'listening '..self.addr..':'..self.port)


	self.block = args.block
	-- use blocking by default.
	-- I had some trouble with blocking and MathJax on android.  Maybe it was my imagination.
	if self.block == nil then self.block = true end
	if self.block then
		--assert(server:settimeout(3600))
		--server:setoption('keepalive',true)
		--server:setoption('linger',{on=true,timeout=3600})
	else
		assert(server:settimeout(0,'b'))
	end


	-- configuration specific to file handling
	-- this stuff is not important if you are doing your own custom handlers


	self.docroot = lfs.currentdir()


	-- whether to simulate wsapi for .lua pages
	self.wsapi = args.wsapi
	if self.wsapi == nil then self.wsapi = true end
	if self.wsapi then
		package.loaded['wsapi.request'] = {
			new = function(env) 
				env = env or {}
				env.doc_root = self.docroot
				return env
			end,
		}
	end


	self.clients = table()
end

function HTTP:log(level, ...)
	if level > self.loglevel then return end
	print(...)
end

function HTTP:findDontInterpret(docroot, remotePath)
	local localPath = docroot .. remotePath
	local dir = io.getfiledir(localPath)
	local docrootparts = string.split(docroot, '/')
	local dirparts = string.split(dir, '/')
	for i=1,#docrootparts do
		assert(docrootparts[i] == dirparts[i])
	end
	for i=#dirparts,#docrootparts,-1 do
		local check = table.concat({table.unpack(dirparts,1,i)}, '/')
		if os.fileexists(check..'/.dontinterpret') then
			return true
		end
	end
end

-- return callback
-- headers is modifyable
function HTTP:handleDirectory(
	filename,
	localfilename,
	headers
)
	headers['content-type'] = 'text/html'
	return '200/OK', coroutine.wrap(function()
		coroutine.yield(
			'<html>\n'
			..'<head>\n'
			..'<title>Directory Listing of '..filename..'</title>\n'
			..'<style type="text/css"> td{padding-right:20px};</style>\n'
			..'</head>\n'
			..'<body>\n'
			..'<h3>Index of '..filename..'</h3>\n'
			..'<table>\n'
			..'<tr><th>Name</th><th>Modified</th><th>Size</th></tr>\n')
		local files = table()
		for f in lfs.dir(localfilename) do
			files:insert(f)
		end
		files:sort(function (a,b) return a:lower() < b:lower() end)
		for _,f in ipairs(files) do
			if f ~= '.' then
				local nextfilename = (filename..'/'..f):gsub('//', '/')
				local displayfile = f
				local subattr = lfs.attributes(localfilename..'/'..f)
				if subattr and subattr.mode == 'directory' then
					displayfile = '[' .. displayfile .. ']'
				end
				coroutine.yield(
					'<tr>'
					..'<td><a href="'..nextfilename..'">'..displayfile..'</a></td>'
					..'<td>'..(subattr and os.date('%Y-%m-%d %H:%M:%S',subattr.modification) or '')..'</td>'
					..'<td style="text-align:center">'..(subattr and (subattr.mode == 'directory' and '-' or subattr.size) or '')..'</td>'
					..'</tr>\n')
			end
		end
		coroutine.yield(
			'</table>\n'
			..'</body>\n')
	end)
end

function HTTP:handleFilename(
	filename,
	localfilename,
	headers,
	reqHeaders,
	POST
)
	local result = io.readfile(localfilename)
	if not result then
		self:log(1, 'from dir '..lfs.currentdir()..' failed to find file at', localfilename)
		return '404 Not Found', coroutine.wrap(function()
			coroutine.yield('failed to find file '..filename)
		end)
	end

	local _,ext = io.getfileext(localfilename)
	local dir, _ = io.getfiledir(localfilename)
	self:log(1, 'wsapi',self.wsapi)
	self:log(1, 'ext',ext)
	local dontinterpret = self:findDontInterpret(self.docroot, filename)
	self:log(1, 'dontinterpret?', dontinterpret)
	
	if self.wsapi and (
		localfilename:sub(-9) == '.html.lua'
		or localfilename:sub(-7) == '.js.lua'
	) then
		self:log(1, 'running templated script',filename)
		assert(lfs.chdir(dir))
		headers['content-type'] = self.mime.types.html
		return '200/OK', coroutine.wrap(function()
			coroutine.yield(require 'template'(result))
		end)
	end

	if self.wsapi 
	and ext == 'lua' 
	and not dontinterpret
	then
		self:log(1, 'running script',filename)
		assert(lfs.chdir(dir))
	
		-- trim off the linux executable stuff that lua interpreter usually does for me
		if result:sub(1,2) == '#!' then
			result = result:match'^[^\n]*\n(.*)$'
		end
		
		local sandboxenv = setmetatable({}, {__index=_ENV})
		local f, err = load(result, localfilename, 'bt', sandboxenv)
		if not f then 
			io.stderr:write(require 'template.showcode'(result),'\n')
			error(err) 
		end
		local fn = assert(f())
		local status, headers2, callback = fn.run{
			reqHeaders = reqHeaders,
			GET = string.split(getargs or'', '&'):map(function(kv, _, t)
				local k, v = kv:match('([^=]*)=(.*)')
				if not v then k,v = kv, #t+1 end
				k, v = url.unescape(k), url.unescape(v)
				return v, k
			end),
			POST = POST,
		}
		for k,v in pairs(headers2) do
			k = k:lower()
			if not headers[k] then headers[k] = v end
		end
		if status == 200 then status = status .. '/OK' end
		return status, callback
	end

	self:log(1, 'serving file',filename)
	headers['content-type'] = ext and self.mime.types[ext:lower()] or 'application/octet-stream'
	return '200/OK', coroutine.wrap(function()
		coroutine.yield(io.readfile(localfilename))
	end)
end

function HTTP:handleRequest(
	filename,
	headers,
	reqHeaders,
	method,
	proto,
	POST
)
	headers['cache-control'] = 'no-cache, no-store, must-revalidate'
	headers['pragma'] = 'no-cache'
	headers['expires'] = '0'
	
	local localfilename = ('./'..filename):gsub('/+', '/')
	
	local attr = lfs.attributes(localfilename)
	if attr and attr.mode == 'directory' then
		self:log(1, 'serving directory',filename)
		return self:handleDirectory(filename, localfilename, headers)
	end
	
	return self:handleFilename(
		filename,
		localfilename,
		headers,
		reqHeaders,
		POST
	)
end

function HTTP:handleClient(client)
	local function readline()
		local t = table.pack(client:receive())
		self:log(1, 'got line', t:unpack(1,t.n))
		if not t[1] then
			--if t[2] ~= 'timeout' then
				self:log(1, 'connection failed:',t:unpack(1,t.n))
			--end
		end
		return t:unpack(1,t.n)
	end
	
	local request = readline()
	if not request then return end

	xpcall(function()
		self:log(1, 'got request',request)
		local method, filename, proto = string.split(request, '%s+'):unpack()
		
		local POST
		local reqHeaders
-- [[
		if method:lower() == 'post' then
			reqHeaders = {}
			while true do
				local line = readline()
				if not line then break end
				line = string.trim(line)
				if line == '' then 
					self:log(1, 'done reading header')
					break 
				end
				local k,v = line:match'^(.-):(.*)$'
				if not k then
					self:log(1, "got invalid header line: "..line)
					break
				end
				reqHeaders[k:lower()] = v
			end
			
			local postLen = tonumber(reqHeaders['content-length'])
			if not postLen then
				print"didn't get POST data length"
			else
				self:log(1, 'reading POST '..postLen..' bytes')
				--local postData = readline()
				local postData = client:receive(postLen)
				self:log(1, 'read POST data: '..postData)
				POST = string.split(postData, '&'):mapi(function(kv, _, t)
					local k, v = kv:match'([^=]*)=(.*)'
					if not v then k,v = kv, #t+1 end
					self:log(10, 'before unescape, k='..k..' v='..v)							
					k, v = url.unescape(k), url.unescape(v)
					self:log(10, 'after unescape, k='..k..' v='..v)							
					return v, k
				end)
			end
		end
--]]
		filename = url.unescape(filename:gsub('%+','%%20'))
		local base, getargs = filename:match('(.-)%?(.*)')
		filename = base or filename
		if not filename then
			self:log(1, "couldn't find filename in request "..('%q'):format(request))
		else
			local headers = {}
			local status, callback = self:handleRequest(
				filename,
				headers,
				reqHeaders,
				method,
				proto,
				POST
			)
		
			local function send(s)
				self:log(10, 'sending '..s)
				return client:send(s)
			end
			assert(send('HTTP/1.1 '..status..'\r\n'))
			for k,v in pairs(headers) do
				assert(send(k..': '..v..'\r\n'))
			end
			assert(send'\r\n')
			if callback then
				self:log(10, 'wsapi started writing')
				for str in callback do
					assert(send(str))
				end
				self:log(10, 'wsapi done writing')
			else
				assert(send[[someone forgot to set a callback!]])
			end
		end
	end, function(err)
		io.stderr:write(err..'\n'..debug.traceback()..'\n')
	end)
	assert(lfs.chdir(self.docroot))
	self:log(1, 'collectgarbage', collectgarbage())
end

function HTTP:run()
	while true do
		local client	
		if self.block then
			self:log(1, 'waiting for client...')	
			client = assert(self.server:accept())
			self:log(1, 'got client!')	
			assert(client:settimeout(3600,'b'))
			self.clients:insert(client)
			self:log(1, 'total #clients',#self.clients)
		else
			client = self.server:accept()
			if client then
				assert(client:settimeout(0,'b'))
				assert(client:setoption('keepalive',true))
				self:log(1, 'got client!')
				self.clients:insert(client)
				self:log(1, 'total #clients',#self.clients)
			end
		end
		for j=#self.clients,1,-1 do
			client = self.clients[j]	
			self:handleClient(client)
			self:log(1, 'closing client...')
			client:close()
			self.clients:remove(j)
		end
	end
end

return HTTP
