// --- Game State Types ---

export interface BaseState {
    tick: number;
    timestamp_ms: number;
    game_mode: number;
    game_mode_flags: string[];
    game_state: number;
    mouse: { x: number; y: number };
    screen: { width: number; height: number };
    context: string;
    test_mode: boolean;
    player_dead?: boolean;
    last_command_debug?: string;
    look_at_result?: string;
}

export interface MovieState extends BaseState {
    context: "movie";
    available_actions: ["skip"];
}

export interface SaveSlot {
    slot: number;
    exists: boolean;
    character_name?: string;
    description?: string;
}

export interface MainMenuState extends BaseState {
    context: "main_menu";
    available_actions: string[];
    save_games: SaveSlot[];
}

export interface CharSelectorState extends BaseState {
    context: "character_selector";
    premade_characters: string[];
    available_actions: string[];
}

// --- Character/Stats ---

export interface SPECIALStats {
    strength: number;
    perception: number;
    endurance: number;
    charisma: number;
    intelligence: number;
    agility: number;
    luck: number;
}

export interface DerivedStats {
    max_hp: number;
    max_ap: number;
    armor_class: number;
    melee_damage: number;
    carry_weight: number;
    sequence: number;
    healing_rate: number;
    critical_chance: number;
    radiation_resistance?: number;
    poison_resistance?: number;
    current_hp?: number;
}

export interface AvailableTrait {
    id: number;
    name: string;
}

export interface AvailablePerk {
    id: number;
    name: string;
    description: string;
    current_rank: number;
}

export interface ActivePerk {
    id: number;
    name: string;
    rank: number;
}

export interface CharacterData {
    name: string;
    remaining_points?: number;
    tagged_skills_remaining?: number;
    special: SPECIALStats;
    derived_stats: DerivedStats;
    traits: string[];
    tagged_skills: string[];
    skills: Record<string, number>;
    available_traits?: AvailableTrait[];
    available_perks?: AvailablePerk[];
    perks?: ActivePerk[];
    level?: number;
    experience?: number;
    xp_for_next_level?: number;
    unspent_skill_points?: number;
    can_level_up?: boolean;
    status_effects?: string[];
    poison_level?: number;
    radiation_level?: number;
    karma?: number;
    town_reputations?: Record<string, number>;
    addictions?: string[];
}

export interface CharEditorState extends BaseState {
    context: "character_editor";
    character: CharacterData;
    available_actions: string[];
}

// --- Map Objects ---

export interface CritterInfo {
    id: number;
    pid: number;
    name: string;
    tile: number;
    distance: number;
    hp: number;
    max_hp: number;
    dead: boolean;
    team: number;
    is_party_member: boolean;
    hostile?: boolean;
    enemy_team?: boolean;
}

export interface GroundItemInfo {
    id: number;
    pid: number;
    name: string;
    tile: number;
    distance: number;
    type: string;
    item_count?: number;
}

export interface SceneryInfo {
    id: number;
    name: string;
    tile: number;
    distance: number;
    scenery_type: string;
    locked?: boolean;
    open?: boolean;
    item_count?: number;
    usable?: boolean;
}

export interface ExitGridInfo {
    id: number;
    tile: number;
    distance: number;
    destination_map: number;
    destination_tile: number;
    destination_elevation: number;
    destination_map_name?: string;
}

export interface MapObjects {
    critters: CritterInfo[];
    ground_items: GroundItemInfo[];
    scenery: SceneryInfo[];
    exit_grids: ExitGridInfo[];
}

// --- Player Position ---

export interface NeighborTile {
    tile: number;
    direction: number;
    walkable: boolean;
}

export interface PlayerPosition {
    tile: number;
    elevation: number;
    rotation: number;
    animation_busy: boolean;
    is_sneaking: boolean;
    movement_waypoints_remaining?: number;
    neighbors: NeighborTile[];
}

// --- Map Info ---

export interface MapInfo {
    name: string;
    index: number;
    elevation: number;
}

