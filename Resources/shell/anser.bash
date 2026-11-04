# Anser shell integration for bash. Anser starts bash with --rcfile pointing
# here, so first load the user's startup files like a login shell would.

[ -r /etc/profile ] && builtin source /etc/profile
for _anser_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -r "$_anser_rc" ]; then builtin source "$_anser_rc"; break; fi
done
# If no login file pulled in .bashrc, load it ourselves.
if [ -r "$HOME/.bashrc" ] && ! grep -qs bashrc "$_anser_rc" 2>/dev/null; then builtin source "$HOME/.bashrc"; fi
unset _anser_rc

# Clear-line key Anser sends before running a command (emacs and vi modes).
for _anser_km in emacs vi-insert vi-command; do
    builtin bind -m "$_anser_km" '"\e[9999~": kill-whole-line' 2>/dev/null
done
unset _anser_km

# Prompt while Anser's editor is in charge: hidden | compact | full.
_anser_prompt_mode=${ANSER_PROMPT_MODE:-full}
_anser_user_ps1=$PS1
case $_anser_prompt_mode in
    hidden)  PS1='\[\e[?25l\]' ;;
    compact) PS1='\[\e[32m\]❯\[\e[0m\] ' ;;
esac
_anser_mode_full() { PS1=$_anser_user_ps1; _anser_prompt_mode=full; printf '\e[?25h'; }
builtin bind -x '"\e[9998~": _anser_mode_full' 2>/dev/null
unset ANSER_PROMPT_MODE ANSER_COMPACT_PROMPT

# Ghostty's integration: prompt marks (OSC 133), titles, cursor shape.
if [[ -r "$ANSER_GHOSTTY_INTEGRATION/bash/ghostty.bash" ]]; then
    builtin source "$ANSER_GHOSTTY_INTEGRATION/bash/ghostty.bash"
fi
if [[ -z "${bash_preexec_imported:-}${__bp_imported:-}" && -r "$ANSER_GHOSTTY_INTEGRATION/bash/bash-preexec.sh" ]]; then
    builtin source "$ANSER_GHOSTTY_INTEGRATION/bash/bash-preexec.sh"
fi

if [[ -n "$ANSER_FIFO" && -p "$ANSER_FIFO" ]] && exec 249<>"$ANSER_FIFO"; then
    unset ANSER_FIFO ANSER_SHELL_DIR ANSER_GHOSTTY_INTEGRATION
    _anser_path=""
    _anser_alias_sig=""

    _anser_esc() {
        REPLY=${1//\\/\\\\}
        REPLY=${REPLY//$'\t'/\\t}
        REPLY=${REPLY//$'\n'/\\n}
    }
    _anser_send() { builtin printf '%s\n' "$1" >&249 2>/dev/null; }

    _anser_precmd() {
        local ec=$?
        if [[ "$PATH" != "$_anser_path" ]]; then
            _anser_path=$PATH
            _anser_esc "$PATH"
            _anser_send "hello"$'\t'"bash"$'\t'"$$"$'\t'"$REPLY"
        fi
        local f="${TMPDIR:-/tmp}/anser-aliases-$$"
        builtin alias > "$f" 2>/dev/null
        if [[ -s "$f" ]]; then _anser_send "aliases"$'\t'"$f"; fi
        _anser_esc "$PWD"
        _anser_send "prompt"$'\t'"$ec"$'\t'"$REPLY"
    }

    _anser_preexec() {
        [[ $_anser_prompt_mode == hidden ]] && printf '\e[?25h'
        local cmd=$1
        [[ "$cmd" == ' '* ]] && cmd=""
        _anser_esc "$cmd"; local c=$REPLY
        _anser_esc "$PWD"
        _anser_send "preexec"$'\t'"$c"$'\t'"$REPLY"
    }

    # ssh: add Anser's hooks to an interactive remote session (see anser.zsh).
    if [ -r "$ANSER_SSH_BOOTSTRAP" ]; then
        _anser_ssh_boot=$ANSER_SSH_BOOTSTRAP
        ssh() {
            local a host="" i=0
            local -a args=("$@")
            while [ $i -lt ${#args[@]} ]; do
                a=${args[$i]}
                case $a in
                    -[OQW]) command ssh "$@"; return ;;
                    -[BbcDEeFIiJLlmopRSw]) i=$((i + 2)); continue ;;
                    --) i=$((i + 1)); continue ;;
                    -*)
                        if [[ $a =~ ^-[46AaCfGgKkMNnqsTtVvXxYy]+$ && $a == *[NfGnsTV]* ]]; then command ssh "$@"; return; fi
                        i=$((i + 1)); continue ;;
                    *)
                        if [ -z "$host" ]; then host=$a; i=$((i + 1)); else command ssh "$@"; return; fi ;;
                esac
            done
            if [ -z "$host" ] || [ ! -t 0 ] || [ ! -t 1 ]; then command ssh "$@"; return; fi
            command ssh -t "$@" "$(cat "$_anser_ssh_boot")"
        }
    fi

    precmd_functions=(_anser_precmd "${precmd_functions[@]}")
    preexec_functions+=(_anser_preexec)
fi
