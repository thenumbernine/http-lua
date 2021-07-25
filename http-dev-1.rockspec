package = "http"
version = "dev-1"
source = {
	url = "git+https://github.com/thenumbernine/http-lua"
}
description = {
	summary = "- uses port 8000 by default.",
	detailed = [[
- uses port 8000 by default.
- runs out of the working directory
- provides directory listings
- caches mime types from iana.org into the file ~/.http.lua.conf]],
	homepage = "https://github.com/thenumbernine/http-lua",
	license = "MIT"
}
build = {
	type = "builtin",
	modules = {
		class = "class.lua",
		http = "http.lua"
	}
}
