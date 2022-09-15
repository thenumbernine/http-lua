local file = require 'ext.file'
local table = require 'ext.table'
local class = require 'ext.class'
local string = require 'ext.string'
local template = require 'template'
local socket = require'socket'
local url = require 'socket.url'
local http = require 'socket.http'
local MIMETypes = require 'mimetypes'


-- bcuz of a subclass that's hacking global print ...
local print = print


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


	self.docroot = file:cwd()


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
	self:log(10, "looking for dontinterpret at docroot='"..docroot.."' remotePath='"..remotePath.."'")
	local localPath = docroot .. remotePath
	local dir = file(localPath):getdir()
	local docrootparts = string.split(docroot, '/')
	local dirparts = string.split(dir, '/')
	for i=1,#docrootparts do
		assert(docrootparts[i] == dirparts[i])
	end
	for i=#dirparts,#docrootparts,-1 do
		local check = table.concat({table.unpack(dirparts,1,i)}, '/')..'/.dontinterpret'
		self:log(10, "checking file '"..check.."'")
		if file(check):exists() then
			self:log(10, "found .dontinterpret")
			return true
		end
	end
	self:log(10, "didn't find .dontinterpret")
end

-- returns the template code to execute when handling a directory
function HTTP:handleDirectoryTemplate()
	return [[
<html>
	<head>
		<title>Directory Listing of <?=filename?></title>
		<style type="text/css"> td{padding-right:20px};</style>
	</head>
	<body>
		<h3>Index of <?=filename?></h3>
		<table>
			<tr>
				<th>Name</th>
				<th>Modified</th>
				<th>Size</th>
			</tr>
<? for _,f in ipairs(files) do
	local displayfile = f
	local subattr = file(localfilename..'/'..f):attr()
	if subattr and subattr.mode == 'directory' then
		displayfile = '[' .. displayfile .. ']'
	end
?>			<tr>
				<td><a href="<?=(filename..'/'..f):gsub('//', '/')?>"><?=displayfile?></a></td>
				<td><?=(subattr and os.date('%Y-%m-%d %H:%M:%S',subattr.modification) or '')?></td>
				<td style="text-align:center"><?=(subattr and (subattr.mode == 'directory' and '-' or subattr.size) or '')?></td>
			</tr>
<? end
?>		</table>
	</body>
</html>
]]
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
		
		local files = table()
		for f in file(localfilename):dir() do
			if f ~= '.' then
				files:insert(f)
			end
		end
		files:sort(function (a,b) return a:lower() < b:lower() end)

		coroutine.yield(
			template(
				self:handleDirectoryTemplate(),
				{
					lfs = require 'lfs',	-- TODO file?
					files = files,
					localfilename = localfilename,
					filename = filename,
				}
			)
		)
	end)
end

function HTTP:makeGETTable(GET)
	if not GET then return {} end
	return string.split(GET or '', '&'):map(function(kv, _, t)
		local k, v = kv:match('([^=]*)=(.*)')
		if not v then k,v = kv, #t+1 end
		k, v = url.unescape(k), url.unescape(v)
		return v, k
	end)
end

function HTTP:handleFile(
	filename,
	localfilename,
	ext,
	dir,
	headers,
	reqHeaders,
	GET,
	POST
)
	local result = file(localfilename):read()
	if not result then
		self:log(1, 'from dir '..file:cwd()..' failed to read file at', localfilename)
		return '403 Forbidden', coroutine.wrap(function()
			coroutine.yield('failed to read file '..filename)
		end)
	end

	local dontinterpret = self:findDontInterpret(
		self.docroot, --dir,
		filename)
	self:log(1, 'dontinterpret?', dontinterpret)
	
	if self.wsapi and (
		localfilename:sub(-9) == '.html.lua'
		or localfilename:sub(-7) == '.js.lua'
	) then
		self:log(1, 'running templated script',filename)
		assert(file(dir):cd())
		headers['content-type'] = 
			localfilename:sub(-7) == '.js.lua'
			and self.mime.types.js
			or self.mime.types.html
		return '200/OK', coroutine.wrap(function()
			coroutine.yield(template(result, {
				env = {
					--SERVER_NAME = os.getenv'HOSTNAME',
					SCRIPT_FILENAME = localfilename,
				},
			}))
		end)
	end

	if self.wsapi 
	and ext == 'lua' 
	and not dontinterpret
	then
		self:log(1, 'running script',filename)
		assert(file(dir):cd())
	
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
			GET = self:makeGETTable(GET),
			POST = POST,
			-- wsapi variables:
			SCRIPT_FILENAME = localfilename,
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
		coroutine.yield(file(localfilename):read())
	end)
