# ZAPRET AUTOPILOT

[Русский](README.md) | **English**

A one-click tool that installs, repairs, tunes and enables [Flowseal's zapret](https://github.com/Flowseal/zapret-discord-youtube) on Windows,
so Discord and YouTube work. It is built for people who are not comfortable with computers.

> The program's interface is in Russian. This guide quotes the on-screen labels in Russian with a translation, and refers to menu items by their numbers.

### [⬇ Download zapret-autopilot.zip](https://github.com/Microb4ek/zapret-autopilot/releases/latest/download/zapret-autopilot.zip)

The archive does not contain zapret itself: the program always downloads the latest release from Flowseal's GitHub.

## How to use

1. Download the archive from the link above and extract all of it: right-click → "Extract All".
2. Open the `zapret-autopilot` folder and double-click `zapret-autopilot.bat`.
   - If Windows asks whether to run the file, click "Run".
   - If a blue "Windows protected your PC" window appears, click "More info" → "Run anyway".
   - When asked to allow the app to make changes, click "Yes".
3. Press **Enter** and wait 5–10 minutes.

From there the program does everything itself:
- finds zapret on the computer, or downloads the latest release and installs it to `C:\zapret` if there is none;
- reinstalls zapret if it is broken (for example, if an antivirus deleted its files);
- tests every strategy and picks the one that works best with your internet provider;
- enables the bypass and makes it start automatically with Windows;
- puts a **"Zapret"** shortcut on the desktop. After that you can delete the downloaded archive.

When something stops working, open the "Zapret" shortcut and choose item **3**, "Что-то не работает? Починить и настроить заново" ("Something doesn't work? Repair and set up again").

A minimized "zapret" window stays on the taskbar. Do not close it: that window is the bypass.

## AUTO mode and manual mode

**AUTO mode** is on by default, and you don't need to press anything.
- **First run, or zapret is broken.** The program counts down 10 seconds, in case you want to open the settings, then installs, repairs and tunes everything by itself.
- **The bypass is off.** The program turns it on and closes itself after 15 seconds.
- **The bypass is already running.** The regular menu opens.

Pressing any key during a countdown keeps the window open. The only question AUTO mode may ask is whether to add a Windows Defender exclusion, and the settings can turn that question off as well (see below).

**Manual mode** always shows the menu and asks before installing, updating or repairing zapret, and before removing conflicting programs.

## Settings

Item **5** on the main screen ("Настройки"). Changes are saved immediately.

| Setting | Options (the first one is the default) |
|---|---|
| Mode | AUTO / manual |
| zapret install folder | `C:\zapret` or any other folder. If zapret is already installed, the program offers to move it there, together with autostart and shortcuts |
| Desktop shortcut | yes / no |
| Start menu shortcut | no / yes |
| Start the bypass with Windows | yes / no |
| Update zapret | only when it stops working / always install the latest release / never |
| Windows Defender exclusion | ask / add without asking / never add |
| Clear the Discord cache during setup | yes / no |
| Remove conflicting programs (GoodbyeDPI etc.) | yes / no |
| Required services | all / any subset of Discord, YouTube, Google, Cloudflare. For example, if you only need Discord and YouTube, the program will not update zapret just because Google doesn't open |
| Copy the program into the zapret folder | yes / no |

## What happens automatically

| Situation | What the program does |
|---|---|
| zapret is not installed | Downloads the latest release from GitHub into the folder from the settings (`C:\zapret`) |
| zapret files are missing | Reinstalls zapret from scratch; your `*-user.txt` lists are kept |
| Files disappear right after installation | Explains that this is the antivirus and, depending on the setting, asks about (or adds, or skips) a Windows Defender exclusion |
| No strategy opens all required services | If GitHub has a newer zapret, updates and tests again; otherwise enables the best strategy available |
| Nothing works at all and zapret lives in a folder with Cyrillic letters or in OneDrive | Installs a clean copy into the folder from the settings and tests again |
| The tests could not run | Enables the standard `general.bat` |
| The zapret service, GoodbyeDPI or similar is installed | Removes them, because they get in the way |

Before every update or repair the old folder is backed up. To bring it back, open item **9** ("Меню для опытных", advanced menu) → item **10** ("Откатить обновление", roll back the update).

## Files

| Location | What it is |
|---|---|
| `zapret-autopilot.bat` | Launcher. Requests administrator rights by itself |
| `autopilot.ps1` | All the logic |
| `<zapret>\autopilot\` | The program copies itself here; the "Zapret" shortcut points to this copy |
| `C:\ProgramData\zapret-autopilot\settings.json` | Settings |
| `C:\ProgramData\zapret-autopilot\state.json` | Memory: zapret folder, best strategy, test results |
| `C:\ProgramData\zapret-autopilot\last-run.log` | Log of the last run, useful when something goes wrong |
| `C:\ProgramData\zapret-autopilot\backup\` | The three latest zapret backups for rollback |

## How the check works

1. **Preparation.** The running bypass is stopped, and the `zapret` service (service.bat → Install Service) is removed.
2. **Diagnostics.** The same checks as service.bat → Run Diagnostics, without the questions.
   TCP timestamps are enabled, BFE is started, a stuck WinDivert service is removed.
   Conflicting bypasses are removed and the Discord cache is cleared, if those options are on in the settings.
3. **Tests.** Flowseal's own `utils\test zapret.ps1` runs in Standard → All configs mode.
4. **Choice.** A strategy counts as working when every address of the required services from `utils\targets.txt` opens (all services by default: Discord, YouTube, Google, Cloudflare).
   Among several working strategies, the one with more successful requests wins.
5. **Start.** The best strategy starts minimized. Autostart uses the `zapret-autopilot` Task Scheduler task, which runs at Windows sign-in with administrator rights.

## For advanced users

Item **9** on the main screen opens the full menu: diagnostics and tests on their own, the results table, reinstall, rollback, folder selection.

Command-line actions:

```
zapret-autopilot.bat auto       do everything without questions (even in manual mode)
zapret-autopilot.bat menu       advanced menu
zapret-autopilot.bat settings   settings
zapret-autopilot.bat cycle      diagnostics -> tests -> start the best strategy
zapret-autopilot.bat start      start the remembered best strategy
zapret-autopilot.bat stop       stop the bypass
zapret-autopilot.bat diag       diagnostics only
zapret-autopilot.bat test       tests only
zapret-autopilot.bat rollback   roll back a zapret update
```
