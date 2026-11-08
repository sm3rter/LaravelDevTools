@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\github\github.ps1" %*
