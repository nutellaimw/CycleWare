## Cycle-Ware

A prison life enhancer (vibe coded, but fully works, and developed by someone who at least knows what is he doing)

## Loader

```lua
getgenv().CW_CONFIG = {
    CURSOR_FILE                = "CycleWare/Assets/cursor.png",
    HITMARKER_FILE             = "CycleWare/Assets/hitmarker.png",
    SOUND_FILE                 = "CycleWare/Assets/sound.mp3",
    HITMARKER_SIZE             = 60,
    SOUND_VOLUME               = 1,
    CURSOR_TARGET_SIZE         = 50,
    HITMARKER_RANDOM_ROTATION  = false,
    HITMARKER_FOLLOW_MOUSE     = false,
    HITMARKER_VISIBLE_DURATION = 0.05,
    HITMARKER_FADEOUT          = true,
    HITMARKER_FADEOUT_DURATION = 0.15,
}

loadstring(game:HttpGet("https://raw.githubusercontent.com/nutellaimw/CycleWare/refs/heads/main/CycleWare.lua"))()
```


## Requirements

You executor must support these functions:

full File API,
getcustomasset,
getgenv,
gethui,
hookmetamethod,
newcclosure,
checkcaller,
getnamecallmethod.


## How to use

To setup, first run the script once. After that, open your executor workspace folder. There will be created a folder named CycleWare. Open it.
Inside, open Assets, and paste the files you would like as your cursor, hitmaker and hit sound, named exactly like this respectably:

cursor.png
hitmarker.png
sound.mp3

(currently no other file format is supported)

Re-run the script and it will be all applied. You can change settings/assets in real time, not needing to rejoin the game.
Everything else is edited directly on the script.

If you still need help, there's a video guide in our discord, and also a bunch of assets posted by me that you can use!

https://discord.gg/7qFKCqpAnc
