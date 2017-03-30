local lfs = require 'lfs'
local socket = require'socket'
local http = require 'socket.http'
local url = require 'socket.url'
local CSV = require'csv'
require'ext'

local configFilename = os.getenv'HOME'..'/.http.lua.conf'
local mimes = assert(load('return '..(file[configFilename]or'')))()
if not mimes then
	mimes = {}
	for _,source in pairs{'application','audio','image','message','model','multipart','text','video'} do
		print('fetching '..source..' mime types...')
		local csv = CSV.string(assert(http.request('http://www.iana.org/assignments/media-types/'..source..'.csv')))
		csv:setColumnNames(csv.rows:remove(1))
		for _,row in ipairs(csv.rows) do
			mimes[row.Name:lower()] = row.Template
		end
	end

	-- well this is strange
	if not mimes.js then
		print('what did iana do with the js extension?!!!')
		mimes.js = mimes.javascript
	end
	
	file[configFilename] = tolua(mimes,{indent = true})
end

local function getn(...)
	return table({...}, {n=select('#', ...)})
end

-- I had some trouble with blocking and MathJax on android.  Maybe it was my imagination.
local block
if _G.block ~= nil then 
	block = _G.block 
else
	block = true
end

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
	for i=#clients,1,-1 do
		local client = clients[i]
	
		local t = getn(client:receive())
		local request = t[1]
		if not request then
			if t[2] ~= 'timeout' then
				print('connection failed:',t:unpack(1,t.n))
				clients:remove(i)
			end
		else
			xpcall(function()
				print('got request',request)
				local method, filename, proto = request:split'%s+':unpack()
				filename = url.unescape(filename:gsub('%+','%%20'))
				local base, getargs = filename:match('(.-)%?(.*)')
				filename = base or filename
				if filename then
					local localfilename = './'..filename
					local attr = lfs.attributes(localfilename)
					if attr and attr.mode == 'directory' then
						print('serving directory',filename)
						assert(client:send(
							'HTTP/1.1 200/OK\r\n'
							..'Content-Type:text/html\r\n'
							..'Cache-Control: no-cache, no-store, must-revalidate\r\n'
							..'Pragma: no-cache\r\n'
							..'Expires: 0\r\n'
							..'\r\n'
							..'<h3>Index of '..filename..'</h3>\n'
							..'<html>\n'
							..'<head>\n'
							..'<title>Directory Listing of '..filename..'</title>\n'
							..'<style type="text/css"> td{padding-right:20px};</style>\n'
							..'</head>\n'
							..'<body>\n'
							..'<table>\n'
							..'<tr><th>Name</th><th>Modified</th><th>Size</th></tr>\n'))
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
								assert(client:send(
									'<tr>'
									..'<td><a href="'..nextfilename..'">'..displayfile..'</a></td>'
									..'<td>'..(subattr and os.date('%F %T',subattr.modification) or '')..'</td>'
									..'<td style="text-align:center">'..(subattr and (subattr.mode == 'directory' and '-' or subattr.size) or '')..'</td>'
									..'</tr>\n'))
							end
						end
						assert(client:send(
							'</table>\n'
							..'</body>\n'))
					else
						local result = file[localfilename]
						if result then
							print('serving file',filename)
							local _,ext = io.getfileext(localfilename)
							if ext then
								local mime = mimes[ext:lower()] or 'application/octet-stream'
								assert(client:send(
									'HTTP/1.1 200/OK\r\n'
									..'Content-Type:'..mime..'\r\n'
									..'Cache-Control: no-cache, no-store, must-revalidate\r\n'
									..'Pragma: no-cache\r\n'
									..'Expires: 0\r\n'
									..'\r\n'))
							end
							assert(client:send(result))
						else
							print('failed to find file',filename)
							assert(client:send('HTTP/1.1 404 Not Found\r\n'))
						end
					end
				end
				print'closed client!'	
				client:close()
				clients:remove(i)	
			end, function(err)
				io.stderr:write(err..debug.traceback()..'\n')
			end)
		end
	end
end
