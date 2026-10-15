# bash completion for tmctl
_tmctl() {
    local cur=${COMP_WORDS[COMP_CWORD]}
    if [ "$COMP_CWORD" -eq 1 ]; then
        mapfile -t COMPREPLY < <(compgen -W 'crc wave version' -- "$cur")
    elif [ "${COMP_WORDS[1]}" = crc ]; then
        mapfile -t COMPREPLY < <(compgen -f -- "$cur")
    fi
}
complete -F _tmctl tmctl
