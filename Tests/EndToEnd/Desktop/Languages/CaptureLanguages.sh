#!/bin/zsh

# 定义真实 Finder 菜单截图支持的语言及其 Finder 资源目录映射。
# 提供产品语言身份和 Finder 原生菜单标志项，供切换语言后的校验使用。

typeset -gra _finder_menu_capture_language_ids=(
    en
    zh-Hans
)

finder_menu_capture_language_ids() {
    print -l -- "${_finder_menu_capture_language_ids[@]}"
}

finder_menu_capture_finder_resource_name() {
    case "$1" in
        en)
            print en
            ;;
        zh-Hans)
            print zh_CN
            ;;
        *)
            return 64
            ;;
    esac
}

# Finder 原生菜单中跨当前截图场景稳定存在的语言标志项。
finder_menu_capture_finder_marker_title() {
    case "$1" in
        en)
            print "Get Info"
            ;;
        zh-Hans)
            print "显示简介"
            ;;
        *)
            return 64
            ;;
    esac
}

# 产品需求中的固定命令名称；预期独立于生产本地化目录，避免文案回归同步改变答案。
finder_menu_capture_command_title() {
    case "$1:$2" in
        command.newFile:en) print -r -- 'New File' ;;
        command.copyPath:en) print -r -- 'Copy Path' ;;
        command.hideItems:en) print -r -- 'Hide Items' ;;
        command.showItems:en) print -r -- 'Show Items' ;;
        command.compressImages:en) print -r -- 'Compress Images' ;;
        command.openInVisualStudioCode:en) print -r -- 'Open in Visual Studio Code' ;;
        command.openInITerm2:en) print -r -- 'Open in iTerm2' ;;
        command.newFile:zh-Hans) print -r -- '新建文件' ;;
        command.copyPath:zh-Hans) print -r -- '拷贝路径' ;;
        command.hideItems:zh-Hans) print -r -- '隐藏项目' ;;
        command.showItems:zh-Hans) print -r -- '显示项目' ;;
        command.compressImages:zh-Hans) print -r -- '压缩图片' ;;
        command.openInVisualStudioCode:zh-Hans) print -r -- '进入 Visual Studio Code' ;;
        command.openInITerm2:zh-Hans) print -r -- '进入 iTerm2' ;;
        *) return 64 ;;
    esac
}
