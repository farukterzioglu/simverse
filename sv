#!/usr/bin/env bash

set -e -o pipefail

VERSION=0.1
HOMEPAGE=https://github.com/darwin/simverse

LAUNCH_DIR=$(pwd -P)

cd "$(dirname "${BASH_SOURCE[0]}")"

export SIMVERSE_HOME="$(pwd -P)"

. _defaults.sh

REQUIRED="variable not set or empty, (haven't you sourced _defaults.sh?)"

RECIPES_DIR="$SIMVERSE_HOME/recipes"
TOOLBOX_DIR="$SIMVERSE_HOME/toolbox"

SIMVERSE_WORKSPACE=${SIMVERSE_WORKSPACE:?REQUIRED}

DEFAULT_SIMNET_NAME=${DEFAULT_SIMNET_NAME:?REQUIRED}
DEFAULT_RECIPE_NAME=${DEFAULT_RECIPE_NAME:?REQUIRED}
DEFAULT_STATE_NAME=${DEFAULT_STATE_NAME:?REQUIRED}

KNOWN_REPOS=(btcd btcwallet lnd)

# error codes
NO_ERR=0
ERR_UNSUPPORTED_FLAG=10
ERR_SIMNET_DOES_NOT_EXIST=11
ERR_SIMNET_ALREADY_EXISTS=12
ERR_STATE_NOT_FOUND=13
ERR_TOO_FEW_ARGUMENTS=14
ERR_SIMNET_MUST_NOT_BE_RUNNING=15
ERR_RECIPE_NOT_FOUND=16
ERR_INVALID_COMMAND=17
ERR_INVALID_STATE_COMMAND=18
ERR_INVALID_REPOS_COMMAND=19
ERR_STATE_ALREADY_EXISTS=20
ERR_UNKNOWN_REPO=21
ERR_SOURCE_REPO_NOT_FOUND=22
ERR_DESTINATION_REPO_EXISTS=23

FAST_CP_OPTS=""
case "$OSTYPE" in
  darwin*) FAST_CP_OPTS="-c" ;; # support fast cloning on APFS under macOS
esac

# -- utils ------------------------------------------------------------------------------------------------------------------

pushd() {
    command pushd "$@" > /dev/null
}

popd() {
    command popd "$@" > /dev/null
}

echo_err() {
  printf "\e[31m%s\e[0m\n" "$*" >&2;
}

# https://stackoverflow.com/a/17841619/84283
join_by() {
 local IFS="$1"
 shift
 echo "$*"
}

say() {
  if [[ -z "$FLAG_QUIET" ]]; then
    echo "$@"
  fi
}

present() {
  if [[ -z "$FLAG_QUIET" ]]; then
    local line="$(join_by " " ${@/eval/})"
    printf "\$ \e[33m%s\e[0m\n" "$line"
  fi
  "$@"
}

# -- usage subsystem --------------------------------------------------------------------------------------------------------

