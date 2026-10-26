@echo off
python "%~dp0fake-instabox.py" %*
exit /b %errorlevel%
