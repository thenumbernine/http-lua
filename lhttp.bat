@echo off
setlocal enableDelayedExpansion
if not defined LUAHTTP_DIR (
	echo set your LUAHTTP_DIR variable to wherever this is installed, and then put this in whatever folder has your executables/scripts...
	exit /b 1
)
lua %LUAHTTP_DIR%\http.lua %*
