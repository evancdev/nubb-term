// Nubb's internal embedder API, a.k.a. "libnubb-internal".
//
// The only consumer of this API is the macOS app, and while it is fairly
// comprehensive, it is tailored to the needs of the macOS app and not designed
// for external use, hence why most functions are undocumented and some are
// macOS-specific (e.g. ones dealing with the Metal graphics API).
#ifndef NUBB_H
#define NUBB_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef _MSC_VER
#include <BaseTsd.h>
typedef SSIZE_T ssize_t;
#else
#include <sys/types.h>
#endif

//-------------------------------------------------------------------
// Macros

#define NUBB_SUCCESS 0

// Symbol visibility for shared library builds. On Windows, functions
// are exported from the DLL when building and imported when consuming.
// On other platforms with GCC/Clang, functions are marked with default
// visibility so they remain accessible when the library is built with
// -fvisibility=hidden. For static library builds, define NUBB_STATIC
// before including this header to make this a no-op.
#ifndef NUBB_API
#if defined(NUBB_STATIC)
  #define NUBB_API
#elif defined(_WIN32) || defined(_WIN64)
  #ifdef NUBB_BUILD_SHARED
    #define NUBB_API __declspec(dllexport)
  #else
    #define NUBB_API __declspec(dllimport)
  #endif
#elif defined(__GNUC__) && __GNUC__ >= 4
  #define NUBB_API __attribute__((visibility("default")))
#else
  #define NUBB_API
#endif
#endif

//-------------------------------------------------------------------
// Types

// Opaque types
typedef void* nubb_app_t;
typedef void* nubb_config_t;
typedef void* nubb_surface_t;

// All the types below are fully defined and must be kept in sync with
// their Zig counterparts. Any changes to these types MUST have an associated
// Zig change.
typedef enum {
  NUBB_PLATFORM_INVALID,
  NUBB_PLATFORM_MACOS,
  NUBB_PLATFORM_IOS,
} nubb_platform_e;

typedef enum {
  NUBB_CLIPBOARD_STANDARD,
  NUBB_CLIPBOARD_SELECTION,
  NUBB_CLIPBOARD_PRIMARY,
} nubb_clipboard_e;

// One representation of clipboard contents. The data is binary-safe with
// an explicit length; it is not necessarily null-terminated.
typedef struct {
  const char *mime;
  const char *data;
  size_t len;
} nubb_clipboard_content_s;

// The payload for completing a clipboard read request. See
// nubb_surface_complete_clipboard_request.
typedef struct {
  const nubb_clipboard_content_s *contents;
  size_t contents_len;
  const char *const *available;
  size_t available_len;
  bool confirmed;
  bool remember;
} nubb_clipboard_complete_s;

// The payload of a clipboard read confirmation request: the would-be
// completion contents plus the information shown in the permission
// prompt. See nubb_runtime_confirm_read_clipboard_cb.
typedef struct {
  const nubb_clipboard_content_s *contents;
  size_t contents_len;
  const char *const *available;
  size_t available_len;
  const char *name;
  bool can_remember;
} nubb_clipboard_confirm_s;

typedef enum {
  NUBB_CLIPBOARD_REQUEST_PASTE,
  NUBB_CLIPBOARD_REQUEST_OSC_52_READ,
  NUBB_CLIPBOARD_REQUEST_OSC_52_WRITE,
  NUBB_CLIPBOARD_REQUEST_KITTY_READ,
  NUBB_CLIPBOARD_REQUEST_KITTY_WRITE,
  NUBB_CLIPBOARD_REQUEST_LIST,
} nubb_clipboard_request_e;

// apprt.ClipboardReadResult
typedef enum {
  NUBB_CLIPBOARD_READ_STARTED,
  NUBB_CLIPBOARD_READ_UNAVAILABLE,
  NUBB_CLIPBOARD_READ_UNSUPPORTED,
} nubb_clipboard_read_result_e;

typedef enum {
  NUBB_MOUSE_RELEASE,
  NUBB_MOUSE_PRESS,
} nubb_input_mouse_state_e;

typedef enum {
  NUBB_MOUSE_UNKNOWN,
  NUBB_MOUSE_LEFT,
  NUBB_MOUSE_RIGHT,
  NUBB_MOUSE_MIDDLE,
  NUBB_MOUSE_FOUR,
  NUBB_MOUSE_FIVE,
  NUBB_MOUSE_SIX,
  NUBB_MOUSE_SEVEN,
  NUBB_MOUSE_EIGHT,
  NUBB_MOUSE_NINE,
  NUBB_MOUSE_TEN,
  NUBB_MOUSE_ELEVEN,
} nubb_input_mouse_button_e;

typedef enum {
  NUBB_MOUSE_MOMENTUM_NONE,
  NUBB_MOUSE_MOMENTUM_BEGAN,
  NUBB_MOUSE_MOMENTUM_STATIONARY,
  NUBB_MOUSE_MOMENTUM_CHANGED,
  NUBB_MOUSE_MOMENTUM_ENDED,
  NUBB_MOUSE_MOMENTUM_CANCELLED,
  NUBB_MOUSE_MOMENTUM_MAY_BEGIN,
} nubb_input_mouse_momentum_e;

typedef enum {
  NUBB_COLOR_SCHEME_LIGHT = 0,
  NUBB_COLOR_SCHEME_DARK = 1,
} nubb_color_scheme_e;

// This is a packed struct (see src/input/mouse.zig) but the C standard
// afaik doesn't let us reliably define packed structs so we build it up
// from scratch.
typedef int nubb_input_scroll_mods_t;

