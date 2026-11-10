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
if exist launcher\assets\patches rmdir /s /q launcher\assets\patches
if exist launcher\assets\payload rmdir /s /q launcher\assets\payload
copy /y herdr-pipe-patch.ps1 launcher\assets\ > nul
copy /y README.md launcher\assets\ > nul
xcopy /e /i /q /y patches launcher\assets\patches > nul
if errorlevel 2 (
    echo === the patches folder is missing ===
    exit /b 1
)
xcopy /e /i /q /y payload launcher\assets\payload > nul
if errorlevel 2 (
    echo === the payload folder is missing ===
    exit /b 1
)

cd /d launcher
echo === building ===
cargo build --release
if errorlevel 1 (
    echo === build failed ===
    exit /b 1
)
copy /y target\release\herdr-pipe-patch.exe ..\herdr-pipe-patch.exe > nul
echo === done: herdr-pipe-patch.exe is up to date ===
exit /b 0