end

-- docroot is more traditional, this is more flexible, here's how I'm mixing them
function HTTP:getSearchPaths()
	return table{self.docroot}
end

function HTTP:handleRequest(...)
	self:log(2, "HTTP:handleRequest", ...)
	local filename,
		headers,
		reqHeaders,
		method,
		proto,
		GET,
		POST = ...

	headers['cache-control'] = 'no-cache, no-store, must-revalidate'
	headers['pragma'] = 'no-cache'
	headers['expires'] = '0'
	
	-- this is slowly becoming a real webserver
	-- do multiple search paths here:
	for _,searchdir in ipairs(self:getSearchPaths()) do
		self:log(1, "searching in dir "..searchdir)

		local localfilename = (searchdir..'/'..filename):gsub('/+', '/')
		
		local attr = file(localfilename):attr()
		if attr then
			if attr.mode == 'directory' then
				self:log(1, 'serving directory',filename)
				return self:handleDirectory(filename, localfilename, headers)
			end

			-- handle file:
			local _,ext = file(localfilename):getext()
			local dirforfile, _ = file(localfilename):getdir()
			self:log(1, 'ext', ext)
			self:log(1, 'dirforfile', dirforfile)
			
			return self:handleFile(
				filename,
				localfilename,
				ext,
				dirforfile,
				headers,
				reqHeaders,
				GET,
				POST
			)
		else
			self:log(1, 'from searchdir '..searchdir..' failed to find file at', localfilename)
		end
	end

	self:log(1, 'failed to find any files at', filename)
	return '404 Not Found', coroutine.wrap(function()
		coroutine.yield('failed to find file '..filename)
	end)
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
		
		method = method:lower()
		if method == 'get' then
			-- fall through, don't error
-- [[
		elseif method == 'post' then
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
				self:log(0, "didn't get POST data length")
			else
				self:log(1, 'reading POST '..postLen..' bytes')
				--local postData = readline()
				local postData = client:receive(postLen)
				self:log(1, 'read POST data: '..postData)
				POST = string.split(postData, '&'):mapi(function(kv, _, t)
					local k, v = kv:match'([^=]*)=(.*)'
					if not v then k,v = kv, #t+1 end
					self:log(10, 'before unescape, k='..k..' v='..v)							
					
					-- plusses are already encoded as %2B, right?
					-- because it looks like jQuery ajax() POST is replacing ' ' with '+'
					k = k:gsub('+', ' ')
					v = v:gsub('+', ' ')
					
					k, v = url.unescape(k), url.unescape(v)
					self:log(10, 'after unescape, k='..k..' v='..v)							
					return v, k
				end)
			end
--]]
		else
			error("unknown method: "..method)
		end
		
		filename = url.unescape(filename:gsub('%+','%%20'))
		local base, GET = filename:match('(.-)%?(.*)')
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
				GET,
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
	assert(file(self.docroot):cd())
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
				--[[ can I do this?
				-- from https://stackoverflow.com/questions/2833947/stuck-with-luasec-lua-secure-socket
				-- TODO need to specify cert files
				-- TODO but if you want to handle both https and non-https on different ports, that means two connections, that means better make non-blocking the default
				if self.usetls then
					local ssl = require 'ssl'	-- package luasec
					assert(client:settimeout(10))
					client = assert(ssl.wrap(client, {
						mode = 'server',
						protocol = 'sslv3',
						key = 'path/to/server.key',
						certificate = 'path/to/server.crt',
						password = '12345',
						options = {'all', 'no_sslv2'},
						ciphers = 'ALL:!ADH:@STRENGTH',
					}))
					client:dohandshake()
				end
				--]]
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
