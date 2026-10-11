#!/bin/zsh

# 定义图片压缩使用的多图选择截图场景和有效 PNG fixture。
# 提供上下文、选择项目与压缩命令期望，交由统一截图入口执行。

finder_menu_capture_image_compression_scenario_ids() {
    print -r -- multiple-images
}

finder_menu_capture_image_compression_create_fixture() {
    local scenario_id="$1"
    local fixture_directory="$2"
    local png_base64

    png_base64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z5cAAAAASUVORK5CYII='

    /bin/mkdir "$fixture_directory"

    print -rn -- "$png_base64" \
        | /usr/bin/base64 -D >"$fixture_directory/Landscape.png"
    print -rn -- "$png_base64" \
        | /usr/bin/base64 -D >"$fixture_directory/Portrait.png"
}

finder_menu_capture_image_compression_context_kind() {
    case "$1" in
        multiple-images)
            print -r -- items
            ;;
        *)
            return 64
            ;;
    esac
}

finder_menu_capture_image_compression_selected_basenames() {
    case "$1" in
        multiple-images)
            print -r -- Landscape.png
            print -r -- Portrait.png
            ;;
        *)
            return 64
            ;;
    esac
}

finder_menu_capture_image_compression_required_command_keys() {
    case "$1" in
        multiple-images)
            print -r -- command.compressImages
            ;;
    esac
}
