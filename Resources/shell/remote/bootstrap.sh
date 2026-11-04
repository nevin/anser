# Runs on the remote host (POSIX sh). Unpacks Anser's hooks into a private
# temp folder, starts the user's shell with them, and they delete the folder
# on exit. Payloads (base64) are filled in by Anser.
d=$(mktemp -d 2>/dev/null || mktemp -d -t anser) || exec "${SHELL:-sh}" -l
dec() { printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D; }
dec '@@ZSH@@' > "$d/anser.zsh"
dec '@@BASH@@' > "$d/anser.bash"
printf '%s\n' 'ZDOTDIR="$HOME"; [ -r "$HOME/.zshenv" ] && . "$HOME/.zshenv"' ". \"$d/anser.zsh\"" > "$d/.zshenv"
export ANSER_REMOTE_DIR="$d"
case "${SHELL##*/}" in
    zsh) ZDOTDIR="$d" exec "$SHELL" -l ;;
    bash) exec "$SHELL" --rcfile "$d/anser.bash" -i ;;
    *) rm -rf "$d"; exec "${SHELL:-sh}" -l ;;
esac
