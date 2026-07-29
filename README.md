A prison life enhancer (vibe coded, but fully works, and developed by someone who at least knows what is he doing)

Integrated with custom settings.


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


You executor must support these functions:

full File API.
getcustomasset
getgenv
gethui
hookmetamethod
newcclosure
checkcaller
getnamecallmethod
