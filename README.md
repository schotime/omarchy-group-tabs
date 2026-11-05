# Group Tabs

Chrome-style tabs with app icons for [Hyprland](https://hypr.land) window
groups, as an [Omarchy](https://omarchy.org) shell service plugin.

Hyprland's groupbar can't draw icons. This plugin keeps the groupbar on but
fully transparent, so it still reserves the strip above each group, and paints
tabs over that strip in a layer surface:

- An app icon and title on each tab, matched the way the launcher and bar find icons
- Tabs cap at 300px and shrink evenly to share the strip once they don't fit
- The active tab is filled in the window's colour and flares into it, Chrome style
- The strip is rounded on top and joined to the window's top corners

The overlay handles the strip's input itself: click focuses a tab (without
moving the cursor), middle-click closes it, the wheel cycles tabs, and dragging
a tab sideways reorders it.

## Install

```sh
omarchy plugin add https://github.com/schotime/omarchy-group-tabs --enable
```

## Required Hyprland config

The plugin draws over the groupbar, so the groupbar must be on, transparent,
and the same height as the plugin's strip. Add this to
`~/.config/hypr/looknfeel.lua`:

```lua
local clear = "rgba(00000000)"
hl.config({
  group = {
    groupbar = {
      enabled = true,
      render_titles = false,
      gradients = true,
      blur = false,
      height = 30,
      indicator_height = 0,
      indicator_gap = 0,
      gaps_in = 0,
      gaps_out = 0,
      keep_upper_gap = false,
      rounding = 0,
      gradient_rounding = 0,
      middle_click_close = true,
      col = {
        active = clear,
        inactive = clear,
        locked_active = clear,
        locked_inactive = clear,
      },
    },
  },
})

-- The overlay must sit exactly on the groupbar; a layer animation would make
-- it lag behind the window it labels.
hl.layer_rule({ match = { namespace = "^omarchy-group-tabs$" }, no_anim = true, blur = true, ignore_alpha = 0.05 })
```

Keep `height` and `gaps_out` in step with `stripHeight` and `stripGap` at the
top of `GroupTabs.qml`. `maxTabWidth` there sets the widest a tab gets.

## Notes

- Service plugins aren't hot-reloaded: run `omarchy restart shell` after editing.
- Tab clicks focus with `cursor:no_warps` turned on just for that focus, then
  set back to `false`.
- Needs Hyprland 0.56+ (Lua config and Lua `hyprctl dispatch`).
