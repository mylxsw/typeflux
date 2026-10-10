# JSON formatting

Requires Python 3. Formats selected or typed JSON locally.

- `json` formats selected JSON.
- `json {"a":1}` formats typed JSON.
- `json min` compacts selected JSON.
- `json min { "a": 1 }` compacts typed JSON.
- `json pretty` explicitly formats selected JSON.

Running `json` with selected JSON and no argument writes the formatted result back to the selection. Runs with an argument (including `min` or `pretty`) keep the result in the launcher: Return copies it, and Option-Return writes it back when requested. Invalid input produces an error.
