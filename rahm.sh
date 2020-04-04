#!/bin/bash
# rahm.sh
#########
#
# A tool for RetroAchievements devs to manage hashes linked to a game ID.
#
# globals ####################################################################

readonly USAGE="
USAGE:
$(basename "$0") [OPTIONS]"

readonly GIT_REPO="https://github.com/meleu/rahashmanager.git"
readonly SCRIPT_DIR="$(cd "$(dirname $0)" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_FULL="$SCRIPT_DIR/$SCRIPT_NAME"
readonly TMP_DIR="/tmp/rahm_$$"
readonly COOKIE="$TMP_DIR/.racookie"
readonly LOG_DIR="$SCRIPT_DIR/logs"
readonly GAMEID_REGEX='^[1-9][0-9]{0,9}$'
readonly HASH_REGEX='^[A-Fa-f0-9]{32}$'
readonly RA_URL='https://retroachievements.org'

CONSOLE_NAME=()
CONSOLE_NAME[1]=megadrive
CONSOLE_NAME[2]=n64
CONSOLE_NAME[3]=snes
CONSOLE_NAME[4]=gb
CONSOLE_NAME[5]=gba
CONSOLE_NAME[6]=gbc
CONSOLE_NAME[7]=nes
CONSOLE_NAME[8]=pcengine
CONSOLE_NAME[9]=segacd
CONSOLE_NAME[10]=sega32x
CONSOLE_NAME[11]=mastersystem
CONSOLE_NAME[12]=xbox360
CONSOLE_NAME[13]=atari
CONSOLE_NAME[14]=neogeo

RA_USER=
RA_PASSWORD=
RA_TOKEN=
GAME_ID=
HASH_FILE=
HASH=
GAME_TITLE=
ACTION=
REMOVED_HASHES_FILE=


# functions ###################################################################

function safe_exit() {
    rm -rf "$TMP_DIR" 
    exit $1
}


function help_message() {
    echo "$USAGE"
    echo
    echo "Where [OPTIONS] are:"
    echo
    # getting the help message from the comments in this source code
    sed -n 's/^#H //p' "$0"
    safe_exit
}


function yes_no() {
    local answer
    echo "Do you want to proceed? (if you're sure, type \"yes\" and press ENTER)" >&2
    read -p 'Answer: ' answer < /dev/tty
    [[ "$answer" =~ ^[Yy][Ee][Ss]$ ]]
}


function urlencode() {
    local LC_ALL=C
    local string="$*"
    local length="${#string}"
    local char

    for (( i = 0; i < length; i++ )); do
        char="${string:i:1}"
        if [[ "$char" == [a-zA-Z0-9.~_-] ]]; then
            printf "$char" 
        else
            printf '%%%02X' "'$char" 
        fi
    done
    printf '\n' # opcional
}


function check_dependencies() {
    local cmd

    for cmd in jq curl; do
        if ! which "$cmd" >/dev/null 2>&1; then
            if ! which apt-get >/dev/null 2>&1; then
                echo "ERROR: missing dependency: $cmd" >&2
                echo "To use this tool you need to install \"$cmd\" package. Please, install it and try again."
                safe_exit 1
            fi
            echo "To use this tool you need to install \"$cmd\", and we are ready to install it now."
            if yes_no; then
                sudo apt-get install "$cmd" || safe_exit 1
            else
                echo "Aborting..."
                safe_exit 1
            fi

        fi
    done
}


# TODO: this function needs more intensive tests
function update_files() {
    local err_flag=0
    local dir="$SCRIPT_DIR"

    if [[ -d "$dir/.git" ]]; then
        pushd "$dir" > /dev/null
        if ! git pull --rebase 2>/dev/null; then
            git fetch && git reset --hard origin/master || err_flag=1
        fi
        popd > /dev/null
    else
        echo "ERROR: \"$dir/.git\": directory not found!" >&2
        echo "Looks like this tool wasn't installed as instructed in repo's README." >&2
        echo "Aborting..." >&2
        err_flag=1
    fi

    if [[ "$err_flag" != 0 ]]; then
        echo "UPDATE: Failed to update \"$SCRIPT_NAME\"." >&2
        safe_exit 1
    fi
    
    echo "UPDATE: The files have been successfully updated."
    safe_exit 0
}


