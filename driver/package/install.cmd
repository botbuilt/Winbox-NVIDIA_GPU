@echo off
rem Installs this test-signed Triton driver. Run as Administrator.
rem Test signing must be enabled first: bcdedit -set TESTSIGNING ON, then reboot.
cd /d "%~dp0"
bcdedit | find /i "testsigning" | find /i "Yes" >nul || (
  echo Test signing is off. Run: bcdedit -set TESTSIGNING ON
  echo then reboot and run this again.
  exit /b 1
)
certutil -addstore -f Root VirtIOTestCert.cer || exit /b 1
certutil -addstore -f TrustedPublisher VirtIOTestCert.cer || exit /b 1
pnputil /add-driver viogpu3d.inf /install || exit /b 1
rem The driver needs these two values (it also restores them at every boot).
reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v TdrDebugMode /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Scheduler" /v EnablePreemption /t REG_DWORD /d 0 /f >nul
echo.
echo Installed. Reboot Windows so every app uses the new driver.
