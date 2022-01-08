HISTDB_FZF_SOURCE="${(%):-%N}"
HISTDB_FZF_COMMAND=${HISTDB_FZF_COMMAND:-fzf}
HISTDB_FZF_MODES=('session' 'local' 'global' 'everywhere')
HISTDB_FZF_DEFAULT_MODE=${HISTDB_FZF_DEFAULT_MODE:-session}

# Set to "nohidden" to start with preview enabled.
HISTDB_FZF_PREVIEW=${HISTDB_FZF_PREVIEW:-hidden}

if [[ ! -v HISTDB_FZF_MODE_KEYS ]]; then
    declare -A HISTDB_FZF_MODE_KEYS
    HISTDB_FZF_MODE_KEYS=(
        [session]="f1"
        [local]="f2"
        [global]="f3"
        [everywhere]="f4"
    )
fi

# variables for substitution in log
NL="
"
NLT=$(printf "\n\t\t")
# use Figure Space U+2007 as separator
SEP=" "

autoload -U colors && colors

histdb-fzf-log() {
    if [[ ! -z ${HISTDB_FZF_LOGFILE} ]]; then
        if [[ ! -f ${HISTDB_FZF_LOGFILE} ]]; then
            touch ${HISTDB_FZF_LOGFILE}
        fi
        printf "%s %s\n" $(date +'%s.%N') ${*//$NL/$NLT} >> ${HISTDB_FZF_LOGFILE}
    fi
}

histdb-fzf-query() {
    # A wrapper for histdb-query with fzf specific options and query.
    _histdb_init

    local where=""
    local everywhere=0
    case "$1" in
        'session')
            where="${where:+$where and} session in (${HISTDB_SESSION})"
            ;;
        'local')
            where="${where:+$where and} (places.dir like '$(sql_escape $PWD)%')"
            ;;
        'everywhere')
            where="${where:+$where and} places.host=${HISTDB_HOST}"
            ;;
    esac

    local query="
        select
          id,
          CASE exit_status WHEN 0 THEN '' ELSE '${fg[red]}' END || replace(argv, '$NL', ' ') as cmd,
          CASE exit_status WHEN 0 THEN '' ELSE '${reset_color}' END
        from
        (select
          max(history.id) as id, commands.argv as argv, max(start_time) as max_start, exit_status
        from
          history
          left join commands on history.command_id = commands.id
          left join places on history.place_id = places.id
        ${where:+where ${where}}
        group by history.command_id
        order by max_start desc)
        order by max_start desc
    "

    histdb-fzf-log "query for log '${(Q)query}'"

    _histdb_query -separator "$SEP" "$query"
    histdb-fzf-log "query completed"
}

histdb-detail() {
    HISTDB_FILE=$1
    local where="(history.id == '$(sed -e "s/'/''/g" <<< "$2" | tr -d '\000')')"

    local query="
        select
          strftime('%Y-%m-%d %H:%M:%S', max_start, 'unixepoch', 'localtime') as time,
          ifnull(exit_status, 'null') as exit_status,
          ifnull(secs, '?') as secs,
          ifnull(host, 'null') as host,
          ifnull(dir, 'null') as dir,
          session,
          id,
          argv as cmd
        from
          (select
            history.id as id,
            commands.argv as argv,
            max(start_time) as max_start,
            exit_status,
            duration as secs,
            count() as run_count,
            history.session as session,
            places.host as host,
            places.dir as dir
          from
            history
            left join commands on history.command_id = commands.id
            left join places on history.place_id = places.id
          where ${where})
    "

    array_str=("${$(sqlite3 -cmd ".timeout 1000" "${HISTDB_FILE}" -separator " " "$query" )}")
    array=(${(@s: :)array_str})

    histdb-fzf-log "DETAIL: ${array_str}"

    # Add some color
    if [[ "${array[2]}" == "null" ]];then
        # Color exitcode magento if not available.
        array[2]=$(echo "\033[35m${array[2]}\033[0m")
    elif [[ ! ${array[2]} ]];then
        # Color exitcode red if not 0.
        array[2]=$(echo "\033[31m${array[2]}\033[0m")
    fi
    if [[ "${array[3]}" == "?" ]];then
        # Color duration magento if not available.
        array[3]=$(echo "\033[35m${array[3]}\033[0m")
    elif [[ "${array[3]}" -gt 300 ]];then
        # Duration red if > 5 min.
        array[3]=$(echo "\033[31m${array[3]}\033[0m")
    elif [[ "${array[3]}" -gt 60 ]];then
        # Duration yellow if > 1 min
        array[3]=$(echo "\033[33m${array[3]}\033[0m")
    fi

    printf "\033[1mLast run\033[0m\n\n"
    printf "Time:       %s\n" ${array[1]}
    printf "Status:     %s\n" ${array[2]}
    printf "Duration:   %ss\n" ${array[3]}
    printf "Host:       %s\n" ${array[4]}
    printf "Directory:  %s\n" ${array[5]}
    printf "Session id: %s\n" ${array[6]}
    printf "Command id: %s\n" ${array[7]}
    echo "\n\n${array[8,-1]}"
}

