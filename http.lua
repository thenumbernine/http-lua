local lfs = require 'lfs'
local socket = require'socket'
local http = require 'socket.http'
local url = require 'socket.url'
local MIMETypes = require 'mimetypes'
local table = require 'ext.table'
local string = require 'ext.string'
local os = require 'ext.os'
local io = require 'ext.io'

-- allow -e 'config=...'
local config = config or (os.getenv'HOME' or os.getenv'USERPROFILE')..'/.http.lua.conf'

local mime = MIMETypes(config)

local docroot = lfs.currentdir()

-- whether to simulate wsapi for .lua pages
local wsapi = true
if _G.wsapi ~= nil then wsapi = _G.wsapi end
if wsapi then
	package.loaded['wsapi.request'] = {
		new = function(env) 
			env = env or {}
			env.doc_root = docroot
			return env
		end,
	}
end

local function findDontInterpret(docroot, remotePath)
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


-- use blocking by default.
-- I had some trouble with blocking and MathJax on android.  Maybe it was my imagination.
local block
if _G.block ~= nil then block = _G.block else block = true end
 
local port = port or 8000
local addr = addr or '*'
local server = assert(socket.bind(addr, port))
local clients = table()
if block then
	--assert(server:settimeout(3600))
	--server:setoption('keepalive',true)
	--server:setoption('linger',{on=true,timeout=3600})
else
	assert(server:settimeout(0,'b'))
end

local addr,port = server:getsockname()
print('listening '..addr..':'..port)
while true do
	local client	
	if block then
		print'waiting for client...'	
		client = assert(server:accept())
		print'got client!'	
		assert(client:settimeout(3600,'b'))
		clients:insert(client)
		print('total #clients',#clients)
	else
		client = server:accept()
		if client then
			assert(client:settimeout(0,'b'))
			assert(client:setoption('keepalive',true))
			print'got client!'
			clients:insert(client)
			print('total #clients',#clients)
		end
	end
	for j=#clients,1,-1 do
		client = clients[j]	
		local function readline()
			local t = table.pack(client:receive())
			print('got line', t:unpack(1,t.n))
			if not t[1] then
				--if t[2] ~= 'timeout' then
					print('connection failed:',t:unpack(1,t.n))
				--end
			end
			return t:unpack(1,t.n)
		end
		local request = readline()
		if request then
			xpcall(function()
				print('got request',request)
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
							print'done reading header'
							break 
						end
						local k,v = line:match'^(.-):(.*)$'
						if not k then
							print("got invalid header line: "..line)
							break
						end
						reqHeaders[k:lower()] = v
					end
					
					local postLen = tonumber(reqHeaders['content-length'])
					if not postLen then
						print"didn't get POST data length"
					else
						print('reading POST '..postLen..' bytes')
						--local postData = readline()
						local postData = client:receive(postLen)
						print('read POST data: '..postData)
						POST = string.split(postData, '&'):mapi(function(kv, _, t)
							local k, v = kv:match'([^=]*)=(.*)'
							if not v then k,v = kv, #t+1 end
--print('before unescape, k='..k..' v='..v)							
							k, v = url.unescape(k), url.unescape(v)
--print('after unescape, k='..k..' v='..v)							
							return v, k
						end)
					end
				end
--]]
				filename = url.unescape(filename:gsub('%+','%%20'))
				local base, getargs = filename:match('(.-)%?(.*)')
				filename = base or filename
				if filename then
					local status
					local headers = {
						['cache-control'] = 'no-cache, no-store, must-revalidate',
						['pragma'] = 'no-cache',
						['expires'] = '0',
					}
					local callback
					local localfilename = ('./'..filename):gsub('/+', '/')
					local attr = lfs.attributes(localfilename)
					if attr and attr.mode == 'directory' then
						print('serving directory',filename)
						status = '200/OK'
						headers['content-type'] = 'text/html'
						callback = coroutine.wrap(function()
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
										..'<td>'..(subattr and os.date('%F %T',subattr.modification) or '')..'</td>'
										..'<td style="text-align:center">'..(subattr and (subattr.mode == 'directory' and '-' or subattr.size) or '')..'</td>'
										..'</tr>\n')
								end
							end
							coroutine.yield(
								'</table>\n'
								..'</body>\n')
						end)
					else
						local result = io.readfile(localfilename)
						if not result then
print('from dir '..lfs.currentdir()..' failed to find file at', localfilename)
							status = '404 Not Found'
							callback = coroutine.wrap(function()
								coroutine.yield('failed to find file '..filename)
							end)
						else
							local _,ext = io.getfileext(localfilename)
							local dir, _ = io.getfiledir(localfilename)
print('wsapi',wsapi)
print('ext',ext)
							local dontinterpret = findDontInterpret(docroot, filename)
print('dontinterpret?', dontinterpret)
							if wsapi and (
								localfilename:sub(-9) == '.html.lua'
								or localfilename:sub(-7) == '.js.lua'
							) then
								print('running templated script',filename)
assert(lfs.chdir(dir))
								status = '200/OK'
								headers['content-type'] = mime.types.html
								callback = coroutine.wrap(function()
									coroutine.yield(require 'template'(result))
								end)							
							elseif wsapi 
							and ext == 'lua' 
							and not dontinterpret
							then
								print('running script',filename)
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
								local headers2
								status, headers2, callback = fn.run{
									reqHeaders = reqHeaders,
									GET = string.split(getargs or'', '&'):map(function(kv, _, t)
										local k, v = kv:match('([^=]*)=(.*)')
										if not v then k,v = kv, #t+1 end
										k, v = url.unescape(k), url.unescape(v)
										return v, k
									end),
									POST = POST,
								}
								headers2 = table.map(headers2, function(v,k) return v, k:lower() end)
								headers = setmetatable(table(headers, headers2), nil)
								if status == 200 then status = status .. '/OK' end
							else
								print('serving file',filename)
								status = '200/OK'
								headers['content-type'] = ext and mime.types[ext:lower()] or 'application/octet-stream'
								callback = coroutine.wrap(function()
									coroutine.yield(io.readfile(localfilename))
								end)
							end
						end
					end
					local function send(s)
--io.write('sending '..s)
						return client:send(s)
					end
					assert(send('HTTP/1.1 '..status..'\r\n'))
					for k,v in pairs(headers) do
						assert(send(k..': '..v..'\r\n'))
					end
					assert(send'\r\n')
					if callback then
--print'wsapi started writing'
						for str in callback do
							assert(send(str))
						end
--print'wsapi done writing'
					else
						assert(send[[someone forgot to set a callback!]])
					end
				end
			end, function(err)
				io.stderr:write(err..'\n'..debug.traceback()..'\n')
			end)
			assert(lfs.chdir(docroot))
			print('collectgarbage', collectgarbage())
		end
		print'closing client...'	
		client:close()
		clients:remove(i)
	end
end