typedef enum {
  NUBB_MODS_NONE = 0,
  NUBB_MODS_SHIFT = 1 << 0,
  NUBB_MODS_CTRL = 1 << 1,
  NUBB_MODS_ALT = 1 << 2,
  NUBB_MODS_SUPER = 1 << 3,
  NUBB_MODS_CAPS = 1 << 4,
  NUBB_MODS_NUM = 1 << 5,
  NUBB_MODS_SHIFT_RIGHT = 1 << 6,
  NUBB_MODS_CTRL_RIGHT = 1 << 7,
  NUBB_MODS_ALT_RIGHT = 1 << 8,
  NUBB_MODS_SUPER_RIGHT = 1 << 9,
} nubb_input_mods_e;

typedef enum {
  NUBB_BINDING_FLAGS_CONSUMED = 1 << 0,
  NUBB_BINDING_FLAGS_ALL = 1 << 1,
  NUBB_BINDING_FLAGS_GLOBAL = 1 << 2,
  NUBB_BINDING_FLAGS_PERFORMABLE = 1 << 3,
} nubb_binding_flags_e;

typedef enum {
  NUBB_ACTION_RELEASE,
  NUBB_ACTION_PRESS,
  NUBB_ACTION_REPEAT,
} nubb_input_action_e;

// Based on: https://www.w3.org/TR/uievents-code/
typedef enum {
  NUBB_KEY_UNIDENTIFIED,

  // "Writing System Keys" § 3.1.1
  NUBB_KEY_BACKQUOTE,
  NUBB_KEY_BACKSLASH,
  NUBB_KEY_BRACKET_LEFT,
  NUBB_KEY_BRACKET_RIGHT,
  NUBB_KEY_COMMA,
  NUBB_KEY_DIGIT_0,
  NUBB_KEY_DIGIT_1,
  NUBB_KEY_DIGIT_2,
  NUBB_KEY_DIGIT_3,
  NUBB_KEY_DIGIT_4,
  NUBB_KEY_DIGIT_5,
  NUBB_KEY_DIGIT_6,
  NUBB_KEY_DIGIT_7,
  NUBB_KEY_DIGIT_8,
  NUBB_KEY_DIGIT_9,
  NUBB_KEY_EQUAL,
  NUBB_KEY_INTL_BACKSLASH,
  NUBB_KEY_INTL_RO,
  NUBB_KEY_INTL_YEN,
  NUBB_KEY_A,
  NUBB_KEY_B,
  NUBB_KEY_C,
  NUBB_KEY_D,
  NUBB_KEY_E,
  NUBB_KEY_F,
  NUBB_KEY_G,
  NUBB_KEY_H,
  NUBB_KEY_I,
  NUBB_KEY_J,
  NUBB_KEY_K,
  NUBB_KEY_L,
  NUBB_KEY_M,
  NUBB_KEY_N,
  NUBB_KEY_O,
  NUBB_KEY_P,
  NUBB_KEY_Q,
  NUBB_KEY_R,
  NUBB_KEY_S,
  NUBB_KEY_T,
  NUBB_KEY_U,
  NUBB_KEY_V,
  NUBB_KEY_W,
  NUBB_KEY_X,
  NUBB_KEY_Y,
  NUBB_KEY_Z,
  NUBB_KEY_MINUS,
  NUBB_KEY_PERIOD,
  NUBB_KEY_QUOTE,
  NUBB_KEY_SEMICOLON,
  NUBB_KEY_SLASH,

  // "Functional Keys" § 3.1.2
  NUBB_KEY_ALT_LEFT,
  NUBB_KEY_ALT_RIGHT,
  NUBB_KEY_BACKSPACE,
  NUBB_KEY_CAPS_LOCK,
  NUBB_KEY_CONTEXT_MENU,
  NUBB_KEY_CONTROL_LEFT,
  NUBB_KEY_CONTROL_RIGHT,
  NUBB_KEY_ENTER,
  NUBB_KEY_META_LEFT,
  NUBB_KEY_META_RIGHT,
  NUBB_KEY_SHIFT_LEFT,
  NUBB_KEY_SHIFT_RIGHT,
  NUBB_KEY_SPACE,
  NUBB_KEY_TAB,
  NUBB_KEY_CONVERT,
  NUBB_KEY_KANA_MODE,
  NUBB_KEY_NON_CONVERT,

  // "Control Pad Section" § 3.2
  NUBB_KEY_DELETE,
  NUBB_KEY_END,
  NUBB_KEY_HELP,
  NUBB_KEY_HOME,
  NUBB_KEY_INSERT,
  NUBB_KEY_PAGE_DOWN,
  NUBB_KEY_PAGE_UP,

  // "Arrow Pad Section" § 3.3
  NUBB_KEY_ARROW_DOWN,
  NUBB_KEY_ARROW_LEFT,
  NUBB_KEY_ARROW_RIGHT,
  NUBB_KEY_ARROW_UP,

  // "Numpad Section" § 3.4
  NUBB_KEY_NUM_LOCK,
  NUBB_KEY_NUMPAD_0,
  NUBB_KEY_NUMPAD_1,
  NUBB_KEY_NUMPAD_2,
  NUBB_KEY_NUMPAD_3,
  NUBB_KEY_NUMPAD_4,
  NUBB_KEY_NUMPAD_5,
  NUBB_KEY_NUMPAD_6,
  NUBB_KEY_NUMPAD_7,
  NUBB_KEY_NUMPAD_8,
  NUBB_KEY_NUMPAD_9,
  NUBB_KEY_NUMPAD_ADD,
  NUBB_KEY_NUMPAD_BACKSPACE,
  NUBB_KEY_NUMPAD_CLEAR,
  NUBB_KEY_NUMPAD_CLEAR_ENTRY,
  NUBB_KEY_NUMPAD_COMMA,
  NUBB_KEY_NUMPAD_DECIMAL,
  NUBB_KEY_NUMPAD_DIVIDE,
  NUBB_KEY_NUMPAD_ENTER,
  NUBB_KEY_NUMPAD_EQUAL,
  NUBB_KEY_NUMPAD_MEMORY_ADD,
  NUBB_KEY_NUMPAD_MEMORY_CLEAR,
  NUBB_KEY_NUMPAD_MEMORY_RECALL,
  NUBB_KEY_NUMPAD_MEMORY_STORE,
  NUBB_KEY_NUMPAD_MEMORY_SUBTRACT,
  NUBB_KEY_NUMPAD_MULTIPLY,
  NUBB_KEY_NUMPAD_PAREN_LEFT,
  NUBB_KEY_NUMPAD_PAREN_RIGHT,
  NUBB_KEY_NUMPAD_SUBTRACT,
  NUBB_KEY_NUMPAD_SEPARATOR,
  NUBB_KEY_NUMPAD_UP,
  NUBB_KEY_NUMPAD_DOWN,
  NUBB_KEY_NUMPAD_RIGHT,
  NUBB_KEY_NUMPAD_LEFT,
  NUBB_KEY_NUMPAD_BEGIN,
  NUBB_KEY_NUMPAD_HOME,
  NUBB_KEY_NUMPAD_END,
  NUBB_KEY_NUMPAD_INSERT,
  NUBB_KEY_NUMPAD_DELETE,
  NUBB_KEY_NUMPAD_PAGE_UP,
  NUBB_KEY_NUMPAD_PAGE_DOWN,

  // "Function Section" § 3.5
  NUBB_KEY_ESCAPE,
  NUBB_KEY_F1,
  NUBB_KEY_F2,
  NUBB_KEY_F3,
  NUBB_KEY_F4,
  NUBB_KEY_F5,
  NUBB_KEY_F6,
  NUBB_KEY_F7,
  NUBB_KEY_F8,
  NUBB_KEY_F9,
  NUBB_KEY_F10,
  NUBB_KEY_F11,
  NUBB_KEY_F12,
  NUBB_KEY_F13,
  NUBB_KEY_F14,
  NUBB_KEY_F15,
  NUBB_KEY_F16,
  NUBB_KEY_F17,
  NUBB_KEY_F18,
  NUBB_KEY_F19,
  NUBB_KEY_F20,
  NUBB_KEY_F21,
  NUBB_KEY_F22,
  NUBB_KEY_F23,
  NUBB_KEY_F24,
  NUBB_KEY_F25,
  NUBB_KEY_FN,
  NUBB_KEY_FN_LOCK,
  NUBB_KEY_PRINT_SCREEN,
  NUBB_KEY_SCROLL_LOCK,
  NUBB_KEY_PAUSE,

  // "Media Keys" § 3.6
  NUBB_KEY_BROWSER_BACK,
  NUBB_KEY_BROWSER_FAVORITES,
  NUBB_KEY_BROWSER_FORWARD,
  NUBB_KEY_BROWSER_HOME,
  NUBB_KEY_BROWSER_REFRESH,
  NUBB_KEY_BROWSER_SEARCH,
  NUBB_KEY_BROWSER_STOP,
  NUBB_KEY_EJECT,
  NUBB_KEY_LAUNCH_APP_1,
  NUBB_KEY_LAUNCH_APP_2,
  NUBB_KEY_LAUNCH_MAIL,
  NUBB_KEY_MEDIA_PLAY_PAUSE,
  NUBB_KEY_MEDIA_SELECT,
  NUBB_KEY_MEDIA_STOP,
  NUBB_KEY_MEDIA_TRACK_NEXT,
  NUBB_KEY_MEDIA_TRACK_PREVIOUS,
  NUBB_KEY_POWER,
  NUBB_KEY_SLEEP,
  NUBB_KEY_AUDIO_VOLUME_DOWN,
  NUBB_KEY_AUDIO_VOLUME_MUTE,
  NUBB_KEY_AUDIO_VOLUME_UP,
  NUBB_KEY_WAKE_UP,

  // "Legacy, Non-standard, and Special Keys" § 3.7
  NUBB_KEY_COPY,
  NUBB_KEY_CUT,
  NUBB_KEY_PASTE,
} nubb_input_key_e;

