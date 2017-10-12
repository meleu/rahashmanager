#!/bin/bash
# addhash2gameid.sh
###################
#
# A tool for RetroAchievements devs to add hashes to a game ID.
#
# globals ####################################################################

readonly USAGE="
USAGE:
$(basename "$0") [OPTIONS]"

readonly GIT_REPO="https://github.com/meleu/addhash2gameid.git"
readonly SCRIPT_DIR="$(cd "$(dirname $0)" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_FULL="$SCRIPT_DIR/$SCRIPT_NAME"
readonly GAMEID_REGEX='^[1-9][0-9]{0,9}$'
readonly HASH_REGEX='^[A-Fa-f0-9]{32}$'

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


function check_dependencies() {
    local cmd
    local answer

    for cmd in jq curl; do
        if ! which "$cmd" 2> /dev/null; then
            if ! which apt-get 2>/dev/null; then
                echo "ERROR: missing dependency: $cmd" >&2
                echo "To use this tool you need to install \"$cmd\" package. Please, install it and try again."
                safe_exit 1
            fi
            echo "To use this tool you need to install \"$cmd\"."
            echo "Do you want to install \"$cmd\" now? (if you're sure, type \"yes\" and press ENTER)"
            read -p 'Answer: ' answer

            if ! [[ "$answer" =~ ^[Yy][Ee][Ss]$ ]]; then
                echo "Aborting..."
                safe_exit 1
            fi

            sudo apt-get install "$cmd"
        fi
    done
}


# TODO: this function needs more intensive tests
function update_files() {
    local err_flag=0
    local dir="$SCRIPT_DIR/.."

    if [[ -d "$dir/.git" ]]; then
        pushd "$dir" > /dev/null
        if ! git pull --rebase ; then
            git merge --abort && git pull -X theirs || err_flag=1
        fi
        if [[ $err_flag -eq 0 ]]; then
            git submodule update --init --recursive || err_flag=1
        fi
        popd > /dev/null
    else
        echo "ERROR: \"$dir/.git\": directory not found!" >&2
        echo "Looks like this tool wasn't installed as instructed in repo's README." >&2
        echo "Aborting..." >&2
        err_flag=1
    fi

    if [[ $err_flag -ne 0 ]]; then
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
    RA_TOKEN="$(curl -s "http://retroachievements.org/dorequest.php?r=login&u=${RA_USER}&p=${RA_PASSWORD}" | jq -r .Token)"
    if [[ "$RA_TOKEN" == null || -z "$RA_TOKEN" ]]; then
        echo "ERROR: cheevos authentication failed."
        safe_exit 1
    fi
}


# Getting info about the game ID
# input: RA_USER, RA_TOKEN, GAME_ID
# updates: GAME_TITLE, CONSOLE_ID
# exit if fails
function get_game_info() {
    local json
    local success
    local id

    get_cheevos_token

    echo "Getting info about game $GAME_ID ..."
    json="$(curl -s "http://retroachievements.org/dorequest.php?r=patch&u=${RA_USER}&g=${GAME_ID}&f=3&l=1&t=${RA_TOKEN}")"
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
            "http://retroachievements.org/dorequest.php?r=submitgametitle&u=${RA_USER}&t=${RA_TOKEN}&m=${HASH}&c=${CONSOLE_ID}")"

    success="$(echo "$json" | jq .Success)"
    if [[ "$success" != true ]]; then
        echo "The hash \"$HASH\" was NOT linked to \"$GAME_TITLE\" (game ID: $GAME_ID)"
        error="$(echo "$json" | jq -r .Error)"
        [[ -n "$error" ]] && echo "ERROR: \"$error\"" >&2
    else
        echo "SUCCESS: hash \"$HASH\" has been linked to \"$GAME_TITLE\" (game ID: $GAME_ID)"
    fi
    echo
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
                RA_PASSWORD="$1"
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

#H -f|--file FILE           Get the hash list to be linked to the game ID (see
#H                          --game-id) from FILE. The file must have one hash per
#H                          line. Any invalid hash will be ignored.
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

#H --hash HASH           HASH is the hash to be linked to the game ID (see
#H                          --game-id).
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
        echo "ERROR: you should provide a hash or a hash list file. See options --hash and --file."
        ret=1
    fi

    if [[ -n "$HASH_FILE" && -n "$HASH" ]]; then
        echo "WARNING: ignoring hash \"$HASH\". Using hashes from \"$HASH_FILE\"."
    fi

    return "$ret"
}


# START HERE ##################################################################

function main() {
    local answer
    local line

    trap safe_exit SIGHUP SIGINT SIGQUIT SIGKILL SIGTERM

    check_dependencies

    [[ -z "$1" ]] && help_message

    parse_args "$@" || safe_exit 1

    get_game_info "$GAME_ID"

    echo "====================="
    echo " W A R N I N G ! ! !"
    echo "====================="
    echo
    echo "You are about to change data on RetroAchievements.org database!"
    echo
    echo "This program links hash(es) to a game. Check the info below before proceed."
    echo
    echo "Game ID.......: $GAME_ID"
    echo "Game Title....: \"$GAME_TITLE\""
    echo "Console.......: ${CONSOLE_NAME[CONSOLE_ID]}" 
    
    if [[ -n "$HASH_FILE" ]]; then
        echo "Hash list file: \"$HASH_FILE\""
    elif [[ -n "$HASH" ]]; then
        echo "Hash..........: \"$HASH\""
    else # probably it'll never happen
        echo "ERROR: Missing hash info!. Aborting..." >&2
        safe_exit 1
    fi

    echo
    echo "Do you want to proceed? (if you're sure, type \"yes\" and press ENTER)"
    read -p 'Answer: ' answer

    if ! [[ "$answer" =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Aborting..."
        safe_exit 1
    fi

    if [[ -f "$HASH_FILE" ]]; then
        while read -r line; do
            if ! [[ "$line" =~ $HASH_REGEX ]]; then
                echo "Warning: ignoring invalid hash: \"$line\"" >&2
                continue
            fi
            HASH="$line"
            submit_game_title
        done < "$HASH_FILE"
    elif [[ -n "$HASH" ]]; then
        submit_game_title
    fi

    safe_exit
}

[[ "$0" == "$BASH_SOURCE" ]] && main "$@"
