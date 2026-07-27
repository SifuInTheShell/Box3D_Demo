@echo off
rem Update the vendored Box3D engine from Erin Catto's upstream repo, rebuild
rem the GDExtension (which includes OUR extended wrapper in godot\src -- the
rem near-complete C-API binding), and deploy fresh DLLs into game\bin\.
rem
rem   tools\update_box3d.bat            pull upstream + rebuild + deploy
rem   tools\update_box3d.bat nopull     rebuild + deploy only (wrapper changes)
rem
rem Run from a "x64 Native Tools Command Prompt for VS" (MSVC on PATH).
rem Requires git and SCons (pip install scons; falls back to python -m SCons).
rem
rem Only upstream-owned paths are replaced (src, include, test, samples,
rem shared, extern, benchmark, data, docs, root build files). godot\ -- with
rem the extended wrapper -- plus README.md/.gitignore are never
rem touched, so a pull can never lose our binding. If the build fails after a
rem pull, upstream changed its C API and the wrapper needs a matching patch
rem (see docs\box3d-build-and-use.md). Nothing is deployed on failure.
setlocal enabledelayedexpansion

set "REPO_ROOT=%~dp0.."
set "VENDOR=%REPO_ROOT%\extern\box3d-godot"
set "GAME_BIN=%REPO_ROOT%\game\bin"
if "%BOX3D_UPSTREAM%"=="" set "BOX3D_UPSTREAM=https://github.com/erincatto/box3d"

if /i "%~1"=="nopull" goto :build

echo ==^> Pulling latest erincatto/box3d (%BOX3D_UPSTREAM%)
set "TMPCLONE=%TEMP%\box3d_upstream_%RANDOM%"
git clone --depth 1 "%BOX3D_UPSTREAM%" "%TMPCLONE%" || goto :fail
for /f %%c in ('git -C "%TMPCLONE%" rev-parse --short HEAD') do set "COMMIT=%%c"
echo ==^> Upstream at %COMMIT% -- replacing upstream-owned paths

for %%d in (src include test samples shared extern benchmark data docs) do (
    if exist "%TMPCLONE%\%%d" (
        robocopy "%TMPCLONE%\%%d" "%VENDOR%\%%d" /MIR /NFL /NDL /NJH /NJS >nul
        if errorlevel 8 goto :fail
    )
)
for %%f in (CMakeLists.txt CMakePresets.json build.sh deploy_docs.sh build_vs2022.bat build_vs2026.bat CONTRIBUTING.md LICENSE) do (
    if exist "%TMPCLONE%\%%f" copy /y "%TMPCLONE%\%%f" "%VENDOR%\%%f" >nul
)
echo %COMMIT%> "%VENDOR%\UPSTREAM_COMMIT"
rmdir /s /q "%TMPCLONE%"
echo ==^> Vendored tree now tracks upstream %COMMIT% (recorded in extern\box3d-godot\UPSTREAM_COMMIT)

:build
echo ==^> Building the GDExtension (debug + release)
cd /d "%VENDOR%\godot" || goto :fail
where scons >nul 2>nul
if errorlevel 1 (
    set "SCONS=python -m SCons"
) else (
    set "SCONS=scons"
)
%SCONS% || goto :fail
%SCONS% target=template_release || goto :fail

echo ==^> Deploying into game\bin\
if not exist "demo\bin\libbox3d_godot.windows.template_release.x86_64.dll" (
    echo No built DLLs found in demo\bin -- build failed?
    goto :fail
)
copy /y "demo\bin\libbox3d_godot.windows.*.dll" "%GAME_BIN%\" || goto :fail

echo.
echo Done. Suggested verification before committing:
echo   godot --headless --path game res://gyms/destruction/settle_test.tscn
echo   godot --headless --path extern\box3d-godot\godot\demo --import   (then the demo selftests)
echo Linux libraries are built separately: tools/update_box3d.sh on a Linux machine.
exit /b 0

:fail
echo.
echo FAILED -- nothing further was deployed. If this happened right after an
echo upstream pull, the wrapper in extern\box3d-godot\godot\src likely needs a
echo patch for an upstream API change (docs\box3d-build-and-use.md).
exit /b 1
