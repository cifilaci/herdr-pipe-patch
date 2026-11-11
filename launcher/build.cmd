@echo off
rem Rebuilds the single-file herdr-pipe-patch.exe.
rem
rem The executable carries the script, the patched core and the patch inside it,
rem so a change to any of them means a rebuild: the files are copied into
rem launcher\assets first, then the exe is built and copied back.
rem
rem The payload folder is copied whole, so a new herdr-core version needs no
rem change here - build.rs picks up whatever is in assets\payload.
rem
rem Needs Rust (cargo) and the MSVC toolchain; nothing else.
setlocal

rem The rustup proxies need RUSTUP_HOME and CARGO_HOME to find their toolchain.
rem Point them at the local rustup install only when it is there: on a CI
rem runner the toolchain is already installed and the path does not exist,
rem and pointing RUSTUP_HOME at a missing folder breaks cargo.
if not defined CARGO_HOME if exist "%LOCALAPPDATA%\puccinialin\puccinialin\Cache\cargo\bin\cargo.exe" set "CARGO_HOME=%LOCALAPPDATA%\puccinialin\puccinialin\Cache\cargo"
if not defined RUSTUP_HOME if defined CARGO_HOME set "RUSTUP_HOME=%LOCALAPPDATA%\puccinialin\puccinialin\Cache\rustup"
if defined CARGO_HOME if exist "%CARGO_HOME%\bin\cargo.exe" set "PATH=%CARGO_HOME%\bin;%PATH%"

cd /d "%~dp0\.."

echo === copying the tool into the launcher ===
rem The tree is not in the repository: a fresh checkout has to make it.
if exist launcher\tree rmdir /s /q launcher\tree
if not exist launcher\tree mkdir launcher\tree

copy /y herdr-pipe-patch.ps1 launcher\tree\ > nul
if errorlevel 1 goto :copyfailed
copy /y README.md launcher\tree\ > nul
if errorlevel 1 goto :copyfailed
rem The README points at the licence, so the executable has to carry it too.
copy /y LICENSE launcher\tree\ > nul
if errorlevel 1 goto :copyfailed
copy /y install-skill.ps1 launcher\tree\ > nul
if errorlevel 1 goto :copyfailed
copy /y install-skill-wsl.sh launcher\tree\ > nul
if errorlevel 1 goto :copyfailed
xcopy /e /i /q /y patches launcher\tree\patches > nul
if errorlevel 2 goto :copyfailed
xcopy /e /i /q /y scripts launcher\tree\scripts > nul
if errorlevel 2 goto :copyfailed
xcopy /e /i /q /y skills launcher\tree\skills > nul
if errorlevel 2 goto :copyfailed
xcopy /e /i /q /y assets launcher\tree\assets > nul
if errorlevel 2 goto :copyfailed
xcopy /e /i /q /y payload launcher\tree\payload > nul
if errorlevel 2 goto :copyfailed
goto :copied

:copyfailed
echo === the files could not be copied into launcher\tree ===
exit /b 1

:copied
cd /d launcher
echo === building ===
cargo build --release
if errorlevel 1 (
    echo === build failed ===
    exit /b 1
)
copy /y target\release\herdr-pipe-patch.exe ..\herdr-pipe-patch.exe > nul
if errorlevel 1 (
    echo === the executable could not be copied back ===
    exit /b 1
)
echo === done: herdr-pipe-patch.exe is up to date ===
exit /b 0
