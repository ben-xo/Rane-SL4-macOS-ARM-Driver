#!/bin/bash
set -e

clear
echo "=========================================================="
echo "   DESINSTALADOR DRIVER RANE SL4                          "
echo "=========================================================="
echo ""
echo "Se eliminaran el driver SL4Device.driver, SL4Api.framework, la app SL 4 Control Panel y las utilidades de Terminal."
echo "(Te pedira la contrasena de inicio de sesion de tu Mac)"
echo ""

sudo rm -rf "/Library/Audio/Plug-Ins/HAL/SL4Device.driver"
sudo rm -rf "/Library/Frameworks/SL4Api.framework"
sudo rm -rf "/Applications/SL 4 Control Panel.app"
sudo rm -rf "/Library/PreferencePanes/SL 4 Audio Control Panel.prefPane"   # instalado por versiones anteriores
sudo rm -rf "/Library/Extensions/SL4.10.9.kext"
sudo rm -f "/usr/local/bin/sl4panel" "/usr/local/bin/sl4dump" "/usr/local/bin/sl4flash"
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod >/dev/null 2>&1 || sudo killall coreaudiod >/dev/null 2>&1 || true

echo ""
echo "Driver Rane SL4 desinstalado correctamente."
echo ""
read -p "Pulsa ENTER para cerrar esta ventana..."
