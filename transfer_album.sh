#!/usr/bin/env bash

###########################################################################
# Google Album to Photoprism Album Transfer Script
#
# To use this script:
#
# 1. Download the desired album via Google Takeout.
# 2. If not working directly on the server, download the
#    photoprism sidecar directory.
# 3. Edit the variables below to match your paths and server configuration.
# 4. Run the script.
#
# Notes:
#
# - Only point this script to one google album directory at a time.
# - Libraries with more than a few thousand photos can take a while
# - Photo UID is assumed to be a SHA-1 hash of the file, if this changes
#   then this script will need to be adjusted
############################################################################

siteURL="https://photos.example.com"
sessionAPI="/api/v1/session"
albumAPI="/api/v1/albums"
# Note - Album photos API: /api/v1/albums/$albumUID/photos

apiUsername=$API_USERNAME
apiPassword=$API_PASSWORD

if [ -z "$apiUsername" ]; then
    read -p 'Username? ' apiUsername
fi
if [ -z "$apiPassword" ]; then
    read -sp 'Password? ' apiUsername
fi
############################################################################

shopt -s globstar

if [[ "$1" == "-c" ]]; then
    commandFile=$2
    rm "$commandFile"
    shift 2
fi

function log() {
    >&2 echo "$@"
}

function logexec() {
    if [ -z "$commandFile" ]; then
        >&2 echo -n "Exec: "
        >&2 printf ' %q' "$@"
        $@
    else
        printf ' %q' "$@" >> "$commandFile"
        echo >> "$commandFile"
    fi
}

function api_call() {
    logexec curl --silent -H "Content-Type: application/json" -H "X-Session-ID: $sessionID" "$@"
}


# Create a new session
log "Creating session..."
sessionID="$(logexec curl --silent -X POST -H "Content-Type: application/json" -d "{\"username\": \"$apiUsername\", \"password\": \"$apiPassword\"}" "$siteURL$sessionAPI" | grep -Eo '"id":.*"' | awk -F '"' '{print $4}')"

# Clean up the session on script exit
trap 'log "Deleting session..." && api_call -X DELETE "$siteURL$sessionAPI/$sessionID" >/dev/null' EXIT

function get_json_field() {
    field=$1; shift
    filename=$1; shift

    # This is more robust but only works if you have jq installed
    #jq -r '.albumData["'"$field"'"]' "$filename"
    # This assumes a nicely formatted JSON with one key:value pair per line and no escaped quotes
    awk -F '"' '/"'"$field"'":/ { print $4 }' "$filename"
}

function make_json_array() {
    first=$1; shift
    list=""
    if [ -n "$first" ]; then
        list="\"$first\""
    fi
    while [ -n "$1" ]; do
        list="$list,\"$1\""
        shift
    done
    echo "[$list]"
}

function add_album_files() {
    albumUID=$1; shift
    albumPhotosAPI="$albumAPI/$albumUID/photos"

    # Send an API request to add the photo to the album
    jsonArray=$(make_json_array $@)
    log "Submitting batch to album id $albumUID"
    api_call -X POST -d "{\"photos\": $jsonArray}" "$siteURL$albumPhotosAPI" >/dev/null
}

function import_album() {
    albumDir="$1"; shift
    metadataFile="$albumDir/metadata.json"

    if [ ! -f "$metadataFile" ]; then
        log "Skipping folder \"$albumDir\", no metadata.json!"
        return
    fi

    # Parse JSON with awk, what could go wrong?
    albumTitle=$(get_json_field title "$metadataFile")
    albumDescription=$(get_json_field description "$metadataFile")

    if [ -z "$albumTitle" ]; then
        log "Skipping folder \"$albumDir\", no album title found!"
        return
    fi

    if [[ "$albumDescription" == "Album for automatically uploaded content from cameras and mobile devices" ]]; then
        log "Skipping album $albumTitle, seems to be an autogenerated date album"
        return
    fi

    if [[ "$albumDescription" == "Hangout:"* ]]; then
        log "Skipping album $albumTitle, seems to be an autogenerated Hangouts album"
        return
    fi

    # Create a new album
    log "Creating album $albumTitle..."
    albumUID=$(api_call -X POST \
        -d "{\"Title\": \"$albumTitle\", \"Description\": \"$albumDescription\"}" \
        "$siteURL$albumAPI" 2>&1 \
        | grep -Eo '"UID":.*"' \
        | awk -F '"' '{print $4}')
    log "Album UID: $albumUID"

    # Scan the google takeout dir for json files
    log "Adding photos..."
    count=1
    batchFiles=""
    batchCount=1
    for jsonFile in "$albumDir"/**/*.json; do
        # Don't try to add metadata files
        if [[ $(basename "$jsonFile") == metadata*.json ]]; then
            continue
        fi

        # Get the photo title (filename) from the google json file
        googleFile=$(get_json_field title "$jsonFile")
        # Skip this file if it has no title
        if [ -z "$googleFile" ]; then
            continue
        fi

        imageFile=${jsonFile%.json}
        fileSHA=$(sha1sum "$imageFile" | awk '{print $1}')

        log "$count: Adding $imageFile with hash $fileSHA to album..."
        batchIds="$batchIds $fileSHA"

        count="$((count+1))"
        batchCount="$((batchCount+1))"

        if [ $batchCount -gt 999 ]; then
            add_album_files $albumUID $batchIds
            batchIds=""
            batchCount=1
        fi
    done

    if [ -n $batchFiles ]; then
        add_album_files $albumUID $batchIds
    fi
}

# Import directory as first parameter
importDirectory=$1
if [ -z "$importDirectory" ]; then
    importDirectory=$(pwd)
fi

if [ -f "metadata.json" ]; then
    # If this is an album directory, just import this album
    log "Importing \"$importDirectory\" as a single album"
    import_album "$importDirectory"
else
    # Else import all albums found in this directory
    log "Importing all albums in \"$importDirectory\""
    find "$importDirectory" -maxdepth 1 -type d | \
    while read album; do
        import_album "$album"
    done
fi
