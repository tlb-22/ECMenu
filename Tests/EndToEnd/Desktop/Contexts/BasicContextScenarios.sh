#!/bin/zsh

# 定义空白处、普通文件和目录三种 Finder 基础菜单截图场景。
# 提供场景身份、隔离 fixture、上下文类型及选择项目，供统一截图注册表调用。

finder_menu_capture_basic_context_scenario_ids() {
    print -r -- container
    print -r -- plain-file
    print -r -- directory
}

finder_menu_capture_basic_context_create_fixture() {
    local scenario_id="$1"
    local fixture_directory="$2"

    /bin/mkdir "$fixture_directory"

    case "$scenario_id" in
        container)
            /usr/bin/touch "$fixture_directory/Background Context.txt"
            ;;
        plain-file)
            /usr/bin/touch "$fixture_directory/Notes.txt"
            ;;
        directory)
            /bin/mkdir "$fixture_directory/Example Folder"
            ;;
    esac
}

finder_menu_capture_basic_context_context_kind() {
    case "$1" in
        container)
            print -r -- container
            ;;
        plain-file|directory)
            print -r -- items
            ;;
        *)
            return 64
            ;;
    esac
}

finder_menu_capture_basic_context_selected_basenames() {
    case "$1" in
        container)
            ;;
        plain-file)
            print -r -- Notes.txt
            ;;
        directory)
            print -r -- "Example Folder"
            ;;
        *)
            return 64
            ;;
    esac
}
