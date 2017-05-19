local lfs = require 'lfs'
local socket = require'socket'
local http = require 'socket.http'
local url = require 'socket.url'
require'ext'

local config = config or (os.getenv'HOME' or os.getenv'USERPROFILE')..'/.http.lua.conf'
local mimes = assert(load('return '..(file[config]or'')))()
if not mimes then
	local CSV = require'csv'
	mimes = {}
	for _,source in pairs{'application','audio','image','message','model','multipart','text','video'} do
		print('fetching '..source..' mime types...')
		local csv = CSV.string(assert(http.request('http://www.iana.org/assignments/media-types/'..source..'.csv')))
		csv:setColumnNames(csv.rows:remove(1))
		for _,row in ipairs(csv.rows) do
			mimes[row.Name:lower()] = row.Template
		end
	end
	mimes.js = mimes.js or mimes.javascript -- well this is strange
	file[config] = tolua(mimes,{indent = true})
end

local function getn(...)
	return table({...}, {n=select('#', ...)})
end

-- whether to simulate wsapi for .lua pages
local wsapi = true
if _G.wsapi ~= nil then wsapi = _G.wsapi end
if wsapi then
	package.loaded['wsapi.request'] = {
		new = function(env) return env end,
	}
end

-- I had some trouble with blocking and MathJax on android.  Maybe it was my imagination.
local block
if _G.block ~= nil then 
	block = _G.block 
else
	block = true
end
 
local cwd = lfs.currentdir()
local port = port or 8000
local addr = addr or '*'
local server = assert(socket.bind(addr, port))
local clients = table()
if block then
	assert(server:settimeout(3600))
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
		local t = getn(client:receive())
		local request = t[1]
		if not request then
			if t[2] ~= 'timeout' then
				print('connection failed:',t:unpack(1,t.n))
			end
		else
			xpcall(function()
				print('got request',request)
				local method, filename, proto = request:split'%s+':unpack()
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
					local localfilename = './'..filename
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
						local result = file[localfilename]
						if not result then
							status = '404 Not Found'
							callback = coroutine.wrap(function()
								coroutine.yield('failed to find file '..filename)
							end)
						else
							local _,ext = io.getfileext(localfilename)
							if wsapi and ext=='lua' then
								print('running script',filename)
								local dir, _ = io.getfiledir(localfilename)
								assert(lfs.chdir(dir))
								local sandboxenv = setmetatable({}, {__index=_ENV})
								local fn = assert(load(result, localfilename, 'bt', sandboxenv))()
								local headers2
								status, headers2, callback = fn.run{
									GET = (getargs or''):split'&':map(function(kv)
										local k, v = kv:match('([^=]*)=(.*)')
										if not v then k,v = kv, true end
										return v, k
									end)
								}
								headers2 = table.map(headers2, function(v,k) return v, k:lower() end)
								headers = setmetatable(table(headers, headers2), nil)
								if status == 200 then status = status .. '/OK' end
							else
								print('serving file',filename)
								status = '200/OK'
								headers['content-type'] = ext and mimes[ext:lower()] or 'application/octet-stream'
								callback = coroutine.wrap(function()
									coroutine.yield(io.readfile(localfilename))
								end)
							end
						end
					end
					assert(client:send('HTTP/1.1 '..status..'\r\n'))
					for k,v in pairs(headers) do
						assert(client:send(k..': '..v..'\r\n'))
					end
					assert(client:send'\r\n')
					if callback then
						for str in callback do
							assert(client:send(str))
						end
					else
						assert(client:send[[someone forgot to set a callback!]])
					end
					assert(lfs.chdir(cwd))
				end
				print'closing client...'	
				client:close()
				clients:remove(i)
			end, function(err)
				io.stderr:write(err..debug.traceback()..'\n')
			end)
		end
	end
end
