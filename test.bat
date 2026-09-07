@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "NOPAUSE=0"
if /i "%~1"=="--no-pause" set "NOPAUSE=1"
if /i "%~1"=="/nopause"   set "NOPAUSE=1"
if /i "%~1"=="--ci"       set "NOPAUSE=1"

set "EXIT_CODE=0"

echo ====================================================
echo  CleanBot - Syntax Verification and Unit Tests
echo ====================================================
echo.

where luac >nul 2>nul
if errorlevel 1 (
    echo [WARN] 'luac' not found in PATH. Skipping syntax check.
    goto :run_tests
)

echo [1/2] Checking Lua 5.1 syntax with luac...
set "SYNTAX_ERR=0"
for /r %%f in (*.lua) do (
    echo "%%f" | findstr /i "\\\.git\\ \\Libs\\" >nul
    if errorlevel 1 (
        luac -p "%%f" >nul 2>&1
        if errorlevel 1 (
            echo [SYNTAX ERROR] %%f
            luac -p "%%f"
            set "SYNTAX_ERR=1"
        )
    )
)

if "!SYNTAX_ERR!"=="1" (
    echo.
    echo [FAIL] Syntax errors detected. Please fix them before continuing.
    set "EXIT_CODE=1"
    goto :finish
)
echo [OK] All Lua files passed syntax check.
echo.

:run_tests
where lua >nul 2>nul
if errorlevel 1 (
    echo [ERROR] 'lua' not found in PATH. Please install Lua 5.1 or add it to PATH.
    set "EXIT_CODE=1"
    goto :finish
)

echo [2/2] Running unit test suite (spec/run.lua)...
echo.
lua spec/run.lua
if errorlevel 1 (
    echo.
    echo [FAIL] One or more unit tests failed.
    set "EXIT_CODE=1"
) else (
    echo.
    echo [SUCCESS] All unit tests passed successfully.
    set "EXIT_CODE=0"
)

:finish
if "!NOPAUSE!"=="1" goto :done
echo.
echo Press any key to exit...
pause >nul

:done
endlocal & exit /b %EXIT_CODE%
