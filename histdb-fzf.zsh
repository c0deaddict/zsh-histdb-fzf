#!/usr/bin/env zsh

# use Figure Space U+2007 as separator
readonly sep=" "

sql_escape() {
    print -r -- ${${@//\'/\'\'}//$'\x00'}
}

histdb-query() {
    local query=$1
    sqlite3 -batch -noheader -cmd ".timeout 1000" -separator "$sep" "${HISTDB_FILE}" "$query"
}

histdb-search() {
    local where=""

    case "$1" in
        'session')
            where="${where:+$where and} session=${HISTDB_SESSION}"
            ;;
        'local')
            where="${where:+$where and} (places.dir like '$(sql_escape "${PWD}")%')"
            ;;
        'everywhere')
            where="${where:+$where and} places.host=${HISTDB_HOST}"
            ;;
    esac

    local query="
        select
          id,
          CASE exit_status WHEN 0 THEN '' ELSE '${fg[red]}' END
          || replace(argv, char(10), ' ') ||
          CASE exit_status WHEN 0 THEN '' ELSE '${reset_color}' END
          as cmd
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

    histdb-query "$query"
}

histdb-detail() {
    local history_id=$1
    local where="(history.id == $(sql_escape "$history_id"))"

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

    detail_str=( "${$(histdb-query "$query")}" )
    detail=(${(@s: :)detail_str})

    # Add some color
    if [[ "${detail[2]}" == "null" ]];then
        # Color exitcode magento if not available.
        detail[2]=$(echo "\033[35m${detail[2]}\033[0m")
    elif [[ ! ${detail[2]} ]];then
        # Color exitcode red if not 0.
        detail[2]=$(echo "\033[31m${detail[2]}\033[0m")
    fi
    if [[ "${detail[3]}" == "?" ]];then
        # Color duration magento if not available.
        detail[3]=$(echo "\033[35m${detail[3]}\033[0m")
    elif [[ "${detail[3]}" -gt 300 ]];then
        # Duration red if > 5 min.
        detail[3]=$(echo "\033[31m${detail[3]}\033[0m")
    elif [[ "${detail[3]}" -gt 60 ]];then
        # Duration yellow if > 1 min
        detail[3]=$(echo "\033[33m${detail[3]}\033[0m")
    fi

    printf "\033[1mLast run\033[0m\n\n"
    printf "Time:       %s\n" ${detail[1]}
    printf "Status:     %s\n" ${detail[2]}
    printf "Duration:   %ss\n" ${detail[3]}
    printf "Host:       %s\n" ${detail[4]}
    printf "Directory:  %s\n" ${detail[5]}
    printf "Session id: %s\n" ${detail[6]}
    printf "Command id: %s\n" ${detail[7]}
    echo "\n\n${detail[8,-1]}"
}

histdb-get-command() {
    local history_id=$1

    local query="
        select
          argv as cmd
        from
          history
          left join commands on history.command_id = commands.id
        where
          history.id='${history_id}'
    "

    printf "%s" "$(histdb-query "$query")"
}

histdb-delete-command() {
    local history_id=$1

    histdb-query "
        delete from history
        where history.command_id = (
          select command_id from history where id = '${history_id}'
        )
    "
    histdb-query "
        delete from commands
        where commands.id not in (
          select distinct history.command_id from history
        )
    "
    histdb-query "
        delete from places
        where places.id not in (
          select distinct history.place_id from history
        )
    "
}

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 COMMAND"
    exit 1
fi

readonly command="$1"
shift

case "$command" in
    search)
        histdb-search "$@"
        ;;
    detail)
        histdb-detail "$@"
        ;;
    get)
        histdb-get-command "$@"
        ;;
    delete)
        histdb-delete-command "$@"
        ;;
    *)
        echo "unknown command $command"
        exit 1
        ;;
esac
