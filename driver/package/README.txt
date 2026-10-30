Triton guest driver (test-signed, unofficial build)

Install (Windows 10 or 11 x64 guest, admin Command Prompt):
  1. bcdedit -set TESTSIGNING ON   (Secure Boot must be off), then reboot
  2. run install.cmd from this folder, then reboot

Uninstall: Device Manager > Display adapters > VirtIO GPU 3D controller >
Properties > Driver > Roll Back Driver (or Uninstall), then
bcdedit -set TESTSIGNING OFF and reboot.

Test mode shows a desktop watermark, and some games with anti-cheat refuse
to run while it is on. Source, patches and license texts:
https://github.com/botbuilt/Winbox-NVIDIA_GPU (driver/ folder)
