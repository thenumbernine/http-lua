require'ext'
local configFilename = os.getenv'HOME'..'/.http.lua.conf'
local mimes = assert(load('return '..(file[configFilename]or'')))()
if not mimes then
	mimes = {}
	for _,source in pairs{'application','audio','image','message','model','multipart','text','video'}do
		print('fetching '..source..' mime types...')
		local csv = require'csv'.string(assert(require'socket.http'.request('http://www.iana.org/assignments/media-types/'..source..'.csv')))
		csv:setColumnNames(csv.rows:remove(1))
		for _,row in ipairs(csv.rows) do
			mimes[row.Name:lower()] = row.Template
		end
	end
	file[configFilename] = tolua(mimes,{indent = true})
end
local port = port or 8000
local server = assert(require'socket'.bind('*',port))
local addr,port = server:getsockname()
print('listening '..addr..':'..port) 
while true do
	local client = assert(server:accept())
	assert(client:settimeout(60))
	local request = client:receive()
	print('request',request)
	if request then
		local method, filename, proto = request:split'%s+':unpack()
		print('method',method)
		print('filename',filename)
		print('proto',proto)
		local base, getargs = filename:match('(.-)%?(.*)')
		filename = base or filename
		if filename then
			local localfilename = './'..filename
			local attr = lfs.attributes(localfilename)
			if attr and attr.mode == 'directory' then
				assert(client:send('HTTP/1.1 200/OK\r\nContent-Type:text/html\r\n\r\n'))
				assert(client:send('<h3>Index of '..filename..'</h3>\n'))
				assert(client:send('<html>\n'))
				assert(client:send('<head>\n'))
				assert(client:send('<title>Directory Listing of '..filename..'</title>\n'))
				assert(client:send('<style type="text/css"> td{padding-right:20px};</style>\n'))
				assert(client:send('</head>\n'))
				assert(client:send('<body>\n'))
				assert(client:send('<table>\n'))
				assert(client:send('<tr><th>Name</th><th>Modified</th><th>Size</th></tr>\n'))
				for file in lfs.dir(localfilename) do
					if file ~= '.' then
						local nextfilename = (filename..'/'..file):gsub('//', '/')
						local displayfile = file
						local subattr = lfs.attributes(localfilename..'/'..file)
						if subattr and subattr.mode == 'directory' then
							displayfile = '[' .. displayfile .. ']'
						end
						assert(client:send('<tr>'))
						assert(client:send('<td><a href="'..nextfilename..'">'..displayfile..'</a></td>'))
						assert(client:send('<td>'..(subattr and os.date('%F %T',subattr.modification) or '')..'</td>'))
						assert(client:send('<td style="text-align:center">'..(subattr and (subattr.mode == 'directory' and '-' or subattr.size) or '')..'</td>'))
						assert(client:send('</tr>\n'))
					end
				end
				assert(client:send('</table>\n'))
				assert(client:send('</body>\n'))
			else
				local result = file[localfilename]
				if result then
					local _,ext = io.getfileext(localfilename)
					if ext then
						local mime = mimes[ext:lower()]
						if mime then
							assert(client:send('HTTP/1.1 200/OK\r\nContent-Type:'..mime..'\r\n\r\n'))
						end
					end
					assert(client:send(result))
				else
					assert(client:send('HTTP/1.1 404 Not Found\r\n'))
				end
			end
		end
	end
	client:close()
end