histdb-next-mode() {
    local current_mode=$1
    local current_idx=${HISTDB_FZF_MODES[(Ie)$current_mode]}
    local next_idx=$((($current_idx % $#HISTDB_FZF_MODES) + 1))
    echo $HISTDB_FZF_MODES[$next_idx]
}

histdb-get-header() {
    case "$1" in
        'session') echo "Session local history" ;;
        'local') echo "Directory local history ${fg[blue]}$(pwd)${reset_color}" ;;
        'global') echo "Global history ${fg[blue]}$(hostname)${reset_color}" ;;
        'everywhere') echo "Everywhere" ;;
    esac

    for mode in ${HISTDB_FZF_MODES[*]}; do
        if [[ "$mode" == "$1" ]]; then
            echo -n "${fg[blue]}"
        else
            echo -n "${bold_color}"
        fi
        local key=${HISTDB_FZF_MODE_KEYS[$mode]}
        echo -n "$key: $mode${reset_color} "
    done
    echo -n "\n―――――――――――――――――――――――――"
}

histdb-get-command() {
    histdb_file=$1
    history_id=$2

    local query="
        select
          argv as cmd
        from
          history
          left join commands on history.command_id = commands.id
        where
          history.id='${history_id}'
    "

    printf "%s" "$(sqlite3 -cmd ".timeout 1000" "${histdb_file}" "$query")"
}

histdb-delete-command() {
    history_id=$1
    histdb-fzf-log "deleting command with history id ${history_id}"

    _histdb_query "
        delete from history
        where history.command_id = (
          select command_id from history where id = '${history_id}'
        )
    "
    _histdb_query "delete from commands where commands.id not in (select distinct history.command_id from history)"
    _histdb_query "delete from places where places.id not in (select distinct history.place_id from history)"
}

histdb-fzf-widget() {
    query=${BUFFER}
    local origquery=${BUFFER}

    histdb-fzf-log "================== START ==================="
    histdb-fzf-log "original buffers: -:$BUFFER l:$LBUFFER r:$RBUFFER"
    histdb-fzf-log "original query $query"

    local mode=$HISTDB_FZF_DEFAULT_MODE

    histdb-fzf-log "Start mode $mode"
    local exitkey="any"
    setopt localoptions noglobsubst noposixbuiltins pipefail 2> /dev/null

    local history_id
    local selected

    # Here it is getting a bit tricky, fzf does not support dynamic updating so we
    # have to close and reopen fzf when changing the focus (session, dir, global)
    # so we check the exitkey and decide what to do.
    while [[ "$exitkey" != "" && "$exitkey" != "esc" ]]; do
        histdb-fzf-log "------------------- TURN -------------------"
        histdb-fzf-log "Exitkey $exitkey"

        local next_mode=${(k)HISTDB_FZF_MODE_KEYS[(Re)$exitkey]}
        if [[ -n "$next_mode" ]]; then
            mode=$next_mode
            histdb-fzf-log "mode changed to $mode"
        elif [[ "$exitkey" == "ctrl-r" ]]; then
            mode=$(histdb-next-mode "$mode")
            histdb-fzf-log "mode changed to $mode"
        elif [[ "$exitkey" == "ctrl-alt-d" ]]; then
            histdb-delete-command "$history_id"
        fi

        # Log the FZF arguments.
        OPTIONS="$FZF_DEFAULT_OPTS
            --ansi
            --header='$(histdb-get-header "$mode")' --delimiter='$SEP'
            -n1.. --with-nth=2..
            --tiebreak=index
            --expect='esc,ctrl-r,ctrl-alt-d,f1,f2,f3,f4'
            --bind 'ctrl-/:toggle-preview'
            --print-query
            --preview='source ${HISTDB_FZF_SOURCE}; histdb-detail ${HISTDB_FILE} {1}'
            --preview-window=right:50%:${HISTDB_FZF_PREVIEW},wrap
            --no-hscroll
            --query='${query}' +m"

        histdb-fzf-log "$OPTIONS"

        result=( "${(@f)$( histdb-fzf-query ${mode} |
            FZF_DEFAULT_OPTS="${OPTIONS}" ${HISTDB_FZF_COMMAND})}" )

        # Here we got a result from fzf, containing all the information, now we
        # must handle it, split it and use the correct elements.
        histdb-fzf-log "returncode was $?"
        query=$result[1]
        exitkey=${result[2]}
        selected="${${(@s: :)result[3]}#* }"
        history_id="${${(@s: :)result[3]}[1]}"
        histdb-fzf-log "Query was      ${query:-<nothing>}"
        histdb-fzf-log "Exitkey was    ${exitkey:-<NONE>}"
        histdb-fzf-log "History ID was ${history_id}"
        histdb-fzf-log "Selected was   ${selected}"
    done

    if [[ "$exitkey" == "esc" ]]; then
        BUFFER=$origquery
    else
        # We already have the selected command, but newlines are replaced by
        # spaces in that. Get the actual command from the sqlite database.
        selected=$(histdb-get-command "${HISTDB_FILE}" "$history_id")
        histdb-fzf-log "selected = $selected"
        BUFFER=$selected
    fi
    CURSOR=$#BUFFER
    zle redisplay
    histdb-fzf-log "new buffers: -:$BUFFER l:$LBUFFER r:$RBUFFER"
    histdb-fzf-log "=================== DONE ==================="
}

zle     -N   histdb-fzf-widget
bindkey '^R' histdb-fzf-widget
