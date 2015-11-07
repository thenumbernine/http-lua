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
	local filename = request and request:split'%s+'[2]
	print('filename',filename)
	if filename then
		local localfilename = './'..filename
		local attr = lfs.attributes(localfilename)
		if attr and attr.mode == 'directory' then
			assert(client:send('HTTP/1.1 200/OK\r\nContent-Type:text/html\r\n\r\n'))
			for file in lfs.dir(localfilename) do
				local nextfilename = (filename..'/'..file):gsub('//', '/')
				assert(client:send('<a href="'..nextfilename..'">'..file..'</a><br>\n'))
			end
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
	client:close()
end