typedef struct {
  nubb_input_action_e action;
  nubb_input_mods_e mods;
  nubb_input_mods_e consumed_mods;
  uint32_t keycode;
  const char* text;
  uint32_t unshifted_codepoint;
  bool composing;
} nubb_input_key_s;

typedef enum {
  NUBB_TRIGGER_PHYSICAL,
  NUBB_TRIGGER_UNICODE,
  NUBB_TRIGGER_CATCH_ALL,
} nubb_input_trigger_tag_e;

typedef union {
  nubb_input_key_e physical;
  uint32_t unicode;
  // catch_all has no payload
} nubb_input_trigger_key_u;

typedef struct {
  nubb_input_trigger_tag_e tag;
  nubb_input_trigger_key_u key;
  nubb_input_mods_e mods;
} nubb_input_trigger_s;

typedef struct {
  const char* action_key;
  const char* action;
  const char* title;
  const char* description;
} nubb_command_s;

typedef enum {
  NUBB_BUILD_MODE_DEBUG,
  NUBB_BUILD_MODE_RELEASE_SAFE,
  NUBB_BUILD_MODE_RELEASE_FAST,
  NUBB_BUILD_MODE_RELEASE_SMALL,
} nubb_build_mode_e;

typedef struct {
  nubb_build_mode_e build_mode;
  const char* version;
  uintptr_t version_len;
} nubb_info_s;

typedef struct {
  const char* message;
} nubb_diagnostic_s;

typedef struct {
  const char* ptr;
  uintptr_t len;
  bool sentinel;
} nubb_string_s;

