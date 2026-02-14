# executor_chargen.sh — Character creation & level-up helpers
#
# Sourced by executor.sh. Depends on: cmd, py, field, context, last_debug,
# wait_idle, wait_tick_advance, wait_context, wait_context_prefix,
# _dbg, _dbg_ts, _dbg_start, _dbg_end, _end_status, GAME_DIR, STATE, CMD.

# ─── Editor Status ───────────────────────────────────────────────────

editor_status() {
    # Print comprehensive editor state summary, adapted to creation vs level-up.
    local _ds=$(_dbg_ts)
    _dbg_start "editor_status" ""

    local ctx=$(context)
    if [ "$ctx" != "character_editor" ]; then
        echo "ERROR: Not in character editor (context=$ctx)"
        _dbg_end "editor_status" "wrong_context" "$_ds"
        return 1
    fi

    py '''
import json

ch = d.get("character", {})
is_creation = ch.get("is_creation_mode", True)
mode = "creation" if is_creation else "level-up"

print(f"=== CHARACTER EDITOR ({mode}) ===")

# Name
name = ch.get("name", "None")
print(f"Name: {name}")

# Level/XP (level-up only)
if not is_creation:
    lvl = ch.get("level", "?")
    xp = ch.get("experience", "?")
    print(f"Level: {lvl} | XP: {xp}")

# SPECIAL
sp = ch.get("special", {})
rem_pts = ch.get("remaining_points", 0)
stats_str = " ".join(f"{k[0].upper()}:{v}" for k, v in [
    ("strength", sp.get("strength", 5)),
    ("perception", sp.get("perception", 5)),
    ("endurance", sp.get("endurance", 5)),
    ("charisma", sp.get("charisma", 5)),
    ("intelligence", sp.get("intelligence", 5)),
    ("agility", sp.get("agility", 5)),
    ("luck", sp.get("luck", 5)),
])
pts_note = f" ({rem_pts} pts remaining)" if is_creation and rem_pts > 0 else ""
print(f"SPECIAL: {stats_str}{pts_note}")

# Traits
traits = ch.get("traits", [])
traits_str = ", ".join(traits) if traits else "(none selected)"
if is_creation:
    slots = 2 - len(traits)
    print(f"Traits ({slots} slot{'s' if slots != 1 else ''} remaining): {traits_str}")
else:
    print(f"Traits: {traits_str}")

# Tagged skills
tagged = ch.get("tagged_skills", [])
tagged_set = set(tagged)
tagged_str = ", ".join(tagged) if tagged else "(none selected)"
if is_creation:
    tag_rem = ch.get("tagged_skills_remaining", 0)
    print(f"Tagged Skills ({tag_rem} remaining): {tagged_str}")
else:
    print(f"Tagged Skills: {tagged_str}")

# Unspent skill points (level-up)
usp = ch.get("unspent_skill_points", 0)
if not is_creation and usp > 0:
    print(f"Unspent Skill Points: {usp}")

# Skills — sorted by value, tagged marked with *
skills = ch.get("skills", {})
if skills:
    sorted_skills = sorted(skills.items(), key=lambda x: -x[1])
    skill_parts = []
    for sname, sval in sorted_skills:
        tag_mark = "*" if sname in tagged_set else ""
        skill_parts.append(f"{sname}:{sval}{tag_mark}")
    print(f"Skills: {' '.join(skill_parts)}")
    if tagged_set:
        print("  (* = tagged, gains 2 pts per click)")

# Derived stats
ds = ch.get("derived_stats", {})
if ds:
    derived_parts = [
        f"HP:{ds.get('max_hp','?')}",
        f"AP:{ds.get('max_ap','?')}",
        f"AC:{ds.get('armor_class','?')}",
        f"Melee:{ds.get('melee_damage','?')}",
        f"Carry:{ds.get('carry_weight','?')}",
        f"Seq:{ds.get('sequence','?')}",
        f"Heal:{ds.get('healing_rate','?')}",
        f"Crit:{ds.get('critical_chance','?')}%",
    ]
    print(f"Derived: {' '.join(derived_parts)}")

# Current perks (level-up)
perks = ch.get("perks", [])
if perks:
    perk_parts = [f"{p['name']} (rank {p['rank']})" for p in perks]
    print(f"Current Perks: {', '.join(perk_parts)}")

# Available perks
avail_perks = ch.get("available_perks", [])
if avail_perks:
    perk_list = [f"{p['name']} (id={p['id']})" for p in avail_perks[:15]]
    suffix = f" ... +{len(avail_perks)-15} more" if len(avail_perks) > 15 else ""
    print(f"Available Perks: {', '.join(perk_list)}{suffix}")

# Karma and town reps (level-up, if available)
karma = ch.get("karma", 0)
town_reps = ch.get("town_reputations", {})
if not is_creation and (karma != 0 or town_reps):
    rep_parts = [f"{k}:{v}" for k, v in town_reps.items()]
    rep_str = ", ".join(rep_parts) if rep_parts else ""
    parts = []
    if karma != 0:
        parts.append(f"Karma: {karma}")
    if rep_str:
        parts.append(f"Reps: {rep_str}")
    print(" | ".join(parts))

# Kill counts
kills = ch.get("kill_counts", {})
if kills:
    kill_parts = [f"{k}:{v}" for k, v in kills.items()]
    print(f"Kills: {', '.join(kill_parts)}")
'''
    _dbg_end "editor_status" "ok" "$_ds"
}

