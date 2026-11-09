# Anser shell integration for zsh.
# Tells the app when a prompt appears and when a command starts, through a
# private FIFO. Uses only builtins, so it adds no measurable delay.

[[ -n "$ANSER_FIFO" && -p "$ANSER_FIFO" ]] || return 0
typeset -gi _anser_fd
# No "2>/dev/null" on this line: with exec, every redirection becomes permanent,
# so it would silently hide all error output in the shell for the whole session.
exec {_anser_fd}<>"$ANSER_FIFO" || return 0
# `imgcat FILE` shows pictures, unless you have an imgcat of your own.
if [[ -n "$ANSER_HELPER" && -x "$ANSER_HELPER" ]] && (( ! $+commands[imgcat] )); then
    typeset -g _anser_helper=$ANSER_HELPER
    imgcat() { "$_anser_helper" imgcat "$@" }
fi
# Don't leak into child programs or nested shells.
builtin unset ANSER_FIFO ANSER_SHELL_DIR ANSER_GHOSTTY_INTEGRATION ANSER_HELPER

typeset -g _anser_alias_sig="" _anser_func_sig="" _anser_path="" _anser_ctx=""

_anser_esc() {
    REPLY=${1//\\/\\\\}
    REPLY=${REPLY//$'\t'/\\t}
    REPLY=${REPLY//$'\n'/\\n}
}

_anser_send() { builtin print -rn -u $_anser_fd -- "$1"$'\n' 2>/dev/null }

_anser_sync() {
    # Cloud context variables, for the status row's context chip.
    local ctx="${AWS_PROFILE:-$AWS_VAULT}"$'\t'"$KUBECONFIG"$'\t'"$DOCKER_CONTEXT"$'\t'"$CLOUDSDK_CORE_PROJECT"$'\t'"$VIRTUAL_ENV"
    if [[ "$ctx" != "$_anser_ctx" ]]; then
        _anser_ctx=$ctx
        _anser_send "ctx"$'\t'"$ctx"
    fi
    if [[ "$PATH" != "$_anser_path" ]]; then
        _anser_path=$PATH
        _anser_esc "$PATH"
        _anser_send "hello"$'\t'"zsh"$'\t'"$$"$'\t'"$REPLY"
    fi
    local sig="${(j: :)${(ko)aliases}}"
    if [[ "$sig" != "$_anser_alias_sig" ]]; then
        _anser_alias_sig=$sig
        local f="${TMPDIR:-/tmp}/anser-aliases-$$"
        builtin alias >| "$f" 2>/dev/null && _anser_send "aliases"$'\t'"$f"
    fi
    if [[ "${#functions}" != "$_anser_func_sig" ]]; then
        _anser_func_sig=${#functions}
        # Skip internal helpers (_git, _ghostty_…): thousands of them, never shown.
        _anser_send "functions"$'\t'"${(j: :)${(k)functions:#_*}}"
    fi
}

# Anser sends ESC [9990~ to load a project's environment (.env values, a
# virtualenv) without typing a command: it writes the file, this sources it.
typeset -g _anser_load_dir=$ANSER_LOAD_DIR
builtin unset ANSER_LOAD_DIR
_anser_load() {
    local f="$_anser_load_dir/load-$$.sh"
    [[ -n $_anser_load_dir && -f $f && -O $f ]] || return 0
    builtin source "$f"
    command rm -f -- "$f"
    _anser_ctx=""
    _anser_sync
    zle reset-prompt
}
[[ -n $_anser_load_dir ]] && _anser_send "caps"$'\t'"load"
# Aliases you made in Anser (Tools → Aliases…).
[[ -r "$ANSER_ALIASES" ]] && builtin source "$ANSER_ALIASES"
builtin unset ANSER_ALIASES

# Anser sends ESC [9999~ to clear text typed straight into the shell before
# it runs a command from its editor. Works in emacs and vi keymaps.
_anser_clear_line() { BUFFER=""; CURSOR=0 }
typeset -gi _anser_bound=0

# How the shell's own prompt looks while Anser's editor is in charge:
#   hidden  – no waiting prompt (the editor is the only input); each command
#             is kept in scrollback as "❯ command"
#   compact – a short ❯ prompt
#   full    – the user's prompt, untouched
typeset -g _anser_default_mode=${ANSER_PROMPT_MODE:-full}
typeset -g _anser_prompt_mode=$_anser_default_mode
typeset -g _anser_user_ps1="" _anser_user_rps1="" _anser_set_ps1="" _anser_transient_ps1=""
# After each command: "── user@mac · 14:02:11 ─────" (line), the same in ┄ (dotted), or nothing.
typeset -g _anser_separator=${ANSER_SEPARATOR:-none} _anser_sep_at=""

# Runs after Ghostty's hook has closed the command's output, so the line is
# neither output (Copy Output skips it) nor prompt.
_anser_sep_print() {
    [[ -n $_anser_sep_at && $_anser_separator != none ]] || { _anser_sep_at=""; return 0 }
    local ch='─'; [[ $_anser_separator == dotted ]] && ch='┄'
    local label=" ${(%):-%n@%m} · $_anser_sep_at "
    local fill=$(( ${COLUMNS:-80} - 3 - ${#label} - 1 ))
    (( fill < 2 )) && fill=2
    builtin print -rn -- $'\e[2m'"${(pl:2::$ch:)}$label${(pl:$fill::$ch:)}"$'\e[0m\n'
    _anser_sep_at=""
}
builtin unset ANSER_PROMPT_MODE ANSER_COMPACT_PROMPT ANSER_SEPARATOR

# Runs after prompt themes and just before Ghostty's hook, which adds the
# prompt marks that "copy last output" relies on.
_anser_prompt() {
    if [[ "$PS1" != "$_anser_set_ps1" && "$PS1" != "$_anser_transient_ps1" ]]; then
        _anser_user_ps1=$PS1
        _anser_user_rps1=$RPS1
    fi
    case $_anser_prompt_mode in
        hidden)  PS1=$'%{\e[?25l%}'; RPS1='' ;;
        compact) PS1='%(?.%F{green}.%F{red})❯%f '; RPS1='' ;;
        *) return 0 ;;
    esac
    _anser_set_ps1=$PS1
}

# When a command is accepted, turn the hidden prompt into "❯ command".
_anser_line_finish() {
    [[ $_anser_prompt_mode == hidden ]] || return 0
    PS1=$'%{\e]133;A;cl=line\a%}%F{8}❯%f %{\e]133;B\a%}'
    _anser_transient_ps1=$PS1
    zle reset-prompt
}

# Anser sends these when its editor is turned off / on.
_anser_mode_full() {
    _anser_prompt_mode=full
    PS1=$_anser_user_ps1; RPS1=$_anser_user_rps1; _anser_set_ps1=""
    builtin print -n $'\e[?25h'
    zle reset-prompt
}
_anser_mode_default() {
    _anser_prompt_mode=$_anser_default_mode
    _anser_prompt
    zle reset-prompt
}

_anser_precmd() {
    local ec=$?
    # Stay first so we always see the real exit status.
    if [[ "${precmd_functions[1]}" != "_anser_precmd" ]]; then
        precmd_functions=(_anser_precmd ${precmd_functions:#_anser_precmd})
    fi
    # Anser's self-test: keep its commands out of the user's real shell history
    # (/etc/zshrc sets HISTFILE after our hooks load, so set it here).
    [[ -n "${ANSER_PRIVATE_HISTFILE:-}" && "$HISTFILE" != "$ANSER_PRIVATE_HISTFILE" ]] && HISTFILE=$ANSER_PRIVATE_HISTFILE
    if (( ! _anser_bound )); then
        _anser_bound=1
        zle -N _anser_clear_line
        zle -N _anser_mode_full
        zle -N _anser_mode_default
        zle -N _anser_load
        local km
        for km in emacs viins vicmd; do
            builtin bindkey -M $km $'\e[9999~' _anser_clear_line 2>/dev/null
            builtin bindkey -M $km $'\e[9998~' _anser_mode_full 2>/dev/null
            builtin bindkey -M $km $'\e[9997~' _anser_mode_default 2>/dev/null
            builtin bindkey -M $km $'\e[9990~' _anser_load 2>/dev/null
        done
        builtin autoload -Uz add-zle-hook-widget && add-zle-hook-widget line-finish _anser_line_finish
    fi
    # Keep _anser_prompt after prompt themes (p10k, starship…) and before Ghostty's hook.
    # The separator goes right after Ghostty's hook (once the command's output is closed).
    local -a rest=(${${precmd_functions:#_anser_prompt}:#_anser_sep_print})
    local i=${rest[(I)_ghostty_precmd]}
    if (( i )); then
        precmd_functions=(${rest[1,i-1]} _anser_prompt _ghostty_precmd _anser_sep_print ${rest[i+1,-1]})
    else
        precmd_functions=($rest _anser_prompt _anser_sep_print)
    fi
    # Apply now too: on the very first prompt the reorder above only takes effect next time.
    [[ ${precmd_functions[(I)_anser_prompt]} -gt 0 && "${_anser_first_done:-}" == "" ]] && { _anser_first_done=1; _anser_prompt; }
    _anser_sync
    _anser_esc "$PWD"
    _anser_send "prompt"$'\t'"$ec"$'\t'"$REPLY"
}

_anser_preexec() {
    _anser_sep_at=${(%):-%D{%H:%M:%S}}
    # Show the terminal cursor again for the running program.
    [[ $_anser_prompt_mode == hidden ]] && builtin print -n $'\e[?25h'
    local cmd=$1
    # Commands starting with a space stay out of history (like HIST_IGNORE_SPACE).
    [[ "$cmd" == ' '* ]] && cmd=""
    _anser_esc "$cmd"; local c=$REPLY
    _anser_esc "$PWD"
    _anser_send "preexec"$'\t'"$c"$'\t'"$REPLY"
}

# ssh: for an interactive login to one host, add Anser's hooks to that remote
# session (temporary, deleted on logout) so the editor and history work there.
if [[ -r "$ANSER_SSH_BOOTSTRAP" ]]; then
    typeset -g _anser_ssh_boot=$ANSER_SSH_BOOTSTRAP
    # The session's secret, kept out of the environment of programs you run.
    typeset -g _anser_tok=$ANSER_REMOTE_TOKEN
    unset ANSER_REMOTE_TOKEN
    _anser_ssh_command() { local b="$(<$_anser_ssh_boot)"; builtin print -r -- "${b//@@TOKEN@@/$_anser_tok}" }
    ssh() {
        local a host="" i=1 n=$#
        while (( i <= n )); do
            a=${@[i]}
            case $a in
                -[OQW]) command ssh "$@"; return ;;
                -[BbcDEeFIiJLlmopRSw]) (( i += 2 )); continue ;;
                --) (( i++ )); continue ;;
                -*)
                    # A cluster of flags: hand over untouched if any is non-interactive.
                    if [[ $a =~ '^-[46AaCfGgKkMNnqsTtVvXxYy]+$' && $a == *[NfGnsTV]* ]]; then command ssh "$@"; return; fi
                    (( i++ )); continue ;;
                *)
                    if [[ -z $host ]]; then host=$a; (( i++ )); else command ssh "$@"; return; fi ;;
            esac
        done
        if [[ -z $host || ! -t 0 || ! -t 1 ]]; then command ssh "$@"; return; fi
        command ssh -t "$@" "$(_anser_ssh_command)"
    }
fi

builtin autoload -Uz add-zsh-hook
precmd_functions=(_anser_precmd ${precmd_functions:#_anser_precmd})
add-zsh-hook preexec _anser_preexec