# Getting the RetroAchievements token
# input: RA_USER, RA_PASSWORD
# updates: RA_TOKEN
# exit if fails
function get_cheevos_token() {
    if [[ -z "$RA_USER" ]]; then
        echo "ERROR: undefined RetroAchievements.org user (see \"--user\" option)." >&2
        safe_exit 1
    fi

    [[ -n "$RA_TOKEN" ]] && return 0

    if [[ -z "$RA_PASSWORD" ]]; then
        echo "ERROR: undefined RetroAchievements.org password (see \"--password\" option)." >&2
        safe_exit 1
    fi

    echo "Getting user's token..." >&2
    RA_TOKEN="$(curl -s "$RA_URL/dorequest.php?r=login&u=${RA_USER}&p=${RA_PASSWORD}" | jq -r .Token)"
    if [[ "$RA_TOKEN" == null || -z "$RA_TOKEN" ]]; then
        echo "ERROR: cheevos authentication failed."
        safe_exit 1
    fi
}


# Print (echo) the game ID of a given hash
# input:
# $1 is a hash
# also needs RA_TOKEN
function get_game_id() {
	local gameid
	local hash="$1"
	[[ -z "$hash" ]] && return 1
    gameid="$(curl -s "$RA_URL/dorequest.php?r=gameid&m=$hash" | jq .GameID)"
    [[ "$gameid" =~ $GAMEID_REGEX ]] || return 1
    echo "$gameid"
}



# Getting info about the game ID
# input: RA_USER, RA_TOKEN, GAME_ID
# updates: GAME_TITLE, CONSOLE_ID
# exit if fails
function fill_game_info() {
    local json
    local success
    local id

    get_cheevos_token

    echo "Getting info about game $GAME_ID ..."
    json="$(curl -s "$RA_URL/dorequest.php?r=patch&u=${RA_USER}&g=${GAME_ID}&f=3&l=1&t=${RA_TOKEN}")"
    if [[ "$?" -ne 0 || -z "$json" ]]; then
        echo "ERROR: Failed to get data from RetroAchievements.org." >&2
        safe_exit 1
    fi

    success="$(echo "$json" | jq '.Success')"
    if [[ "$success" != true ]]; then
        echo "ERROR: Failed to get data from RetroAchievements.org \"$(echo "$json" | jq .Error)\"." >&2
        safe_exit 1
    fi

    id="$(echo "$json" | jq '.PatchData.ID')"
    if [[ "$id" != "$GAME_ID" ]]; then
        echo "ERROR: Looks like the game ID $GAME_ID doesn't exist in RetroAchievements.org database."
        safe_exit 1
    fi

    CONSOLE_ID="$(echo "$json" | jq '.PatchData.ConsoleID')"
    if [[ "$CONSOLE_ID" == null || -z "$CONSOLE_ID" ]]; then
        echo "ERROR: Unable to get console ID." >&2
        safe_exit 1
    fi

    GAME_TITLE="$(echo "$json" | jq -r '.PatchData.Title')"
    if [[ "$GAME_TITLE" == null || -z "$GAME_TITLE" ]]; then
        echo "ERROR: Unable to get game title." >&2
        safe_exit 1
    fi
}


function submit_game_title() {
    local json
    local error
    local success

    json="$(curl -s -G --data-urlencode "i=${GAME_TITLE}" \
            "$RA_URL/dorequest.php?r=submitgametitle&u=${RA_USER}&t=${RA_TOKEN}&m=${HASH}&c=${CONSOLE_ID}")"

    success="$(echo "$json" | jq .Success)"
    if [[ "$success" != true ]]; then
        echo "The hash \"$HASH\" was NOT linked to \"$GAME_TITLE\" (game ID: $GAME_ID)" >&2
        error="$(echo "$json" | jq -r .Error)"
        [[ -n "$error" ]] && echo "ERROR: \"$error\"" >&2
    else
        echo "SUCCESS: hash \"$HASH\" has been linked to \"$GAME_TITLE\" (game ID: $GAME_ID)" >&2
    fi
    echo >&2
}


function get_cookie() {
    # authenticating on the website (getting the cookie).
    curl -s --data "r=/&u=${RA_USER}&p=${RA_PASSWORD}" --cookie-jar "$COOKIE" "$RA_URL/login.php"

    if ! grep -q "retroachievements.org.*TRUE.*/.*RA_User.*${RA_USER}" "$COOKIE"; then
        echo "ERROR: failed to authenticate on RetroAchievements.org website." >&2
        safe_exit 1
    fi
}


function get_game_hashlib() {
    [[ -f "$COOKIE" ]] || get_cookie
    curl -s --cookie "$COOKIE" "$RA_URL/attemptunlink.php?g=${GAME_ID}" \
    | grep -Eo '[A-Fa-f0-9]{32}' \
    | sort -u
}


