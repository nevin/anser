# Anser shell integration for fish. Loaded with: fish -l -C "source …/anser.fish"
# Sends prompt/command events to Anser through a private FIFO.

status is-interactive; or exit 0
set -q ANSER_FIFO; and test -p "$ANSER_FIFO"; or exit 0
set -g __anser_fifo $ANSER_FIFO
set -e ANSER_FIFO

# Ghostty's integration: prompt marks (OSC 133), titles, cursor shape.
if set -q ANSER_GHOSTTY_INTEGRATION
    set -l gi "$ANSER_GHOSTTY_INTEGRATION/fish/vendor_conf.d/ghostty-shell-integration.fish"
    test -r "$gi"; and source "$gi"
end
set -e ANSER_SHELL_DIR ANSER_GHOSTTY_INTEGRATION ANSER_PROMPT_MODE

# Escape backslash, tab and newline the way Anser's parser expects.
function __anser_esc
    string replace -a -- '\\' '\\\\' $argv[1] | string replace -a -- \t '\\t' | string join '\\n'
end

function __anser_send
    printf '%s\n' $argv[1] >> $__anser_fifo 2>/dev/null
end

set -g __anser_ec 0
set -g __anser_path ""
set -g __anser_ctx ""

function __anser_postexec --on-event fish_postexec
    set -g __anser_ec $status
end

function __anser_prompt --on-event fish_prompt
    set -l aws $AWS_PROFILE
    test -z "$aws"; and set aws $AWS_VAULT
    set -l ctx "$aws"\t"$KUBECONFIG"\t"$DOCKER_CONTEXT"\t"$CLOUDSDK_CORE_PROJECT"\t"$VIRTUAL_ENV"
    if test "$ctx" != "$__anser_ctx"
        set -g __anser_ctx $ctx
        __anser_send "ctx"\t$ctx
    end
    set -l p (string join : $PATH)
    if test "$p" != "$__anser_path"
        set -g __anser_path $p
        __anser_send "hello"\t"fish"\t$fish_pid\t(__anser_esc $p)
        __anser_send "functions"\t(functions -n | string match -v -r '^_' | string join ' ')
    end
    __anser_send "prompt"\t$__anser_ec\t(__anser_esc $PWD)
end

function __anser_preexec --on-event fish_preexec
    set -l cmd $argv[1]
    string match -q -- ' *' $cmd; and set cmd ""
    __anser_send "preexec"\t(__anser_esc $cmd)\t(__anser_esc $PWD)
end

# Anser sends ESC [9999~ to clear text typed straight into the shell.
bind \e\[9999~ 'commandline -r ""'
bind -M insert \e\[9999~ 'commandline -r ""' 2>/dev/null

# Anser sends ESC [9990~ to load a project's environment it wrote to a file.
set -g __anser_load_dir "$ANSER_LOAD_DIR"
set -e ANSER_LOAD_DIR
function __anser_load
    set -l f "$__anser_load_dir/load-$fish_pid.sh"
    test -n "$__anser_load_dir" -a -f "$f" -a -O "$f"; or return 0
    source $f
    command rm -f -- $f
    set -g __anser_ctx ""
    commandline -f repaint
end
bind \e\[9990~ __anser_load
bind -M insert \e\[9990~ __anser_load 2>/dev/null
test -n "$__anser_load_dir"; and __anser_send "caps"\tload
# Aliases you made in Anser (Tools → Aliases…).
test -r "$ANSER_ALIASES"; and source "$ANSER_ALIASES"
set -e ANSER_ALIASES
