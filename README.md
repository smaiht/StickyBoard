# StickyBoard

macOS floating overlay — pin text and images to have them always visible.

## How it works

Menu bar app (📌) with a transparent fullscreen overlay. Elements float on screen across all desktops.

- **Left click** 📌 → menu (add text, paste, switch desks)
- **Right click** 📌 → toggle edit mode

## Edit mode

- Drag elements to move them
- Click element → select (shows handles: resize, rotate, delete, context menu)
- Click empty space → deselect / exit edit mode
- Esc → exit edit mode
- Click text → edit inline (Enter = new line, Esc = done)

## Features

- Multiple desks (workspaces)
- Text and image elements
- Rotation, resize
- Paste from clipboard (text or image)
- Data saved to `~/Library/Application Support/StickyBoard/`

## Build

```
brew install xcodegen  # if needed
xcodegen generate
xcodebuild -scheme StickyBoard -configuration Release build
```

## Requirements

macOS 13+
