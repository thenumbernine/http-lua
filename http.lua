require'ext'
configFilename=os.getenv'HOME'..'/.http.lua.conf'
mimes=assert(load('return '..(file[configFilename]or'')))()
if not mimes then
	mimes={}
	for _,source in pairs{'application','audio','image','message','model','multipart','text','video'}do
		print('fetching '..source..' mime types...')
		csv=require'csv'.string(assert(require'socket.http'.request('http://www.iana.org/assignments/media-types/'..source..'.csv')))
		for i=2,#csv.rows do
			row=csv.rows[i]
			mimes[row[1]:lower()]=row[2]
		end
	end
	file[configFilename]=tolua(mimes,{indent=true})
end
port=port or 8000
server=assert(require'socket'.bind('*',port))
addr,port=server:getsockname()
print('listening '..addr..':'..port) 
while{}do
	client=assert(server:accept())
	assert(client:settimeout(60))
	request=client:receive()
	filename=request and'./'..request:split'%s+'[2]
	result=filename and file[filename]
	_,ext=filename and io.getfileext(filename)
	mime=ext and mimes[ext:lower()]
	assert(client:send(result and(mime and'HTTP/1.1 200/OK\r\nContent-Type:'..mime..'\r\n\r\n'or'')..result or'HTTP/1.1 404 Not Found\r\n'))
	client:close()
end
