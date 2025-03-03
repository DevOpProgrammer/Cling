function cling() {
    local folders=()
    for arg in "$@"; do
        if [ -d "$arg" ]; then
            folders+=("$arg")
        else [ -f "$arg" ]
            folders+=("$(dirname "$arg")")
        fi
    done
    open -a Cling "${folders[@]}"
}
