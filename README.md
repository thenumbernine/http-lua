[![Donate via Stripe](https://img.shields.io/badge/Donate-Stripe-green.svg)](https://buy.stripe.com/00gbJZ0OdcNs9zi288)<br>
[![Donate via Bitcoin](https://img.shields.io/badge/Donate-Bitcoin-green.svg)](bitcoin:37fsp7qQKU8XoHZGRQvVzQVP8FrEJ73cSJ)<br>

# Lua HTTP Server #

- uses port 8000 by default.
- runs out of the working directory
- provides directory listings
- caches mime types from iana.org into the file ~/.http.lua.conf

### Depends on: ###

- luasocket: http://w3.impa.br/~diego/software/luasocket/
- luafilesystem: https://keplerproject.github.io/luafilesystem/
- lua-ext: https://github.com/thenumbernine/lua-ext
- lua-csv: https://github.com/thenumbernine/lua-csv


### Usage: ###

make sure your `LUA_PATH` points to the directory containing http.lua (and the lua-ext and lua-csv projects it depends on) and run:

`lua -lhttp`


alternatively you can explicitly invoke the file via:

`lua path/to/http.lua`


or you can set the `LUAHTTP_DIR` variable to wherever the rockspec is installed, 
and copy the lhttp.bat file to some executable directory and use:

`lhttp`


to set the port manually (defaults to 8000):

`lua -e "port=80" -lhttp`

`lua path/to/http/http.lua port=80`

`lhttp.bat port=12345`


to set the interface manually (defaults to `*`, which sometimes doesn't work):

`lua -e "addr='10.0.0.1'" -lhttp`


to use non-blocking clients:

`lua -e "block=false" -lhttp`


wsapi simulation is enabled by default

to disable wsapi simulation:

`lua -e "wsapi=false" -lhttp`
