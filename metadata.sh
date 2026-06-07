#!/bin/bash

# --- CONFIGURATION ---
# Resolve the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use METADATA_DIR if set, otherwise fallback to script directory
BASE_DIR="${METADATA_DIR:-$SCRIPT_DIR}"
TASKS_DIR="$BASE_DIR/tasks"
MILESTONES_DIR="$BASE_DIR/milestones"
STORIES_DIR="$BASE_DIR/stories"
PLANS_DIR="$BASE_DIR/plans"

# Ensure core directories exist
mkdir -p "$TASKS_DIR" "$MILESTONES_DIR" "$STORIES_DIR" "$PLANS_DIR"

# --- UTILITIES ---

# Generate a full UUID (v4-like)
gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # Fallback using /dev/urandom
        local hex=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
        echo "${hex:0:8}-${hex:8:4}-${hex:12:4}-${hex:16:4}-${hex:20:12}"
    fi
}

# Resolve UUID to sharded task path
get_task_path() {
    local uuid=$1
    local shard="${uuid:0:2}"
    local rest="${uuid:2}"
    echo "$TASKS_DIR/$shard/$rest.json"
}

# Resolve Milestone UUID to path
get_milestone_path() {
    local uuid=$1
    echo "$MILESTONES_DIR/$uuid.json"
}

# Resolve Story UUID to path
get_story_path() {
    local uuid=$1
    echo "$STORIES_DIR/$uuid.json"
}

# Resolve Plan UUID to path
get_plan_path() {
    local uuid=$1
    local shard="${uuid:0:2}"
    local rest="${uuid:2}"
    echo "$PLANS_DIR/$shard/$rest.md"
}

# Resolve Plan UUID or Slug to absolute path
resolve_plan_path() {
    local id_or_slug=$1
    # Try direct UUID sharded path first
    local plan_path=$(get_plan_path "$id_or_slug")
    if [ -f "$plan_path" ]; then
        echo "$plan_path"
        return 0
    fi
    # Fallback to search inside files for "slug: slug" (case-insensitive)
    local slug_match=$(find "$PLANS_DIR" -name "*.md" -exec grep -li "^slug: $id_or_slug" {} + | head -n 1)
    if [ -n "$slug_match" ]; then
        echo "$slug_match"
        return 0
    fi
    return 1
}

# Resolve Task UUID or Slug to absolute path
resolve_task_path() {
    local id_or_slug=$1
    # Try direct UUID sharded path first
    local task_path=$(get_task_path "$id_or_slug")
    if [ -f "$task_path" ]; then
        echo "$task_path"
        return 0
    fi
    # Fallback to slug search - anchored to exact slug match (case-insensitive)
    local slug_match=$(find "$TASKS_DIR" -name "*.json" -exec grep -li "\"slug\": \"$id_or_slug\"" {} + | while read -r f; do
        if grep -qi "\"slug\": \"$id_or_slug\"" "$f"; then
            echo "$f"
            break
        fi
    done)
    
    # Re-verify slug match exactly to avoid partial matches like SV-1 matching SV-10
    local exact_match=$(find "$TASKS_DIR" -name "*.json" -exec grep -li "\"slug\": \"$id_or_slug\"" {} + | xargs grep -li "\"slug\": \"$id_or_slug\"" | head -n 20)
    for m in $exact_match; do
        if grep -qi "\"slug\": \"$id_or_slug\"" "$m"; then
             echo "$m"
             return 0
        fi
    done
    return 1
}

# Resolve Story UUID or Slug to absolute path
resolve_story_path() {
    local id_or_slug=$1
    # Try direct UUID path first
    local story_path=$(get_story_path "$id_or_slug")
    if [ -f "$story_path" ]; then
        echo "$story_path"
        return 0
    fi
    # Fallback to slug search (case-insensitive)
    local slug_match=$(grep -li "\"slug\": \"$id_or_slug\"" "$STORIES_DIR"/*.json 2>/dev/null | while read -r f; do
        if grep -qi "\"slug\": \"$id_or_slug\"" "$f"; then
            echo "$f"
            break
        fi
    done)

    if [ -n "$slug_match" ]; then
        echo "$slug_match"
        return 0
    fi
    return 1
}

# Get RFC3339 timestamp
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Simple JSON/YAML field extractor
get_json_val() {
    local key=$1
    local file=$2
    [ ! -f "$file" ] && return
    
    # 1. Try JSON style: "key": "value"
    local val=$(grep "\"$key\":" "$file" | head -n 1 | sed -E "s/.*\"$key\": *\"(.*)\",?/\1/" | sed 's/"$//')
    if [ -n "$val" ]; then
        echo "$val"
        return
    fi
    
    # 2. Try YAML style: key: value
    grep "^$key: " "$file" | head -n 1 | sed -E "s/^$key: *(.*)/\1/" | tr -d '"'
}

# Simple JSON array extractor
get_json_array() {
    local key=$1
    local file=$2
    [ ! -f "$file" ] && return
    
    # 1. Try single-line match first: "key": ["val1", "val2"]
    local single_line=$(grep "\"$key\":" "$file" | grep "\[.*\]")
    if [ -n "$single_line" ]; then
        echo "$single_line" | sed -E "s/.*\"$key\": *\[(.*)\].*/\1/" | tr -d '"' | sed 's/, /\n/g' | sed 's/,/\n/g' | sed '/^$/d'
        return
    fi
    
    # 2. Fallback to multi-line range
    sed -n "/\"$key\": *\[/,/\]/p" "$file" | grep -vE "\[|\]" | sed -E 's/^[[:space:]]*"//; s/",?$//' | sed '/^$/d'
}

# Sort UUIDs by their slug field
sort_uuids_by_slug() {
    local type=$1
    shift
    local uuids=$@
    [ -z "$uuids" ] && return
    for uuid in $uuids; do
        local path=""
        case "$type" in
            task) path=$(get_task_path "$uuid") ;;
            story) path=$(get_story_path "$uuid") ;;
            milestone) path=$(get_milestone_path "$uuid") ;;
            plan) path=$(get_plan_path "$uuid") ;;
        esac
        if [ -f "$path" ]; then
            echo "$(get_json_val "slug" "$path") $uuid"
        fi
    done | sort -V | cut -d' ' -f2-
}

# --- CORE FUNCTIONS ---

create_plan() {
    local title=$1
    local slug=$2
    
    local uuid=$(gen_uuid)
    local plan_path=$(get_plan_path "$uuid")
    local shard_dir=$(dirname "$plan_path")

    mkdir -p "$shard_dir"

    cat <<EOF > "$plan_path"
---
id: $uuid
slug: $slug
title: "$title"
created_at: $(get_timestamp)
---

# Implementation Plan: $title

## Context
Provide background and why this change is necessary.

## Design
Describe the technical approach.

## Implementation Details
Specify files to be modified and exact logic changes.

## Verification
List steps to verify the implementation.
EOF
    echo "Created Plan: $uuid - $title ($slug)"
}

edit_plan() {
    local id_or_slug=$1
    local plan_path=$(resolve_plan_path "$id_or_slug")

    if [ -z "$plan_path" ] || [ ! -f "$plan_path" ]; then
        echo "Error: Plan '$id_or_slug' not found."
        return 1
    fi

    if [ -n "$EDITOR" ]; then
        $EDITOR "$plan_path"
    else
        echo "Plan file: $plan_path"
        echo "Tip: Set \$EDITOR to your favorite editor (e.g. export EDITOR=vim)"
    fi
}

