# Anser hooks for a remote zsh (sent over ssh for this session only).
# Events travel in-band as terminal title updates that Anser intercepts:
#   ESC ] 2 ; U+E000 "anser:" token U+E001 fields-separated-by-U+E001 BEL
# The token is a per-session secret, so program output can't fake events.
# plus OSC 133 prompt marks for command blocks and output copying.
[[ -o interactive ]] || return 0
typeset -g _ar_tok=${ANSER_REMOTE_TOKEN:-none}; unset ANSER_REMOTE_TOKEN
typeset -g _ar_mark=$'' _ar_sep=$''
[[ -n "$ANSER_REMOTE_DIR" ]] && trap 'command rm -rf -- "$ANSER_REMOTE_DIR"' EXIT

_ar_emit() { builtin print -rn -- $'\e]2;'"${_ar_mark}anser:${_ar_tok}${_ar_sep}$1"$'\a' }

_ar_precmd() {
    local ec=$?
    builtin print -rn -- $'\e]133;D;'"$ec"$'\a'
    _ar_emit "prompt${_ar_sep}${ec}${_ar_sep}${HOST}${_ar_sep}${PWD}"
}
_ar_preexec() {
    local c=${1//$'\n'/ }
    [[ "$c" == ' '* ]] && c=""
    _ar_emit "preexec${_ar_sep}${c}${_ar_sep}${PWD}"
    builtin print -rn -- $'\e]133;C\a'
}
# Prompt marks, added after any theme has built the prompt.
_ar_marks() {
    [[ "$PS1" == *$'\e]133;A'* ]] || PS1=$'%{\e]133;A\a%}'"$PS1"$'%{\e]133;B\a%}'
}
_ar_clear_line() { BUFFER=""; CURSOR=0 }
zle -N _ar_clear_line
for _ar_km in emacs viins vicmd; do builtin bindkey -M $_ar_km $'\e[9999~' _ar_clear_line 2>/dev/null; done
unset _ar_km
builtin autoload -Uz add-zsh-hook
precmd_functions=(_ar_precmd ${precmd_functions:#_ar_precmd})
add-zsh-hook preexec _ar_preexec
precmd_functions+=(_ar_marks)
_ar_emit "hello${_ar_sep}zsh${_ar_sep}${HOST}"
