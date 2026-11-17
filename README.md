<h1 align="center">Rane SL4 macOS ARM Driver (Apple Silicon M1 / M2 / M3 / M4)</h1>

<p align="center">
  <strong>Native User-Space CoreAudio Driver + Serato DJ Pro 2.5.5 Bridge (<code>SL4Api.framework</code>) for Rane SL 4 on Modern Macs</strong><br>
  <em>Original idea & project by <strong>pepelee (PPLEE)</strong> — <a href="https://www.instagram.com/pepeleedj/">@pepeleedj</a> &nbsp;|&nbsp; Ultra-low-latency audio engine & CoreAudio architecture with <strong>Ben XO</strong> (<a href="https://github.com/ben-xo">@ben-xo</a>)</em>
</p>

<p align="center">
  <a href="https://github.com/pepeleedj/Rane-SL4-macOS-ARM-Driver/raw/main/Rane-SL4-Installer-Mac-M1-M2-M3-M4.zip"><strong>⬇️ DOWNLOAD INSTALLER (.ZIP)</strong></a>
  &nbsp;|&nbsp;
  <a href="https://github.com/pepeleedj/Rane-SL4-macOS-ARM-Driver/raw/main/Installer/RaneSL4-macOS-Universal.pkg"><strong>📦 DOWNLOAD .PKG DIRECTLY</strong></a>
  &nbsp;|&nbsp;
  <a href="#-español-instrucciones-en-español"><strong>🇪🇸 LEER EN ESPAÑOL</strong></a>
</p>

> ⚠️ **Not yet tested on an SL 4.** This driver is built on the engine of the Rane SL 2 and SL 3 drivers, which
> are tested on their hardware, and on what Rane's own SL 4 driver and firmware show about the box. If you try
> it with an SL 4, please report what works and what doesn't (an issue with `sl4panel`'s output and the
> driver's log helps most).

---

## 🇬🇧 English

### Why does this exist?
When Apple transitioned to **Apple Silicon (M1 / M2 / M3 / M4)** and modern macOS versions, Rane and Serato discontinued support for the flagship **Rane SL 4** dual-USB DVS audio interface because the official Rane driver relied on a legacy Intel Kernel Extension (`SL4.10.9.kext`).

**This project brings the Rane SL 4 to Apple Silicon Macs (M1, M2, M3, M4 — Base, Pro, Max, Ultra) and modern macOS (Monterey, Ventura, Sonoma, Sequoia, and newer):**

* ✅ **Designed for Serato DJ Pro 2.5.5** (the last Serato version that supports the Rane SL 4: 4-deck DVS `ABS` / `REL` / `INT` modes, `THRU` per deck, and the USB A / USB B port status) through a replacement `SL4Api.framework`.
* ✅ **NO SIP Disable Required & NO Reboot Required:** Runs 100% in user space via Apple's `AudioServerPlugIn` (CoreAudio HAL) and `IOUSBHost` frameworks.
* ✅ **Includes the SL 4 Control Panel app** (in Applications, macOS 13+) and a terminal control utility (`sl4panel`): **Thru** per deck (decks 1–4), level meters, output volume, the sample rate, which USB port (A or B) the Mac is on and whether a computer is on the other, and the firmware version.
* ✅ **Works as a 10-In / 10-Out (24-bit) CoreAudio Soundcard** in **Mixxx, Traktor, Ableton Live, Rekordbox, Logic Pro**, and system-wide macOS audio.
* ✅ **48 kHz or 96 kHz, chosen on the SL 4 itself:** the box sets its own rate and the driver follows it (the SL 4 has no 44.1 kHz, and no computer can change its rate).
* ✅ **Low-latency DVS engine, shared with the Rane SL 2 and SL 3 drivers:** deep-scheduled late-write playback and early-read capture (`docs/SL4-AUDIO-ENGINE.md`). On the SL 2 and SL 3 it measures an 8.5–9.3 ms DVS round trip at a 48–64-frame buffer; the SL 4's figures are still to be measured.
* ✅ **Output volume and mute** from the menu bar and the volume keys, and per channel in Audio MIDI Setup (the SL 4 has no volume control of its own, so the driver provides one). It applies to everything the SL 4 plays, **Serato's decks included**, and macOS remembers it: if your decks sound quiet in Serato, check the SL 4's volume.

