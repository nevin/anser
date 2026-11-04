# Anser hooks for a remote bash (sent over ssh for this session only).
# Load the user's startup files first, like a login shell.
for _ar_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -r "$_ar_rc" ]; then . "$_ar_rc"; break; fi
done
if [ -r "$HOME/.bashrc" ] && ! grep -qs bashrc "$_ar_rc" 2>/dev/null; then . "$HOME/.bashrc"; fi
unset _ar_rc
[ -n "$ANSER_REMOTE_DIR" ] && trap 'command rm -rf -- "$ANSER_REMOTE_DIR"' EXIT

_ar_mark=$(printf '\356\200\200'); _ar_sep=$(printf '\356\200\201')
_ar_emit() { printf '\033]2;%sanser:%s\007' "$_ar_mark" "$1"; }
_ar_ready=0
_ar_ec=0
# PROMPT_COMMAND = _ar_start; (user's commands); _ar_end - so $? is the
# command's status and the user's own prompt commands aren't mistaken for commands.
_ar_start() { _ar_ec=$?; _ar_ready=0; printf '\033]133;D;%s\007' "$_ar_ec"; }
_ar_end() {
    _ar_emit "prompt${_ar_sep}${_ar_ec}${_ar_sep}${HOSTNAME}${_ar_sep}${PWD}"
    case "$PS1" in *'133;A'*) ;; *) PS1='\[\033]133;A\007\]'"$PS1"'\[\033]133;B\007\]' ;; esac
    _ar_ready=1
}
_ar_preexec() {
    [ "$_ar_ready" = 1 ] || return 0
    [ -n "$COMP_LINE" ] && return 0
    _ar_ready=0
    local c
    c=$(HISTTIMEFORMAT= builtin history 1 | sed 's/^ *[0-9]* *//')
    case "$c" in ' '*) c="" ;; esac
    _ar_emit "preexec${_ar_sep}${c}${_ar_sep}${PWD}"
    printf '\033]133;C\007'
}
trap '_ar_preexec' DEBUG
PROMPT_COMMAND="_ar_start${PROMPT_COMMAND:+;$PROMPT_COMMAND};_ar_end"
for _ar_km in emacs vi-insert vi-command; do bind -m "$_ar_km" '"\e[9999~": kill-whole-line' 2>/dev/null; done
unset _ar_km
_ar_emit "hello${_ar_sep}bash${_ar_sep}${HOSTNAME}"