view_plan() {
    local id_or_slug=$1
    local plan_path=$(resolve_plan_path "$id_or_slug")

    if [ -z "$plan_path" ] || [ ! -f "$plan_path" ]; then
        echo "Error: Plan '$id_or_slug' not found."
        return 1
    fi

    # Colors
    local BOLD=$'\033[1m'
    local CYAN=$'\033[0;36m'
    local MAGENTA=$'\033[0;35m'
    local RESET=$'\033[0m'

    echo -e "${CYAN}${BOLD}--------------------------------------------------------------------------------${RESET}"
    echo -e "${MAGENTA}${BOLD}                                     P L A N                                    ${RESET}"
    echo -e "${CYAN}${BOLD}--------------------------------------------------------------------------------${RESET}"
    cat "$plan_path"
    echo -e "${CYAN}${BOLD}--------------------------------------------------------------------------------${RESET}"
}

create_task() {
    local title=$1
    local slug=$2
    local priority=$(echo "${3:-MEDIUM}" | tr '[:lower:]' '[:upper:]')
    local type=$(echo "${4:-TASK}" | tr '[:lower:]' '[:upper:]')
    
    local uuid=$(gen_uuid)
    local task_path=$(get_task_path "$uuid")
    local shard_dir=$(dirname "$task_path")

    mkdir -p "$shard_dir"

    cat <<EOF > "$task_path"
{
  "id": "$uuid",
  "slug": "$slug",
  "title": "$title",
  "status": "OPEN",
  "priority": "$priority",
  "type": "$type",
  "plan": "",
  "tags": [

  ],
  "depends_on": [

  ],
  "description": "",
  "acceptance_criteria": [

  ],
  "work_tree": [

  ],
  "implementation_notes": [

  ],
  "created_at": "$(get_timestamp)"
}
EOF
    echo "Created Task: $uuid - $title ($slug)"
}

edit_task() {
    local id_or_slug=$1
    local task_path=$(resolve_task_path "$id_or_slug")

    if [ -z "$task_path" ]; then
        echo "Error: Task '$id_or_slug' not found."
        return 1
    fi

    if [ -n "$EDITOR" ]; then
        $EDITOR "$task_path"
    else
        echo "Task file: $task_path"
        echo "Tip: Set \$EDITOR to your favorite editor (e.g. export EDITOR=vim)"
    fi
}

create_milestone() {
    local title=$1
    local slug=$2
    local status="PLANNED"
    
    local uuid=$(gen_uuid)
    local milestone_path=$(get_milestone_path "$uuid")

    cat <<EOF > "$milestone_path"
{
  "id": "$uuid",
  "title": "$title",
  "slug": "$slug",
  "status": "$status",
  "description": "",
  "stories": [],
  "tasks": [],
  "completed_at": ""
}
EOF
    echo "Created Milestone: $uuid - $title ($slug)"
}

