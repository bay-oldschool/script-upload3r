@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0ps\delete.ps1" %*
