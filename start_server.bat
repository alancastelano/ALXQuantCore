@echo off
cd /d C:\ALXQuant
"C:\ALXQuant\.venv\Scripts\python.exe" -m gui.html.serve > C:\ALXQuant\server_restart.log 2> C:\ALXQuant\server_restart_err.log
