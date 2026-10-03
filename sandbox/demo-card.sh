#!/bin/sh
printf '\n   \033[1mN O T H I N G   L I Q U I D\033[0m\n\n'
printf '   \033[90mmaterial\033[0m   liquid glass, squircle bezel\n'
printf '   \033[90moptics  \033[0m   snell refraction  n = 1.5\n'
printf '   \033[90mrim     \033[0m   even hairline, no key light\n'
printf '   \033[90mlight   \033[0m   only where you press\n'
printf '   \033[90maccent  \033[0m   \033[31m●\033[0m  one red\n\n'
ls --color=always -p /usr/share/wallpapers /usr/share/backgrounds 2>/dev/null | head -14
exec sh