// --- Combat ---

export interface HitChances {
    uncalled: number;
    torso: number;
    head: number;
    eyes: number;
    groin: number;
    left_arm: number;
    right_arm: number;
    left_leg: number;
    right_leg: number;
}

export interface HostileInfo {
    id: number;
    name: string;
    tile: number;
    distance: number;
    hp: number;
    max_hp: number;
    hit_chances: HitChances;
}

export interface WeaponAttack {
    ap_cost: number;
    range: number;
    damage_min?: number;
    damage_max?: number;
}

export interface ActiveWeapon {
    name: string;
    primary: WeaponAttack;
    secondary: WeaponAttack;
}

export interface CombatState {
    current_ap: number;
    max_ap: number;
    free_move: number;
    active_hand: string;
    current_hit_mode?: number;
    aiming?: boolean;
    active_weapon: ActiveWeapon;
    hostiles: HostileInfo[];
    pending_attacks: number;
}

// --- Dialogue ---

export interface DialogueOption {
    index: number;
    text: string;
}

export interface DialogueState {
    speaker_name?: string;
    speaker_id?: number;
    reply_text: string;
    options: DialogueOption[];
}

// --- Loot/Container ---

export interface ContainerItem {
    pid: number;
    name: string;
    quantity: number;
    type: string;
    weight: number;
}

export interface LootState {
    target_name: string;
    target_id: number;
    target_pid: number;
    container_items: ContainerItem[];
}

// --- Inventory ---

export interface InventoryItem {
    pid: number;
    name: string;
    quantity: number;
    type: string;
    weight: number;
}

export interface EquippedItem {
    pid: number;
    name: string;
    ammo_count?: number;
    ammo_capacity?: number;
    ammo_pid?: number;
    ammo_name?: string;
    damage_type?: string;
    damage_min?: number;
    damage_max?: number;
}

export interface InventoryState {
    items: InventoryItem[];
    equipped: {
        right_hand: EquippedItem | null;
        left_hand: EquippedItem | null;
        armor: EquippedItem | null;
    };
    total_weight: number;
    carry_capacity: number;
    active_hand: string;
    current_hit_mode?: number;
}

// --- Barter ---

export interface BarterItem {
    pid: number;
    name: string;
    quantity: number;
    type?: string;
    cost: number;
}

export interface TradeInfo {
    player_offer_value: number;
    merchant_offer_value: number;
    party_barter_skill: number;
    npc_barter_skill: number;
    merchant_wants: number;
    trade_will_succeed: boolean;
}

export interface BarterState {
    merchant_name: string;
    merchant_id: number;
    merchant_inventory: BarterItem[];
    player_offer: BarterItem[];
    merchant_offer: BarterItem[];
    barter_modifier: number;
    player_caps: number;
    merchant_caps: number;
    trade_info?: TradeInfo;
}

// --- World Map ---

export interface WorldmapEntrance {
    index: number;
    map_index: number;
    elevation: number;
    tile: number;
    known: boolean;
    map_name?: string;
}

export interface WorldmapLocation {
    area_id: number;
    name: string;
    x: number;
    y: number;
    visited: boolean;
    entrances: WorldmapEntrance[];
}

export interface WorldmapState {
    world_pos_x: number;
    world_pos_y: number;
    current_area_id: number;
    current_area_name?: string;
    is_walking: boolean;
    walk_destination_x?: number;
    walk_destination_y?: number;
    is_in_car: boolean;
    car_fuel?: number;
    car_fuel_max?: number;
    locations: WorldmapLocation[];
}

// --- Party Member ---

export interface PartyMember {
    id: number;
    pid: number;
    name: string;
    tile: number;
    distance: number;
    hp: number;
    max_hp: number;
    dead: boolean;
    armor?: string;
    weapon?: string;
}

// --- Game Time ---

export interface GameTime {
    hour: number;
    month: number;
    day: number;
    year: number;
    time_string: string;
    ticks: number;
}

// --- Quest ---

