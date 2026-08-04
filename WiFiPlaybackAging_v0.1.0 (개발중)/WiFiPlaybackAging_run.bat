@echo off
chcp 65001 > nul
setlocal
title V-Audit WiFiPlaybackAging
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WiFiPlaybackAging.ps1"
