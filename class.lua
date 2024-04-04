--[[
This is starting to have a lot in common with 'websocket'
--]]
local path = require 'ext.path'
local table = require 'ext.table'
local os = require 'ext.os'
local class = require 'ext.class'
local string = require 'ext.string'
local tolua = require 'ext.tolua'
local template = require 'template'
local socket = require'socket'
local url = require 'socket.url'
local http = require 'socket.http'
local MIMETypes = require 'mimetypes'
local ThreadManager = require 'threadmanager'
local json = require 'dkjson'


-- bcuz of a subclass that's hacking global print ...
local print = print

local HTTP = class()

HTTP.enableDirectoryListing = true

--[[
args:
	addr = address to bind to, default *
	port = port to use, default 8000.  port=false means don't use non-ssl connections
	sslport = ssl port to use, default 8001. sslport=false means don't use ssl connections.
	keyfile = ssl key file
	certfile = ssl cert file
	block = whether to use blocking, default true
		block = true will have problems if port and sslport are used, since you'll have two blocking server sockets
	wsapi = whether to use wsapi emulation
	config = where to store the mimetypes file
	log = log level.  level 0 = none, 1 = only most serious, 2 3 etc = more and more information, all the way to infinity.
	threads = (optional) ThreadManager.  if you provide one then you have to update it manually.
	enableDirectoryListing = (optional) set to 'false' to disable, otherwise default is 'true'
--]]
function HTTP:init(args)
	args = args or {}

	local config = args.config or os.home()..'/.http.lua.conf'
	self.mime = MIMETypes(config)

	self.loglevel = args.log or 0

	self.enableDirectoryListing = args.enableDirectoryListing

	self.servers = table()
	local boundaddr, boundport

	local addr = args.addr or '*'
	local port = args.port or 8000		-- 80
	if port then
		self:log(3, "bind addr port "..tostring(addr)..':'..tostring(port))
		self.server = assert(socket.bind(addr, port))
		self.servers:insert(self.server)
		boundaddr, boundport = self.server:getsockname()
		self.port = boundport
		self:log(1, 'listening '..tostring(boundaddr)..':'..tostring(boundport))
	end

	local sslport = args.sslport or 8001	-- 443 ... or should I even listen on ssl by default?
	if sslport or args.keyfile or args.certfile then
		if sslport
		and args.keyfile
		and args.certfile
		then
			self.keyfile = args.keyfile
			self.certfile = args.certfile
			assert(path(self.keyfile):exists(), "failed to find keyfile "..self.keyfile)
			assert(path(self.certfile):exists(), "failed to find certfile "..self.certfile)
			self:log(3, "bind ssl addr port "..tostring(addr)..':'..tostring(sslport))
			self.sslserver = assert(socket.bind(addr, sslport))
			self.servers:insert(self.sslserver)
			boundaddr, boundport = self.sslserver:getsockname()
			self.sslport = boundport
			self:log(1, 'ssl listening '..tostring(boundaddr)..':'..tostring(boundport))
			self:log(1, 'key file '..tostring(self.keyfile))
			self:log(1, 'cert file '..tostring(self.certfile))
		else
			print('WARNING: for ssl to work you need to specify sslport, keyfile, certfile')
		end
	end

	self:log(3, '# server sockets '..tostring(#self.servers))

	self.block = args.block
	-- use blocking by default.
	-- I had some trouble with blocking and MathJax on android.  Maybe it was my imagination.
	if self.block == nil then self.block = false end
	self:log(1, "blocking? "..tostring(self.block))

	if self.block then
		--[[ not necessary?
		for _,server in ipairs{self.server, self.sslserver} do
			assert(server:settimeout(3600))
			server:setoption('keepalive',true)
			server:setoption('linger',{on=true,timeout=3600})
		end
		--]]
		if #self.servers > 1 then
			self:log(0, "WARNING: you're using blocking with two listening ports.  You will experience unexpected lengthy delays.")
		end
	else
		-- [[
		for _,server in ipairs(self.servers) do
			assert(server:settimeout(0,'b'))
		end
		--]]
	end

	-- configuration specific to file handling
	-- this stuff is not important if you are doing your own custom handlers

	self.docroot = path:cwd().path

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

	-- if you provide external ThreadManager then it has to call :update() / coroutine.resume itself.
	self.threads = args.threads
	if not self.threads then
		self.threads = ThreadManager()
		self.ownThreads = true
	end
end

function HTTP:send(conn, data)
	self:log(10, conn, '<<', tolua(data))
	local i = 1
	while true do
		-- conn:send() successful response will be numberBytesSent, nil, nil, time
		-- conn:send() failed response will be nil, 'wantwrite', numBytesSent, time
		-- socket.send lets you use i,j as substring args, but does luasec's ssl.wrap?
		local successlen, reason, faillen, time = conn:send(data:sub(i))
		self:log(10, conn, '...', successlen, reason, faillen, time)
		self:log(10, conn, '...getstats()', conn:getstats())
		if successlen ~= nil then
			assert(reason ~= 'wantwrite')	-- will wantwrite get set only if res[1] is nil?
			self:log(10, conn, '...done sending')
			return successlen, reason, faillen, time
		end
		if reason ~= 'wantwrite' then
			return nil, reason, faillen, time
		end
		--socket.select({conn}, nil)	-- not good?
		-- try again
		i = i + faillen
		self:log(10, conn, 'sending from offset '..i)
		coroutine.yield()
	end
end

function HTTP:log(level, ...)
	if level > self.loglevel then return end
	print(...)
end

function HTTP:findDontInterpret(docroot, remotePath)
	self:log(10, "looking for dontinterpret at docroot='"..docroot.."' remotePath='"..remotePath.."'")
	local localPath = docroot .. remotePath
	local dir = path(localPath):getdir()
	local docrootparts = string.split(docroot, '/')
	local dirparts = string.split(dir.path, '/')
	for i=1,#docrootparts do
		assert(docrootparts[i] == dirparts[i])
	end
	for i=#dirparts,#docrootparts,-1 do
		local check = table.concat({table.unpack(dirparts,1,i)}, '/')..'/.dontinterpret'
		self:log(10, "checking file '"..check.."'")
		if path(check):exists() then
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
	local subattr = path(localfilename..'/'..f):attr()
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
	if not self.enableDirectoryListing then
		return '404 Not Found', coroutine.wrap(function()
			coroutine.yield('failed to find file '..filename)
		end)
	end

	headers['content-type'] = 'text/html'
	return '200 OK', coroutine.wrap(function()

		local files = table()
		for f in path(localfilename):dir() do
			if f.path ~= '.' then
				files:insert(f.path)
			end
		end
		files:sort(function (a,b) return a:lower() < b:lower() end)

		coroutine.yield(
			template(
				self:handleDirectoryTemplate(),
				{
					path = path,
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
	local localfilepath = path(localfilename)

	local result = localfilepath:read()
	if not result then
		self:log(1, 'from dir '..path:cwd()..' failed to read file at', localfilename)
		return '403 Forbidden', coroutine.wrap(function()
			coroutine.yield('failed to read file '..filename)
		end)
	end

	local dontinterpret = self:findDontInterpret(
		self.docroot, --dir,
		filename)
	self:log(1, 'dontinterpret?', dontinterpret)

	local base, ext1 = localfilepath:getext()
	local ext2
	base, ext2 = base:getext()

	if self.wsapi
	and ext1 == 'lua'
	and ext2
	then
		self:log(1, 'running templated script',filename)
		assert(path(dir):cd())
		headers['content-type'] = self.mime.types[ext2]

		local processed = template(result, {
			headers = headers,	-- TODO what a more conventional way to pass templated lua pages the header table?
			env = {
				DOCUMENT_ROOT = self.docroot,
				--SERVER_NAME = os.getenv'HOSTNAME',
				SERVER_NAME = 'localhost', --os.getenv'HOSTNAME',
				SCRIPT_FILENAME = localfilename,
				GET = self:makeGETTable(GET),
				POST = POST,
			},
		})
		headers['content-length'] = #processed

		return '200 OK', coroutine.wrap(function()
			coroutine.yield(processed)
		end)
	end

	if self.wsapi
	and ext == 'lua'
	and not dontinterpret
	then
		self:log(1, 'running script',filename)
		assert(path(dir):cd())

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
		local fn = assert((f()))
		local status, headers2, callback = fn.run{
			reqHeaders = reqHeaders,
			GET = self:makeGETTable(GET),
			POST = POST,
			-- wsapi variables:
			DOCUMENT_ROOT = self.docroot,
			SERVER_NAME = 'localhost', --os.getenv'HOSTNAME',
			SCRIPT_FILENAME = localfilename,
		}
		for k,v in pairs(headers2) do
			k = k:lower()
			if not headers[k] then headers[k] = v end
		end
		if status == 200 then status = status .. ' OK' end
		return status, callback
	end

	self:log(1, 'serving file', filename)
	headers['content-type'] = ext and self.mime.types[ext:lower()] or 'application/octet-stream'
	headers['content-length'] = #result
	return '200 OK', coroutine.wrap(function()
		coroutine.yield(result)
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
		local localfilepath = path(localfilename)
		local attr = localfilepath:attr()
		if attr then
			if attr.mode == 'directory' then
				self:log(1, 'serving directory',filename)
				return self:handleDirectory(filename, localfilename, headers)
			end

			-- handle file:
			local _,ext = localfilepath:getext()
			local dirforfile, _ = localfilepath:getdir()
			self:log(1, 'ext', ext)
			self:log(1, 'dirforfile', dirforfile.path)

			return self:handleFile(
				filename,
				localfilename,
				ext,
				dirforfile.path,
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

-- this is coroutine-blocking
-- kinda matches websocket
-- but it has read amount (defaults to *l)
-- soon these two will merge, and this whole project will have gotten out of hand
function HTTP:receive(conn, amount, waitduration)
	amount = amount or '*l'
	coroutine.yield()

	local endtime
	if waitduration then
		endtime = self.getTime() + waitduration
	end
	local data
	repeat
		local reason
		data, reason = conn:receive(amount)
		self:log(10, conn, '...', data, reason)
		self:log(10, conn, '...getstats()', conn:getstats())
		if reason == 'wantread' then
			-- can we have data AND wantread?
			assert(not data, "FIXME I haven't considered wantread + already-read data")
			--self:log(10, 'got wantread, calling select...')
			socket.select(nil, {conn})
			--self:log(10, '...done calling select')
			-- and try again
		else
			if data then
				self:log(10, conn, '>>', tolua(data))
				return data
			end
			if reason ~= 'timeout' then
				self:log(10, 'connection failed:', reason)
				return nil, reason		-- error() ?
			end
			-- else check timeout
			if waitduration and self.getTime() > endtime then
				return nil, 'timeout'
			end
			-- continue
		end
		coroutine.yield()
	until data ~= nil
end

function HTTP:handleClient(client)
	local request = self:receive(client)
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
				local line = self:receive(client)
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
				v = string.trim(v)
				reqHeaders[k:lower()] = v
				self:log(3, "reqHeaders["..tolua(k:lower()).."] = "..tolua(v))
			end

			local postLen = tonumber(reqHeaders['content-length'])
			if not postLen then
				self:log(0, "didn't get POST data length")
			else
				self:log(1, 'reading POST '..postLen..' bytes')
				local postData = self:receive(client, postLen) or ''
				self:log(1, 'read POST data: '..postData)
				local contentType = string.trim(reqHeaders['content-type'])
				local contentTypeParts = string.split(contentType, ';'):mapi(function(s) return string.trim(s) end)
				local contentTypePartsMap = {}	-- first one is the content-type, rest are key=value
				for _,part in ipairs(contentTypeParts) do
					local k, v = part:match'([^=]*)=(.*)'
					if not k then
						self:log(0, 'got unknown contentType part '..part)
					else
						k = string.trim(k):lower()	-- case-insensitive right?
						v = string.trim(v)
						contentTypePartsMap[k] = v
					end
				end
				if contentTypeParts[1] == 'application/json' then
					POST = json.decode(postData)
				elseif contentTypeParts[1] == 'application/x-www-form-urlencoded' then
					self:log(2, "splitting up post...")
					POST = string.split(postData, '&'):mapi(function(kv, _, t)
						local k, v = kv:match'([^=]*)=(.*)'
						if not v then k,v = kv, #t+1 end
						self:log(10, 'before unescape, k='..k..' v='..v)

						-- plusses are already encoded as %2B, right?
						-- because it looks like jQuery ajax() POST is replacing ' ' with '+'
						k = k:gsub('+', ' ')
						k = url.unescape(k)
						if type(v) == 'string' then
							v = v:gsub('+', ' ')
							v = url.unescape(v)
						end
						self:log(10, 'after unescape, k='..k..' v='..v)
						return v, k
					end)
				elseif contentTypeParts[1] == 'multipart/form-data' then
					local boundary = contentTypePartsMap.boundary
					local parts = string.split(postData, string.patescape('--'..boundary))
					assert(parts:remove(1) == '')
					POST = {}
					while #parts > 0 do
						local formInputData = parts:remove(1)
						self:log(2, 'form-data part:\n'..formInputData)
						local lines = string.split(formInputData, '\r\n')
						self:log(3, tolua(lines))
						if #parts == 0 then
							assert(lines[1] == '--')
							assert(lines[2] == '')
							assert(#lines == 2)
							break
						end
						assert(lines:remove(1) == '')
						-- then do another header-read here with k:v; .. kinda with some optional stuff too ...
						-- who thinks this stupid standard up? we have some k:v, some k=v, ...some bullshit
						local thisPostVar = {}
						while lines[1] ~= nil and lines[1] ~= '' do
							-- in here is all the important stuff:
							local nextline = lines:remove(1)
							self:log(2, "next line:\n"..nextline)
							local splits = string.split(nextline, ';')
							for i,split in ipairs(splits) do
								split = string.trim(split)
								-- order probably matters
								local k, v
								if i == 1 then
									k, v = split:match'([^:]*):(.*)$'
									if k == nil or v == nil then
										error("failed to parse POST form-data line "..split)
									end
								else
									k, v = split:match'([^=]*)="(.*)"$'
									if k == nil or v == nil then
										error("failed to parse POST form-data line "..split)
									end
								end
								thisPostVar[k:lower()] = string.trim(v)
							end
						end
						assert(lines[1] ~= nil, "removed too many lines in our form-part data")
						assert(lines:remove(1) == '')
						assert(lines:remove() == '')
						local data = lines:concat'\r\n'
						self:log(3, 'setting post var '..tostring(thisPostVar.name)..' to data len '..#data)
						POST[thisPostVar.name] = thisPostVar
						POST[thisPostVar.name].body = data
					end
				else
					self:log(1, "what to do with post and our content-type "..tostring(contentType))
					POST = postData
				end
			end
--]]
		else
			error("unknown method: "..method)
		end

		self:log(3, "about to handleRequest with "..tolua{GET=GET, POST=POST})

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

			assert(self:send(client, 'HTTP/1.1 '..status..'\r\n'))
			for k,v in pairs(headers) do
				assert(self:send(client, k..': '..v..'\r\n'))
			end
			assert(self:send(client, '\r\n'))
			if callback then
				self:log(10, 'wsapi started writing')
				for str in callback do
					assert(self:send(client, str))
				end
				self:log(10, 'wsapi done writing')
			else
				assert(self:send(client, [[someone forgot to set a callback!]]))
			end
		end
	end, function(err)
		io.stderr:write(err..'\n'..debug.traceback()..'\n')
	end)
	assert(path(self.docroot):cd())
	self:log(1, 'collectgarbage', collectgarbage())
end

function HTTP:connectCoroutine(client, server)
	self:log(1, 'got connection!', client)
	assert(client)
	assert(server)
	self:log(2, 'connection from', client:getpeername())
	self:log(2, 'connection to', server:getsockname())
	self:log(2, 'spawning new thread...')

	-- TODO for block as well
	if server == self.sslserver then
		-- from https://stackoverflow.com/questions/2833947/stuck-with-luasec-lua-secure-socket
		-- TODO need to specify cert files
		-- TODO but if you want to handle both https and non-https on different ports, that means two connections, that means better make non-blocking the default
		--assert(client:settimeout(10))
		self:log(3, 'ssl server calling ssl.wrap...')
		self:log(1, 'key file '..tostring(self.keyfile))
		self:log(1, 'cert file '..tostring(self.certfile))
		local ssl = require 'ssl'	-- package luasec
		client = assert(ssl.wrap(client, {
			mode = 'server',
			options = {'all'},
			protocol = 'any',
			key = assert(self.keyfile),
			certificate = assert(self.certfile),
			password = '12345',
			ciphers = 'ALL:!ADH:@STRENGTH',
		}))

		if not self.block then
			assert(client:settimeout(0, 'b'))
		end

		self:log(3, 'waiting for handshake')
		local result,reason
		while not result do
			coroutine.yield()
			result, reason = client:dohandshake()
			if reason ~= 'wantread' then
				self:log(3, 'client:dohandshake', result, reason)
			end
			if reason == 'wantread' then
				socket.select(nil, {client})
				-- and try again
			elseif not result then
				-- then error
				error("handshake failed: "..tostring(reason))
			end
			if reason == 'unknown state' then
				error('handshake conn in unknown state')
			end
			-- result == true and we can stop
		end
		self:log(3, 'got handshake')
	end
	self:log(1, 'got client!')
	self.clients:insert(client)
	self:log(1, 'total #clients',#self.clients)

	self:handleClient(client)
	self:log(1, 'closing client...')
	client:close()
	self.clients:removeObject(client)
	self:log(2, '# clients remaining: '..#self.clients)
end

function HTTP:run()
	while true do
		for _,server in ipairs(self.servers) do
			if self.block then
				-- blocking is easiest with single-server-socket impls
				-- tho it had problems on android luasocket iirc
				-- and now that i'm switching to ssl as well, ... gonna have problems
				self:log(1, 'waiting for client...')
				local client = assert(server:accept())
				assert(client:settimeout(3600,'b'))
				self.threads:add(self.connectCoroutine, self, client, server)
			else
				local client = server:accept()
				if client then
					-- [[ should the client be non-blocking as well?  or can we assert the client will respond in time?
					assert(client:setoption('keepalive',true))
					assert(client:settimeout(0,'b'))
					--]]
					self.threads:add(self.connectCoroutine, self, client, server)
				end
			end
		end
		if self.ownThreads then
			self.threads:update()
		end
	end
end

return HTTP