typedef struct {
  double tl_px_x;
  double tl_px_y;
  uint32_t offset_start;
  uint32_t offset_len;
  const char* text;
  uintptr_t text_len;
} nubb_text_s;

typedef enum {
  NUBB_POINT_ACTIVE,
  NUBB_POINT_VIEWPORT,
  NUBB_POINT_SCREEN,
  NUBB_POINT_SURFACE,
} nubb_point_tag_e;

typedef enum {
  NUBB_POINT_COORD_EXACT,
  NUBB_POINT_COORD_TOP_LEFT,
  NUBB_POINT_COORD_BOTTOM_RIGHT,
} nubb_point_coord_e;

typedef struct {
  nubb_point_tag_e tag;
  nubb_point_coord_e coord;
  uint32_t x;
  uint32_t y;
} nubb_point_s;

typedef struct {
  nubb_point_s top_left;
  nubb_point_s bottom_right;
  bool rectangle;
} nubb_selection_s;

typedef struct {
  const char* key;
  const char* value;
} nubb_env_var_s;

typedef struct {
  void* nsview;
} nubb_platform_macos_s;

typedef struct {
  void* uiview;
} nubb_platform_ios_s;

typedef union {
  nubb_platform_macos_s macos;
  nubb_platform_ios_s ios;
} nubb_platform_u;

typedef enum {
  NUBB_SURFACE_CONTEXT_WINDOW = 0,
  NUBB_SURFACE_CONTEXT_TAB = 1,
  NUBB_SURFACE_CONTEXT_SPLIT = 2,
} nubb_surface_context_e;

typedef struct {
  nubb_platform_e platform_tag;
  nubb_platform_u platform;
  void* userdata;
  double scale_factor;
  float font_size;
  const char* working_directory;
  const char* command;
  nubb_env_var_s* env_vars;
  size_t env_var_count;
  const char* initial_input;
  bool wait_after_command;
  nubb_surface_context_e context;
} nubb_surface_config_s;

typedef struct {
  uint16_t columns;
  uint16_t rows;
  uint32_t width_px;
  uint32_t height_px;
  uint32_t cell_width_px;
  uint32_t cell_height_px;
} nubb_surface_size_s;

// Config types

// config.Path
typedef struct {
  const char* path;
  bool optional;
} nubb_config_path_s;

// config.Color
typedef struct {
  uint8_t r;
  uint8_t g;
  uint8_t b;
} nubb_config_color_s;

// config.RepeatableCommand
typedef struct {
  const nubb_command_s* commands;
  size_t len;
} nubb_config_command_list_s;

// config.Palette
typedef struct {
  nubb_config_color_s colors[256];
} nubb_config_palette_s;

// config.Fullscreen
typedef enum {
  NUBB_CONFIG_FULLSCREEN_FALSE,
  NUBB_CONFIG_FULLSCREEN_TRUE,
  NUBB_CONFIG_FULLSCREEN_NON_NATIVE,
  NUBB_CONFIG_FULLSCREEN_NON_NATIVE_VISIBLE_MENU,
  NUBB_CONFIG_FULLSCREEN_NON_NATIVE_PADDED_NOTCH,
} nubb_config_fullscreen_e;

// apprt.Target.Key
typedef enum {
  NUBB_TARGET_APP,
  NUBB_TARGET_SURFACE,
} nubb_target_tag_e;

typedef union {
  nubb_surface_t surface;
} nubb_target_u;

typedef struct {
  nubb_target_tag_e tag;
  nubb_target_u target;
} nubb_target_s;

// apprt.action.SplitDirection
typedef enum {
  NUBB_SPLIT_DIRECTION_RIGHT,
  NUBB_SPLIT_DIRECTION_DOWN,
  NUBB_SPLIT_DIRECTION_LEFT,
  NUBB_SPLIT_DIRECTION_UP,
} nubb_action_split_direction_e;

// apprt.action.GotoSplit
typedef enum {
  NUBB_GOTO_SPLIT_PREVIOUS,
  NUBB_GOTO_SPLIT_NEXT,
  NUBB_GOTO_SPLIT_UP,
  NUBB_GOTO_SPLIT_LEFT,
  NUBB_GOTO_SPLIT_DOWN,
  NUBB_GOTO_SPLIT_RIGHT,
} nubb_action_goto_split_e;

// apprt.action.GotoWindow
typedef enum {
  NUBB_GOTO_WINDOW_PREVIOUS,
  NUBB_GOTO_WINDOW_NEXT,
} nubb_action_goto_window_e;

// apprt.action.ResizeSplit.Direction
typedef enum {
  NUBB_RESIZE_SPLIT_UP,
  NUBB_RESIZE_SPLIT_DOWN,
  NUBB_RESIZE_SPLIT_LEFT,
  NUBB_RESIZE_SPLIT_RIGHT,
} nubb_action_resize_split_direction_e;

// apprt.action.ResizeSplit
typedef struct {
  uint16_t amount;
  nubb_action_resize_split_direction_e direction;
} nubb_action_resize_split_s;

// apprt.action.MoveTab
typedef struct {
  ssize_t amount;
} nubb_action_move_tab_s;

// apprt.action.GotoTab
typedef enum {
  NUBB_GOTO_TAB_PREVIOUS = -1,
  NUBB_GOTO_TAB_NEXT = -2,
  NUBB_GOTO_TAB_LAST = -3,
} nubb_action_goto_tab_e;

// apprt.action.Fullscreen
typedef enum {
  NUBB_FULLSCREEN_NATIVE,
  NUBB_FULLSCREEN_MACOS_NON_NATIVE,
  NUBB_FULLSCREEN_MACOS_NON_NATIVE_VISIBLE_MENU,
  NUBB_FULLSCREEN_MACOS_NON_NATIVE_PADDED_NOTCH,
} nubb_action_fullscreen_e;

