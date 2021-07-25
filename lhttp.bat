@echo off
setlocal enableDelayedExpansion

rem luarocks is going to install the rockspec wherever it does,
rem and LUAHTTP_DIR is only used in this batch file at the moment, for the standalone webserver,
rem so if LUAHTTP_DIR isn't defined, just assume luarocks is, and try to find lua-http's directory

if not defined LUAHTTP_DIR (
	echo LUAHTTP_DIR was not defined.
) else (
	if not exist %LUAHTTP_DIR%\http.lua (
		echo LUAHTTPDIR is set to a bad location: %LUAHTTP_DIR%
	)
)
call :assignDirEnvVar

echo starting...
lua %LUAHTTP_DIR%\http.lua %*
echo this line should be unreachable, because by defeault batch files bail immediately after calls


:assignDirEnvVar
	echo searching for LUAHTTP_DIR...

	rem ext.io.getfiledir only splits by / at the moment
	rem ext.os does its processing assuming / for paths, and uses os.sep to swap to the os-specific before using it externally
	rem TODO reconcile the two?
	rem until then, this line will be ugly:
	for /f "usebackq" %%i in (`lua -lext -e "print((io.getfiledir(package.searchpath('http', package.path):gsub(os.sep, '/')):gsub('/', os.sep)))"`) do set LUAHTTP_DIR=%%i
	echo set LUAHTTP_DIR to %LUAHTTP_DIR%

	if not exist %LUAHTTP_DIR%\http.lua (
		echo failed to search for LUAHTTP_DIR
		echo exiting...
		exit /b 1
	)
	
	exit /b 0
