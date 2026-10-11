#!/bin/zsh

# 声明拷贝路径命令在各个已覆盖 Finder 截图上下文中必须出现。
# 输出稳定本地化键，供截图入口核对菜单标题。

finder_menu_capture_copy_path_required_command_keys() {
    case "$1" in
        container|plain-file|directory|multiple-images|new-file-submenu)
            print -r -- command.copyPath
            ;;
    esac
}