// apprt.action.FloatWindow
typedef enum {
  NUBB_FLOAT_WINDOW_ON,
  NUBB_FLOAT_WINDOW_OFF,
  NUBB_FLOAT_WINDOW_TOGGLE,
} nubb_action_float_window_e;

// apprt.action.SecureInput
typedef enum {
  NUBB_SECURE_INPUT_ON,
  NUBB_SECURE_INPUT_OFF,
  NUBB_SECURE_INPUT_TOGGLE,
} nubb_action_secure_input_e;

// apprt.action.Readonly
typedef enum {
  NUBB_READONLY_OFF,
  NUBB_READONLY_ON,
} nubb_action_readonly_e;

// apprt.action.DesktopNotification.C
typedef struct {
  const char* title;
  const char* body;
} nubb_action_desktop_notification_s;

// apprt.action.SetTitle.C
typedef struct {
  const char* title;
} nubb_action_set_title_s;

// apprt.action.PromptTitle
typedef enum {
  NUBB_PROMPT_TITLE_SURFACE,
  NUBB_PROMPT_TITLE_TAB,
} nubb_action_prompt_title_e;

// apprt.action.Pwd.C
typedef struct {
  const char* pwd;
} nubb_action_pwd_s;

// apprt.action.OpenConfig
typedef enum {
  // Open the config in the OS default editor.
  NUBB_ACTION_OPEN_CONFIG_OS_OPEN,
  // Open the config in a new window using $EDITOR or $VISUAL
  NUBB_ACTION_OPEN_CONFIG_NEW_WINDOW,
} nubb_action_open_config_e;

// terminal.MouseShape
typedef enum {
  NUBB_MOUSE_SHAPE_DEFAULT,
  NUBB_MOUSE_SHAPE_CONTEXT_MENU,
  NUBB_MOUSE_SHAPE_HELP,
  NUBB_MOUSE_SHAPE_POINTER,
  NUBB_MOUSE_SHAPE_PROGRESS,
  NUBB_MOUSE_SHAPE_WAIT,
  NUBB_MOUSE_SHAPE_CELL,
  NUBB_MOUSE_SHAPE_CROSSHAIR,
  NUBB_MOUSE_SHAPE_TEXT,
  NUBB_MOUSE_SHAPE_VERTICAL_TEXT,
  NUBB_MOUSE_SHAPE_ALIAS,
  NUBB_MOUSE_SHAPE_COPY,
  NUBB_MOUSE_SHAPE_MOVE,
  NUBB_MOUSE_SHAPE_NO_DROP,
  NUBB_MOUSE_SHAPE_NOT_ALLOWED,
  NUBB_MOUSE_SHAPE_GRAB,
  NUBB_MOUSE_SHAPE_GRABBING,
  NUBB_MOUSE_SHAPE_ALL_SCROLL,
  NUBB_MOUSE_SHAPE_COL_RESIZE,
  NUBB_MOUSE_SHAPE_ROW_RESIZE,
  NUBB_MOUSE_SHAPE_N_RESIZE,
  NUBB_MOUSE_SHAPE_E_RESIZE,
  NUBB_MOUSE_SHAPE_S_RESIZE,
  NUBB_MOUSE_SHAPE_W_RESIZE,
  NUBB_MOUSE_SHAPE_NE_RESIZE,
  NUBB_MOUSE_SHAPE_NW_RESIZE,
  NUBB_MOUSE_SHAPE_SE_RESIZE,
  NUBB_MOUSE_SHAPE_SW_RESIZE,
  NUBB_MOUSE_SHAPE_EW_RESIZE,
  NUBB_MOUSE_SHAPE_NS_RESIZE,
  NUBB_MOUSE_SHAPE_NESW_RESIZE,
  NUBB_MOUSE_SHAPE_NWSE_RESIZE,
  NUBB_MOUSE_SHAPE_ZOOM_IN,
  NUBB_MOUSE_SHAPE_ZOOM_OUT,
} nubb_action_mouse_shape_e;

// apprt.action.MouseVisibility
typedef enum {
  NUBB_MOUSE_VISIBLE,
  NUBB_MOUSE_HIDDEN,
} nubb_action_mouse_visibility_e;

// apprt.action.MouseOverLink
typedef struct {
  const char* url;
  size_t len;
} nubb_action_mouse_over_link_s;

// apprt.action.InitialSize
typedef struct {
  uint32_t width;
  uint32_t height;
} nubb_action_initial_size_s;

// apprt.action.ResizeWindow
typedef struct {
  uint32_t width;
  uint32_t height;
} nubb_action_resize_window_s;

// apprt.action.CellSize
typedef struct {
  uint32_t width;
  uint32_t height;
} nubb_action_cell_size_s;

// renderer.Health
typedef enum {
  NUBB_RENDERER_HEALTH_HEALTHY,
  NUBB_RENDERER_HEALTH_UNHEALTHY,
} nubb_action_renderer_health_e;

// apprt.action.KeySequence
typedef struct {
  bool active;
  nubb_input_trigger_s trigger;
} nubb_action_key_sequence_s;

// apprt.action.KeyTable.Tag
typedef enum {
  NUBB_KEY_TABLE_ACTIVATE,
  NUBB_KEY_TABLE_DEACTIVATE,
  NUBB_KEY_TABLE_DEACTIVATE_ALL,
} nubb_action_key_table_tag_e;

// apprt.action.KeyTable.CValue
typedef union {
  struct {
    const char *name;
    size_t len;
  } activate;
} nubb_action_key_table_u;