export interface QuestInfo {
    location: string;
    description: string;
    completed: boolean;
    gvar_value: number;
}

export interface HolodiskInfo {
    name: string;
}

// --- Composite Gameplay States ---

/** Base gameplay fields shared by all gameplay sub-contexts */
interface GameplayBase extends BaseState {
    character: CharacterData;
    inventory: InventoryState;
    party_members: PartyMember[];
    message_log: string[];
    game_time: GameTime;
    quests?: QuestInfo[];
    holodisks?: HolodiskInfo[];
}

/** Exploration context — player walking around a map */
export interface GameplayExplorationState extends GameplayBase {
    context: "gameplay_exploration";
    map: MapInfo;
    player: PlayerPosition;
    objects: MapObjects;
}

/** Combat (player's turn) — includes combat-specific state + map/objects */
export interface GameplayCombatState extends GameplayBase {
    context: "gameplay_combat";
    map: MapInfo;
    player: PlayerPosition;
    objects: MapObjects;
    combat: CombatState;
}

/** Combat (waiting for other combatants' turns) */
export interface GameplayCombatWaitState extends GameplayBase {
    context: "gameplay_combat_wait";
    map: MapInfo;
    player: PlayerPosition;
    objects: MapObjects;
    combat?: CombatState;
}

/** Dialogue with an NPC */
export interface GameplayDialogueState extends GameplayBase {
    context: "gameplay_dialogue";
    map: MapInfo;
    player: PlayerPosition;
    objects: MapObjects;
    dialogue: DialogueState;
}

/** Loot screen (container open) */
export interface GameplayLootState extends GameplayBase {
    context: "gameplay_loot";
    loot: LootState;
}

/** Inventory screen */
export interface GameplayInventoryState extends GameplayBase {
    context: "gameplay_inventory";
}

/** Barter screen */
export interface GameplayBarterState extends GameplayBase {
    context: "gameplay_barter";
    barter: BarterState;
}

/** World map (overland travel) */
export interface GameplayWorldmapState extends GameplayBase {
    context: "gameplay_worldmap";
    worldmap: WorldmapState;
}

/** Generic gameplay fallback */
export interface GameplayState extends BaseState {
    context: "gameplay";
    character?: CharacterData;
}

export type GameState =
    | MovieState
    | MainMenuState
    | CharSelectorState
    | CharEditorState
    | GameplayExplorationState
    | GameplayCombatState
    | GameplayCombatWaitState
    | GameplayDialogueState
    | GameplayLootState
    | GameplayInventoryState
    | GameplayBarterState
    | GameplayWorldmapState
    | GameplayState
    | BaseState;

// --- Command Types ---

// Character editor commands
export interface AdjustStatCommand {
    type: "adjust_stat";
    stat: string;
    direction: "up" | "down";
}

export interface ToggleTraitCommand {
    type: "toggle_trait";
    trait: string;
}

export interface ToggleSkillTagCommand {
    type: "toggle_skill_tag";
    skill: string;
}

export interface SetNameCommand {
    type: "set_name";
    name: string;
}

export interface EditorDoneCommand {
    type: "editor_done";
}

export interface SetSpecialCommand {
    type: "set_special";
    strength: number;
    perception: number;
    endurance: number;
    charisma: number;
    intelligence: number;
    agility: number;
    luck: number;
}

export interface SelectTraitsCommand {
    type: "select_traits";
    traits: string[];
}

export interface TagSkillsCommand {
    type: "tag_skills";
    skills: string[];
}

export interface FinishCharacterCreationCommand {
    type: "finish_character_creation";
}

// Input commands
export interface KeyPressCommand {
    type: "key_press";
    key: string;
}

export interface KeyReleaseCommand {
    type: "key_release";
    key: string;
}

export interface MouseMoveCommand {
    type: "mouse_move";
    x: number;
    y: number;
}

export interface MouseClickCommand {
    type: "mouse_click";
    x: number;
    y: number;
    button?: "left" | "right";
}

export interface InputEventCommand {
    type: "input_event";
    key_code: number;
}

