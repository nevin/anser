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

function __anser_postexec --on-event fish_postexec
    set -g __anser_ec $status
end

function __anser_prompt --on-event fish_prompt
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
