<div align="center">

# vivo Office Kit in English

**Use the Chinese vivo Office Kit (vivo办公套件) in English, in one click.**<br>
For China-market vivo phones that only work with the Chinese version.

[![Download](https://img.shields.io/badge/⬇_Download-vivo_English_Kit-2EA44F?style=for-the-badge)](https://github.com/dr-dolomite/vivo-office-kit-english/releases/latest/download/vivo-office-kit-english-v1.0.0.zip)

Windows 10 & 11 · Nothing else to install · Undo anytime

</div>

---

## 🚀 Install in 3 steps

<table>
<tr>
<td width="55%">

**1. Download and unzip**<br>
Click the green **Download** button above. Right-click the downloaded zip, choose
**Extract All…**, then **Extract**.

**2. Open the kit**<br>
In the extracted folder, double-click **`vivo English Kit.cmd`**.

**3. Click Install**<br>
Click **Install English Language Support**. When Windows asks for permission, click **Yes**.

**That's it.** vivo Office Kit restarts in English.

</td>
<td width="45%">

![The vivo English Kit window](docs/gui.png)

</td>
</tr>
</table>

> [!TIP]
> **"Windows protected your PC"?** That's normal for downloaded files. Click **More info**, then **Run anyway**.

> [!IMPORTANT]
> **After a vivo Office Kit update** the app goes back to Chinese. Just open the kit and click **Install** again.

### Undo

Open the kit and click **Restore Chinese**. Everything goes back exactly as it was.

---

## Is this for me?

Yes, if you have a **China-market vivo phone** (for example a vivo X200 Ultra from China).
Only the **Chinese** vivo Office Kit connects to those phones, and it has no language option.
This kit adds English and changes nothing else: your account, cloud sync and phone connection
keep working as normal.

If your phone is a Global model, use vivo's Global Office Kit instead. It's already in English.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Installation not found" | Install the **Chinese** vivo Office Kit first, then try again. |
| "This is the GLOBAL build" | You have the Global version, which is already English. Nothing to do. |
| Still in Chinese | Close vivo Office Kit completely (also from the system tray) and click **Install** again. |
| Something else | Click **View log** in the kit window and [open an issue](https://github.com/dr-dolomite/vivo-office-kit-english/issues) with the log text. |

## Leave a tip ☕

If this saved you some frustration, a coffee is always appreciated:

[![Donate with PayPal](https://img.shields.io/badge/Donate-PayPal-003087?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/iamrusss)
[![Pay with Wise](https://img.shields.io/badge/Tip-Wise-9FE870?style=for-the-badge&logo=wise&logoColor=163300)](https://wise.com/pay/business/blackcatdev?currency=USD)

---

<details>
<summary><b>More details</b> (tested versions, what gets translated, no-window option)</summary>

### Tested with
vivo Office Kit **7.0.6** (Chinese build), Windows 11, vivo X200 Ultra (China). Other versions
will probably work. The kit tells you if something looks different.

The kit window gets the Windows 11 look automatically if PowerShell 7.5 or newer is installed.
Otherwise it uses the classic look. Both work the same.

### What gets translated
- Everything vivo already translated for its Global version.
- China-only features vivo never translated, using vivo's own English names where they exist:
  **Origin Notes**, **Calendar**, **Albums**, **Recorder**, **To-dos**, the cloud services
  (Contacts, Cloud Drive, Find My Device…), sync prompts, search, sorting and File Manager categories.
- Some less-used screens may still show a little Chinese. Spotted one?
  [Open an issue](https://github.com/dr-dolomite/vivo-office-kit-english/issues) with a screenshot.

To keep vivo's original Chinese labels for those features, untick
**"Also translate China-only labels"** before clicking Install.

### No window
Double-click **`Install-English.cmd`** to install, or **`Restore-Chinese.cmd`** to undo.

</details>

<details>
<summary><b>Technical details</b> (what it changes, command line)</summary>

- `resources\app.asar` in the vivo Office Kit folder:
  - Removes the code that forces Chinese on the Chinese build.
  - Translates the labels listed in `translations.json`.
  - The original is saved as `app.asar.en-kit.bak`, and Restore puts it back.
- `%APPDATA%\pcsuite\config.json` and `config.ini`: language set to English.
- It does **not** touch `build-config.json`, vivo's servers, your account, or how the phone connects.
- Every run is logged to `patch-log.txt` in the kit folder.

Command line (PowerShell):

```powershell
.\Add-VivoEnglish.ps1 [-Restore] [-NoLabelTranslation] [-InstallDir <path>]
```

Exit codes: `0` success, `1` install not found, `2` Global build detected.

</details>

## Disclaimer

Unofficial, community-made tool. Not affiliated with or endorsed by vivo. It modifies files of an
installed app, so use it at your own risk. You can always undo it with **Restore Chinese** or by
reinstalling vivo Office Kit.

Licensed under [MIT](LICENSE).
