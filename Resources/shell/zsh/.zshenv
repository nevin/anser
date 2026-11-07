# Anser: zsh starts here because Anser points ZDOTDIR at this folder.
# Restore the user's real ZDOTDIR, run their .zshenv, then load the hooks.
# Everything after this (.zprofile, .zshrc, .zlogin) loads from the user's own ZDOTDIR.

# Nothing but macOS's "Last login: …" line has been printed yet; clear it.
if [[ -n "$ANSER_HIDE_LOGIN" ]]; then
    [[ -o interactive ]] && 'builtin' 'print' -n $'\e[H\e[2J'
    'builtin' 'unset' 'ANSER_HIDE_LOGIN'
fi

if [[ -n "${ANSER_ORIG_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$ANSER_ORIG_ZDOTDIR"
    'builtin' 'unset' 'ANSER_ORIG_ZDOTDIR'
else
    'builtin' 'unset' 'ZDOTDIR'
fi

{
    'builtin' 'typeset' _anser_file=${ZDOTDIR-$HOME}"/.zshenv"
    [[ ! -r "$_anser_file" ]] || 'builtin' 'source' '--' "$_anser_file"
} always {
    if [[ -o 'interactive' ]]; then
        # Ghostty's own integration: prompt marks (OSC 133), titles, cursor shape.
        'builtin' 'typeset' _anser_file="$ANSER_GHOSTTY_INTEGRATION/zsh/ghostty-integration"
        if [[ -r "$_anser_file" ]]; then
            'builtin' 'autoload' '-Uz' '--' "$_anser_file"
            ghostty-integration
            'builtin' 'unfunction' 'ghostty-integration'
        fi
        [[ ! -r "$ANSER_SHELL_DIR/anser.zsh" ]] || 'builtin' 'source' '--' "$ANSER_SHELL_DIR/anser.zsh"
    fi
    'builtin' 'unset' '_anser_file'
}
