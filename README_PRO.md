# LibreMuse Pro — Install Guide

Thank you for purchasing LibreMuse Pro! You get:

- `LibreMusePro.lua` — the Pro Studio plugin (everything in the base edition, plus Prompt Library, Debug mode, Explain mode, Optimize mode, and Prompt History)
- `bridge/bridge.py` — the local bridge server (same file the base edition uses)

## Install (Windows)

1. If you have the base LibreMuse plugin installed, remove it first:
   delete `LibreMuse.lua` from `%LOCALAPPDATA%\Roblox\Plugins\`
2. Copy `LibreMusePro.lua` into `%LOCALAPPDATA%\Roblox\Plugins\`
3. Make sure Python 3 is installed, then run `bridge.py` (double-click it or run
   `python bridge.py` in a terminal). **Keep that window open** while you use the plugin.
4. Restart Roblox Studio. A new **LibreMuse Pro** toolbar button appears.
5. The first time the plugin talks to the bridge, Studio will ask for localhost
   HTTP permission — click **Allow**.

## Requirements

- Roblox Studio (with HTTP requests enabled — on by default)
- Python 3.x on your PC
- `opencode` installed and configured (`opencode.json`), since LibreMuse Pro
  uses YOUR opencode setup and models. No new API key needed.

## The 4 modes

- **✨ Generate** — describe what to build, get Luau code, insert it.
- **🐞 Debug** — select a broken script, paste the error, get the fixed script.
- **💬 Explain** — select any script, get a plain-English explanation.
- **🚀 Optimize** — select a script, get a performance-refactored version.

**📚 Templates** holds built-in prompts (double jump, sprint + stamina,
leaderstats + DataStore, day/night cycle…) and your own saved prompts.
**🕘 History** keeps your last 20 prompts — one click to re-run.

## Activation (license key)

1. After purchase, find your license key at **whop.com/hub** → LibreMuse Pro.
2. Open Roblox Studio — the plugin will ask for your key on first run.
3. Paste it and click **Activate**. One key works on one machine.

Need help? Message us through the Whop chat on your product page.
