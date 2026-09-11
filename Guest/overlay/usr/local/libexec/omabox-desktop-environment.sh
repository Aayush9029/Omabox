omabox_export_desktop_environment() {
  local _omabox_env_declaration
  case "$1" in
    _omabox_env_*|OMABOX_GUEST_PREFERENCES|BASH_ENV|ENV|BASH_XTRACEFD|BASH_COMPAT|BASH_ARGV0|PROMPT_COMMAND|PS0|PS1|PS2|PS4)
      return 1
      ;;
  esac
  _omabox_env_declaration=$(builtin declare -p "$1" 2>/dev/null) || _omabox_env_declaration=
  if [[ $_omabox_env_declaration =~ ^declare\ -[^[:space:]]*[airnA] ]]; then
    return 1
  fi
  builtin export "$1=$2" 2>/dev/null
}

omabox_load_desktop_environment_file() {
  local -r _omabox_env_path=${1-}
  local _omabox_env_entry _omabox_env_key _omabox_env_value
  [[ -f $_omabox_env_path && -r $_omabox_env_path ]] || return 0
  while IFS= read -r _omabox_env_entry || [[ -n $_omabox_env_entry ]]; do
    _omabox_env_entry=${_omabox_env_entry%$'\r'}
    [[ $_omabox_env_entry == *=* ]] || continue
    _omabox_env_key=${_omabox_env_entry%%=*}
    [[ $_omabox_env_key =~ ^[A-Za-z_][A-Za-z_0-9]*$ ]] || continue
    _omabox_env_value=${_omabox_env_entry#*=}
    if omabox_export_desktop_environment "$_omabox_env_key" "$_omabox_env_value"; then
      if [[ $_omabox_env_key == GDK_SCALE ]]; then
        omabox_export_desktop_environment OMABOX_GDK_SCALE "$_omabox_env_value" || true
      fi
    fi
  done < "$_omabox_env_path"
  return 0
}

omabox_load_desktop_environment() {
  local -r _omabox_env_guest_path=${1-}
  local -r _omabox_env_host_path=${2-}
  omabox_load_desktop_environment_file "$_omabox_env_guest_path"
  omabox_load_desktop_environment_file "$_omabox_env_host_path"
}
