@echo off
chcp 65001 >nul
cd /d %~dp0
echo [白羽] 正在启动电脑被观看端...
python -m pip install -r requirements.txt
echo.
echo 用 ipconfig 查到你的局域网 IP，iOS 端填 ws://那个IP:8080/ws
ipconfig | findstr /i "IPv4"
echo.
python sender.py --host 0.0.0.0 --port 8080 --monitor 1 --fps 30
pause
