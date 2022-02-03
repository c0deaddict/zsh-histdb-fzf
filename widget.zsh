HISTDB_FZF_COMMAND=${HISTDB_FZF_COMMAND:-fzf}
HISTDB_FZF_DEFAULT_MODE=${HISTDB_FZF_DEFAULT_MODE:-global}

# Set to "nohidden" to start with preview enabled.
HISTDB_FZF_PREVIEW=${HISTDB_FZF_PREVIEW:-hidden}

# use Figure Space U+2007 as separator
sep=" "

autoload -U colors && colors

histdb-fzf-widget() {
    local query=${BUFFER}

    local modes=("session" "local" "global" "everywhere")

    declare -A mode_keys
    mode_keys=(
        [session]="f1"
        [local]="f2"
        [global]="f3"
        [everywhere]="f4"
    )

    local mode=$HISTDB_FZF_DEFAULT_MODE
    local script="${0:a:h}/histdb-fzf.zsh"

    setopt localoptions noglobsubst noposixbuiltins pipefail 2> /dev/null

    local options=(
        --ansi
        --delimiter "'$sep'"
        -n1..
        --with-nth=2..
        --tiebreak=index
        --bind 'ctrl-/:toggle-preview'
        --bind "'ctrl-alt-d:execute(${script} delete {1})'"
        "--preview='${script} detail {1}'"
        "--preview-window=right:50%:${HISTDB_FZF_PREVIEW},wrap"
        --no-hscroll
        "--query='${query}'"
        --prompt "'${mode}> '"
        +m
    )

    for m in ${modes[*]}; do
        local key="${mode_keys[$m]}"
        local command="${script} search $m"
        options+=("--bind" "'${key}:change-prompt(${m}> )+reload(${command})'")
    done

    local result=( "$(
        export PWD HISTDB_FILE HISTDB_HOST HISTDB_SESSION;
        ${script} search $mode |
        FZF_DEFAULT_OPTS="$FZF_DEFAULT_OPTS ${options[@]}" ${HISTDB_FZF_COMMAND}
    )" )

    if [ -n "${result[1]}" ]; then
        local history_id=${${(@s: :)result[1]}[1]}

        # The selected command could be extracted from the result, but newlines
        # are replaced by spaces in that. Get the actual command from the sqlite
        # database.
        BUFFER=$( HISTDB_FILE="${HISTDB_FILE}" $script get "$history_id" )
    fi

    CURSOR=$#BUFFER
    zle redisplay
}

zle -N histdb-fzf-widget
bindkey '^R' histdb-fzf-widget
