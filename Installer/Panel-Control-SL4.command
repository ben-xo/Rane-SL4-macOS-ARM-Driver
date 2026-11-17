#!/bin/bash
clear
echo "=========================================================="
echo "   PANEL DE CONTROL RANE SL4 — by pepelee (@pepeleedj)    "
echo "   Instagram: https://www.instagram.com/pepeleedj/        "
echo "=========================================================="
echo ""
# La app SL 4 Control Panel si esta instalada; si no, el estado en Terminal.
if [ -d "/Applications/SL 4 Control Panel.app" ]; then
    open "/Applications/SL 4 Control Panel.app"
    exit 0
elif [ -x "/usr/local/bin/sl4panel" ]; then
    /usr/local/bin/sl4panel status
else
    echo "La herramienta sl4panel aun no esta instalada en /usr/local/bin/sl4panel."
    echo "Ejecuta primero Instalar-Rane-SL4.command o RaneSL4-macOS-Universal.pkg"
fi
echo ""
read -p "Pulsa ENTER para cerrar esta ventana..."
