# mc.sh

mc.sh is a single file Minecraft launcher written entirely in POSIX sh + a
couple other utilities.

## Warning

Theoretically you could play without owning the game due to the complete lack
of authentication on Microsoft's/Mojang's servers, not that you'd want to do
that or anything.

With some effort, you could play online multiplayer if you want to pull a
session token from the actual launcher or want to implement authentication
yourself, but it is out of scope for this project.

## Dependencies

- jq
- curl
- unzip
- Java, the version your desired version supports.

## Running

1. Make a new folder and copy `mc.sh` to it.
2. Run `mc.sh list` to get a list of all available versions, and then `mc.sh
   <ver>` to download it.
3. Now whenever you want to play, run `./mc.sh` and the game will start.

### My computer sucks I need OptiFine

Run `./mc.sh optifine` after downloading a Minecraft version.

## Issues

- Not many versions of Minecraft have been tested.
  My system is weak and can only really run 1.8.9 competently.
  Newest version I can run is 1.18.2; 1.19.3, the latest as of writing,
  segfaults on my machine, and may or may not work on your system.
- Minecraft works fine on musl but you may need to replace a couple libraries
  in `libraries/natives` with ones provided by your distribution.
  This is done automatically on musl, and provided you have the libraries
  installed it should just work.