edit_milestone() {
    local id_or_slug=$1
    local milestone_path=$(get_milestone_path "$id_or_slug")

    if [ ! -f "$milestone_path" ]; then
        # Try finding by slug if uuid lookup fails (case-insensitive)
        local slug_match=$(grep -li "\"slug\": \"$id_or_slug\"" "$MILESTONES_DIR"/*.json 2>/dev/null | head -n 1)
        if [ -n "$slug_match" ]; then
            milestone_path="$slug_match"
        else
            echo "Error: Milestone '$id_or_slug' not found (UUID or Slug)."
            return 1
        fi
    fi

    if [ -n "$EDITOR" ]; then
        $EDITOR "$milestone_path"
    else
        echo "Milestone file: $milestone_path"
        echo "Tip: Set \$EDITOR to your favorite editor (e.g. export EDITOR=vim)"
    fi
}

create_story() {
    local title=$1
    local slug=$2
    local status="PLANNED"
    
    local uuid=$(gen_uuid)
    local story_path=$(get_story_path "$uuid")

    cat <<EOF > "$story_path"
{
  "id": "$uuid",
  "title": "$title",
  "slug": "$slug",
  "status": "$status",
  "description": "",
  "tasks": []
}
EOF
    echo "Created Story: $uuid - $title ($slug)"
}

edit_story() {
    local id_or_slug=$1
    local story_path=$(resolve_story_path "$id_or_slug")

    if [ -z "$story_path" ]; then
        echo "Error: Story '$id_or_slug' not found."
        return 1
    fi

    if [ -n "$EDITOR" ]; then
        $EDITOR "$story_path"
    else
        echo "Story file: $story_path"
        echo "Tip: Set \$EDITOR to your favorite editor (e.g. export EDITOR=vim)"
    fi
}

view_story() {
    local id_or_slug=$1
    local story_path=$(resolve_story_path "$id_or_slug")

    if [ -z "$story_path" ]; then
        echo "Error: Story '$id_or_slug' not found."
        return 1
    fi

    # Colors
    local BOLD=$'\033[1m'
    local CYAN=$'\033[0;36m'
    local BLUE=$'\033[0;34m'
    local GREEN=$'\033[0;32m'
    local RED=$'\033[0;31m'
    local YELLOW=$'\033[0;33m'
    local MAGENTA=$'\033[0;35m'
    local GRAY=$'\033[1;30m'
    local RESET=$'\033[0m'

    echo -e "${CYAN}${BOLD}--------------------------------------------------------------------------------${RESET}"
    echo -e "${MAGENTA}${BOLD}                                    S T O R Y                                   ${RESET}"
    echo -e "${CYAN}${BOLD}--------------------------------------------------------------------------------${RESET}"

    local status=$(get_json_val "status" "$story_path" | tr '[:lower:]' '[:upper:]')
    local status_color=$RESET
    case "$status" in
        ACTIVE) status_color=$GREEN ;;
        PLANNED) status_color=$CYAN ;;
        CLOSED) status_color=$RED ;;
        COMPLETED) status_color=$MAGENTA ;;
        CANCELLED) status_color=$GRAY ;;
    esac

    # Formatting helper for wrapping text
    wrap_text() {
        local label=$1
        local text=$2
        printf "${BLUE}${BOLD}%s:${RESET}\n" "$label"
        if [ -n "$text" ]; then
            echo "$text" | fold -s -w 80 | sed 's/^/  /'
        else
            echo "  (empty)"
        fi
    }

    printf "${BLUE}${BOLD}ID:${RESET}    %s\n" "$(get_json_val "id" "$story_path")"
    printf "${BLUE}${BOLD}SLUG:${RESET}  %s\n" "$(get_json_val "slug" "$story_path")"
    printf "${BLUE}${BOLD}TITLE:${RESET} ${BOLD}%s${RESET}\n" "$(get_json_val "title" "$story_path")"
    echo -e "${CYAN}--------------------------------------------------------------------------------${RESET}"
    printf "${BLUE}${BOLD}STATUS:${RESET}   ${status_color}%-10s${RESET}\n" "$status"
    echo -e "${CYAN}--------------------------------------------------------------------------------${RESET}"
    wrap_text "DESCRIPTION" "$(get_json_val "description" "$story_path")"
    echo ""
    
    local uuid_regex="[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    local uuids=$(sed -n '/"tasks": \[/,/\]/p' "$story_path" | grep -oE "$uuid_regex")

    printf "${BLUE}${BOLD}TASKS:${RESET}\n"
    if [ -n "$uuids" ]; then
        for uuid in $(sort_uuids_by_slug "task" $uuids); do
            local task_path=$(get_task_path "$uuid")
            if [ -f "$task_path" ]; then
                local task_title=$(get_json_val "title" "$task_path")
                local task_status=$(get_json_val "status" "$task_path" | tr '[:lower:]' '[:upper:]')
                local task_slug=$(get_json_val "slug" "$task_path")
                
                local t_status_color=$RESET
                case "$task_status" in
                    OPEN) t_status_color=$GREEN ;;
                    IN-PROGRESS) t_status_color=$YELLOW ;;
                    PLANNED) t_status_color=$CYAN ;;
                    CLOSED) t_status_color=$RED ;;
                    CANCELLED) t_status_color=$GRAY ;;
                esac

                printf "  ${BOLD}[%s]:${RESET}\n" "$uuid"
                printf "    ${BLUE}Title:${RESET}  %s\n" "$task_title"
                printf "    ${BLUE}Slug:${RESET}   %s\n" "$task_slug"
                printf "    ${BLUE}Status:${RESET} ${t_status_color}%s${RESET}\n" "$task_status"
                echo ""
            else
                printf "  [%s] ${RED}(MISSING)${RESET}\n" "$uuid"
            fi
        done
    else
        echo "  (No tasks)"
    fi
    echo -e "${CYAN}--------------------------------------------------------------------------------${RESET}"
}

view_milestone() {
    local id_or_slug=$1
    local milestone_path=$(get_milestone_path "$id_or_slug")

    if [ ! -f "$milestone_path" ]; then
        # Try finding by slug if uuid lookup fails (case-insensitive)
        local slug_match=$(grep -li "\"slug\": \"$id_or_slug\"" "$MILESTONES_DIR"/*.json 2>/dev/null | head -n 1)
        if [ -n "$slug_match" ]; then
            milestone_path="$slug_match"
        else
            echo "Error: Milestone '$id_or_slug' not found (UUID or Slug)."
            return 1
        fi
    fi

    # Colors
    local BOLD=$'\033[1m'
    local CYAN=$'\033[0;36m'
    local BLUE=$'\033[0;34m'
    local GREEN=$'\033[0;32m'
    local RED=$'\033[0;31m'
    local YELLOW=$'\033[0;33m'
    local MAGENTA=$'\033[0;35m'
    local GRAY=$'\033[1;30m'
    local RESET=$'\033[0m'

    echo -e "${CYAN}${BOLD}--------------------------------------------------------------------------------${RESET}"
    echo -e "${MAGENTA}${BOLD}                                M I L E S T O N E                               ${RESET}"
    echo -e "${CYAN}${BOLD}--------------------------------------------------------------------------------${RESET}"

    local status=$(get_json_val "status" "$milestone_path" | tr '[:lower:]' '[:upper:]')
    local status_color=$RESET
    case "$status" in
        ACTIVE) status_color=$GREEN ;;
        PLANNED) status_color=$CYAN ;;
        CLOSED) status_color=$RED ;;
        COMPLETED) status_color=$MAGENTA ;;
        CANCELLED) status_color=$GRAY ;;
    esac

    # Formatting helper for wrapping text
    wrap_text() {
        local label=$1
        local text=$2
        printf "${BLUE}${BOLD}%s:${RESET}\n" "$label"
        if [ -n "$text" ]; then
            echo "$text" | fold -s -w 80 | sed 's/^/  /'
        else
            echo "  (empty)"
        fi
    }

    printf "${BLUE}${BOLD}ID:${RESET}    %s\n" "$(get_json_val "id" "$milestone_path")"
    printf "${BLUE}${BOLD}SLUG:${RESET}  %s\n" "$(get_json_val "slug" "$milestone_path")"
    printf "${BLUE}${BOLD}TITLE:${RESET} ${BOLD}%s${RESET}\n" "$(get_json_val "title" "$milestone_path")"
    echo -e "${CYAN}--------------------------------------------------------------------------------${RESET}"
    printf "${BLUE}${BOLD}STATUS:${RESET}   ${status_color}%-10s${RESET}\n" "$status"
    echo -e "${CYAN}--------------------------------------------------------------------------------${RESET}"
    wrap_text "DESCRIPTION" "$(get_json_val "description" "$milestone_path")"
    echo ""
    
    local uuid_regex="[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    
    # --- STORIES ---
    local story_uuids=$(sed -n '/"stories": \[/,/\]/p' "$milestone_path" | grep -oE "$uuid_regex")
    printf "${BLUE}${BOLD}STORIES:${RESET}\n"
    if [ -n "$story_uuids" ]; then
        for s_uuid in $(sort_uuids_by_slug "story" $story_uuids); do
            local s_path=$(get_story_path "$s_uuid")
            if [ -f "$s_path" ]; then
                local s_title=$(get_json_val "title" "$s_path")
                local s_status=$(get_json_val "status" "$s_path" | tr '[:lower:]' '[:upper:]')
                local s_slug=$(get_json_val "slug" "$s_path")
                
                local s_status_color=$RESET
                case "$s_status" in
                    ACTIVE) s_status_color=$GREEN ;;
                    PLANNED) s_status_color=$CYAN ;;
                    CLOSED) s_status_color=$RED ;;
                esac

                printf "  ${BOLD}[%s]:${RESET}\n" "$s_uuid"
                printf "    ${BLUE}Title:${RESET}  %s\n" "$s_title"
                printf "    ${BLUE}Slug:${RESET}   %s\n" "$s_slug"
                printf "    ${BLUE}Status:${RESET} ${s_status_color}%s${RESET}\n" "$s_status"
                echo ""
            else
                printf "  [%s] ${RED}(MISSING)${RESET}\n" "$s_uuid"
            fi
        done
    else
        echo "  (No stories)"
    fi

    # --- TASKS ---
    local task_uuids=$(sed -n '/"tasks": \[/,/\]/p' "$milestone_path" | grep -oE "$uuid_regex")
    printf "${BLUE}${BOLD}TASKS:${RESET}\n"
    if [ -n "$task_uuids" ]; then
        for t_uuid in $(sort_uuids_by_slug "task" $task_uuids); do
            local t_path=$(get_task_path "$t_uuid")
            if [ -f "$t_path" ]; then
                local t_title=$(get_json_val "title" "$t_path")
                local t_status=$(get_json_val "status" "$t_path" | tr '[:lower:]' '[:upper:]')
                local t_slug=$(get_json_val "slug" "$t_path")
                
                local t_status_color=$RESET
                case "$t_status" in
                    OPEN) t_status_color=$GREEN ;;
                    IN-PROGRESS) t_status_color=$YELLOW ;;
                    PLANNED) t_status_color=$CYAN ;;
                    CLOSED) t_status_color=$RED ;;
                    CANCELLED) t_status_color=$GRAY ;;
                esac

                printf "  ${BOLD}[%s]:${RESET}\n" "$t_uuid"
                printf "    ${BLUE}Title:${RESET}  %s\n" "$t_title"
                printf "    ${BLUE}Slug:${RESET}   %s\n" "$t_slug"
                printf "    ${BLUE}Status:${RESET} ${t_status_color}%s${RESET}\n" "$t_status"
                echo ""
            else
                printf "  [%s] ${RED}(MISSING)${RESET}\n" "$t_uuid"
            fi
        done
    else
        echo "  (No tasks)"
    fi
    echo -e "${CYAN}--------------------------------------------------------------------------------${RESET}"
}

link_entities() {
    local child_id_or_slug=$1
    local parent_id_or_slug=$2

    # --- NEW: Resolve Plan Child ---
    local plan_path=$(resolve_plan_path "$child_id_or_slug")
    if [ -n "$plan_path" ]; then
        local task_path=$(resolve_task_path "$parent_id_or_slug")
        if [ -n "$task_path" ]; then
            local plan_id=$(get_json_val "id" "$plan_path")
            local plan_slug=$(get_json_val "slug" "$plan_path")
            sed -i '' "s/\"plan\": \".*\"/\"plan\": \"$plan_id\"/" "$task_path"
            echo "Linked PLAN $plan_id ($plan_slug) to TASK $(get_json_val "id" "$task_path") ($(get_json_val "slug" "$task_path"))"
            return 0
        fi
    fi

    # 1. Resolve Child (Existing Logic)
    local child_path=""
    local child_type=""
    local child_uuid=""

    if resolve_task_path "$child_id_or_slug" >/dev/null; then
        child_path=$(resolve_task_path "$child_id_or_slug")
        child_type="TASK"
    elif resolve_story_path "$child_id_or_slug" >/dev/null; then
        child_path=$(resolve_story_path "$child_id_or_slug")
        child_type="STORY"
    else
        echo "Error: Child '$child_id_or_slug' not found (Task or Story)."
        return 1
    fi
    child_uuid=$(get_json_val "id" "$child_path")

    # 2. Resolve Parent
    local parent_path=""
    local parent_type=""
    local parent_uuid=""

    if resolve_story_path "$parent_id_or_slug" >/dev/null; then
        parent_path=$(resolve_story_path "$parent_id_or_slug")
        parent_type="STORY"
    elif [ -f "$(get_milestone_path "$parent_id_or_slug")" ]; then
        parent_path=$(get_milestone_path "$parent_id_or_slug")
        parent_type="MILESTONE"
    else
        # Try milestone slug search (case-insensitive)
        local m_slug_match=$(grep -li "\"slug\": \"$parent_id_or_slug\"" "$MILESTONES_DIR"/*.json 2>/dev/null | head -n 1)
        if [ -n "$m_slug_match" ]; then
            parent_path="$m_slug_match"
            parent_type="MILESTONE"
        else
            echo "Error: Parent '$parent_id_or_slug' not found (Story or Milestone)."
            return 1
        fi
    fi
    parent_uuid=$(get_json_val "id" "$parent_path")

    # 3. Determine target array
    local target_array=""
    if [ "$child_type" == "TASK" ]; then
        target_array="tasks"
    elif [ "$child_type" == "STORY" ]; then
        if [ "$parent_type" == "MILESTONE" ]; then
            target_array="stories"
        else
            echo "Error: Cannot link a Story to a Story."
            return 1
        fi
    fi

    # 4. Extract and update
    local uuid_regex="[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    local existing_uuids=$(sed -n "/\"$target_array\": \[/,/\]/p" "$parent_path" | grep -oE "$uuid_regex")
    local all_uuids=$( (echo "$existing_uuids"; echo "$child_uuid") | sed '/^$/d' | sort -u)
    
    # Read other fields (simplistic update)
    local title=$(get_json_val "title" "$parent_path")
    local slug=$(get_json_val "slug" "$parent_path")
    local status=$(get_json_val "status" "$parent_path")
    local description=$(get_json_val "description" "$parent_path")
    
    # Check if we need to preserve both stories and tasks for Milestones
    local stories_json=""
    local tasks_json=""
    
    if [ "$parent_type" == "MILESTONE" ]; then
        if [ "$target_array" == "stories" ]; then
            stories_json=$(echo "$all_uuids" | sed 's/.*/    "&"/' | paste -sd "," - | sed 's/,/,\n/g')
            local existing_tasks=$(sed -n '/"tasks": \[/,/\]/p' "$parent_path" | grep -oE "$uuid_regex")
            tasks_json=$(echo "$existing_tasks" | sed 's/.*/    "&"/' | paste -sd "," - | sed 's/,/,\n/g')
        else
            tasks_json=$(echo "$all_uuids" | sed 's/.*/    "&"/' | paste -sd "," - | sed 's/,/,\n/g')
            local existing_stories=$(sed -n '/"stories": \[/,/\]/p' "$parent_path" | grep -oE "$uuid_regex")
            stories_json=$(echo "$existing_stories" | sed 's/.*/    "&"/' | paste -sd "," - | sed 's/,/,\n/g')
        fi
        
        cat <<EOF > "$parent_path"
{
  "id": "$parent_uuid",
  "title": "$title",
  "slug": "$slug",
  "status": "$status",
  "description": "$description",
  "stories": [
${stories_json}
  ],
  "tasks": [
${tasks_json}
  ]
}
EOF
    else
        # Story parent
        tasks_json=$(echo "$all_uuids" | sed 's/.*/    "&"/' | paste -sd "," - | sed 's/,/,\n/g')
        cat <<EOF > "$parent_path"
{
  "id": "$parent_uuid",
  "title": "$title",
  "slug": "$slug",
  "status": "$status",
  "description": "$description",
  "tasks": [
${tasks_json}
  ]
}
EOF
    fi

    echo "Linked $child_type $child_uuid to $parent_type $parent_uuid"
}

task_status() {
    local id_or_slug=$1
    local new_status=$(echo "$2" | tr '[:lower:]' '[:upper:]')
    local task_path=$(resolve_task_path "$id_or_slug")

    if [ -z "$task_path" ]; then
        echo "Error: Task '$id_or_slug' not found."
        return 1
    fi

    if [[ ! "$new_status" =~ ^(OPEN|CLOSED|IN-PROGRESS|PLANNED|CANCELLED)$ ]]; then
        echo "Error: Status must be OPEN, CLOSED, IN-PROGRESS, PLANNED, or CANCELLED."
        return 1
    fi

    local task_uuid=$(get_json_val "id" "$task_path")
    sed -i '' "s/\"status\": \".*\"/\"status\": \"$new_status\"/" "$task_path"
    echo "Updated Task $task_uuid status to $new_status"
}

story_status() {
    local id_or_slug=$1
    local new_status=$(echo "$2" | tr '[:lower:]' '[:upper:]')
    local story_path=$(resolve_story_path "$id_or_slug")

    if [ -z "$story_path" ]; then
        echo "Error: Story '$id_or_slug' not found."
        return 1
    fi

    if [[ ! "$new_status" =~ ^(ACTIVE|CLOSED|PLANNED|COMPLETED|CANCELLED)$ ]]; then
        echo "Error: Status must be ACTIVE, CLOSED, PLANNED, COMPLETED, or CANCELLED."
        return 1
    fi

    local story_uuid=$(get_json_val "id" "$story_path")
    sed -i '' "s/\"status\": \".*\"/\"status\": \"$new_status\"/" "$story_path"
    echo "Updated Story $story_uuid status to $new_status"
}

milestone_status() {
    local id_or_slug=$1
    local new_status=$(echo "$2" | tr '[:lower:]' '[:upper:]')
    local milestone_path=$(get_milestone_path "$id_or_slug")

    if [ ! -f "$milestone_path" ]; then
        # Try finding by slug if uuid lookup fails (case-insensitive)
        local slug_match=$(grep -li "\"slug\": \"$id_or_slug\"" "$MILESTONES_DIR"/*.json 2>/dev/null | head -n 1)
        if [ -n "$slug_match" ]; then
            milestone_path="$slug_match"
        else
            echo "Error: Milestone '$id_or_slug' not found (UUID or Slug)."
            return 1
        fi
    fi

    if [[ ! "$new_status" =~ ^(ACTIVE|CLOSED|PLANNED|COMPLETED|CANCELLED)$ ]]; then
        echo "Error: Status must be ACTIVE, CLOSED, PLANNED, COMPLETED, or CANCELLED."
        return 1
    fi

    local milestone_uuid=$(get_json_val "id" "$milestone_path")
    
    # Update status
    sed -i '' "s/\"status\": \".*\"/\"status\": \"$new_status\"/" "$milestone_path"
    
    # Handle completed_at
    if [ "$new_status" == "COMPLETED" ]; then
        local ts=$(get_timestamp)
        if grep -q "\"completed_at\":" "$milestone_path"; then
            sed -i '' "s/\"completed_at\": \".*\"/\"completed_at\": \"$ts\"/" "$milestone_path"
        else
            # Insert before the last brace
            sed -i '' "s/}$/  ,\"completed_at\": \"$ts\"\n}/" "$milestone_path"
        fi
    fi

    echo "Updated Milestone $milestone_uuid status to $new_status"
}

view_task() {
    local id_or_slug=$1
    local task_path=$(resolve_task_path "$id_or_slug")

    if [ -z "$task_path" ]; then
        echo "Error: Task '$id_or_slug' not found."
        return 1
    fi

    # Colors
    local BOLD=$'\033[1m'
    local CYAN=$'\033[0;36m'
    local BLUE=$'\033[0;34m'
    local GREEN=$'\033[0;32m'
    local RED=$'\033[0;31m'
    local YELLOW=$'\033[0;33m'
    local GRAY=$'\033[1;30m'
    local RESET=$'\033[0m'

    echo -e "${CYAN}${BOLD}--------------------------------------------------------------------------------${RESET}"
    echo -e "${MAGENTA}${BOLD}                                     T A S K                                    ${RESET}"
    echo -e "${CYAN}${BOLD}--------------------------------------------------------------------------------${RESET}"

    local status=$(get_json_val "status" "$task_path" | tr '[:lower:]' '[:upper:]')
    local status_color=$RESET
    case "$status" in
        OPEN) status_color=$GREEN ;;
        IN-PROGRESS) status_color=$YELLOW ;;
        PLANNED) status_color=$CYAN ;;
        CLOSED) status_color=$RED ;;
        CANCELLED) status_color=$GRAY ;;
    esac

    local priority=$(get_json_val "priority" "$task_path" | tr '[:lower:]' '[:upper:]')
    local priority_color=$RESET
    case "$priority" in
        HIGH) priority_color=$RED ;;
        MEDIUM) priority_color=$YELLOW ;;
        LOW) priority_color=$CYAN ;;
    esac

    # Formatting helper for wrapping text
    wrap_text() {
        local label=$1
        local text=$2
        printf "${BLUE}${BOLD}%s:${RESET}\n" "$label"
        if [ -n "$text" ]; then
            echo "$text" | fold -s -w 80 | sed 's/^/  /'
        else
            echo "  (empty)"
        fi
    }

    printf "${BLUE}${BOLD}ID:${RESET}    %s\n" "$(get_json_val "id" "$task_path")"
    printf "${BLUE}${BOLD}SLUG:${RESET}  %s\n" "$(get_json_val "slug" "$task_path")"
    printf "${BLUE}${BOLD}TITLE:${RESET} ${BOLD}%s${RESET}\n" "$(get_json_val "title" "$task_path")"
    echo -e "${CYAN}--------------------------------------------------------------------------------${RESET}"
    printf "${BLUE}${BOLD}STATUS:${RESET}   ${status_color}%-10s${RESET} ${BLUE}${BOLD}PRIORITY:${RESET} ${priority_color}%s${RESET}\n" "$status" "$priority"
    printf "${BLUE}${BOLD}TYPE:${RESET}     %-10s ${BLUE}${BOLD}CREATED:${RESET}  %s\n" "$(get_json_val "type" "$task_path")" "$(get_json_val "created_at" "$task_path")"
    
    local plan_id=$(get_json_val "plan" "$task_path")
    local plan_display="none"
    if [ -n "$plan_id" ]; then
        local plan_path=$(get_plan_path "$plan_id")
        if [ -f "$plan_path" ]; then
            plan_display="$plan_id ($(get_json_val "slug" "$plan_path"))"
        else
            plan_display="$plan_id (FILE MISSING)"
        fi
    fi
    printf "${BLUE}${BOLD}PLAN:${RESET}     %s\n" "$plan_display"
    
    # Simple array extraction for view
    local tags=$(get_json_array "tags" "$task_path")
    local deps=$(get_json_array "depends_on" "$task_path")
    local acs=$(get_json_array "acceptance_criteria" "$task_path")
    local wt=$(get_json_array "work_tree" "$task_path")
    local notes=$(get_json_array "implementation_notes" "$task_path")
    
    printf "${BLUE}${BOLD}TAGS:${RESET}     %s\n" "${tags:-none}" | tr '\n' ' ' && echo ""
    printf "${BLUE}${BOLD}DEPENDS:${RESET}  %s\n" "${deps:-none}" | tr '\n' ' ' && echo ""
    echo -e "${CYAN}--------------------------------------------------------------------------------${RESET}"
    wrap_text "DESCRIPTION" "$(get_json_val "description" "$task_path")"
    echo ""
    printf "${BLUE}${BOLD}ACCEPTANCE CRITERIA:${RESET}\n"
    if [ -n "$acs" ]; then
        echo "$acs" | sed 's/^/  - /'
    else
        echo "  (none)"
    fi
    echo ""
    printf "${BLUE}${BOLD}WORK TREE:${RESET}\n"
    if [ -n "$wt" ]; then
        echo "$wt" | sed 's/^/  - /'
    else
        echo "  (none)"
    fi
    echo ""
    printf "${BLUE}${BOLD}IMPLEMENTATION NOTES:${RESET}\n"
    if [ -n "$notes" ]; then
        echo "$notes" | sed 's/^/  - /'
    else
        echo "  (none)"
    fi
    echo -e "${CYAN}--------------------------------------------------------------------------------${RESET}"
}

get_backlog_uuids() {
    local uuid_regex="[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    
    # Colors
    local BOLD=$'\033[1m'
    local BLUE=$'\033[0;34m'
    local CYAN=$'\033[0;36m'
    local YELLOW=$'\033[0;33m'
    local RESET=$'\033[0m'

    # 1. Find all Stories
    local all_stories=$(find "$STORIES_DIR" -name "*.json" -exec basename {} .json \;)
    # 2. Find Stories claimed by Milestones
    local claimed_stories=$(find "$MILESTONES_DIR" -name "*.json" -exec sed -n '/"stories": \[/,/\]/p' {} + | grep -oE "$uuid_regex" | sort -u)
    
    local backlog_stories=$(comm -23 <(echo "$all_stories" | sort) <(echo "$claimed_stories" | sort) | sed '/^$/d')

    if [ -n "$backlog_stories" ]; then
        echo -e "${BOLD}${YELLOW}=== Story Backlog (Unclaimed) ===${RESET}"
        for uuid in $(sort_uuids_by_slug "story" $backlog_stories); do
            local s_path=$(get_story_path "$uuid")
            local title=$(get_json_val "title" "$s_path")
            local slug=$(get_json_val "slug" "$s_path")
            echo -e "  ${BOLD}[$slug]${RESET} - ${BOLD}[$uuid]${RESET} - ${BLUE}$title${RESET}"
        done
        echo ""
    fi

    # 2. Tasks
    local all_tasks=$(find "$TASKS_DIR" -type f -name "*.json" | sed "s|.*/\([^/]*\)/\([^/]*\)\.json|\1\2|")
    local claimed_by_m=$(find "$MILESTONES_DIR" -name "*.json" -exec sed -n '/"tasks": \[/,/\]/p' {} + | grep -oE "$uuid_regex")
    local claimed_by_s=$(find "$STORIES_DIR" -name "*.json" -exec sed -n '/"tasks": \[/,/\]/p' {} + | grep -oE "$uuid_regex")
    local all_claimed_tasks=$( (echo "$claimed_by_m"; echo "$claimed_by_s") | sed '/^$/d' | sort -u)

    local backlog_tasks=$(comm -23 <(echo "$all_tasks" | sort) <(echo "$all_claimed_tasks" | sort) | sed '/^$/d')

    if [ -n "$backlog_tasks" ]; then
        echo -e "${BOLD}${YELLOW}=== Task Backlog (Unclaimed) ===${RESET}"
        for uuid in $(sort_uuids_by_slug "task" $backlog_tasks); do
            local t_path=$(get_task_path "$uuid")
            local title=$(get_json_val "title" "$t_path")
            local slug=$(get_json_val "slug" "$t_path")
            echo -e "  ${BOLD}[$slug]${RESET} - ${BOLD}[$uuid]${RESET} - ${BLUE}$title${RESET}"
        done
        echo ""
    fi

    # 3. Plans
    local all_plans=$(find "$PLANS_DIR" -type f -name "*.md" | sed "s|.*/\([^/]*\)/\([^/]*\)\.md|\1\2|")
    local linked_plans=$(find "$TASKS_DIR" -type f -name "*.json" -exec grep -oE "\"plan\": \"$uuid_regex\"" {} + | grep -oE "$uuid_regex" | sort -u)
    local backlog_plans=$(comm -23 <(echo "$all_plans" | sort) <(echo "$linked_plans" | sort) | sed '/^$/d')

    if [ -n "$backlog_plans" ]; then
        echo -e "${BOLD}${YELLOW}=== Plan Backlog (Unlinked) ===${RESET}"
        for uuid in $(sort_uuids_by_slug "plan" $backlog_plans); do
            local p_path=$(get_plan_path "$uuid")
            local title=$(get_json_val "title" "$p_path")
            local slug=$(get_json_val "slug" "$p_path")
            echo -e "  ${BOLD}[$slug]${RESET} - ${BOLD}[$uuid]${RESET} - ${BLUE}$title${RESET}"
        done
        echo ""
    fi

    if [ -z "$backlog_stories" ] && [ -z "$backlog_tasks" ] && [ -z "$backlog_plans" ]; then
        echo "Backlog is empty."
    fi
}

generate_changelog() {
    local out_dir="${1:-.}"
    # Remove trailing slash if present
    out_dir="${out_dir%/}"
    local changelog_file="$out_dir/CHANGELOG.md"
    local uuid_regex="[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    
    # Ensure directory exists
    mkdir -p "$out_dir"
    
    cat <<EOF > "$changelog_file"
# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

EOF

    local handled_uuids=""

    is_handled() {
        echo "$handled_uuids" | grep -q "$1"
    }

    mark_handled() {
        handled_uuids="$handled_uuids $1"
    }

    # Helper variables for grouping
    local added=""
    local fixed=""
    local changed=""

    process_task() {
        local t_uuid=$1
        local t_path=$(get_task_path "$t_uuid")
        local t_status=$(get_json_val "status" "$t_path" | tr '[:lower:]' '[:upper:]')
        if [ -f "$t_path" ] && [ "$t_status" == "CLOSED" ]; then
            local t_title=$(get_json_val "title" "$t_path")
            local t_slug=$(get_json_val "slug" "$t_path")
            local t_type=$(get_json_val "type" "$t_path" | tr '[:lower:]' '[:upper:]')
            local line="- [TASK: $t_slug] - $t_title"
            
            case "$t_type" in
                FEAT|FEATURE|ADD) added="$added\n$line" ;;
                FIX|BUG|HOTFIX) fixed="$fixed\n$line" ;;
                *) changed="$changed\n$line" ;;
            esac
            mark_handled "$t_uuid"
        fi
    }

    # --- 1. Completed Milestones (Releases) ---
    local completed_milestones=$(grep -l "\"status\": \"COMPLETED\"" "$MILESTONES_DIR"/*.json 2>/dev/null | sed 's|.*/||; s/\.json$//')
    
    # Sort milestones by completed_at descending (newest first)
    local sorted_milestones=""
    if [ -n "$completed_milestones" ]; then
        sorted_milestones=$(for m_uuid in $completed_milestones; do
            local m_file=$(get_milestone_path "$m_uuid")
            local c_at=$(get_json_val "completed_at" "$m_file")
            echo "$c_at $m_uuid"
        done | sort -r | cut -d' ' -f2)
    fi

    for m_uuid in $sorted_milestones; do
        local m_file=$(get_milestone_path "$m_uuid")
        local m_title=$(get_json_val "title" "$m_file")
        local m_date=$(get_json_val "completed_at" "$m_file" | cut -d'T' -f1)
        [ -z "$m_date" ] && m_date="YYYY-MM-DD"

        echo "## [$m_title] - $m_date" >> "$changelog_file"
        echo "" >> "$changelog_file"
        
        added=""
        fixed=""
        changed=""

        # Stories in this Milestone
        local s_uuids=$(sed -n '/"stories": \[/,/\]/p' "$m_file" | grep -oE "$uuid_regex")
        if [ -n "$s_uuids" ]; then
             for s_uuid in $(sort_uuids_by_slug "story" $s_uuids); do
                 local s_path=$(get_story_path "$s_uuid")
                 local s_status=$(get_json_val "status" "$s_path" | tr '[:lower:]' '[:upper:]')
                 if [ -f "$s_path" ] && [ "$s_status" == "COMPLETED" ]; then
                     mark_handled "$s_uuid"
                     local st_uuids=$(sed -n '/"tasks": \[/,/\]/p' "$s_path" | grep -oE "$uuid_regex")
                     for t_uuid in $st_uuids; do process_task "$t_uuid"; done
                 fi
             done
        fi
        
        # Direct Tasks in this Milestone
        local t_uuids=$(sed -n '/"tasks": \[/,/\]/p' "$m_file" | grep -oE "$uuid_regex")
        for t_uuid in $t_uuids; do process_task "$t_uuid"; done

        if [ -n "$added" ]; then
            echo "### Added" >> "$changelog_file"
            echo -e "$added" | sed '/^$/d' >> "$changelog_file"
            echo "" >> "$changelog_file"
        fi
        if [ -n "$fixed" ]; then
            echo "### Fixed" >> "$changelog_file"
            echo -e "$fixed" | sed '/^$/d' >> "$changelog_file"
            echo "" >> "$changelog_file"
        fi
        if [ -n "$changed" ]; then
            echo "### Changed" >> "$changelog_file"
            echo -e "$changed" | sed '/^$/d' >> "$changelog_file"
            echo "" >> "$changelog_file"
        fi
    done

    # --- 2. Unreleased Section ---
    added=""
    fixed=""
    changed=""

    # Standalone Stories
    local all_completed_stories=$(grep -li "\"status\": \"COMPLETED\"" "$STORIES_DIR"/*.json 2>/dev/null | sed 's|.*/||; s/\.json$//')
    for s_uuid in $all_completed_stories; do
        if ! is_handled "$s_uuid"; then
             local s_path=$(get_story_path "$s_uuid")
             local st_uuids=$(sed -n '/"tasks": \[/,/\]/p' "$s_path" | grep -oE "$uuid_regex")
             for t_uuid in $st_uuids; do process_task "$t_uuid"; done
             mark_handled "$s_uuid"
        fi
    done

    # Standalone Tasks
    local all_closed_tasks=$(find "$TASKS_DIR" -type f -name "*.json" -exec grep -li "\"status\": \"CLOSED\"" {} + | sed "s|.*/\([^/]*\)/\([^/]*\)\.json|\1\2|")
    for t_uuid in $all_closed_tasks; do
        if ! is_handled "$t_uuid"; then
            process_task "$t_uuid"
        fi
    done

    if [ -n "$added" ] || [ -n "$fixed" ] || [ -n "$changed" ]; then
        echo "## [Unreleased]" >> "$changelog_file"
        echo "" >> "$changelog_file"
        if [ -n "$added" ]; then
            echo "### Added" >> "$changelog_file"
            echo -e "$added" | sed '/^$/d' >> "$changelog_file"
            echo "" >> "$changelog_file"
        fi
        if [ -n "$fixed" ]; then
            echo "### Fixed" >> "$changelog_file"
            echo -e "$fixed" | sed '/^$/d' >> "$changelog_file"
            echo "" >> "$changelog_file"
        fi
        if [ -n "$changed" ]; then
            echo "### Changed" >> "$changelog_file"
            echo -e "$changed" | sed '/^$/d' >> "$changelog_file"
            echo "" >> "$changelog_file"
        fi
    fi

    echo "Generated $changelog_file successfully."
}

show_dashboard() {
    local mode=$1
    local target=$2
    local uuid_regex="[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    
    # Colors
    local BOLD=$'\033[1m'
    local CYAN=$'\033[0;36m'
    local BLUE=$'\033[0;34m'
    local GREEN=$'\033[0;32m'
    local RED=$'\033[0;31m'
    local YELLOW=$'\033[0;33m'
    local MAGENTA=$'\033[0;35m'
    local GRAY=$'\033[1;30m'
    local RESET=$'\033[0m'

    echo -e "${BOLD}${CYAN}=== Project Dashboard ===${RESET}"
    
    local milestone_files=""
    if [ "$mode" == "milestone" ] && [ -n "$target" ]; then
        # Resolve target milestone
        local m_path=""
        if [ -f "$MILESTONES_DIR/$target.json" ]; then
            m_path="$MILESTONES_DIR/$target.json"
        else
            # Case-insensitive slug search
            m_path=$(grep -li "\"slug\": \"$target\"" "$MILESTONES_DIR"/*.json 2>/dev/null | head -n 1)
        fi
        
        if [ -z "$m_path" ]; then
            echo "Error: Milestone '$target' not found."
            return 1
        fi
        milestone_files="$m_path"
    else
        milestone_files=$(for f in "$MILESTONES_DIR"/*.json; do
            [ -e "$f" ] || continue
            echo "$(get_json_val "slug" "$f") $f"
        done | sort -V | cut -d' ' -f2-)
    fi

    for milestone_file in $milestone_files; do
        [ -e "$milestone_file" ] || continue
        local m_id=$(get_json_val "id" "$milestone_file")
        local m_title=$(get_json_val "title" "$milestone_file")
        local m_slug=$(get_json_val "slug" "$milestone_file")
        local m_status=$(get_json_val "status" "$milestone_file" | tr '[:lower:]' '[:upper:]')
        
        local m_status_color=$RESET
        case "$m_status" in
            ACTIVE) m_status_color=$GREEN ;;
            PLANNED) m_status_color=$CYAN ;;
            CLOSED) m_status_color=$RED ;;
            COMPLETED) m_status_color=$MAGENTA ;;
            CANCELLED) m_status_color=$GRAY ;;
        esac

        echo -e "\n${BOLD}${BLUE}Milestone:${RESET} ${BOLD}[$m_slug]${RESET} - ${BOLD}[$m_id]${RESET} - ${BOLD}$m_title${RESET} - ${m_status_color}$m_status${RESET}"
        
        # --- Stories under Milestone ---
        local story_uuids=$(sed -n '/"stories": \[/,/\]/p' "$milestone_file" | grep -oE "$uuid_regex")
        for s_uuid in $(sort_uuids_by_slug "story" $story_uuids); do
            local s_path=$(get_story_path "$s_uuid")
            if [ -f "$s_path" ]; then
                local s_title=$(get_json_val "title" "$s_path")
                local s_status=$(get_json_val "status" "$s_path" | tr '[:lower:]' '[:upper:]')
                local s_slug=$(get_json_val "slug" "$s_path")
                
                local s_status_color=$RESET
                case "$s_status" in
                    ACTIVE) s_status_color=$GREEN ;;
                    PLANNED) s_status_color=$CYAN ;;
                    CLOSED) s_status_color=$RED ;;
                    COMPLETED) s_status_color=$MAGENTA ;;
                    CANCELLED) s_status_color=$GRAY ;;
                esac
                
                echo -e "  ${BOLD}${YELLOW}Story:${RESET} [${s_slug}] - [${s_uuid}] - $s_title - ${s_status_color}$s_status${RESET}"
                
                # --- Tasks under Story (only if not in 'stories' mode) ---
                if [ "$mode" != "stories" ]; then
                    local t_uuids=$(sed -n '/"tasks": \[/,/\]/p' "$s_path" | grep -oE "$uuid_regex")
                    for t_uuid in $(sort_uuids_by_slug "task" $t_uuids); do
                        local t_path=$(get_task_path "$t_uuid")
                        if [ -f "$t_path" ]; then
                            local t_title=$(get_json_val "title" "$t_path")
                            local t_status=$(get_json_val "status" "$t_path" | tr '[:lower:]' '[:upper:]')
                            
                            local t_slug=$(get_json_val "slug" "$t_path")
                            local t_status_color=$RESET
                            case "$t_status" in
                                OPEN) t_status_color=$GREEN ;;
                                IN-PROGRESS) t_status_color=$YELLOW ;;
                                PLANNED) t_status_color=$CYAN ;;
                                CLOSED) t_status_color=$RED ;;
                                CANCELLED) t_status_color=$GRAY ;;
                            esac
                            echo -e "    ${BOLD}[$t_slug]${RESET} - ${BOLD}[$t_uuid]${RESET} - ${BLUE}$t_title${RESET} - ${t_status_color}$t_status${RESET}"
                        fi
                    done
                fi
            fi
        done

        # --- Tasks under Milestone (only if not in 'stories' mode) ---
        if [ "$mode" != "stories" ]; then
            local direct_task_uuids=$(sed -n '/"tasks": \[/,/\]/p' "$milestone_file" | grep -oE "$uuid_regex")
            if [ -n "$direct_task_uuids" ]; then
                echo -e "  ${BOLD}${YELLOW}Tasks:${RESET}"
                for t_uuid in $(sort_uuids_by_slug "task" $direct_task_uuids); do
                    local t_path=$(get_task_path "$t_uuid")
                    if [ -f "$t_path" ]; then
                        local t_title=$(get_json_val "title" "$t_path")
                        local t_status=$(get_json_val "status" "$t_path" | tr '[:lower:]' '[:upper:]')
                        
                        local t_slug=$(get_json_val "slug" "$t_path")
                        local t_status_color=$RESET
                        case "$t_status" in
                            OPEN) t_status_color=$GREEN ;;
                            IN-PROGRESS) t_status_color=$YELLOW ;;
                            PLANNED) t_status_color=$CYAN ;;
                            CLOSED) t_status_color=$RED ;;
                            CANCELLED) t_status_color=$GRAY ;;
                        esac
                        echo -e "    ${BOLD}[$t_slug]${RESET} - ${BOLD}[$t_uuid]${RESET} - ${BLUE}$t_title${RESET} - ${t_status_color}$t_status${RESET}"
                    fi
                done
            fi
        fi
    done

    # --- Backlog summary (only in full mode) ---
    if [ -z "$mode" ]; then
        local all_stories=$(find "$STORIES_DIR" -name "*.json" -exec basename {} .json \;)
        local claimed_stories=$(find "$MILESTONES_DIR" -name "*.json" -exec sed -n '/"stories": \[/,/\]/p' {} + | grep -oE "$uuid_regex" | sort -u)
        local backlog_stories=$(comm -23 <(echo "$all_stories" | sort) <(echo "$claimed_stories" | sort) | sed '/^$/d')

        local all_tasks=$(find "$TASKS_DIR" -type f -name "*.json" | sed "s|.*/\([^/]*\)/\([^/]*\)\.json|\1\2|")
        local claimed_by_m=$(find "$MILESTONES_DIR" -name "*.json" -exec sed -n '/"tasks": \[/,/\]/p' {} + | grep -oE "$uuid_regex")
        local claimed_by_s=$(find "$STORIES_DIR" -name "*.json" -exec sed -n '/"tasks": \[/,/\]/p' {} + | grep -oE "$uuid_regex")
        local all_claimed_tasks=$( (echo "$claimed_by_m"; echo "$claimed_by_s") | sed '/^$/d' | sort -u)
        local backlog_tasks=$(comm -23 <(echo "$all_tasks" | sort) <(echo "$all_claimed_tasks" | sort) | sed '/^$/d')

        local all_plans=$(find "$PLANS_DIR" -type f -name "*.md" | sed "s|.*/\([^/]*\)/\([^/]*\)\.md|\1\2|")
        local linked_plans=$(find "$TASKS_DIR" -type f -name "*.json" -exec grep -oE "\"plan\": \"$uuid_regex\"" {} + | grep -oE "$uuid_regex" | sort -u)
        local backlog_plans=$(comm -23 <(echo "$all_plans" | sort) <(echo "$linked_plans" | sort) | sed '/^$/d')

        if [ -n "$backlog_stories" ] || [ -n "$backlog_tasks" ] || [ -n "$backlog_plans" ]; then
            echo -e "\n${BOLD}${RED}--- BACKLOG ---${RESET}"
            if [ -n "$backlog_stories" ]; then
                echo -e "${BOLD}Unclaimed Stories:${RESET}"
                for uuid in $(sort_uuids_by_slug "story" $backlog_stories); do
                    local s_path=$(get_story_path "$uuid")
                    local s_title=$(get_json_val "title" "$s_path")
                    local s_slug=$(get_json_val "slug" "$s_path")
                    echo -e "  - [$s_slug] - [$uuid] - $s_title"
                done
            fi
            if [ -n "$backlog_tasks" ]; then
                echo -e "${BOLD}Unclaimed Tasks:${RESET}"
                for uuid in $(sort_uuids_by_slug "task" $backlog_tasks); do
                    local t_path=$(get_task_path "$uuid")
                    local t_title=$(get_json_val "title" "$t_path")
                    local t_slug=$(get_json_val "slug" "$t_path")
                    echo -e "  - [$t_slug] - [$uuid] - $t_title"
                done
            fi
            if [ -n "$backlog_plans" ]; then
                echo -e "${BOLD}Unclaimed Plans:${RESET}"
                for uuid in $(sort_uuids_by_slug "plan" $backlog_plans); do
                    local p_path=$(get_plan_path "$uuid")
                    local p_title=$(get_json_val "title" "$p_path")
                    local p_slug=$(get_json_val "slug" "$p_path")
                    echo -e "  - [$p_slug] - [$uuid] - $p_title"
                done
            fi
        fi
    fi
}

# --- CLI DISPATCHER ---

case "$1" in
    task-create)
        create_task "$2" "$3" "$4" "$5"
        ;;
    task-edit)
        edit_task "$2"
        ;;
    task-status)
        task_status "$2" "$3"
        ;;
    task-view)
        view_task "$2"
        ;;
    milestone-create)
        create_milestone "$2" "$3"
        ;;
    milestone-edit)
        edit_milestone "$2"
        ;;
    milestone-status)
        milestone_status "$2" "$3"
        ;;
    milestone-view)
        view_milestone "$2"
        ;;
    story-create)
        create_story "$2" "$3"
        ;;
    story-edit)
        edit_story "$2"
        ;;
    story-status)
        story_status "$2" "$3"
        ;;
    story-view)
        view_story "$2"
        ;;
    plan-create)
        create_plan "$2" "$3"
        ;;
    plan-edit)
        edit_plan "$2"
        ;;
    plan-view)
        view_plan "$2"
        ;;
    link)
        link_entities "$2" "$3"
        ;;
    backlog)
        get_backlog_uuids
        ;;
    dashboard)
        show_dashboard "$2" "$3"
        ;;
    changelog)
        generate_changelog "$2"
        ;;
    *)
        echo "Git-first Metadata Engine"
        echo "Usage: $0 {task-create|task-edit|task-status|task-view|milestone-create|milestone-edit|milestone-status|milestone-view|story-create|story-edit|story-status|story-view|plan-create|plan-edit|plan-view|link|backlog|dashboard|changelog}"
        echo ""
        echo "  task-create \"Title\" \"slug\" \"priority\" \"type\""
        echo "  task-edit   \"uuid_or_slug\""
        echo "  task-status \"uuid_or_slug\" \"OPEN|CLOSED|IN-PROGRESS|PLANNED|CANCELLED\""
        echo "  task-view   \"uuid_or_slug\""
        echo "  milestone-create \"Title\" \"slug\""
        echo "  milestone-edit   \"uuid_or_slug\""
        echo "  milestone-status \"uuid_or_slug\" \"ACTIVE|CLOSED|PLANNED|COMPLETED|CANCELLED\""
        echo "  milestone-view   \"uuid_or_slug\""
        echo "  story-create \"Title\" \"slug\""
        echo "  story-edit   \"uuid_or_slug\""
        echo "  story-status \"uuid_or_slug\" \"ACTIVE|CLOSED|PLANNED|COMPLETED|CANCELLED\""
        echo "  story-view   \"uuid_or_slug\""
        echo "  plan-create  \"Title\" \"slug\""
        echo "  plan-edit    \"uuid_or_slug\""
        echo "  plan-view    \"uuid_or_slug\""
        echo "  link \"child_uuid_or_slug\" \"parent_uuid_or_slug\""
        echo "  backlog"
        echo "  dashboard [stories | milestone <id_or_slug>]"
        echo "  changelog [output_directory]"
        ;;
esac
