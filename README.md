# 🔗 Wired-Steam-Link-VR - Stable Wired PCVR for Quest Headsets

## 🚀 What This Does

Wired-Steam-Link-VR lets you run Steam Link over a USB cable instead of Wi-Fi. This gives you a stable, low-latency PC VR connection for your Meta Quest 2 or Quest 3.

## 📥 Quick Download

[![Download the latest release](https://img.shields.io/badge/Download-Latest_Release-brightgreen?style=for-the-badge&logo=github)](https://github.com/Siken9013/Wired-Steam-Link-VR/releases)

Visit this link to download the application.

## 📋 What You Need

- Windows 10 or Windows 11 PC
- Meta Quest 2 or Quest 3 headset
- USB cable (data-capable, preferably USB 3.0 or higher)
- Steam installed on your PC
- Steam Link app installed on your Quest headset
- ADB drivers installed (the tool can help with this)

## ✅ How to Use

1. **Download** the latest release from the link above.
2. **Extract** the ZIP file to a folder on your PC.
3. **Run** the application (the `.exe` file).
4. **Connect** your Quest headset to your PC using a USB cable.
5. **Follow** the on-screen instructions. The tool will enable the USB Ethernet connection automatically.
6. **Open** Steam Link on your Quest. You will see your PC ready to stream over the wired connection.

## 🔧 Features

- Switches your Quest to USB Ethernet mode automatically
- Bypasses Wi-Fi for lower latency
- Completely free and open-source
- Portable – no installation needed
- Works with any Steam Link compatible USB cable

## 📖 How It Works

Wired-Steam-Link-VR uses ADB commands to change your Quest headset's USB configuration from charging to Ethernet tethering mode. Once activated, the headset's TCP/IP stack uses the USB connection as its network interface. This allows Steam Link to communicate with your PC over the cable instead of Wi-Fi, reducing latency and interference.

## 🏁 System Requirements

- **OS**: Windows 10 or Windows 11 (64-bit)
- **RAM**: 8GB or more
- **USB Port**: USB 3.0 or higher (recommended)
- **Headset**: Meta Quest 2, Quest 3, or Quest Pro
- **ADB**: Enabled (the release includes or offers this option)

## ❓ Troubleshooting

- **Headset not detected:** Make sure USB debugging is enabled in your Quest's Developer mode.
- **USB connection fails:** Try a different USB port (USB 3.0) or a different cable.
- **Latency still high:** Ensure no other network adapters are active; if possible, disable Wi-Fi on your PC.
- **Ethernet not showing:** Re-run the tool and follow the instructions again. Restart both devices if needed.

## 💬 Support

Report issues on the [GitHub Issues page](https://github.com/Siken9013/Wired-Steam-Link-VR/issues). Include your Windows version, Quest model, and a brief description of the problem.

## 🤝 Contributing

Contributions, improvements, and bug fixes are welcome. Fork the repo and submit a pull request.

Keywords: adb, meta-quest, ncm, pcvr, powershell, quest2, quest3, steam-link, usb, usb-ethernet, virtual-reality, vr, windows, wired