export interface SkipCommand {
    type: "skip";
}

// Menu commands
export interface MainMenuCommand {
    type: "main_menu";
    action: string;
    slot?: number;
}

export interface MainMenuSelectCommand {
    type: "main_menu_select";
    option: string;
}

export interface CharSelectorSelectCommand {
    type: "char_selector_select";
    option: string;
}

// Movement commands
export interface MoveToCommand {
    type: "move_to";
    tile: number;
}

export interface RunToCommand {
    type: "run_to";
    tile: number;
}

export interface CombatMoveCommand {
    type: "combat_move";
    tile: number;
}

// Interaction commands
export interface UseObjectCommand {
    type: "use_object";
    object_id: number;
}

export interface PickUpCommand {
    type: "pick_up";
    object_id: number;
}

export interface UseSkillCommand {
    type: "use_skill";
    skill: string;
    object_id: number;
}

export interface TalkToCommand {
    type: "talk_to";
    object_id: number;
}

export interface UseItemOnCommand {
    type: "use_item_on";
    item_pid: number;
    object_id: number;
}

export interface LookAtCommand {
    type: "look_at";
    object_id: number;
}

// Inventory commands
export interface EquipItemCommand {
    type: "equip_item";
    item_pid: number;
    hand: string;
}

export interface UnequipItemCommand {
    type: "unequip_item";
    hand: string;
}

export interface UseItemCommand {
    type: "use_item";
    item_pid: number;
}

export interface ReloadWeaponCommand {
    type: "reload_weapon";
}

export interface DropItemCommand {
    type: "drop_item";
    item_pid: number;
    quantity?: number;
}

export interface GiveItemCommand {
    type: "give_item";
    item_pid: number;
    quantity?: number;
}

export interface ArmExplosiveCommand {
    type: "arm_explosive";
    item_pid: number;
}

// Combat commands
export interface AttackCommand {
    type: "attack";
    target_id: number;
    hit_location?: string;
    hit_mode?: string;
}

export interface EndTurnCommand {
    type: "end_turn";
}

export interface UseCombatItemCommand {
    type: "use_combat_item";
    item_pid: number;
}

export interface EnterCombatCommand {
    type: "enter_combat";
}

export interface FleeCombatCommand {
    type: "flee_combat";
}

// Interface commands
export interface SwitchHandCommand {
    type: "switch_hand";
}

export interface CycleAttackModeCommand {
    type: "cycle_attack_mode";
}

export interface CenterCameraCommand {
    type: "center_camera";
}

export interface RestCommand {
    type: "rest";
    hours?: number;
}

export interface PipBoyCommand {
    type: "pip_boy";
}

export interface CharacterScreenCommand {
    type: "character_screen";
}

export interface InventoryOpenCommand {
    type: "inventory_open";
}

export interface SkilldexCommand {
    type: "skilldex";
}

export interface ToggleSneakCommand {
    type: "toggle_sneak";
}

// Dialogue commands
export interface SelectDialogueCommand {
    type: "select_dialogue";
    index: number;
}

// Container/loot commands
export interface OpenContainerCommand {
    type: "open_container";
    object_id: number;
}

export interface LootTakeCommand {
    type: "loot_take";
    item_pid: number;
    quantity?: number;
}

export interface LootTakeAllCommand {
    type: "loot_take_all";
}

export interface LootCloseCommand {
    type: "loot_close";
}

// Barter commands
export interface BarterOfferCommand {
    type: "barter_offer";
    item_pid: number;
    quantity?: number;
}

export interface BarterRemoveOfferCommand {
    type: "barter_remove_offer";
    item_pid: number;
    quantity?: number;
}

export interface BarterRequestCommand {
    type: "barter_request";
    item_pid: number;
    quantity?: number;
}

export interface BarterRemoveRequestCommand {
    type: "barter_remove_request";
    item_pid: number;
    quantity?: number;
}

export interface BarterConfirmCommand {
    type: "barter_confirm";
}