show_main_help() {
  cat <<EOF
SimVerse v${VERSION}.

A generator of simnet clusters for lnd and friends.

Usage: ./sv [command] [args...]

Commands:

  create    create a new simnet based on a recipe
  destroy   destroy existing named simnet
  list      list existing simnets
  enter     enter a named simnet
  state     perform state operations on a simnet
  repos     perform operations on code repositories
  help      this help page

Run \`./sv help <command>\` for specific usage.
Run \`./sv help <topic>\` to learn about general concepts.

Topics: simnet, recipes, workspace, toolbox, aliases.

Please visit '${HOMEPAGE}' for further info.
EOF
}

show_create_help() {
  cat <<EOF
Usage: ./sv create [-f] [name] [recipe]

Creates a new simnet with \`name\` (default) based on \`recipe\` (default).
On success, prints a path to generated simnet working folder in your workspace.

Flags:
  -f,--force    force creation by destroying previous simnet

Recipe should be name of a script in \`recipes\` folder. It specifies requested simnet
parameters and drives the generator.

Read more about recipes via \`./sv help recipes\`
EOF
}

show_destroy_help() {
  cat <<EOF
Usage: ./sv destroy [name]

Deletes a simnet with \`name\` (default).
EOF
}

show_enter_help() {
  cat <<EOF
Usage: ./sv enter [name]

Enters into a sub-shell with environment prepared for simnet with \`name\` (default).

You typically use this command to start working with a given simnet. In the sub-shell we:

  * switch working directory into simnet's folder
  * set PATH to additionally contain toolbox and aliases
EOF
}

show_simnet_help() {
  cat <<EOF
About simnets

Simnet is a cluster of bitcoin and lighting nodes talking to each other.
Simnets are used during development to test different scenarios/workflow
where multiple nodes are required.

Simnets can have different sizes and shapes. They can be heavily parametrized.

This tool aims to help with simnet creation and maintenance.

The goal is to:

  * easily generate a simnet based on given parameters
  * easily manage state of a simnet (e.g. for future replays)
  * somewhat isolate simnet from host machine (via docker)
  * provide cross-platform solution (macos, linux)

Typical simnet folder structure is:

  _workspace/[simnet_name]/
    _states/
      master/
        certs/
        lnd-data-alice/
        btcd-data-btcd1/
        ...
      ...
    _volumes -> _states/master
    aliases/
    docker/
    helpers/
    repos/
    toolbox/
    dc
    docker-compose.yml

Feel free to look around. Below we discuss state management.

Simnet state

All docker containers have their state mapped to host machine into _volumes folder.
It contains btcd's data directories, lnd's data directories and similar.
When you stop docker containers and later run them again, the state will persist.

When you look at _volumes you realize that it is just a symlink somewhere into _states directory.
Typically pointing to 'master', which is the default state.

You can manage states via \`./sv state ...\`.
Those are just convenience commands to copy/switch _volumes symlink between states.

This is an advanced feature for people who want to snapshot a state for further rollbacks.
It can be also used for replays during automated testing.


A note on hybrid simnets

By default, simnet is generated in a way that all nodes live inside docker containers
managed by docker-compose. For convenience we map all relevant ports to host machine.
This allows running another node directly on host machine and interact with nodes in
the cluster inside docker.

This is expected workflow for someone who want to develop particular feature and
needs supporting simnet "in the background".


A note on debugging nodes inside docker

Currently all nodes run go-based software. We support go-delve debugger which is
prepared to be attached to go processes inside container and offer port mappings
to be controlled from host machine. Please see \`attach_dlv\` command inside the toolbox.
EOF
}

show_list_help() {
  cat <<EOF
Usage: ./sv list [filter]

Lists all available simnets by name. Optionally you can filter the list using a case-insensitive substring.

Run \`./sv help simnet\` to learn what is a simnet.
EOF
}

show_state_help() {
  cat <<EOF
Usage: ./sv state [sub-command] ...

Manipulates simnet state.

Sub-commands:

  show     show currently selected state in a given simnet
  clone    clone existing state in a given simnet
  switch   switch selection to a named state in a given simnet
  list     list states for a given simnet
  rm       remove a named state in a given simnet

./sv state show [simnet_name]
./sv state clone [--force] [--switch] [simnet_name] <new_state_name> [old_state_name]
./sv state switch [simnet_name] [state_name]
./sv state list [simnet_name] [filter]
./sv state rm [simnet_name] <state_name>

Run \`./sv help simnet\` to learn about simnet states.
EOF
}

show_repos_help() {
  cat <<EOF
Usage: ./sv repos [sub-command] ...

Manipulates code repositories.

Sub-commands:

  init     init default repos (git clone)
  update   update default repos (git pull)
  clone    clone existing repo under a new name
  list     list repos
  rm       remove repo(s)

./sv repos init [repo_name] [...]
./sv repos update [repo_name] [...]
./sv repos clone [--force] <repo_name> <new_repo_name>
./sv repos list [filter]
./sv repos rm [repo_name] [...]
EOF
}

show_recipes_help() {
  cat <<EOF
About recipes

Simnets can have different sizes and shapes. They can be heavily parametrized.
Recipe is a script describing how to build a given simnet.

An example of a simple recipe:

    . cookbook/cookbook.sh

    prelude

    add btcd btcd

    add lnd alice
    add lnd bob

Recipes are located under \`recipes\` folder.
Say, we store above recipe as \`recipes/example.sh\`.

By running \`./sv create mysn example\`, we create a new simnet named \`mysn\`
which has one btcd node and two lnd nodes, all with default settings.

Recipes are bash scripts executed as the last step in simnet creation.
That means you can do anything bash can do to tweak given simnet.
To make your life easier, we provide a simple library "cookbook" for building
simnet on step-by-step basis with sane defaults.

We are not going to document the cookbook here. Please refer to its sources.

Please look around in \`recipes\` folder and see how existing recipes are done.
EOF
}

show_workspace_help() {
  cat <<EOF
About workspace

Workspace is a working folder where your generated simnets get stored.
By default it is under \`_workspace\` but you can control it
via SIMVERSE_WORKSPACE environmental variable.

Each simnet has a name given to it during \`./sv create [name]\` call.
Workspace contains a folder for each simnet named after it.

You can enter your simnet via \`./sv enter [name]\`.
EOF
}

show_toolbox_help() {
  cat <<EOF
About toolbox

Toolbox is a set of convenience scripts for typical interaction with simnet.

When you enter a simnet via \`./sv enter [name]\`, toolbox folder is added to your PATH.

Explore \`toolbox\` folder for the details:

`find "${TOOLBOX_DIR}" -maxdepth 1 -perm -744 -type f -exec basename {} \; | sort | sed 's/^/  /'`

EOF
}

show_aliases_help() {
  cat <<EOF
About aliases

Aliases are scripts generated depending on shape/parameters of your simnet.

When you enter a simnet via \`./sv enter [name]\`. Aliases folder is added to your PATH.

For example default simnet will generate following aliases for you:

  alice
  bob
  btcd
  btcctl -> btcd
  lncli -> alice

Aliases are convenience shortcuts to control tools for individual nodes (named by simnet recipe).

Additionally there will be generated \`btcctl\` symlink pointing to first btcd node. And \`lncli\`
symlink pointing to the first lnd node. This comes handy for asking general questions about networks
not specific to exact node.
EOF
}

show_help() {
  local command=$1
  case "$command" in
    "create") show_create_help ;;
    "destroy") show_destroy_help ;;
    "enter") show_enter_help ;;
    "list") show_list_help ;;
    "state") show_state_help ;;
    "repo"*) show_repos_help ;;
    "recipe"*) show_recipes_help ;;
    "workspace"*) show_workspace_help ;;
    "simnet"*) show_simnet_help ;;
    "toolbox") show_toolbox_help ;;
    "alias"*) show_aliases_help ;;
    *) show_main_help ;;
  esac
}

# -- helpers ----------------------------------------------------------------------------------------------------------------

cook_recipe() {
  local recipe_script=$1
  local simnet_name=$2
  pushd "$RECIPES_DIR"
  present ${recipe_script} ${simnet_name} "$SIMVERSE_WORKSPACE_ABSOLUTE"
  popd
}

validate_simnet_exists() {
  local simnet_name=$1

  pushd "$SIMVERSE_WORKSPACE_ABSOLUTE"
  if [[ ! -d "$simnet_name" ]]; then
    echo_err "simnet '$simnet_name' does not exist in '$SIMVERSE_WORKSPACE_ABSOLUTE'"
    exit ${ERR_SIMNET_DOES_NOT_EXIST}
  fi
  popd
}

get_state_dir() {
  local simnet_name=$1
  local state_name=$2
  local states_dir_prefix="$simnet_name/_states"
  if [[ -z "$state_name" ]]; then
    echo "$states_dir_prefix"
  else
    echo "$states_dir_prefix/$state_name"
  fi
}

get_selected_state_dir() {
  local simnet_name=$1
  pushd "$SIMVERSE_WORKSPACE_ABSOLUTE"
  cd "$simnet_name"
  current_state_dir=$(cd "_volumes"; pwd -P) # resolves via symlink
  current_state_dir_without_prefix=${current_state_dir#${SIMVERSE_WORKSPACE_ABSOLUTE}/}
  popd
  echo "$current_state_dir_without_prefix"
}

LAST_REPORTED_DIR=""
present_cwd() {
  if [[ -z "$FLAG_QUIET" ]]; then
    local dir_absolute=$(pwd -P)
    if [[ ! "$LAST_REPORTED_DIR" == "$dir_absolute" ]]; then
      LAST_REPORTED_DIR="$dir_absolute"
      reposdir_without_prefix=${dir_absolute#${LAUNCH_DIR}/}
      printf "(in) \e[34m%s\e[0m\n" "$reposdir_without_prefix"
    fi
  fi
}

make_sure_simnet_is_not_running() {
  if [[ -n "$FLAG_FORCE" ]]; then
    return
  fi

  nc -z "localhost" "$SIMVERSE_PRE_SIGNAL_PORT_ON_HOST" > /dev/null 2>&1
  result=$?
  if [[ "$result" -eq 0 ]]; then
    # _pre is running
    echo_err "some simnet seems to be running, please shut it down first or force this with the -f flag"
    exit ${ERR_SIMNET_MUST_NOT_BE_RUNNING}
  fi
}

are_known_repos_initialized() {
  pushd "$SIMVERSE_REPOS_ABSOLUTE"
  for repo in ${KNOWN_REPOS[@]}; do
    if [[ ! -e "$repo" ]]; then
      popd
      return 1
    fi
  done
  popd
}

make_sure_repos_are_initialized() {
  if [[ -n "$FLAG_FORCE" ]]; then
    return
  fi

  if ! are_known_repos_initialized; then
    read -n 1 -p "Repos seem to be not initialized in '$SIMVERSE_REPOS'. Do you want to init them now?(y/n)" answer; echo ""
    if [[ "$answer" == "y" ]]; then
      pushd "$SIMVERSE_HOME"
      present_cwd
      present ./sv repos init
      popd
    fi
  fi
}

# -- commands ---------------------------------------------------------------------------------------------------------------

# create [-f] [simnet_name] [recipe_name]
create_simnet() {
  local simnet_name=${1:-$DEFAULT_SIMNET_NAME}
  local recipe_alias=${2:-$DEFAULT_RECIPE_NAME}

  local recipe_script="$RECIPES_DIR/${recipe_alias}.sh" # TODO: allow full path alternative

  if [[ ! -f "$recipe_script" ]]; then
    echo_err "the recipe file does not exist at '$recipe_script'"
    exit ${ERR_RECIPE_NOT_FOUND}
  fi

  present_cwd

  if [[ -d "$simnet_name" ]]; then
    if [[ -n "$FLAG_FORCE" && -n "$simnet_name" ]]; then
      # we don't want to delete simnet directory, this would confuse interactive shells which may be entered inside
      present find "$simnet_name" -mindepth 1 -maxdepth 1 -exec rm -rf {} \;
    else
      echo_err "simnet '$simnet_name' already exists, delete it first with \`./sv destroy $simnet_name\` or force overwrite with the -f flag"
      exit ${ERR_SIMNET_ALREADY_EXISTS}
    fi
  fi

  make_sure_repos_are_initialized

  cook_recipe "$recipe_script" "$simnet_name"
  present cd "$simnet_name"

  pwd -P
}

# ---------------------------------------------------------------------------------------------------------------------------

# destroy [simnet_name]
destroy_simnet() {
  local simnet_name=${1:-$DEFAULT_SIMNET_NAME}

  validate_simnet_exists "$simnet_name"

  make_sure_simnet_is_not_running

  present_cwd
  present rm -rf "$simnet_name"
}

# ---------------------------------------------------------------------------------------------------------------------------

# enter [simnet_name]
enter_simnet() {
  local simnet_name=${1:-$DEFAULT_SIMNET_NAME}

  validate_simnet_exists "$simnet_name"

  present_cwd
  present cd "$simnet_name"
  local absolute_simnet_dir=$(pwd -P)
  export PATH=$PATH:"$absolute_simnet_dir/toolbox":"$absolute_simnet_dir/aliases"
  present exec "$SHELL"
}

# ---------------------------------------------------------------------------------------------------------------------------

# list [filter]
list_simnets() {
  local filter=$1
  find . -maxdepth 1 -type d -exec basename {} \; | tail -n "+2" | sort | grep -i "$filter"
}

# ---------------------------------------------------------------------------------------------------------------------------

# state show [simnet_name]
show_state() {
  local simnet_name=${1:-$DEFAULT_SIMNET_NAME}

  validate_simnet_exists "$simnet_name"

  current_state_dir=$(get_selected_state_dir "$simnet_name")

  basename "$current_state_dir"
}

# state rm [simnet_name] <state_name>
rm_state() {
  local simnet_name=$1
  local state_name=$2

  # special case for optional simnet_name
  if [[ $# -lt 2 ]]; then
    simnet_name=${DEFAULT_SIMNET_NAME}
    state_name=${1:-$DEFAULT_STATE_NAME}
  fi

  validate_simnet_exists "$simnet_name"

  make_sure_simnet_is_not_running

  present_cwd

  local state_dir=$(get_state_dir "$simnet_name" "$state_name")

  if [[ ! -d "$state_dir" ]]; then
    echo_err "state '$state_dir' does not exist"
    exit ${ERR_STATE_NOT_FOUND}
  fi

  current_state_dir=$(get_selected_state_dir "$simnet_name")

  present rm -rf "$state_dir"

  if [[ "$current_state_dir" == "$state_dir" ]]; then
     say "you have removed currently selected state, keeping it as empty directory"
     present mkdir -p "$state_dir"
  fi
}

# state switch [simnet_name] <state_name>
switch_state() {
  local simnet_name=$1
  local state_name=$2

  # special case for optional simnet_name
  if [[ $# -lt 2 ]]; then
    simnet_name=${DEFAULT_SIMNET_NAME}
    state_name=${1:-$DEFAULT_STATE_NAME}
  fi

  validate_simnet_exists "$simnet_name"

  make_sure_simnet_is_not_running

  present_cwd

  local state_dir=$(get_state_dir "$simnet_name" "$state_name")

  current_state_dir=$(get_selected_state_dir "$simnet_name")
  if [[ "$current_state_dir" == "$state_dir" ]]; then
    say "already on '$current_state_dir'"
    exit ${NO_ERR}
  fi

  if [[ ! -d "$state_dir" ]]; then
    echo_err "state '$state_dir' does not exist"
    exit ${ERR_STATE_NOT_FOUND}
  fi

  local volumes_link="$simnet_name/_volumes"
  present rm "$volumes_link"
  present ln -s "_states/$state_name" "$volumes_link"
}

# state clone [-fs] [simnet_name] <new_state_name> [old_state_name]
clone_state() {
  local simnet_name=$1
  local new_state_name=$2
  local old_state_name=$3

  # special case for optional simnet_name
  if [[ $# -lt 2 ]]; then
    simnet_name=${DEFAULT_SIMNET_NAME}
    if [[ -z "$1" ]]; then
      echo_err "please specify at least new state name"
      exit ${ERR_TOO_FEW_ARGUMENTS}
    fi
    new_state_name=$1
  fi

  validate_simnet_exists "$simnet_name"

  make_sure_simnet_is_not_running

  present_cwd

  if [[ -z "$old_state_name" ]]; then
    old_state_name=$(basename "$(get_selected_state_dir "$simnet_name")")
  fi

  local src=$(get_state_dir "$simnet_name" "$old_state_name")
  local dest=$(get_state_dir "$simnet_name" "$new_state_name")

  if [[ -d "$dest" ]]; then
    if [[ -n "$FLAG_FORCE" ]]; then
      rm_state "$simnet_name" "$new_state_name"
    else
      echo_err "new state already exists, remove it with \`./sv state rm $new_state_name\` or force it with -f flag"
      exit ${ERR_STATE_ALREADY_EXISTS}
    fi
  fi

  present cp ${FAST_CP_OPTS} -a "$src" "$dest"

  if [[ -n "$FLAG_SWITCH" ]]; then
    switch_state "$simnet_name" "$new_state_name"
  fi
}

# state list [simnet_name] [filter]
list_states() {
  local simnet_name=${1:-$DEFAULT_SIMNET_NAME}
  local filter=$2

  validate_simnet_exists "$simnet_name"
  local state_dir=$(get_state_dir "$simnet_name")
  find "$state_dir" -maxdepth 1 -type d -exec basename {} \; | tail -n "+2" | sort | grep -i "$filter"
}

handle_state() {
  local subcommand=${1-show}
  shift || true

  case "$subcommand" in
    "show") show_state "$@" ;;
    "clone") clone_state "$@" ;;
    "switch") switch_state "$@" ;;
    "list") list_states "$@" ;;
    "rm") rm_state "$@" ;;
    *) echo_err "unsupported subcommand '$subcommand', use './sv help state'"; exit ${ERR_INVALID_STATE_COMMAND} ;;
  esac
}

# ---------------------------------------------------------------------------------------------------------------------------

get_repo_url() {
  local repo=$1

  REPO_URL="?"
  case "$repo" in
    "btcd") REPO_URL="$SIMVERSE_BTCD_REPO_URL" ;;
    "btcwallet") REPO_URL="$SIMVERSE_BTCWALLET_REPO_URL" ;;
    "lnd") REPO_URL="$SIMVERSE_LND_REPO_URL" ;;
    *) echo_err "unknown repo '$repo'"; exit ${ERR_UNKNOWN_REPO} ;;
  esac

  echo "$REPO_URL"
}

init_repo() {
  local repo=$1

  if [[ ! -e "$repo" ]]; then
    if [[ -n "$FLAG_FORCE" ]]; then
      present rm -rf "$repo"
    fi
  fi

  if [[ -e "$repo" ]]; then
    say "repo '$repo' already exists"
    return
  fi

  local repo_url=$(get_repo_url "$repo")
  present git clone ${SIMVERSE_GIT_CLONE_OPTS} "$repo_url"
}

# repos init [repo_name] [...]
init_repos() {
  local args=$@

  cd "$SIMVERSE_REPOS_ABSOLUTE"
  present_cwd

  if [[ $# -eq 0 ]]; then
    # init all repos
    for repo in ${KNOWN_REPOS[@]}; do
      init_repo "$repo"
    done
  else
    # init specific repos
    for repo in ${args}; do
      init_repo "$repo"
    done
  fi
}

update_repo() {
  local repo=$1

  if [[ ! -e "$repo" ]]; then
    if [[ -n "$FLAG_FORCE" ]]; then
      present rm -rf "$repo"
    fi
  fi

  if [[ ! -e "$repo" ]]; then
    say "repo '$repo' does not exist, init it first"
    return
  fi

  pushd "$repo"
  present_cwd
  present git pull ${SIMVERSE_GIT_FETCH_OPTS} origin
  present git submodule update --recursive
  popd
}

# repos update [repo_name] [...]
update_repos() {
  local args=$@

  cd "$SIMVERSE_REPOS_ABSOLUTE"
  present_cwd

  if [[ $# -eq 0 ]]; then
    # update all repos
    for repo in ${KNOWN_REPOS[@]}; do
      update_repo "$repo"
    done
  else
    # init specific repos
    for repo in ${args}; do
      update_repo "$repo"
    done
  fi
}

# repos clone [--force] <repo_name> <new_repo_name>
clone_repo() {
  local repo_name=$1
  local new_repo_name=$2

  if [[ -z "$new_repo_name" ]]; then
    echo_err "please specify new repo name"
    exit ${ERR_TOO_FEW_ARGUMENTS}
  fi

  if [[ -z "$repo_name" ]]; then
    echo_err "please specify source repo name"
    exit ${ERR_TOO_FEW_ARGUMENTS}
  fi

  cd "$SIMVERSE_REPOS_ABSOLUTE"
  present_cwd

  if [[ ! -e "$repo_name" ]]; then
    echo_err "source repo '$repo_name' does not exist"
    exit ${ERR_SOURCE_REPO_NOT_FOUND}
  fi

  if [[ -e "$new_repo_name" ]]; then
    if [[ -n "$FLAG_FORCE" ]]; then
      present rm -rf "$new_repo_name"
    else
      echo_err "repo '$new_repo_name' already exists, delete it first or force deletion via the -f flag"
      exit ${ERR_DESTINATION_REPO_EXISTS}
    fi
  fi

  present cp ${FAST_CP_OPTS} -a "$repo_name" "$new_repo_name"
}


# repos list [filter]
list_repos() {
  local filter=$1

  find "$SIMVERSE_REPOS_ABSOLUTE" -maxdepth 1 -type d -exec basename {} \; | tail -n "+2" | sort | grep -i "$filter"
}

# repos rm [repo_name] [...]
rm_repos() {
  local args=$@

  cd "$SIMVERSE_REPOS_ABSOLUTE"
  present_cwd

  if [[ $# -eq 0 ]]; then
    # delete all repos
    if [[ -z "$(ls -A .)" ]]; then
      exit ${NO_ERR}
    else
      # better ask for confirmation
      answer=y
      if [[ -z "$FLAG_FORCE" ]]; then
        read -n 1 -p "Repos [$(ls | xargs)] will be deleted! Really delete all repos (y/N)?" answer; echo ""
      fi
      if [[ "$answer" == "y" ]]; then
        present rm -rf *
      fi
    fi
  else
    # delete specific repos
    for repo in ${args}; do
      if [[ -e "$repo" ]]; then
        present rm -rf "$repo"
      else
        echo "repo '$repo' does not exist, skipping..."
      fi
    done
  fi
}

handle_repos() {
  local subcommand=${1-list}
  shift || true

  case "$subcommand" in
    "init") init_repos "$@" ;;
    "update") update_repos "$@" ;;
    "clone") clone_repo "$@" ;;
    "list") list_repos "$@" ;;
    "rm") rm_repos "$@" ;;
    *) echo_err "unsupported subcommand '$subcommand', use './sv help repos'"; exit ${ERR_INVALID_REPOS_COMMAND} ;;
  esac
}

# ---------------------------------------------------------------------------------------------------------------------------

start_pre_block() {
  echo "\`\`\`"
}

end_pre_block() {
  echo "\`\`\`"
}

emit_help_markdown() {
  local line="$(join_by " " ${@/eval/})"
  echo ""
  echo "\`> $line\`"
  start_pre_block
  "$@"
  end_pre_block
}

generate_readme() {
  cd "$SIMVERSE_HOME"
  emit_help_markdown ./sv help
  emit_help_markdown ./sv help simnet
  emit_help_markdown ./sv help workspace
  emit_help_markdown ./sv help create
  emit_help_markdown ./sv help recipe
  emit_help_markdown ./sv help toolbox
  emit_help_markdown ./sv help aliases
  emit_help_markdown ./sv help destroy
  emit_help_markdown ./sv help enter
  emit_help_markdown ./sv help list
  emit_help_markdown ./sv help state
  emit_help_markdown ./sv help repos
}

# ---------------------------------------------------------------------------------------------------------------------------

# parsing flags
# see https://stackoverflow.com/a/9899366/84283
ARGS=()
while test $# -gt 0; do
  case $1 in
    # normal option processing
    -f | --force) FLAG_FORCE=1 ;;
    -s | --switch) FLAG_SWITCH=1 ;;
    -q | --quiet) FLAG_QUIET=1; ;;
    # ...

    # special cases
    --) break ;;
    --*) echo_err "error unknown (long) option '$1'"; exit ${ERR_UNSUPPORTED_FLAG};;
    -?) echo_err "error unknown (short) option '$1'"; exit ${ERR_UNSUPPORTED_FLAG};;

    # split apart combined short options
    -*)
      split=$1
      shift
      set -- $(echo "$split" | cut -c 2- | sed 's/./-& /g') "$@"
      continue
      ;;

    # accumulate non-flag args
    *) ARGS+=($1) ;;
  esac
  shift
done

# reset with flags filtered out
set -- ${ARGS[*]}

# ---------------------------------------------------------------

if [[ ! -d "$SIMVERSE_REPOS" ]]; then
  say "simverse repos dir does not exist at '$SIMVERSE_REPOS', creating it..."
  present mkdir -p "$SIMVERSE_REPOS"
fi

pushd "$SIMVERSE_REPOS"
SIMVERSE_REPOS_ABSOLUTE=$(pwd -P)
popd

# ---------------------------------------------------------------

if [[ ! -d "$SIMVERSE_WORKSPACE" ]]; then
  say "simverse workspace dir does not exist at '$SIMVERSE_WORKSPACE', creating it..."
  present mkdir -p "$SIMVERSE_WORKSPACE"
fi

cd "$SIMVERSE_WORKSPACE"

SIMVERSE_WORKSPACE_ABSOLUTE=$(pwd -P)

# ---------------------------------------------------------------

COMMAND=${1:-help}
shift || true

case "$COMMAND" in
  "help"|"--help") show_help "$@" ;;
  "create") create_simnet "$@" ;;
  "destroy") destroy_simnet "$@" ;;
  "enter") enter_simnet "$@" ;;
  "list") list_simnets "$@" ;;
  "state") handle_state "$@" ;;
  "repos") handle_repos "$@" ;;
  "genreadme") generate_readme ;; # internal
  *) echo_err "unsupported command '$COMMAND', use './sv help'"; exit ${ERR_INVALID_COMMAND} ;;
esac