// apprt.action.KeyTable.C
typedef struct {
  nubb_action_key_table_tag_e tag;
  nubb_action_key_table_u value;
} nubb_action_key_table_s;

// apprt.action.ColorKind
typedef enum {
  NUBB_ACTION_COLOR_KIND_FOREGROUND = -1,
  NUBB_ACTION_COLOR_KIND_BACKGROUND = -2,
  NUBB_ACTION_COLOR_KIND_CURSOR = -3,
} nubb_action_color_kind_e;

// apprt.action.ColorChange
typedef struct {
  nubb_action_color_kind_e kind;
  uint8_t r;
  uint8_t g;
  uint8_t b;
} nubb_action_color_change_s;

// apprt.action.ConfigChange
typedef struct {
  nubb_config_t config;
} nubb_action_config_change_s;

// apprt.action.ReloadConfig
typedef struct {
  bool soft;
} nubb_action_reload_config_s;

// apprt.action.OpenUrlKind
typedef enum {
  NUBB_ACTION_OPEN_URL_KIND_UNKNOWN,
  NUBB_ACTION_OPEN_URL_KIND_TEXT,
  NUBB_ACTION_OPEN_URL_KIND_HTML,
  NUBB_ACTION_OPEN_URL_KIND_OSC8,
} nubb_action_open_url_kind_e;

// apprt.action.OpenUrl.C
typedef struct {
  nubb_action_open_url_kind_e kind;
  const char* url;
  uintptr_t len;
} nubb_action_open_url_s;

// apprt.action.CloseTabMode
typedef enum {
  NUBB_ACTION_CLOSE_TAB_MODE_THIS,
  NUBB_ACTION_CLOSE_TAB_MODE_OTHER,
  NUBB_ACTION_CLOSE_TAB_MODE_RIGHT,
} nubb_action_close_tab_mode_e;

// apprt.surface.Message.ChildExited
typedef struct {
  uint32_t exit_code;
  uint64_t timetime_ms;
} nubb_surface_message_childexited_s;

// terminal.osc.Command.ProgressReport.State
typedef enum {
  NUBB_PROGRESS_STATE_REMOVE,
  NUBB_PROGRESS_STATE_SET,
  NUBB_PROGRESS_STATE_ERROR,
  NUBB_PROGRESS_STATE_INDETERMINATE,
  NUBB_PROGRESS_STATE_PAUSE,
} nubb_action_progress_report_state_e;

// terminal.osc.Command.ProgressReport.C
typedef struct {
  nubb_action_progress_report_state_e state;
  // -1 if no progress was reported, otherwise 0-100 indicating percent
  // completeness.
  int8_t progress;
} nubb_action_progress_report_s;

// apprt.action.CommandFinished.C
typedef struct {
  // -1 if no exit code was reported, otherwise 0-255
  int16_t exit_code;
  // number of nanoseconds that command was running for
  uint64_t duration;
} nubb_action_command_finished_s;

// apprt.action.StartSearch.C
typedef struct {
  const char* needle;
} nubb_action_start_search_s;

// apprt.action.SearchTotal
typedef struct {
  ssize_t total;
} nubb_action_search_total_s;

// apprt.action.SearchSelected
typedef struct {
  ssize_t selected;
} nubb_action_search_selected_s;

// terminal.Scrollbar
typedef struct {
  uint64_t total;
  uint64_t offset;
  uint64_t len;
} nubb_action_scrollbar_s;

// apprt.Action.Key
typedef enum {
  NUBB_ACTION_QUIT,
  NUBB_ACTION_NEW_WINDOW,
  NUBB_ACTION_NEW_TAB,
  NUBB_ACTION_CLOSE_TAB,
  NUBB_ACTION_NEW_SPLIT,
  NUBB_ACTION_CLOSE_ALL_WINDOWS,
  NUBB_ACTION_TOGGLE_MAXIMIZE,
  NUBB_ACTION_TOGGLE_FULLSCREEN,
  NUBB_ACTION_TOGGLE_COMMAND_PALETTE,
  NUBB_ACTION_TOGGLE_VISIBILITY,
  NUBB_ACTION_TOGGLE_BACKGROUND_OPACITY,
  NUBB_ACTION_MOVE_TAB,
  NUBB_ACTION_GOTO_TAB,
  NUBB_ACTION_GOTO_SPLIT,
  NUBB_ACTION_GOTO_WINDOW,
  NUBB_ACTION_RESIZE_SPLIT,
  NUBB_ACTION_EQUALIZE_SPLITS,
  NUBB_ACTION_TOGGLE_SPLIT_ZOOM,
  NUBB_ACTION_PRESENT_TERMINAL,
  NUBB_ACTION_RESET_WINDOW_SIZE,
  NUBB_ACTION_INITIAL_SIZE,
  NUBB_ACTION_CELL_SIZE,
  NUBB_ACTION_SCROLLBAR,
  NUBB_ACTION_DESKTOP_NOTIFICATION,
  NUBB_ACTION_SET_TITLE,
  NUBB_ACTION_SET_TAB_TITLE,
  NUBB_ACTION_PROMPT_TITLE,
  NUBB_ACTION_PWD,
  NUBB_ACTION_MOUSE_SHAPE,
  NUBB_ACTION_MOUSE_VISIBILITY,
  NUBB_ACTION_MOUSE_OVER_LINK,
  NUBB_ACTION_RENDERER_HEALTH,
  NUBB_ACTION_OPEN_CONFIG,
  NUBB_ACTION_FLOAT_WINDOW,
  NUBB_ACTION_SECURE_INPUT,
  NUBB_ACTION_KEY_SEQUENCE,
  NUBB_ACTION_KEY_TABLE,
  NUBB_ACTION_COLOR_CHANGE,
  NUBB_ACTION_RELOAD_CONFIG,
  NUBB_ACTION_CONFIG_CHANGE,
  NUBB_ACTION_CLOSE_WINDOW,
  NUBB_ACTION_RING_BELL,
  NUBB_ACTION_SELECTION_CHANGED,
  NUBB_ACTION_UNDO,
  NUBB_ACTION_REDO,
  NUBB_ACTION_OPEN_URL,
  NUBB_ACTION_SHOW_CHILD_EXITED,
  NUBB_ACTION_PROGRESS_REPORT,
  NUBB_ACTION_COMMAND_FINISHED,
  NUBB_ACTION_START_SEARCH,
  NUBB_ACTION_END_SEARCH,
  NUBB_ACTION_SEARCH_TOTAL,
  NUBB_ACTION_SEARCH_SELECTED,
  NUBB_ACTION_READONLY,
  NUBB_ACTION_COPY_TITLE_TO_CLIPBOARD,
  NUBB_ACTION_MOVE_TAB_TO_NEW_WINDOW,
  NUBB_ACTION_RESIZE_WINDOW,
} nubb_action_tag_e;

