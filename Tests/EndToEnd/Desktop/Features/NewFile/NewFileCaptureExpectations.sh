#!/bin/zsh

# 定义新建文件子菜单的纯截图场景，并声明父菜单在各上下文中的可用性。
# 复用空白处 fixture，只展开模板子菜单，不执行模板或修改模板库。

finder_menu_capture_new_file_scenario_ids() {
    print -r -- new-file-submenu
}

finder_menu_capture_new_file_create_fixture() {
    finder_menu_capture_basic_context_create_fixture container "$2"
}

finder_menu_capture_new_file_context_kind() {
    print -r -- container
}

finder_menu_capture_new_file_selected_basenames() {
    # 空白处场景没有选中项目。
}

finder_menu_capture_new_file_required_command_keys() {
    case "$1" in
        container|plain-file|directory|new-file-submenu)
            print -r -- command.newFile
            ;;
    esac
}
