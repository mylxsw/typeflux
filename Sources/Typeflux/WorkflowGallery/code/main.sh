#!/bin/zsh
# code [name]: the folders in your project folders, most recently changed first.
# Return opens the chosen one in your editor, Option-Return shows it in Finder,
# Command-C copies its path.
# Options: "roots" lists where to look; "editor" names the editor (found by itself when empty).
emulate -L zsh

# A JSON string, with the characters JSON needs escaped.
json() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  print -rn -- "\"$s\""
}

editor=$TYPEFLUX_OPTION_EDITOR
if [[ -z $editor ]]; then
  for candidate in "Visual Studio Code" "Cursor" "Zed" "Sublime Text" "Nova" "BBEdit"; do
    if [[ -d "/Applications/$candidate.app" || -d "$HOME/Applications/$candidate.app" ]]; then
      editor=$candidate
      break
    fi
  done
fi

tilde='~'
roots=(${=${TYPEFLUX_OPTION_ROOTS:-"$tilde/Projects $tilde/Code $tilde/Developer $tilde/src $tilde/GitHub"}})
filter=${(L)1}
items=()
for root in $roots; do
  root=${root/#$tilde/$HOME}
  # Folders only, most recently changed first.
  for folder in $root/*(N/om); do
    name=${folder:t}
    [[ -n $filter && ${(L)name} != *$filter* ]] && continue
    item="{\"uid\": $(json $folder), \"title\": $(json $name), \"subtitle\": $(json ${folder/#$HOME/$tilde})"
    item+=", \"arg\": $(json $folder), \"action\": \"open\""
    [[ -n $editor ]] && item+=", \"app\": $(json $editor)"
    item+=", \"icon\": {\"type\": \"fileicon\", \"path\": $(json $folder)}"
    item+=", \"mods\": {\"alt\": {\"action\": \"reveal\", \"subtitle\": \"Show in Finder\"}}}"
    items+=("$item")
    (( ${#items} >= 50 )) && break 2
  done
done

if (( ${#items} == 0 )); then
  looked=${(j:, :)roots}
  items=("{\"title\": \"No projects found\", \"subtitle\": $(json "Looked in ${looked//$HOME/$tilde}"), \"valid\": false}")
fi
print -r -- "{\"items\": [${(j:, :)items}]}"