# ─── Set SPECIAL ─────────────────────────────────────────────────────

set_special() {
    # Set all SPECIAL stats at once (creation mode only).
    # Usage: set_special S P E C I A L
    local _ds=$(_dbg_ts)
    _dbg_start "set_special" "$*"

    if [ $# -ne 7 ]; then
        echo "Usage: set_special S P E C I A L  (e.g., set_special 8 5 8 3 5 8 3)"
        _dbg_end "set_special" "bad_args" "$_ds"
        return 1
    fi

    local ctx=$(context)
    if [ "$ctx" != "character_editor" ]; then
        echo "ERROR: Not in character editor (context=$ctx)"
        _dbg_end "set_special" "wrong_context" "$_ds"
        return 1
    fi

    local targets=("$@")
    local stat_names=("strength" "perception" "endurance" "charisma" "intelligence" "agility" "luck")

    # Validate range
    for i in {1..7}; do
        local v="${targets[$i]}"
        if [ "$v" -lt 1 ] || [ "$v" -gt 10 ] 2>/dev/null; then
            echo "ERROR: All stats must be 1-10 (got $v for ${stat_names[$i]})"
            _dbg_end "set_special" "invalid_range" "$_ds"
            return 1
        fi
    done

    # Read current values and remaining points
    local current=$(py '''
ch = d.get("character", {})
sp = ch.get("special", {})
rem = ch.get("remaining_points", 0)
vals = [sp.get("strength",5), sp.get("perception",5), sp.get("endurance",5),
        sp.get("charisma",5), sp.get("intelligence",5), sp.get("agility",5), sp.get("luck",5)]
print(str(rem) + "\t" + "\t".join(str(v) for v in vals))
''')

    local rem_pts="${current%%	*}"
    local cur_vals_str="${current#*	}"

    # Calculate and validate total delta
    local total_delta=0
    local cur_arr=()
    IFS=$'\t' read -rA cur_arr <<< "$cur_vals_str"

    for i in {1..7}; do
        local delta=$(( targets[$i] - cur_arr[$i] ))
        total_delta=$(( total_delta + delta ))
    done

    if [ "$total_delta" -ne 0 ]; then
        local avail=$(( rem_pts - total_delta ))
        if [ "$avail" -ne 0 ]; then
            echo "ERROR: Point mismatch. Remaining: $rem_pts, net delta: $total_delta (must equal remaining points)"
            echo "Current: S:${cur_arr[1]} P:${cur_arr[2]} E:${cur_arr[3]} C:${cur_arr[4]} I:${cur_arr[5]} A:${cur_arr[6]} L:${cur_arr[7]}"
            _dbg_end "set_special" "point_mismatch" "$_ds"
            return 1
        fi
    fi

    # Issue adjust_stat commands in batches
    local cmds_issued=0
    for i in {1..7}; do
        local delta=$(( targets[$i] - cur_arr[$i] ))
        if [ "$delta" -eq 0 ]; then continue; fi

        local direction="up"
        local count="$delta"
        if [ "$delta" -lt 0 ]; then
            direction="down"
            count=$(( -delta ))
        fi

        local batch=""
        for j in $(seq 1 $count); do
            if [ -n "$batch" ]; then batch="$batch,"; fi
            batch="$batch{\"type\":\"adjust_stat\",\"stat\":\"${stat_names[$i]}\",\"direction\":\"$direction\"}"
            cmds_issued=$(( cmds_issued + 1 ))

            # Batch of 6 commands then flush
            if [ $(( cmds_issued % 6 )) -eq 0 ]; then
                send "{\"commands\":[$batch]}"
                wait_tick_advance 10
                batch=""
            fi
        done

        # Flush remaining
        if [ -n "$batch" ]; then
            send "{\"commands\":[$batch]}"
            wait_tick_advance 10
            batch=""
        fi
    done

    # Verify
    sleep 0.3
    local final=$(py '''
ch = d.get("character", {})
sp = ch.get("special", {})
rem = ch.get("remaining_points", 0)
print(f"S:{sp.get('strength',0)} P:{sp.get('perception',0)} E:{sp.get('endurance',0)} C:{sp.get('charisma',0)} I:{sp.get('intelligence',0)} A:{sp.get('agility',0)} L:{sp.get('luck',0)} (remaining: {rem})")
''')
    echo "SPECIAL set: $final"
    _dbg_end "set_special" "ok" "$_ds"
}

# ─── Set Traits ──────────────────────────────────────────────────────

set_traits() {
    # Set traits (creation mode only).
    # Usage: set_traits heavy_handed fast_shot
    #        set_traits gifted
    #        set_traits none
    local _ds=$(_dbg_ts)
    _dbg_start "set_traits" "$*"

    if [ $# -lt 1 ]; then
        echo "Usage: set_traits trait1 [trait2]   or   set_traits none"
        _dbg_end "set_traits" "bad_args" "$_ds"
        return 1
    fi

    local ctx=$(context)
    if [ "$ctx" != "character_editor" ]; then
        echo "ERROR: Not in character editor (context=$ctx)"
        _dbg_end "set_traits" "wrong_context" "$_ds"
        return 1
    fi

    # Build target list (deduplicate via zsh -U flag)
    local -aU target_traits=()
    if [ "$1" != "none" ]; then
        target_traits=("$@")
    fi

    if [ ${#target_traits[@]} -gt 2 ]; then
        echo "ERROR: Maximum 2 traits allowed"
        _dbg_end "set_traits" "too_many" "$_ds"
        return 1
    fi

    # Read current traits
    local current_traits=$(py '''
traits = d.get("character", {}).get("traits", [])
print("\t".join(traits) if traits else "")
''')

    local -a cur=()
    if [ -n "$current_traits" ]; then
        IFS=$'\t' read -rA cur <<< "$current_traits"
    fi

    # Toggle OFF traits not in target list first
    for trait in "${cur[@]}"; do
        local found=false
        for target in "${target_traits[@]}"; do
            if [ "$trait" = "$target" ]; then found=true; break; fi
        done
        if ! $found; then
            cmd "{\"type\":\"toggle_trait\",\"trait\":\"$trait\"}"
            wait_tick_advance 10
        fi
    done

    # Toggle ON traits in target list that aren't already selected
    for target in "${target_traits[@]}"; do
        local found=false
        for trait in "${cur[@]}"; do
            if [ "$trait" = "$target" ]; then found=true; break; fi
        done
        if ! $found; then
            cmd "{\"type\":\"toggle_trait\",\"trait\":\"$target\"}"
            wait_tick_advance 10
        fi
    done

    # Verify
    sleep 0.3
    local final=$(py '''
traits = d.get("character", {}).get("traits", [])
print(", ".join(traits) if traits else "(none)")
''')
    echo "Traits: $final"
    _dbg_end "set_traits" "ok" "$_ds"
}

# ─── Tag Skills ──────────────────────────────────────────────────────

tag_skills() {
    # Tag skills (creation mode only).
    # Usage: tag_skills unarmed lockpick doctor
    local _ds=$(_dbg_ts)
    _dbg_start "tag_skills" "$*"

    if [ $# -lt 1 ]; then
        echo "Usage: tag_skills skill1 skill2 skill3"
        _dbg_end "tag_skills" "bad_args" "$_ds"
        return 1
    fi

    local ctx=$(context)
    if [ "$ctx" != "character_editor" ]; then
        echo "ERROR: Not in character editor (context=$ctx)"
        _dbg_end "tag_skills" "wrong_context" "$_ds"
        return 1
    fi

    # Deduplicate via zsh -U flag
    local -aU target_skills=("$@")

    # Read current tagged skills
    local current_tags=$(py '''
tagged = d.get("character", {}).get("tagged_skills", [])
print("\t".join(tagged) if tagged else "")
''')

    local -a cur=()
    if [ -n "$current_tags" ]; then
        IFS=$'\t' read -rA cur <<< "$current_tags"
    fi

    # Toggle OFF skills not in target list first
    for skill in "${cur[@]}"; do
        local found=false
        for target in "${target_skills[@]}"; do
            if [ "$skill" = "$target" ]; then found=true; break; fi
        done
        if ! $found; then
            cmd "{\"type\":\"toggle_skill_tag\",\"skill\":\"$skill\"}"
            wait_tick_advance 10
        fi
    done

    # Toggle ON target skills not already tagged
    for target in "${target_skills[@]}"; do
        local found=false
        for skill in "${cur[@]}"; do
            if [ "$skill" = "$target" ]; then found=true; break; fi
        done
        if ! $found; then
            cmd "{\"type\":\"toggle_skill_tag\",\"skill\":\"$target\"}"
            wait_tick_advance 10
        fi
    done

    # Verify
    sleep 0.3
    local final=$(py '''
ch = d.get("character", {})
tagged = ch.get("tagged_skills", [])
rem = ch.get("tagged_skills_remaining", 0)
print(f"{', '.join(tagged)} (remaining: {rem})")
''')
    echo "Tagged: $final"
    _dbg_end "tag_skills" "ok" "$_ds"
}

# ─── Add Skills ──────────────────────────────────────────────────────

add_skills() {
    # Distribute skill points in bulk (level-up).
    # Usage: add_skills lockpick=10 small_guns=5 doctor=3
    local _ds=$(_dbg_ts)
    _dbg_start "add_skills" "$*"

    if [ $# -lt 1 ]; then
        echo "Usage: add_skills skill=N [skill=N ...]"
        _dbg_end "add_skills" "bad_args" "$_ds"
        return 1
    fi

    local ctx=$(context)
    if [ "$ctx" != "character_editor" ]; then
        echo "ERROR: Not in character editor (context=$ctx)"
        _dbg_end "add_skills" "wrong_context" "$_ds"
        return 1
    fi

    local total_usp=$(field "character.unspent_skill_points")
    echo "Starting skill points: $total_usp"

    for arg in "$@"; do
        local skill="${arg%%=*}"
        local count="${arg##*=}"

        if [ -z "$skill" ] || [ -z "$count" ] || [ "$count" -le 0 ] 2>/dev/null; then
            echo "  SKIP: invalid arg '$arg' (format: skill=N)"
            continue
        fi

        local start_val=$(py "print(d.get('character',{}).get('skills',{}).get('$skill','?'))")
        local applied=0
        local batch=""
        local batch_size=0

        for i in $(seq 1 $count); do
            if [ -n "$batch" ]; then batch="$batch,"; fi
            batch="$batch{\"type\":\"skill_add\",\"skill\":\"$skill\"}"
            batch_size=$(( batch_size + 1 ))

            # Flush every 5 commands
            if [ $batch_size -ge 5 ]; then
                send "{\"commands\":[$batch]}"
                wait_tick_advance 10
                batch=""
                batch_size=0
                applied=$(( applied + 5 ))

                # Check if we ran out of points
                local cur_usp=$(field "character.unspent_skill_points")
                if [ "$cur_usp" = "0" ]; then
                    echo "  $skill: ran out of skill points after $applied clicks"
                    break
                fi
            fi
        done

        # Flush remaining
        if [ -n "$batch" ]; then
            send "{\"commands\":[$batch]}"
            wait_tick_advance 10
        fi

        sleep 0.3
        local end_val=$(py "print(d.get('character',{}).get('skills',{}).get('$skill','?'))")
        local end_usp=$(field "character.unspent_skill_points")
        echo "  $skill: $start_val -> $end_val (SP remaining: $end_usp)"
    done

    _dbg_end "add_skills" "ok" "$_ds"
}

# ─── Choose Perk ─────────────────────────────────────────────────────

choose_perk() {
    # Select a perk by name or ID.
    # Usage: choose_perk "bonus rate of fire"
    #        choose_perk 8
    local _ds=$(_dbg_ts)
    _dbg_start "choose_perk" "$*"

    if [ $# -lt 1 ]; then
        echo "Usage: choose_perk <name_or_id>"
        _dbg_end "choose_perk" "bad_args" "$_ds"
        return 1
    fi

    local ctx=$(context)
    if [ "$ctx" != "character_editor" ]; then
        echo "ERROR: Not in character editor (context=$ctx)"
        _dbg_end "choose_perk" "wrong_context" "$_ds"
        return 1
    fi

    local query="$1"

    # Match perk from available_perks
    local match=$(py "
query = '$query'
perks = d.get('character', {}).get('available_perks', [])
if not perks:
    print('ERROR: No available perks')
else:
    try:
        qid = int(query)
        for p in perks:
            if p['id'] == qid:
                print(f\"MATCH\t{p['id']}\t{p['name']}\t{p.get('description','')}\")
                break
        else:
            print(f'ERROR: Perk id={qid} not in available perks')
    except ValueError:
        q = query.lower()
        matches = [p for p in perks if q in p['name'].lower()]
        if len(matches) == 1:
            p = matches[0]
            print(f\"MATCH\t{p['id']}\t{p['name']}\t{p.get('description','')}\")
        elif len(matches) == 0:
            print(f\"ERROR: No perk matching '{query}'. Available:\")
            for p in perks[:10]:
                print(f\"  {p['name']} (id={p['id']})\")
        else:
            print(f\"ERROR: Multiple matches for '{query}':\")
            for p in matches:
                print(f\"  {p['name']} (id={p['id']})\")
")

    if [[ "$match" != MATCH* ]]; then
        echo "$match"
        _dbg_end "choose_perk" "no_match" "$_ds"
        return 1
    fi

    local perk_id=$(echo "$match" | cut -f2)
    local perk_name=$(echo "$match" | cut -f3)
    local perk_desc=$(echo "$match" | cut -f4-)

    echo "Selecting: $perk_name (id=$perk_id)"
    [ -n "$perk_desc" ] && echo "  $perk_desc"

    cmd "{\"type\":\"perk_add\",\"perk_id\":$perk_id}"
    wait_tick_advance 15

    # Verify — check if engine rejected the selection
    sleep 0.3
    local debug=$(last_debug)
    if [[ "$debug" == *"failed"* ]] || [[ "$debug" == *"error"* ]] || [[ "$debug" == *"cannot"* ]] || [[ "$debug" == *"invalid"* ]]; then
        echo "FAILED: $debug"
        _dbg_end "choose_perk" "rejected" "$_ds"
        return 1
    fi
    echo "Selected: $perk_name — $debug"
    _dbg_end "choose_perk" "ok" "$_ds"
}

# ─── Level Up ────────────────────────────────────────────────────────

level_up() {
    # Open character editor for leveling up.
    local _ds=$(_dbg_ts)
    _dbg_start "level_up" ""

    # Check if level-up is available
    local can_level=$(field "character.can_level_up")
    if [ "$can_level" != "True" ] && [ "$can_level" != "true" ]; then
        local xp=$(field "character.experience")
        local next_xp=$(field "character.xp_for_next_level")
        local lvl=$(field "character.level")
        echo "Cannot level up. Level: $lvl, XP: $xp / $next_xp"
        _dbg_end "level_up" "not_available" "$_ds"
        return 1
    fi

    # Open character screen (triggers level-up when available)
    cmd '{"type":"character_screen"}'
    if ! wait_context "character_editor" 15; then
        echo "ERROR: Editor did not open"
        _dbg_end "level_up" "editor_timeout" "$_ds"
        return 1
    fi

    wait_tick_advance 5
    sleep 0.5

    echo "=== LEVEL UP ==="
    editor_status
    _dbg_end "level_up" "ok" "$_ds"
}

# ─── Finish Editor ───────────────────────────────────────────────────

finish_editor() {
    # Close the character editor with pre-validation.
    local _ds=$(_dbg_ts)
    _dbg_start "finish_editor" ""

    local ctx=$(context)
    if [ "$ctx" != "character_editor" ]; then
        echo "ERROR: Not in character editor (context=$ctx)"
        _dbg_end "finish_editor" "wrong_context" "$_ds"
        return 1
    fi

    # Check for unfinished business
    local check=$(py '''
ch = d.get("character", {})
is_creation = ch.get("is_creation_mode", True)
rem_pts = ch.get("remaining_points", 0)
tag_rem = ch.get("tagged_skills_remaining", 0)
usp = ch.get("unspent_skill_points", 0)
issues = []
if is_creation:
    if rem_pts > 0:
        issues.append(f"SPECIAL points remaining: {rem_pts}")
    if tag_rem > 0:
        issues.append(f"Tagged skills remaining: {tag_rem}")
if is_creation and issues:
    print("BLOCK\t" + "; ".join(issues))
elif not is_creation and usp > 0:
    print(f"WARN\tUnspent skill points: {usp} (will be saved for later)")
else:
    print("OK")
''')

    if [[ "$check" == BLOCK* ]]; then
        local reason="${check#BLOCK	}"
        echo "Cannot close editor: $reason"
        _dbg_end "finish_editor" "blocked" "$_ds"
        return 1
    fi

    if [[ "$check" == WARN* ]]; then
        local warning="${check#WARN	}"
        echo "Warning: $warning"
    fi

    cmd '{"type":"editor_done"}'
    if ! wait_context_prefix "gameplay_" 15; then
        # May transition to character_selector or movie first
        sleep 2
        local new_ctx=$(context)
        if [ "$new_ctx" = "character_editor" ]; then
            echo "ERROR: Editor did not close (may have validation errors)"
            _dbg_end "finish_editor" "failed" "$_ds"
            return 1
        fi
        echo "Editor closed (context: $new_ctx)"
    fi

    _end_status
    _dbg_end "finish_editor" "ok" "$_ds"
}