function unlink_hash() {
    local md5_hash="$1"
    local tmp_file="$(mktemp "$TMP_DIR/tmpfile.XXXX")"
    echo -n > "$tmp_file"

    [[ -f "$COOKIE" ]] || get_cookie

    [[ -z "$RA_USER" || -z "$GAME_ID" || -z "$GAME_TITLE" || -z "$md5_hash" ]] && return 1

    curl -v --cookie "$COOKIE" --data "u=${RA_USER}&g=${GAME_ID}&f=3&v=${md5_hash}" "$RA_URL/requestmodifygame.php" \
        2> "$tmp_file"

    if ! grep -qi "location: http.*/game/${GAME_ID}?e=modify_game_ok" "$tmp_file"; then
        echo "ERROR: failed to unlink \"${md5_hash}\" from \"$GAME_TITLE\" (game ID $GAME_ID)" >&2
        return 1
    fi

    echo "SUCCESS: unlinked \"${md5_hash}\" from \"$GAME_TITLE\" (game ID $GAME_ID)" >&2
}


function add_hash() {
    local line

    if [[ -f "$HASH_FILE" ]]; then
        local game_original_hashlib="$(get_game_hashlib)"
        while read -r line; do
            if ! [[ "$line" =~ $HASH_REGEX ]]; then
                echo "WARNING: ignoring invalid hash: \"$line\"" >&2
                continue
            fi
            if echo "$game_original_hashlib" | grep -q "$line" ; then
                echo "Ignoring \"$line\": already linked to this game." >&2
                continue
            fi
            HASH="$line"
            submit_game_title
        done < "$HASH_FILE"
    elif [[ -n "$HASH" ]]; then
        submit_game_title
    fi
}


function delete_hash() {
    local line
    local game_original_hashlib="$(get_game_hashlib)"

    if [[ "$ACTION" =~ ^(-d|--delete)$ ]]; then
        if [[ -f "$HASH_FILE" ]]; then
            while read -r line; do
                if ! [[ "$line" =~ $HASH_REGEX ]]; then
                    echo "WARNING: ignoring invalid hash: \"$line\"" >&2
                    continue
                fi
                if echo "$game_original_hashlib" | grep -q "$line"; then
                    # this is the hash we want to remove
                    unlink_hash "$line"
                else
                    echo "WARNING: ignoring \"$line\": NOT linked to game ID ${GAME_ID}" >&2
                fi
            done < "$HASH_FILE"
        elif [[ -n "$HASH" ]]; then
            local gameid
            if gameid="$(get_game_id "$HASH")"; then
                if [[ "$gameid" != "$GAME_ID" ]]; then
                    echo "ERROR: the \"$HASH\" hash is NOT linked to the game ID $GAME_ID (it's linked to the game ID $gameid)." >&2
                    echo "Aborting..." >&2
                    safe_exit 1
                else
                    unlink_hash "$HASH"
                fi
            else
                echo "ERROR: failed to get the game ID for \"$HASH\" hash." >&2
                echo "       Are you sure it's linked to game ID ${GAME_ID}?" >&2
                echo "Aborting..." >&2
                safe_exit 1
            fi
        fi
    fi
}


# helping to deal with command line arguments
function check_argument() {
    # limitation: the argument 2 can NOT start with '-'
    if [[ -z "$2" || "$2" =~ ^- ]]; then
        echo "$1: missing argument" >&2
        return 1
    fi
}


function parse_args() {
    local ret=0

    while [[ -n "$1" ]]; do
        case "$1" in

#H -h|--help                Print the help message and exit.
#H 
            -h|--help)
                help_message
                ;;

#H --update                 Update the script and exit.
#H 
            --update)
                update_files
                ;;

#H -u|--user USER           USER is your RetroAchievements.org username.
#H 
            -u|--user)
                check_argument "$1" "$2" || ret=1
                shift
                RA_USER="$1"
                ;;

#H -p|--password PASSWORD   PASSWORD is your RetroAchievements.org password.
#H 
            -p|--password)
                check_argument "$1" "$2" || ret=1
                shift
                RA_PASSWORD="$(urlencode "$1")"
                ;;

#H -g|--game-id GAME_ID     Check if there are cheevos for a given GAME_ID and 
#H                          exit. Accept game IDs separated by commas, ex: 1,2,3
#H                          Note: this option should be the last argument.
#H 
            -g|--game-id)
                check_argument "$1" "$2" || ret=1
                GAME_ID="$2"
                if ! [[ "$GAME_ID" =~ $GAMEID_REGEX && "$GAME_ID" != 0 ]]; then
                    echo "ERROR: $1 $2: invalid game ID." >&2
                    ret=1
                fi
                shift
                ;;