export interface BarterTalkCommand {
    type: "barter_talk";
}

export interface BarterCancelCommand {
    type: "barter_cancel";
}

// Level-up commands
export interface SkillAddCommand {
    type: "skill_add";
    skill: string;
}

export interface SkillSubCommand {
    type: "skill_sub";
    skill: string;
}

export interface PerkAddCommand {
    type: "perk_add";
    perk_id: number;
}

// World map commands
export interface WorldmapTravelCommand {
    type: "worldmap_travel";
    area_id: number;
}

export interface WorldmapEnterLocationCommand {
    type: "worldmap_enter_location";
    area_id: number;
    entrance?: number;
}

// Navigation/debug commands
export interface FindPathCommand {
    type: "find_path";
    to: number;
    from?: number;
}

export interface TileObjectsCommand {
    type: "tile_objects";
    tile: number;
}

export interface FindItemCommand {
    type: "find_item";
    pid: number;
}

export interface ListAllItemsCommand {
    type: "list_all_items";
}

export interface MapTransitionCommand {
    type: "map_transition";
    map?: number;
    tile?: number;
    elevation?: number;
}

export interface TeleportCommand {
    type: "teleport";
    tile: number;
    elevation?: number;
}

// Save/Load commands
export interface QuicksaveCommand {
    type: "quicksave";
}

export interface QuickloadCommand {
    type: "quickload";
}

export interface SaveSlotCommand {
    type: "save_slot";
    slot: number;
    description?: string;
}

export interface LoadSlotCommand {
    type: "load_slot";
    slot: number;
}

// Test mode
export interface SetTestModeCommand {
    type: "set_test_mode";
    enabled: boolean;
}

export type Command =
    | AdjustStatCommand
    | ToggleTraitCommand
    | ToggleSkillTagCommand
    | SetNameCommand
    | EditorDoneCommand
    | SetSpecialCommand
    | SelectTraitsCommand
    | TagSkillsCommand
    | FinishCharacterCreationCommand
    | KeyPressCommand
    | KeyReleaseCommand
    | MouseMoveCommand
    | MouseClickCommand
    | InputEventCommand
    | SkipCommand
    | MainMenuCommand
    | MainMenuSelectCommand
    | CharSelectorSelectCommand
    | MoveToCommand
    | RunToCommand
    | CombatMoveCommand
    | UseObjectCommand
    | PickUpCommand
    | UseSkillCommand
    | TalkToCommand
    | UseItemOnCommand
    | LookAtCommand
    | EquipItemCommand
    | UnequipItemCommand
    | UseItemCommand
    | ReloadWeaponCommand
    | DropItemCommand
    | GiveItemCommand
    | ArmExplosiveCommand
    | AttackCommand
    | EndTurnCommand
    | UseCombatItemCommand
    | EnterCombatCommand
    | FleeCombatCommand
    | SwitchHandCommand
    | CycleAttackModeCommand
    | CenterCameraCommand
    | RestCommand
    | PipBoyCommand
    | CharacterScreenCommand
    | InventoryOpenCommand
    | SkilldexCommand
    | ToggleSneakCommand
    | SelectDialogueCommand
    | OpenContainerCommand
    | LootTakeCommand
    | LootTakeAllCommand
    | LootCloseCommand
    | BarterOfferCommand
    | BarterRemoveOfferCommand
    | BarterRequestCommand
    | BarterRemoveRequestCommand
    | BarterConfirmCommand
    | BarterTalkCommand
    | BarterCancelCommand
    | SkillAddCommand
    | SkillSubCommand
    | PerkAddCommand
    | WorldmapTravelCommand
    | WorldmapEnterLocationCommand
    | FindPathCommand
    | TileObjectsCommand
    | FindItemCommand
    | ListAllItemsCommand
    | MapTransitionCommand
    | TeleportCommand
    | QuicksaveCommand
    | QuickloadCommand
    | SaveSlotCommand
    | LoadSlotCommand
    | SetTestModeCommand;