typedef union {
  nubb_action_split_direction_e new_split;
  nubb_action_fullscreen_e toggle_fullscreen;
  nubb_action_move_tab_s move_tab;
  nubb_action_goto_tab_e goto_tab;
  nubb_action_goto_split_e goto_split;
  nubb_action_goto_window_e goto_window;
  nubb_action_resize_split_s resize_split;
  nubb_action_initial_size_s initial_size;
  nubb_action_resize_window_s resize_window;
  nubb_action_cell_size_s cell_size;
  nubb_action_scrollbar_s scrollbar;
  nubb_action_desktop_notification_s desktop_notification;
  nubb_action_set_title_s set_title;
  nubb_action_set_title_s set_tab_title;
  nubb_action_prompt_title_e prompt_title;
  nubb_action_pwd_s pwd;
  nubb_action_mouse_shape_e mouse_shape;
  nubb_action_mouse_visibility_e mouse_visibility;
  nubb_action_mouse_over_link_s mouse_over_link;
  nubb_action_renderer_health_e renderer_health;
  nubb_action_float_window_e float_window;
  nubb_action_secure_input_e secure_input;
  nubb_action_key_sequence_s key_sequence;
  nubb_action_key_table_s key_table;
  nubb_action_color_change_s color_change;
  nubb_action_reload_config_s reload_config;
  nubb_action_config_change_s config_change;
  nubb_action_open_url_s open_url;
  nubb_action_close_tab_mode_e close_tab_mode;
  nubb_surface_message_childexited_s child_exited;
  nubb_action_progress_report_s progress_report;
  nubb_action_command_finished_s command_finished;
  nubb_action_start_search_s start_search;
  nubb_action_search_total_s search_total;
  nubb_action_search_selected_s search_selected;
  nubb_action_readonly_e readonly;
  nubb_action_open_config_e open_config;
} nubb_action_u;

typedef struct {
  nubb_action_tag_e tag;
  nubb_action_u action;
} nubb_action_s;

typedef void (*nubb_runtime_wakeup_cb)(void*);
typedef nubb_clipboard_read_result_e (*nubb_runtime_read_clipboard_cb)(
    void*,
    nubb_clipboard_e,
    void*,
    const char* const*,
    size_t,
    bool);
typedef void (*nubb_runtime_confirm_read_clipboard_cb)(
    void*,
    const nubb_clipboard_confirm_s*,
    void*,
    nubb_clipboard_request_e);
typedef void (*nubb_runtime_write_clipboard_cb)(void*,
                                                   nubb_clipboard_e,
                                                   const nubb_clipboard_content_s*,
                                                   size_t,
                                                   bool);
typedef void (*nubb_runtime_close_surface_cb)(void*, bool);
typedef bool (*nubb_runtime_action_cb)(nubb_app_t,
                                          nubb_target_s,
                                          nubb_action_s);

typedef struct {
  void* userdata;
  bool supports_selection_clipboard;
  nubb_runtime_wakeup_cb wakeup_cb;
  nubb_runtime_action_cb action_cb;
  nubb_runtime_read_clipboard_cb read_clipboard_cb;
  nubb_runtime_confirm_read_clipboard_cb confirm_read_clipboard_cb;
  nubb_runtime_write_clipboard_cb write_clipboard_cb;
  nubb_runtime_close_surface_cb close_surface_cb;
} nubb_runtime_config_s;

//-------------------------------------------------------------------
// Published API

NUBB_API int nubb_init(uintptr_t, char**);
NUBB_API void nubb_cli_try_action(void);
NUBB_API nubb_info_s nubb_info(void);
NUBB_API void nubb_string_free(nubb_string_s);

NUBB_API nubb_config_t nubb_config_new();
NUBB_API void nubb_config_free(nubb_config_t);
NUBB_API nubb_config_t nubb_config_clone(nubb_config_t);
NUBB_API void nubb_config_load_cli_args(nubb_config_t);
NUBB_API void nubb_config_load_file(nubb_config_t, const char*);
NUBB_API void nubb_config_load_default_files(nubb_config_t);
NUBB_API void nubb_config_load_recursive_files(nubb_config_t);
NUBB_API void nubb_config_finalize(nubb_config_t);
NUBB_API bool nubb_config_get(nubb_config_t, void*, const char*, uintptr_t);
NUBB_API nubb_input_trigger_s nubb_config_trigger(nubb_config_t,
                                                              const char*,
                                                              uintptr_t);
NUBB_API bool nubb_config_key_is_binding(nubb_config_t, nubb_input_key_s);
NUBB_API uint32_t nubb_config_diagnostics_count(nubb_config_t);
NUBB_API nubb_diagnostic_s nubb_config_get_diagnostic(nubb_config_t, uint32_t);
NUBB_API nubb_string_s nubb_config_open_path(void);