#H -l|--hashlib             Print the hashes linked to the given game ID and exit.
#H 
            -l|--hashlib)
                if [[ -z "$GAME_ID" ]]; then
                    echo "ERROR: missing game ID (see --game-id option)." >&2
                    safe_exit 1
                fi
                fill_game_info
                echo "--- hashes linked to game ID $GAME_ID - \"$GAME_TITLE\" (${CONSOLE_NAME[CONSOLE_ID]}):"
                get_game_hashlib
                safe_exit 0
                ;;

#H -f|--file FILE           Get from FILE the hash list to be linked/unlinked
#H                          to/from the given game ID (see --game-id). The file
#H                          must have one hash per line. Any invalid hash will
#H                          be ignored.
#H 
            -f|--file)
                check_argument "$1" "$2" || ret=1
                shift
                HASH_FILE="$1"
                if ! [[ -f "$HASH_FILE" ]]; then
                    echo "ERROR: $HASH_FILE: no such file." >&2
                    ret=1
                fi
                ;;

#H --hash HASH              HASH is the hash to be linked/unlinked to/from the
#H                          given game ID (see --game-id).
#H 
            --hash)
                check_argument "$1" "$2" || ret=1
                HASH="$2"
                if ! [[ "$HASH" =~ $HASH_REGEX ]]; then
                    echo "ERROR: $1 $2: invalid hash." >&2
                    ret=1
                fi
                shift
                ;;

#H -a|--add                 Tell the script that you want to add the given hash to
#H                          RetroAchievements.org database (see: --hash and --file).
#H                          This option can NOT be used with --delete.
#H 
#H -d|--delete              Tell the script that you want to delete the given hash from
#H                          RetroAchievements.org database (see: --hash and --file).
#H                          This option can NOT be used with --add.
#H 
            -a|--add|-d|--delete)
                if [[ -n "$ACTION" ]]; then
                    echo "ERROR: the option \"$1\" can NOT be used with \"$ACTION\"." >&2
                    echo "PLEASE, BE VERY CAREFUL WHEN USING THIS TOOL!" >&2
                    safe_exit 1
                else
                    ACTION="$1"
                fi
                ;;

            *)  break
                ;;
        esac
        shift
    done

    if [[ -z "$GAME_ID" ]]; then
        echo "ERROR: missing game ID (see --game-id option)." >&2
        ret=1
    fi

    if [[ -z "$HASH" && -z "$HASH_FILE" ]]; then
        echo "ERROR: you must provide a hash or a hash list file. See options --hash and --file."
        ret=1
    fi

    if [[ -z "$ACTION" ]]; then
        echo "ERROR: you must define what to do with the given hash (see --add or --delete options)." >&2
        ret=1
    fi

    if [[ -n "$HASH_FILE" && -n "$HASH" ]]; then
        echo "WARNING: ignoring hash \"$HASH\". Using hashes from \"$HASH_FILE\"."
    fi

    return "$ret"
}


# START HERE ##################################################################

function main() {
    trap safe_exit SIGHUP SIGINT SIGQUIT SIGKILL SIGTERM

    check_dependencies

    [[ -z "$1" ]] && help_message

    mkdir -p "$TMP_DIR"
    parse_args "$@" || safe_exit 1

    mkdir -p "$LOG_DIR"
    readonly REMOVED_HASHES_FILE="$LOG_DIR/unlinked_from_${GAME_ID}_$(date +%Y-%m-%d-%H%M%S).txt"

    fill_game_info
    echo "====================="
    echo " W A R N I N G ! ! !"
    echo "====================="
    echo
    echo "You are about to change data on RetroAchievements.org database!"
    echo
    echo "Check the info below before proceed."
    echo
    echo "Game ID.......: $GAME_ID"
    echo "Game Title....: \"$GAME_TITLE\""
    echo "Console.......: ${CONSOLE_NAME[CONSOLE_ID]}" 
    
    if [[ -n "$HASH_FILE" ]]; then
        echo "Hash list file: \"$HASH_FILE\""
    elif [[ -n "$HASH" ]]; then
        echo "Hash..........: \"$HASH\""
    else # probably it'll never happen
        echo "ERROR: Missing hash info! Aborting..." >&2
        safe_exit 1
    fi

    case "$ACTION" in
        -a|--add)
            echo "ACTION........: LINK the given hash(es) to the game"
            echo
            if ! yes_no; then
                echo "Aborting..."
                safe_exit 1
            fi
            echo
            echo "Please wait..."
            add_hash
            ;;

        -d|--delete)
            echo "ACTION........: UNLINK the given hash(es) from the game"
            echo
            if ! yes_no; then
                echo "Aborting..."
                safe_exit 1
            fi
            echo
            delete_hash
            ;;
    esac

    safe_exit
}

[[ "$0" == "$BASH_SOURCE" ]] && main "$@"