---

### 🚀 Quick Installation (1-Click)

1. [**Download `Rane-SL4-Installer-Mac-M1-M2-M3-M4.zip`**](https://github.com/pepeleedj/Rane-SL4-macOS-ARM-Driver/raw/main/Rane-SL4-Installer-Mac-M1-M2-M3-M4.zip) and unzip it on your Mac.
2. Open Terminal and clear macOS Gatekeeper quarantine on the downloaded folder (type `xattr -cr ` with a space at the end, drag the unzipped folder into Terminal, and press **Enter**):
   ```bash
   xattr -cr ~/Downloads/Installer
   ```
3. Double-click **`Instalar-Rane-SL4.command`** (or right-click -> **Open** on **`RaneSL4-macOS-Universal.pkg`**).
4. Enter your Mac password when prompted.
5. **Done!** `coreaudiod` reloads automatically (no reboot needed). Plug in your Rane SL 4 via USB A or USB B.

#### Audio channels (10 in / 10 out, 24-bit, 48 / 96 kHz)
* **Channels 1–2:** Deck 1 · **3–4:** Deck 2 · **5–6:** Deck 3 · **7–8:** Deck 4 · **9–10:** Aux
* *This order is assumed, not yet checked on a box: the SL 4 names its channels only "CH1"–"CH10".*

---

### 🔗 Also Available: Rane SL 2 & Rane SL 3 macOS ARM Drivers!
* 🎛️ **Rane SL 2 Driver:** [pepeleedj/Rane-SL2-Macos-ARM-Driver](https://github.com/pepeleedj/Rane-SL2-Macos-ARM-Driver)
* 🎛️ **Rane SL 3 Driver:** [pepeleedj/Rane-SL3-Macos-ARM-Driver](https://github.com/pepeleedj/Rane-SL3-Macos-ARM-Driver)

---
---

## 🇪🇸 Español (Instrucciones en Español)

> ⚠️ **Todavía no probado con una SL 4.** Este driver usa el motor de los drivers de la Rane SL 2 y SL 3, probados
> en su hardware, y lo que el driver y el firmware de Rane muestran de la SL 4. Si lo pruebas con una SL 4, cuéntanos
> qué funciona y qué no.

### ¿Qué es este proyecto?
Con la llegada de los procesadores **Apple Silicon (M1 / M2 / M3 / M4)** y los nuevos sistemas macOS, las míticas tarjetas **Rane SL 4** quedaron sin soporte oficial porque el driver original de Rane dependía de una extensión de kernel antigua (`SL4.10.9.kext`) para procesadores Intel.

* ✅ **Compatible con Serato DJ Pro 2.5.5** (la última versión de Serato compatible con Rane SL 4: los 4 platos en modo DVS `ABS` / `REL` / `INT`, `THRU` por plato y el estado de los puertos USB A/B), mediante un `SL4Api.framework` de reemplazo.
* ✅ **SIN desactivar la seguridad del Mac (SIP) y SIN reiniciar:** todo funciona en espacio de usuario (plugin HAL de CoreAudio `SL4Device.driver` sobre `IOUSBHost`).
* ✅ **Incluye la app SL 4 Control Panel** (en Aplicaciones, macOS 13+) y la utilidad `sl4panel`: **Thru** por plato (1–4), medidores, volumen de salida, frecuencia de muestreo, puerto USB (A o B) y el estado del otro puerto, y la versión del firmware.
* ✅ **Tarjeta de sonido de 10 Entradas y 10 Salidas (24-bit)** en **Ableton Live, Traktor, Mixxx, Rekordbox, Logic Pro** y el audio general de macOS.
* ✅ **48 kHz o 96 kHz, elegido en la propia SL 4:** la tarjeta fija su frecuencia y el driver la sigue (la SL 4 no tiene 44.1 kHz y ningún ordenador puede cambiarla).
* ✅ **Motor de audio de baja latencia, compartido con los drivers de la SL 2 y la SL 3** (en ellas mide 8.5–9.3 ms de ida y vuelta DVS; las cifras de la SL 4 están por medir).
* ✅ **Volumen y silencio de salida** desde la barra de menús y las teclas de volumen, y por canal en Configuración de Audio MIDI. Afecta a todo lo que suena por la SL 4, **incluidos los platos de Serato**.

---

### 🚀 Instalación Paso a Paso

1. [**Descarga `Rane-SL4-Installer-Mac-M1-M2-M3-M4.zip`**](https://github.com/pepeleedj/Rane-SL4-macOS-ARM-Driver/raw/main/Rane-SL4-Installer-Mac-M1-M2-M3-M4.zip) y descomprímelo.
2. Si macOS bloquea los archivos descargados de Internet, abre **Terminal**, escribe `xattr -cr ` (con un espacio al final), arrastra la carpeta descomprimida dentro de la Terminal y pulsa **ENTER**.
3. Haz doble clic en **`Instalar-Rane-SL4.command`** (o abre **`RaneSL4-macOS-Universal.pkg`**), introduce la contraseña de tu Mac y pulsa ENTER.

#### Canales de Audio (10 Entradas / 10 Salidas a 24-bit, 48 / 96 kHz)
* **Canales 1–2:** Deck 1 · **3–4:** Deck 2 · **5–6:** Deck 3 · **7–8:** Deck 4 · **9–10:** Aux
* *Orden supuesto, todavía sin comprobar en una SL 4.*

---

### 🛠️ Compilar desde el código fuente / Build from Source
Requires Xcode Command Line Tools (`xcode-select --install`):
```bash
make            # the driver, SL4Api, sl4panel, sl4dump, sl4flash and the SL 4 Control Panel app
make install    # install a built driver over the installed package (DEBUG=1 for a debug build)
make package    # the installer package and zip, into build/
make hwtest ARGS="--loopback"   # the hardware tests (see tools/latency/README.md)
```
* `plugin/SL4Device.m`: the CoreAudio HAL AudioServerPlugIn (`SL4Device.driver`), driving the box over IOUSBHost.
* `tools/SL4Api.m`: replacement `SL4Api.framework`, matching Rane's 2.0.1f1, for Serato DJ Pro 2.5.5.
* `tools/sl4panel.m`, `tools/controlpanel/`: status and control, in Terminal and as an app.
* `tools/firmware/`, `tools/sl4dump.m`: firmware extraction from Rane's driver, over-USB updating (not yet tested on an SL 4), read-only status.
* `tools/latency/`, `tools/hwtest.sh`: latency, glitch and hardware tests.
* Docs: `docs/SL4-AUDIO-ENGINE.md` (design, bug catalogue, and what is still to check on hardware), `docs/SL4-COMMANDS.md` (the box's protocol, from Rane's driver and firmware), `AGENTS.md` (for contributors).

---

### 🙌 Créditos y Licencia / Credits & License
* **Idea original, puente Serato (`SL4Api.framework`), utilidad `sl4panel` e instalador macOS Universal:** **pepelee (PPLEE)** — Instagram: [@pepeleedj](https://www.instagram.com/pepeleedj/)
* **Motor de audio de baja latencia (del driver de la SL 2), controles de volumen/mute, `SL 4 Control Panel.app`, herramientas de firmware, pruebas de hardware y documentación del protocolo:** **Ben XO** — GitHub: [@ben-xo](https://github.com/ben-xo)
* **Licencia:** [GPL-3.0-or-later](LICENSE).
* *Disclaimer:* Proyecto independiente no afiliado con Rane ni Serato. "Rane", "SL 4" y "Serato" son marcas registradas de sus respectivos propietarios.

---

### 🔗 Other Rane Series Drivers for Apple Silicon (M1 / M2 / M3 / M4)
* 🎛️ **Rane SL 2:** [pepeleedj/Rane-SL2-Macos-ARM-Driver](https://github.com/pepeleedj/Rane-SL2-Macos-ARM-Driver)
* 🎛️ **Rane SL 3:** [pepeleedj/Rane-SL3-Macos-ARM-Driver](https://github.com/pepeleedj/Rane-SL3-Macos-ARM-Driver)
* 🎛️ **Rane SL 4:** [pepeleedj/Rane-SL4-macOS-ARM-Driver](https://github.com/pepeleedj/Rane-SL4-macOS-ARM-Driver)
