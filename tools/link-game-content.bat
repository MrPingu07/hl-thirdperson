@echo off
rem link-game-content.bat - bridge this mod folder to the retail Half-Life content.
rem
rem Windows twin of link-game-content.sh.  GoldSrc reads a few UI paths straight
rem out of the game folder, with no fallback to valve/, so a fresh mod folder
rem starts with a bare menu, no intro video and no Options dialogs:
rem
rem   resource/   the main menu, the decorated background, the UI scheme and
rem               icons, and the Options dialogs
rem   media/      the startup intro videos
rem   gfx/        the shell graphics the UI loads up front (palette, cursors)
rem   logos/      the spraypaint logos listed in the Options tab
rem   titles.txt  the on-screen chapter titles
rem
rem This creates directory junctions (mklink /J) for the folders and a hardlink
rem (mklink /H) for titles.txt.  Neither needs administrator rights, nothing in
rem valve/ is modified, and no Valve asset is copied: the links live inside the
rem mod folder, which Steam never overwrites.
rem
rem Usage:
rem   link-game-content.bat            run from inside the mod folder
rem   link-game-content.bat --unlink   remove the links again
rem
rem Note: no parenthesised if-blocks anywhere in this file.  cmd.exe expands
rem %VAR% while parsing a block, so a path like "Program Files (x86)" would end
rem the block early.  Everything branches with goto instead.
setlocal EnableExtensions

rem Resolve paths with pushd so they are fully qualified (no .. left in them).
pushd "%~dp0." >nul
set "MOD_DIR=%CD%"
for %%I in (.) do set "MOD_NAME=%%~nxI"
popd >nul
pushd "%MOD_DIR%\.." >nul
set "GAME_DIR=%CD%"
popd >nul
set "VALVE_DIR=%GAME_DIR%\valve"
set "LINKTYPE_FILE=%TEMP%\hltps-linktype.txt"

if /I "%~1"=="--unlink" goto unlink

echo Linking retail Half-Life content into %MOD_DIR%

if not exist "%VALVE_DIR%\" goto no_valve

for %%E in (resource media gfx logos) do call :link_dir "%%E"
call :link_file "titles.txt"

echo Done. Launch the mod with: -game %MOD_NAME% -console
exit /b 0

:no_valve
echo Retail Half-Life content not found at:
echo     %VALVE_DIR%
echo.
echo This script expects the mod folder to sit next to the game's 'valve'
echo folder (for example Half-Life\hltps next to Half-Life\valve).
exit /b 1

:unlink
echo Removing retail content links from %MOD_DIR%
for %%E in (resource media gfx logos) do call :unlink_dir "%%E"
call :unlink_file "titles.txt"
echo Done.
exit /b 0

rem --------------------------------------------------------------------------
rem link_dir <name>: junction the retail folder into the mod folder.
rem --------------------------------------------------------------------------
:link_dir
set "REL=%~1"
set "SRC=%VALVE_DIR%\%REL%"
set "DST=%MOD_DIR%\%REL%"
if not exist "%SRC%\" exit /b 0
if exist "%DST%\" goto link_dir_exists
mklink /J "%DST%" "%SRC%" >nul 2>&1
if errorlevel 1 goto link_dir_failed
echo   linked  %REL%
exit /b 0

:link_dir_exists
echo   kept    %REL% (already present)
exit /b 0

:link_dir_failed
echo   FAILED  %REL% - create the link by hand with:
echo           mklink /J "%DST%" "%SRC%"
exit /b 0

rem --------------------------------------------------------------------------
rem link_file <name>: hardlink the retail file into the mod folder.
rem --------------------------------------------------------------------------
:link_file
set "REL=%~1"
set "SRC=%VALVE_DIR%\%REL%"
set "DST=%MOD_DIR%\%REL%"
if not exist "%SRC%" exit /b 0
if exist "%DST%" goto link_file_exists
mklink /H "%DST%" "%SRC%" >nul 2>&1
if errorlevel 1 goto link_file_failed
echo   linked  %REL%
exit /b 0

:link_file_exists
echo   kept    %REL% (already present)
exit /b 0

:link_file_failed
echo   FAILED  %REL% - create the link by hand with:
echo           mklink /H "%DST%" "%SRC%"
exit /b 0

rem --------------------------------------------------------------------------
rem unlink_dir <name>: drop the junction.  rmdir without /S removes the link
rem itself and never the contents of valve/.
rem --------------------------------------------------------------------------
:unlink_dir
set "REL=%~1"
set "DST=%MOD_DIR%\%REL%"
if not exist "%DST%\" exit /b 0
rmdir "%DST%" >nul 2>&1
if exist "%DST%\" goto unlink_dir_kept
echo   removed %REL%
exit /b 0

:unlink_dir_kept
echo   kept    %REL% (not a link, or not empty)
exit /b 0

rem --------------------------------------------------------------------------
rem unlink_file <name>: a hardlink looks like an ordinary file, so ask
rem PowerShell what it really is before deleting anything.  If it is not a
rem link, the file is left alone.
rem --------------------------------------------------------------------------
:unlink_file
set "REL=%~1"
set "DST=%MOD_DIR%\%REL%"
set "LINKTYPE="
if not exist "%DST%" exit /b 0
powershell -NoProfile -Command "(Get-Item -LiteralPath '%DST%' -ErrorAction SilentlyContinue).LinkType" > "%LINKTYPE_FILE%" 2>nul
set /p "LINKTYPE="<"%LINKTYPE_FILE%"
del "%LINKTYPE_FILE%" >nul 2>&1
if /I "%LINKTYPE%"=="HardLink" goto unlink_file_yes
echo   kept    %REL% (not a link)
exit /b 0

:unlink_file_yes
del "%DST%"
echo   removed %REL%
exit /b 0
