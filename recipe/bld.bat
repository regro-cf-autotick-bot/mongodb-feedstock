@echo ON
setlocal ENABLEDELAYEDEXPANSION

REM mongo ships a tools/bazel wrapper; skip it so the conda 'bazel' is used.
set "BAZELISK_SKIP_WRAPPER=1"

set "VS_ROOT=%VSINSTALLDIR%"
if defined VS_ROOT if "!VS_ROOT:~-1!"=="\" set "VS_ROOT=!VS_ROOT:~0,-1!"

set "VC_ROOT=%VCINSTALLDIR%"
if defined VC_ROOT if "!VC_ROOT:~-1!"=="\" set "VC_ROOT=!VC_ROOT:~0,-1!"

set "VC_VER=%VCToolsVersion%"

if not defined VS_ROOT ( echo ERROR: VSINSTALLDIR not set; VS activation did not run. & exit /b 1 )
if not defined VC_ROOT ( echo ERROR: VCINSTALLDIR not set; VS activation did not run. & exit /b 1 )
if not defined VC_VER  ( echo ERROR: VCToolsVersion not set; VS activation did not run. & exit /b 1 )

REM Relocate TMP/TEMP to a short path outside AppData.
if not exist D:\mongo_tmp mkdir D:\mongo_tmp
set "TMP=D:\mongo_tmp"
set "TEMP=D:\mongo_tmp"

set BAZEL_ARGS=^
 "--repo_env=BAZEL_VS=!VS_ROOT!" ^
 "--repo_env=BAZEL_VC=!VC_ROOT!" ^
 "--repo_env=BAZEL_VC_FULL_VERSION=!VC_VER!" ^
 "--repo_env=BAZEL_WINSDK_FULL_VERSION=" ^
 --action_env=TMP=D:\mongo_tmp ^
 --action_env=TEMP=D:\mongo_tmp ^
 --repo_env=TMP=D:\mongo_tmp ^
 --repo_env=TEMP=D:\mongo_tmp ^
 --config=local ^
 --disable_warnings_as_errors=True ^
 --build_enterprise=False ^
 --//bazel/config:running_through_bazelisk=true ^
 --verbose_failures ^
 --keep_going ^
 --compilation_mode=opt ^
 --copt=/Zm100 ^
 "--per_file_copt=.*(resharding_op\w*|resharding_util\w*|fle2_\w*_cmd|get_cluster_parameter_command)\.cpp@/Od" ^
 --define=MONGO_VERSION=%PKG_VERSION%

if not exist D:\b mkdir D:\b

REM Raise the 260-char path ceiling for long-path-aware tools; shoudl be set before bazel.
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f

REM MongoDB 8.3+ resolves header deps through per-package .auto_header/ Bazel
REM packages, generated at build time from a ripgrep scan of the include graph.
REM The generator only runs inside mongo's bazelisk wrapper, which we do not
REM use, and its output is gitignored, so the release tarball has none. The
REM helper resolves ripgrep from PATH and forces the offline fallbacks itself.
REM Run it after the long-path registry tweak above.
set "RG_PATH=rg"
set "FORCE_NO_FD=1"
python -c "import sys;sys.path.insert(0,'.');from pathlib import Path;from bazel.auto_header.auto_header import gen_auto_headers as g;from bazel.auto_header.gen_all_headers import spawn_all_headers_thread as s;r=Path.cwd();t,st=s(r);a=g(r);t.join();sys.exit(None if a['ok'] and st['ok'] else 'auto_header generation failed')"
if errorlevel 1 exit /b 1

REM Two passes: parallel build (some actions may OOM), then -j1 to finish from cache.
bazel --output_user_root=D:\b build %BAZEL_ARGS% --//bazel/config:dbg=False --//bazel/config:opt=on --jobs=4 install-core
bazel --output_user_root=D:\b build %BAZEL_ARGS% --//bazel/config:dbg=False --//bazel/config:opt=on --jobs=1 install-core
if errorlevel 1 exit /b 1

if not exist "%LIBRARY_BIN%" mkdir "%LIBRARY_BIN%"
copy /Y "bazel-bin\install\bin\mongod.exe" "%LIBRARY_BIN%\mongod.exe" || exit /b 1
copy /Y "bazel-bin\install\bin\mongos.exe" "%LIBRARY_BIN%\mongos.exe" || exit /b 1

bazel --output_user_root=D:\b clean --expunge || ver > nul

endlocal
exit /b 0

