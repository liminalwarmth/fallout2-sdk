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

export interface CharacterData {
    name: string;
    remaining_points: number;
    tagged_skills_remaining: number;
    special: SPECIALStats;
    derived_stats: DerivedStats;
    traits: string[];
    tagged_skills: string[];
    skills: Record<string, number>;
    available_traits?: AvailableTrait[];
    level?: number;
    experience?: number;
}

export interface CharEditorState extends BaseState {
    context: "character_editor";
    character: CharacterData;
    available_actions: string[];
}

export interface GameplayState extends BaseState {
    context: "gameplay";
    character: CharacterData;
}

export type GameState =
    | MovieState
    | MainMenuState
    | CharSelectorState
    | CharEditorState
    | GameplayState
    | BaseState;

// --- Command Types ---

export interface KeyPressCommand {
    type: "key_press";
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

export interface MainMenuSelectCommand {
    type: "main_menu_select";
    option: string;
}

export interface CharSelectorSelectCommand {
    type: "char_selector_select";
    option: string;
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

export interface SetNameCommand {
    type: "set_name";
    name: string;
}

export interface FinishCharacterCreationCommand {
    type: "finish_character_creation";
}

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

export interface EditorDoneCommand {
    type: "editor_done";
}

export type Command =
    | KeyPressCommand
    | MouseMoveCommand
    | MouseClickCommand
    | MainMenuSelectCommand
    | CharSelectorSelectCommand
    | SetSpecialCommand
    | SelectTraitsCommand
    | TagSkillsCommand
    | SetNameCommand
    | FinishCharacterCreationCommand
    | AdjustStatCommand
    | ToggleTraitCommand
    | ToggleSkillTagCommand
    | EditorDoneCommand;
