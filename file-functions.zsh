fpbcopy() {
    osascript -e "set the clipboard to (POSIX file \"$(realpath "$1")\")"
}
