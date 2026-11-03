@echo off
python "%~dp0fake-ssh.py" %*
exit /b %errorlevel%
