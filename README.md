<div align="center">

<img src="https://github.com/user-attachments/assets/53b2a29a-ff7a-4e18-b3dc-41610dbe630d"
     alt="Cycle-Ware Logo"
     width="247">

</div>

##                                              Cycle-Ware

A prison life enhancer (vibe coded, but fully works, and developed by someone who at least knows what is he doing)

## Loader

```lua
getgenv().CW_CONFIG = {
    CURSOR_FILE                = "CycleWare/Assets/cursor.png",
    HITMARKER_FILE             = "CycleWare/Assets/hitmarker.png",
    SOUND_FILE                 = "CycleWare/Assets/sound.mp3",
    HITMARKER_SIZE             = 40,
    SOUND_VOLUME               = 1,
    CURSOR_TARGET_SIZE         = 82,
    HITMARKER_RANDOM_ROTATION  = true,
    HITMARKER_FOLLOW_MOUSE     = true,
    HITMARKER_VISIBLE_DURATION = 0.05,
    HITMARKER_FADEOUT          = true,
    HITMARKER_FADEOUT_DURATION = 0.15,
    customBulletTracers        = false,
    tracerColor                = Color3.fromRGB(170, 0, 255),
    glowColor                  = Color3.fromRGB(200, 100, 255),
    tracerWidth                = 0.05,
    tracerLifetime             = 0.05,
    applyToOthers              = false,
}

loadstring(game:HttpGet("https://raw.githubusercontent.com/nutellaimw/CycleWare/refs/heads/main/CycleWare.lua"))()
```

Differently of other scripts, CycleWare does not use imagelabels as the cursor. Instead, we use the MouseIcon, which offers 0 delay on mov.
The only thing in usage as imagelabel is the hitmarker. But we plan to change that in the future.


## Requirements

You executor must support these functions:

Full File API,
getcustomasset,
getgenv,
gethui,
hookmetamethod,
newcclosure,
checkcaller,
getnamecallmethod.


## How to use

To setup, first run the script once. After that, open your executor workspace folder. There will be created a folder named CycleWare. Open it.
Inside, open Assets, and paste the files you would like as your cursor, hitmarker, hit sound, and gun texture, named exactly like this respectably:


```text
cursor.png
hitmarker.png
sound.mp3
texture.png
```

(currently no other file format is supported)

Re-run the script and it will be all applied. You can change settings/assets in real time, not needing to rejoin the game.
Everything else is edited directly on the script.

If you still need help, there's a video guide in our discord, and also a bunch of assets posted by me that you can use!

https://discord.gg/7qFKCqpAnc

This script was a try at recreating an old prison life script with the same idea behind it. But since prison life got updated and the original script was never updated, I decided to step in and remake it. 

The original script is also available for anyone to see: https://raw.githubusercontent.com/VapingCat/IA-Battlegrounds-Hitmarkers-Cursor/main/script.lua
