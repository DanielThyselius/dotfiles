# If not running interactively, don't do anything (leave this at the top of this file)
[[ $- != *i* ]] && return

# All the default Omarchy aliases and functions
# (don't mess with these directly, just overwrite them here!)
source ~/.local/share/omarchy/default/bash/rc

# Add your own exports, aliases, and functions here.
#
# Make an alias for invoking commands you use constantly
# alias p='python'

. "$HOME/.local/share/../bin/env"

# Bun global bin (archon CLI)
export PATH="$HOME/.cache/.bun/bin:$PATH"

alias gt='git-town'

# Ramudden Workspace
export RAMUDDEN_WORKSPACE_PATH="/home/daniel/Source/ramudden"

# peon-ping quick controls
alias peon="bash /home/daniel/.claude/hooks/peon-ping/peon.sh"
[ -f /home/daniel/.claude/hooks/peon-ping/completions.bash ] && source /home/daniel/.claude/hooks/peon-ping/completions.bash