NUBB_API nubb_app_t nubb_app_new(const nubb_runtime_config_s*,
                                             nubb_config_t);
NUBB_API void nubb_app_free(nubb_app_t);
NUBB_API void nubb_app_tick(nubb_app_t);
NUBB_API void* nubb_app_userdata(nubb_app_t);
NUBB_API void nubb_app_set_focus(nubb_app_t, bool);
NUBB_API bool nubb_app_key(nubb_app_t, nubb_input_key_s);
NUBB_API void nubb_app_keyboard_changed(nubb_app_t);
NUBB_API void nubb_app_update_config(nubb_app_t, nubb_config_t);
NUBB_API bool nubb_app_needs_confirm_quit(nubb_app_t);
NUBB_API void nubb_app_set_color_scheme(nubb_app_t, nubb_color_scheme_e);

NUBB_API nubb_surface_config_s nubb_surface_config_new();

NUBB_API nubb_surface_t nubb_surface_new(nubb_app_t,
                                                     const nubb_surface_config_s*);
NUBB_API void nubb_surface_free(nubb_surface_t);
NUBB_API void* nubb_surface_userdata(nubb_surface_t);
NUBB_API nubb_app_t nubb_surface_app(nubb_surface_t);
NUBB_API nubb_surface_config_s nubb_surface_inherited_config(nubb_surface_t, nubb_surface_context_e);
NUBB_API void nubb_surface_update_config(nubb_surface_t, nubb_config_t);
NUBB_API bool nubb_surface_needs_confirm_quit(nubb_surface_t);
NUBB_API bool nubb_surface_process_exited(nubb_surface_t);
NUBB_API void nubb_surface_set_content_scale(nubb_surface_t, double, double);
NUBB_API void nubb_surface_set_focus(nubb_surface_t, bool);
NUBB_API void nubb_surface_set_occlusion(nubb_surface_t, bool);
NUBB_API void nubb_surface_set_size(nubb_surface_t, uint32_t, uint32_t);
NUBB_API nubb_surface_size_s nubb_surface_size(nubb_surface_t);
NUBB_API void nubb_surface_set_color_scheme(nubb_surface_t,
                                                     nubb_color_scheme_e);
NUBB_API nubb_input_mods_e nubb_surface_key_translation_mods(nubb_surface_t,
                                                                         nubb_input_mods_e);
NUBB_API bool nubb_surface_key(nubb_surface_t, nubb_input_key_s);
NUBB_API bool nubb_surface_key_is_binding(nubb_surface_t,
                                                   nubb_input_key_s,
                                                   nubb_binding_flags_e*);
NUBB_API void nubb_surface_text(nubb_surface_t, const char*, uintptr_t);
NUBB_API void nubb_surface_paste_text(nubb_surface_t, const char*, uintptr_t);
NUBB_API void nubb_surface_preedit(nubb_surface_t, const char*, uintptr_t);
NUBB_API bool nubb_surface_mouse_captured(nubb_surface_t);
NUBB_API bool nubb_surface_mouse_button(nubb_surface_t,
                                                 nubb_input_mouse_state_e,
                                                 nubb_input_mouse_button_e,
                                                 nubb_input_mods_e);
NUBB_API void nubb_surface_mouse_pos(nubb_surface_t,
                                              double,
                                              double,
                                              nubb_input_mods_e);
NUBB_API void nubb_surface_mouse_scroll(nubb_surface_t,
                                                 double,
                                                 double,
                                                 nubb_input_scroll_mods_t);
NUBB_API void nubb_surface_mouse_pressure(nubb_surface_t, uint32_t, double);
NUBB_API void nubb_surface_ime_point(nubb_surface_t, double*, double*, double*, double*);
NUBB_API void nubb_surface_request_close(nubb_surface_t);
NUBB_API void nubb_surface_split(nubb_surface_t, nubb_action_split_direction_e);
NUBB_API void nubb_surface_split_focus(nubb_surface_t,
                                                nubb_action_goto_split_e);
NUBB_API void nubb_surface_split_resize(nubb_surface_t,
                                                 nubb_action_resize_split_direction_e,
                                                 uint16_t);
NUBB_API void nubb_surface_split_equalize(nubb_surface_t);
NUBB_API bool nubb_surface_binding_action(nubb_surface_t, const char*, uintptr_t);
NUBB_API void nubb_surface_complete_clipboard_request(
    nubb_surface_t,
    const nubb_clipboard_complete_s*,
    void*);
NUBB_API void nubb_surface_deny_clipboard_request(nubb_surface_t,
                                                           void*);
NUBB_API bool nubb_surface_has_selection(nubb_surface_t);
NUBB_API bool nubb_surface_read_selection(nubb_surface_t, nubb_text_s*);
NUBB_API bool nubb_surface_read_text(nubb_surface_t,
                                              nubb_selection_s,
                                              nubb_text_s*);
NUBB_API void nubb_surface_free_text(nubb_surface_t, nubb_text_s*);

#ifdef __APPLE__
NUBB_API void nubb_surface_set_display_id(nubb_surface_t, uint32_t);
NUBB_API void* nubb_surface_quicklook_font(nubb_surface_t);
NUBB_API bool nubb_surface_quicklook_word(nubb_surface_t, nubb_text_s*);
#endif

// APIs I'd like to get rid of eventually but are still needed for now.
// Don't use these unless you know what you're doing.
NUBB_API void nubb_set_window_background_blur(nubb_app_t, void*);

// Benchmark API, if available.
NUBB_API bool nubb_benchmark_cli(const char*, const char*);

#ifdef __cplusplus
}
#endif

#endif /* NUBB_H */
