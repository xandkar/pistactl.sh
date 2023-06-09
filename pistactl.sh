#! /bin/bash

set -e

DEFAULT_DIR=~/.pistactl.sh
DEFAULT_SESSION=pistactl.sh
DEFAULT_PISTA_OPTS="-l 3 -f ' (' -s ')    (' -r ') ' -x"

SLOTS_CONF_FILE_NAME=slots.conf

counter_next() {
    local -r file="$_counter_file"

    awk '{n = $1} END {print n + 1}' "$file" | sponge "$file"
    cat "$file"
}

from_file_or_default() {
    local -r file="$1"
    local -r default="$2"
    local value

    if [ -s "$file" ]
    then
        value=$(< "$file")
    else
        value="$default"
    fi
    echo "$value"
}

tmux_new_win() {
    local -r cmd="$1"

    local -r window=$(counter_next "$_counter_file")
    local -r pane=0

    if [[ "$DEBUG" ]]; then
        echo "[debug] window:\"$window\" cmd:\"$cmd\"" >&2
    fi
    $_tmux new-window -t "$_session"
    $_tmux send-keys  -t "$_session":"$window"."$pane" "$cmd" ENTER
}

start_slot() {
    local -r len="$1"
    local -r ttl="$2"
    local -r cmd="$3"
    local -r arg="$4"

    local -r slot_id=$((++_slot_count))
    local -r dir_slot="$_dir"/slots/"$slot_id"
    local -r out_pipe="$dir_slot"/out

    # We're going to cd into $dir_slot just in case the $cmd will end up
    # writing something to its current working directory - so that it is easier
    # to find and/or debug.
    mkdir -p "$dir_slot"
    rm -f "$out_pipe"
    mkfifo "$out_pipe"
    tmux_new_win "cd $dir_slot && $cmd $arg > $out_pipe; notify-send -u critical 'pista slot exited!' \"$cmd\n\$?\""
    printf '%s %d %d\n' "$out_pipe" "$len" "$ttl"
}

start_slots() {
    local -r slots_conf_file_path="$_dir"/"$SLOTS_CONF_FILE_NAME"
    local len ttl cmd arg
    _slot_count=0

    awk -F \# '{print $1}' "$slots_conf_file_path" \
    | awk '
        # Blank - ignore:
        NF == 0 {
            next
        }

        # Correct - use:
        NF >= 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^-?[0-9]+$/ {
            print
            next
        }

        # Incorrect - warn and ignore:
        {
            printf \
                "[warning] slot configuration line %d is not in the expected format of:" \
                "\"LEN TTL COMMAND\". Line: \"%s\"\n", NR, $0 \
                > "/dev/stderr"
        }
    ' \
    | while read -r len ttl cmd arg; do
        start_slot "$len" "$ttl" "$cmd" "$arg"
    done
}

remove_slot_pipes() {
    find "$_dir_slots" -type p -delete
}

_start() {
    local -r opts=$(from_file_or_default "$_dir"/options "$DEFAULT_PISTA_OPTS")

    mkdir -p "$_dir_slots"

    $_tmux new-session -d -s "$_session"

    # Have to increment window ids in a file, because an increment operation
    # would be executed local to each subprocess if we did something like:
    #     $(start_slot $((win++)) foo)
    _counter_file=$(mktemp)
    tmux_new_win \
        "pista $opts $(start_slots | xargs); notify-send -u critical 'pista exited!' \"\$?\""
    rm "$_counter_file"
}

_stop() {
    $_tmux kill-session -t "$_session"
    remove_slot_pipes
}

_restart() {
    _stop || true
    _start
}

_attach() {
    $_tmux attach -t "$_session"
}

main() {
    local -r program="$0"
    local -r arg_cmd="$1"
    local -r arg_dir="$2"

    local cmd

    case "$arg_cmd" in
        'start'   ) cmd=_start;;
        'stop'    ) cmd=_stop;;
        'restart' ) cmd=_restart;;
        'attach'  ) cmd=_attach;;
        'help')
            echo "$program (start|stop|restart|attach|help) [DIRECTORY]" >&2
            exit 1;;
        '')
            echo "[error] No command given." >&2
            exit 1;;
        *)
            echo "[error] Unknown command: \"$arg_cmd\". Known: start|stop|restart|attach" >&2
            exit 1;;
    esac
    case "$arg_dir" in
        '')
            _dir="$DEFAULT_DIR";;
        *)
            _dir="$arg_dir";;
    esac

    local -r session_name_file="$_dir"/session
    if [ -s "$session_name_file" ]
    then
        _session=$(< "$session_name_file")
    else
        _session="$DEFAULT_SESSION"
    fi

    _dir_slots="$_dir"/slots
    _tmux="tmux -L $_session"

    mkdir -p "$_dir"
    cd "$_dir"
    $cmd
}

main "$@"
