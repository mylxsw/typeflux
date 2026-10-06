# Open Project

- `code` — lists the folders in your project folders, most recently changed first.
- `code web` — only the projects whose name contains “web”.

Return opens the chosen project in your editor (Visual Studio Code, Cursor, Zed, Sublime Text, Nova or BBEdit, whichever is installed first; Finder without one). Option-Return shows it in Finder, Command-C copies its path.

Change where it looks and which editor it uses in the keyword's options in the workflow editor:

- `roots`: the folders to look in, separated by spaces (`~/Projects ~/Code ~/Developer ~/src ~/GitHub`).
- `editor`: an application name, such as `Xcode`.

The script prints an item list (`{"items": [...]}`) in the format of Alfred's Script Filter, with `app` naming the application that opens each folder.
