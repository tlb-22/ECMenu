#!/bin/zsh

# 声明隐藏命令在普通文件、目录和多图选择截图场景中的可用性。
# 输出稳定本地化键，供截图入口核对选中项目对应的菜单标题。

finder_menu_capture_visibility_required_command_keys() {
    case "$1" in
        plain-file|directory|multiple-images)
            print -r -- command.hideItems
            ;;
    esac
}
