@echo off
rem Stress test: full set, isolated forest + real game world from the stress cache, about 4 minutes.
rem Report: tools\control\runs\stress\stress.md (summary) and stress.json (all numbers).
cd /d "%~dp0..\.."
if not defined GODOT set "GODOT=..\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"
"%GODOT%" --path . --script res://tools/stress/stress.gd -- --groups all %*
echo.
echo Report: %CD%\tools\control\runs\stress\stress.md
pause
