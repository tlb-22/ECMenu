/**
 管理一次 Finder 菜单验收拥有的窗口、选择、菜单和子菜单生命周期。
 通过 Accessibility 观察驱动状态推进，校验截图期间的来源稳定性并关闭会话拥有的界面。
 */

import AppKit
import ApplicationServices
import Foundation

@MainActor
final class FinderMenuSession {
    private enum MenuCommandModifiers {
        static let commandOnly = Int(([] as AXMenuItemModifiers).rawValue)
        static let commandShift = Int(AXMenuItemModifiers.shift.rawValue)
    }

    private struct ResolvedItem {
        let itemScope: AXUIElement
        let menuElement: AXUIElement
    }

    private struct ResolvedContext {
        let window: AXUIElement
        let selectionOwner: AXUIElement
        let firstItem: ResolvedItem
        let remainingItems: [ResolvedItem]

    }

    private struct SelectionOwnerCandidate {
        let owner: AXUIElement
        var itemsByURL: [[ResolvedItem]]
    }

    private struct VerifiedSelection {
        let owner: AXUIElement
        let urls: [URL]
    }

    private enum MenuObservation {
        case ready(MenuSnapshot)
        case notReady
        case gone
    }

    private enum FinderWindowCandidateStatus {
        case pending
        case unrelated
        case finderWindow
    }

    private enum State {
        case initialized
        case window(AXUIElement, AXUIElement)
        case sheet(AXUIElement, AXUIElement, AXUIElement)
        case menuRequested(AXUIElement, AXUIElement, VerifiedSelection)
        case menuOpened(AXUIElement, AXUIElement, AXUIElement, VerifiedSelection)
        case menuReady(
            AXUIElement,
            AXUIElement,
            AXUIElement,
            VerifiedSelection,
            MenuSnapshot
        )
        case finished
    }

    private let context: FinderMenuContext
    private var finder: NSRunningApplication?
    private var state: State = .initialized
    private var actionWindowBaseline: [AXUIElement] = []
    private var resultWindows: [AXUIElement] = []

    init(context: FinderMenuContext) {
        self.context = context
    }

    func prepare(requiredTitles: Set<String> = []) throws -> MenuSnapshot {
        let finder = try waitForFinder()
        self.finder = finder
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        let window = try createFinderWindow(
            finder: finder,
            application: application,
            processIdentifier: finder.processIdentifier
        )
        state = .window(application, window)
        let resolvedContext = try navigateOwnedWindow(
            window,
            application: application,
            processIdentifier: finder.processIdentifier,
            directory: context.directory
        )
        state = .window(application, resolvedContext.window)

        let selection = try applySelection(
            in: resolvedContext,
            application: application
        )
        let target = try menuTarget(in: resolvedContext)
        let menuWaiter = try AXElementNotificationWaiter(
            processIdentifier: finder.processIdentifier,
            application: application,
            notification: kAXMenuOpenedNotification as CFString
        )

        state = .menuRequested(application, resolvedContext.window, selection)
        try showMenu(
            on: target,
            in: resolvedContext,
            application: application
        )
        guard let menu = try menuWaiter.wait(
            timeout: AutomationTiming.menu,
            resolve: { elements in
                try self.firstElement(
                    withRole: kAXMenuRole as String,
                    in: elements
                )
            }
        ) else {
            throw AutomationFailure.menuOpenTimeout(
                frontmostBundleIdentifier: NSWorkspace.shared
                    .frontmostApplication?
                    .bundleIdentifier
            )
        }

        state = .menuOpened(application, resolvedContext.window, menu, selection)
        try movePointerOutsideMenu(menu, within: resolvedContext.window)
        let snapshot = try waitForStableMenu(menu, requiredTitles: requiredTitles)
        try verifySelection(selection)
        state = .menuReady(
            application,
            resolvedContext.window,
            menu,
            selection,
            snapshot
        )
        return snapshot
    }

    /// 缺席断言观察完整菜单等待窗口，避免把扩展尚未填充的原生菜单误判为成功。
    func observeAbsentItems(named titles: Set<String>) throws -> MenuSnapshot {
        guard case let .menuReady(application, window, menu, selection, _) = state else {
            preconditionFailure("Absence verification requires a prepared menu")
        }
        let deadline = Date().addingTimeInterval(AutomationTiming.menu)
        var latest: MenuSnapshot
        repeat {
            try verifySelection(selection)
            guard case let .ready(snapshot) = try observeMenu(menu) else {
                throw AutomationFailure.menuChanged
            }
            if let unexpected = snapshot.titles.first(where: { titles.contains($0) }) {
                throw AutomationFailure.menuItemUnexpected(unexpected)
            }
            latest = snapshot
            runLoopSlice(AutomationTiming.poll)
        } while Date() < deadline
        state = .menuReady(application, window, menu, selection, latest)
        try verifyAfterCapture()
        return latest
    }

    func verifyAfterCapture() throws {
        guard case let .menuReady(
            application,
            window,
            menu,
            selection,
            expected
        ) = state,
              let finder,
              !finder.isTerminated,
              try AXClient.bool(
                  kAXFrontmostAttribute as CFString,
                  of: application
              ) == true else {
            throw AutomationFailure.focusLost("Finder lost foreground focus during capture.")
        }
        guard let mainWindow = try AXClient.element(
            kAXMainWindowAttribute as CFString,
            of: application
        ), AXClient.same(mainWindow, window) else {
            throw AutomationFailure.focusLost(
                "The owned Finder window stopped being the main window during capture."
            )
        }
        try verifySelection(selection)

        let actual: MenuSnapshot
        switch try observeMenu(menu) {
        case let .ready(snapshot):
            actual = snapshot
        case .notReady:
            throw AutomationFailure.menuChanged
        case .gone:
            throw AutomationFailure.focusLost("The Finder menu closed during capture.")
        }
        guard actual == expected else { throw AutomationFailure.menuChanged }
    }

    /// 会话已确认的子菜单，供截图和后续菜单动作使用。
    struct Submenu {
        fileprivate let element: AXUIElement
        let snapshot: MenuSnapshot
    }

    /// 悬停指定父菜单，并等待其直接子菜单完成布局。
    func prepareSubmenu(parentTitle: String) async throws -> Submenu {
        try verifyAfterCapture()
        guard case let .menuReady(_, _, rootMenu, _, _) = state else {
            preconditionFailure("A verified capture requires a prepared menu")
        }
        let parent = try uniqueMenuItem(named: parentTitle, in: rootMenu)
        try FinderPointer.move(to: FinderPointer.location(of: parent))
        let deadline = Date().addingTimeInterval(AutomationTiming.menu)
        while true {
            for candidate in try AXClient.elements(
                kAXChildrenAttribute as CFString, of: parent
            ) where try AXClient.string(kAXRoleAttribute as CFString, of: candidate) == kAXMenuRole as String {
                if case .ready = try observeMenu(candidate) {
                    let submenu = Submenu(element: candidate, snapshot: try waitForStableMenu(candidate, before: deadline))
                    // AX 与窗口服务器分别公布布局；未对应时继续重新枚举子菜单并读取当前快照。
                    if try await MenuScreenshot.isVisible(submenu.snapshot) {
                        try verifySubmenu(submenu)
                        return submenu
                    }
                }
            }
            guard Date() < deadline else { throw AutomationFailure.menuItemUnavailable(parentTitle) }
            runLoopSlice(AutomationTiming.poll)
        }
    }

    /// 验证父菜单、来源选择和子菜单在截图期间均未改变。
    func verifySubmenu(_ submenu: Submenu) throws {
        try verifyAfterCapture()
        guard case .ready(let current) = try observeMenu(submenu.element),
              current == submenu.snapshot else {
            throw AutomationFailure.menuChanged
        }
    }

    /// 点击已验证子菜单中的唯一启用项，并将清理所有权推进到来源窗口。
    func pressItem(named title: String, in submenu: Submenu) throws {
        try verifySubmenu(submenu)
        guard case let .menuReady(application, window, _, _, _) = state else {
            preconditionFailure("A verified capture requires a prepared menu")
        }
        let item = try uniqueMenuItem(named: title, in: submenu.element)
        guard try AXClient.supports(kAXPressAction as CFString, on: item) else {
            throw AutomationFailure.menuItemUnavailable(title)
        }
        actionWindowBaseline = try AXClient.elements(kAXWindowsAttribute as CFString, of: application)
        try AXClient.perform(kAXPressAction as CFString, on: item)
        state = .window(application, window)
    }

    /// 点击一级菜单的唯一启用项；验收调用方随后核对真实系统输出。
    func pressItem(named title: String) throws {
        try verifyAfterCapture()
        guard case let .menuReady(application, window, menu, _, _) = state else {
            preconditionFailure("A verified action requires a prepared menu")
        }
        let item = try uniqueMenuItem(named: title, in: menu)
        actionWindowBaseline = try AXClient.elements(kAXWindowsAttribute as CFString, of: application)
        try AXClient.perform(kAXPressAction as CFString, on: item)
        state = .window(application, window)
    }

    /// 读取点击菜单前的 AX 选择事实；数组顺序不作为 FinderSync 返回顺序的契约。
    func selectedURLsBeforeAction() throws -> [URL] {
        try verifyAfterCapture()
        guard case let .menuReady(_, _, _, selection, _) = state else {
            preconditionFailure("Selection observation requires a prepared menu")
        }
        return try selectedURLs(on: selection.owner)
    }

    /// 在同一来源窗口及选择上执行 Finder 自身的拷贝路径名命令，供独立对照。
    func copySelectedPathnamesUsingFinder() throws {
        guard case let .window(application, window) = state else {
            preconditionFailure("Native path comparison requires a completed menu action")
        }
        guard try finderWindowIsFocused(window, application: application),
              let resolved = try resolveContext(in: window) else {
            throw AutomationFailure.focusLost("Finder source changed before native path comparison")
        }
        try verifySelection(VerifiedSelection(owner: resolved.selectionOwner, urls: context.selectedURLs))
        guard let command = try menuCommand(character: "c", modifiers: Int(AXMenuItemModifiers.option.rawValue),
                                            application: application),
              try AXClient.bool(kAXEnabledAttribute as CFString, of: command.element) == true else {
            throw AutomationFailure.menuItemUnavailable("Finder Copy as Pathname")
        }
        try AXClient.perform(kAXPressAction as CFString, on: command.element)
    }

    /// 读取会话拥有的窗口是否仅选中指定 URL；选择容器随 Finder 更新重新解析。
    func isSoleSelectedItem(_ url: URL) throws -> Bool {
        try hasExactlySelectedItems([url])
    }

    /// 比较来源窗口或动作新建的结果窗口中，Finder 实际选中的完整 URL 集合。
    func hasExactlySelectedItems(_ urls: [URL]) throws -> Bool {
        guard case let .window(application, window) = state else {
            preconditionFailure("Result selection requires a completed menu action")
        }
        precondition(!urls.isEmpty, "A result selection requires at least one URL")
        let windows = try AXClient.elements(kAXWindowsAttribute as CFString, of: application)
        let eligible = windows.filter { candidate in
            AXClient.same(candidate, window) || !actionWindowBaseline.contains { AXClient.same($0, candidate) }
        }
        var matches: [AXUIElement] = []
        for candidate in eligible {
            guard let resolved = try resolveContext(in: candidate, representing: urls) else { continue }
            let actual = try selectedURLs(on: resolved.selectionOwner)
            if actual.count == urls.count && Set(actual.map(\.path)) == Set(urls.map(\.path)) {
                matches.append(candidate)
            }
        }
        guard matches.count <= 1 else { throw AutomationFailure.finderWindowOwnershipAmbiguous }
        guard let result = matches.first else { return false }
        if !AXClient.same(result, window), !resultWindows.contains(where: { AXClient.same($0, result) }) {
            resultWindows.append(result)
        }
        return true
    }

    private func uniqueMenuItem(named title: String, in menu: AXUIElement) throws -> AXUIElement {
        let matches = try AXClient.elements(
            kAXChildrenAttribute as CFString,
            of: menu
        ).filter { item in
            try AXClient.string(kAXRoleAttribute as CFString, of: item)
                == kAXMenuItemRole as String
                && AXClient.string(kAXTitleAttribute as CFString, of: item) == title
                && AXClient.bool(kAXEnabledAttribute as CFString, of: item) == true
        }
        guard matches.count == 1 else {
            throw AutomationFailure.menuItemUnavailable(title)
        }
        return matches[0]
    }

    /// 即使菜单关闭失败，也继续尝试关闭本次拥有的窗口；首个失败仍会返回给调用方。
    func closeOwnedUI() throws {
        let application: AXUIElement
        let window: AXUIElement
        let sheet: AXUIElement?
        let menu: AXUIElement?

        switch state {
        case .initialized, .finished:
            state = .finished
            return
        case let .window(app, ownedWindow),
             let .menuRequested(app, ownedWindow, _):
            application = app
            window = ownedWindow
            sheet = nil
            menu = nil
        case let .sheet(app, ownedWindow, ownedSheet):
            application = app
            window = ownedWindow
            sheet = ownedSheet
            menu = nil
        case let .menuOpened(app, ownedWindow, openMenu, _),
             let .menuReady(app, ownedWindow, openMenu, _, _):
            application = app
            window = ownedWindow
            sheet = nil
            menu = openMenu
        }

        var firstFailure: AutomationFailure?
        if let menu {
            do {
                try closeMenu(menu, application: application)
            } catch let failure as AutomationFailure {
                firstFailure = failure
            }
        }
        if let sheet {
            do {
                try closeSheet(sheet, in: window, application: application)
            } catch let failure as AutomationFailure {
                if firstFailure == nil { firstFailure = failure }
            }
        }
        for resultWindow in resultWindows {
            do {
                try closeWindow(resultWindow, application: application)
            } catch let failure as AutomationFailure {
                if firstFailure == nil { firstFailure = failure }
            }
        }
        resultWindows.removeAll()
        do {
            try closeWindow(window, application: application)
            state = .finished
        } catch let failure as AutomationFailure {
            if firstFailure == nil { firstFailure = failure }
        }
        if let firstFailure { throw firstFailure }
    }

    private func createFinderWindow(
        finder: NSRunningApplication,
        application: AXUIElement,
        processIdentifier: pid_t
    ) throws -> AXUIElement {
        let existingWindows = try AXClient.elements(
            kAXWindowsAttribute as CFString,
            of: application
        )
        if !finder.isActive, existingWindows.isEmpty {
            let activationWindowWaiter = try AXElementNotificationWaiter(
                processIdentifier: processIdentifier,
                application: application,
                notification: kAXWindowCreatedNotification as CFString
            )
            try waitForFinderFrontmost(
                finder: finder,
                application: application
            )
            return try claimCreatedFinderWindow(
                using: activationWindowWaiter,
                application: application
            )
        }

        try waitForFinderFrontmost(
            finder: finder,
            application: application
        )
        guard let command = try menuCommand(
            character: "n",
            modifiers: MenuCommandModifiers.commandOnly,
            application: application
        ),
              try AXClient.supports(kAXPressAction as CFString, on: command.element) else {
            throw AutomationFailure.newFinderWindowUnavailable
        }
        let windowWaiter = try AXElementNotificationWaiter(
            processIdentifier: processIdentifier,
            application: application,
            notification: kAXWindowCreatedNotification as CFString
        )
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            != "com.apple.loginwindow" else {
            throw AutomationFailure.interactiveSessionUnavailable
        }
        try AXClient.perform(kAXPressAction as CFString, on: command.element)
        return try claimCreatedFinderWindow(
            using: windowWaiter,
            application: application
        )
    }

    private func claimCreatedFinderWindow(
        using waiter: AXElementNotificationWaiter,
        application: AXUIElement
    ) throws -> AXUIElement {
        let window = try waitForCreatedFinderWindow(
            using: waiter,
            application: application
        )
        state = .window(application, window)
        try waitForOwnedFinderWindow(
            window,
            using: waiter,
            application: application
        )
        return window
    }

    private func waitForCreatedFinderWindow(
        using waiter: AXElementNotificationWaiter,
        application: AXUIElement
    ) throws -> AXUIElement {
        var previousCandidate: AXUIElement?
        guard let window = try waiter.wait(
            timeout: AutomationTiming.finder,
            resolve: { elements -> AXUIElement? in
                guard let candidate = try self.createdFinderWindow(
                    from: elements,
                    application: application
                ) else {
                    previousCandidate = nil
                    return nil
                }
                guard let previousCandidate,
                      AXClient.same(previousCandidate, candidate) else {
                    previousCandidate = candidate
                    return nil
                }
                return candidate
            }
        ) else {
            throw AutomationFailure.finderWindowTimeout
        }
        return window
    }

    private func waitForOwnedFinderWindow(
        _ window: AXUIElement,
        using waiter: AXElementNotificationWaiter,
        application: AXUIElement
    ) throws {
        var wasFocused = false
        guard try waiter.wait(
            timeout: AutomationTiming.finder,
            resolve: { elements -> Bool? in
                guard let candidate = try self.createdFinderWindow(
                    from: elements,
                    application: application
                ) else {
                    wasFocused = false
                    return nil
                }
                guard AXClient.same(candidate, window) else {
                    throw AutomationFailure.finderWindowOwnershipAmbiguous
                }
                guard try self.finderWindowIsFocused(
                    window,
                    application: application
                ) else {
                    wasFocused = false
                    return nil
                }
                guard wasFocused else {
                    wasFocused = true
                    return nil
                }
                return true
            }
        ) != nil else {
            throw AutomationFailure.finderWindowTimeout
        }
    }

    private func navigateOwnedWindow(
        _ window: AXUIElement,
        application: AXUIElement,
        processIdentifier: pid_t,
        directory: URL
    ) throws -> ResolvedContext {
        let sheetWaiter = try AXElementNotificationWaiter(
            processIdentifier: processIdentifier,
            application: application,
            notification: kAXSheetCreatedNotification as CFString
        )
        guard let command = try menuCommand(
            character: "g",
            modifiers: MenuCommandModifiers.commandShift,
            application: application
        ) else {
            throw AutomationFailure.finderOpenFailed(directory.path)
        }
        try AXClient.perform(kAXPressAction as CFString, on: command.element)
        guard let sheet = try sheetWaiter.wait(
            timeout: AutomationTiming.menu,
            resolve: { elements in
                try self.firstElement(
                    withRole: kAXSheetRole as String,
                    in: elements,
                    attachedTo: window
                )
            }
        ) else {
            throw AutomationFailure.finderOpenFailed(directory.path)
        }
        state = .sheet(application, window, sheet)

        let textFields = try AXTree.paths(below: sheet).filter { path in
            try AXClient.string(
                kAXRoleAttribute as CFString,
                of: path.element
            ) == kAXTextFieldRole as String
        }
        guard textFields.count == 1 else {
            throw AutomationFailure.finderOpenFailed(directory.path)
        }
        let textField = textFields[0].element
        try AXClient.setValue(
            directory.path as CFString,
            for: kAXValueAttribute as CFString,
            on: textField
        )
        try AXClient.setValue(
            kCFBooleanTrue,
            for: kAXFocusedAttribute as CFString,
            on: textField
        )
        guard try AXClient.bool(
            kAXFocusedAttribute as CFString,
            of: textField
        ) == true else {
            throw AutomationFailure.finderOpenFailed(directory.path)
        }
        try FinderKeyboard.press(.returnKey)

        let ownedWindow = window
        let deadline = Date().addingTimeInterval(AutomationTiming.target)
        while Date() < deadline {
            guard try AXClient.bool(
                kAXFrontmostAttribute as CFString,
                of: application
            ) == true else {
                throw AutomationFailure.focusLost(
                    "Finder lost foreground focus while navigating."
                )
            }
            guard let focusedWindow = try AXClient.element(
                kAXFocusedWindowAttribute as CFString,
                of: application
            ) else {
                runLoopSlice(AutomationTiming.poll)
                continue
            }
            if try isOwnedSheetFocus(focusedWindow, sheet: sheet, window: ownedWindow) {
                runLoopSlice(AutomationTiming.poll)
                continue
            }
            guard AXClient.same(focusedWindow, ownedWindow) else {
                FinderNavigationEvidence.record(stage: .focusChanged, window: window,
                                                application: application, context: context)
                throw AutomationFailure.focusLost(
                    "Finder focused another window while navigating."
                )
            }
            if let resolved = try resolveContext(in: focusedWindow),
               try !sheetIsAttached(sheet, to: focusedWindow) {
                state = .window(application, focusedWindow)
                return resolved
            }
            runLoopSlice(AutomationTiming.poll)
        }
        FinderNavigationEvidence.record(stage: .contextTimeout, window: window,
                                        application: application, context: context)
        throw AutomationFailure.finderOpenFailed(directory.path)
    }

    private func isOwnedSheetFocus(
        _ focusedElement: AXUIElement,
        sheet: AXUIElement,
        window: AXUIElement
    ) throws -> Bool {
        if AXClient.same(focusedElement, sheet) { return true }
        guard try AXClient.string(
            kAXRoleAttribute as CFString,
            of: focusedElement
        ) == kAXSheetRole as String,
              let sheetWindow = try AXClient.element(
                  kAXWindowAttribute as CFString,
                  of: focusedElement
              ) else {
            return false
        }
        return AXClient.same(sheetWindow, window)
    }

    private func resolveContext(in window: AXUIElement, representing urls: [URL]? = nil) throws -> ResolvedContext? {
        let requestedURLs = urls ?? context.representedURLs
        let paths = try AXTree.paths(below: window)
        var candidates: [SelectionOwnerCandidate] = []

        for (urlIndex, requestedURL) in requestedURLs.enumerated() {
            let matches = try paths.filter {
                try AXClient.url(of: $0.element)?.path == requestedURL.path
            }
            guard !matches.isEmpty else { return nil }

            for path in matches {
                for (ancestorIndex, owner) in path.ancestors.enumerated() {
                    guard try AXClient.isSettable(
                        kAXSelectedChildrenAttribute as CFString,
                        on: owner
                    ) else { continue }

                    let itemElements = path.elementAndAncestors.prefix(
                        ancestorIndex + 1
                    )
                    guard let itemScope = try itemElements.reversed().first(where: { element in
                        let urls = Set(try ([element] + AXTree.paths(below: element).map(\.element))
                            .compactMap { try AXClient.url(of: $0)?.path })
                        return urls == [requestedURL.path]
                    }) else { continue }
                    guard let menuElement = try itemElements.first(where: {
                        try AXClient.supports(
                            kAXShowMenuAction as CFString,
                            on: $0
                        )
                    }) else { continue }

                    let item = ResolvedItem(
                        itemScope: itemScope,
                        menuElement: menuElement
                    )
                    if let candidateIndex = candidates.firstIndex(where: {
                        AXClient.same($0.owner, owner)
                    }) {
                        if !candidates[candidateIndex].itemsByURL[urlIndex].contains(where: {
                            AXClient.same($0.itemScope, itemScope)
                        }) {
                            candidates[candidateIndex].itemsByURL[urlIndex].append(item)
                        }
                    } else {
                        var itemsByURL = Array(
                            repeating: [ResolvedItem](),
                            count: requestedURLs.count
                        )
                        itemsByURL[urlIndex] = [item]
                        candidates.append(SelectionOwnerCandidate(
                            owner: owner,
                            itemsByURL: itemsByURL
                        ))
                    }
                }
            }
        }

        let complete = candidates.compactMap { candidate -> ResolvedContext? in
            guard candidate.itemsByURL.allSatisfy({ $0.count == 1 }) else {
                return nil
            }
            let items = candidate.itemsByURL.map { $0[0] }
            guard let firstItem = items.first else { return nil }
            for (index, item) in items.enumerated() {
                guard !items.dropFirst(index + 1).contains(where: {
                    AXClient.same($0.itemScope, item.itemScope)
                }) else { return nil }
            }
            return ResolvedContext(
                window: window,
                selectionOwner: candidate.owner,
                firstItem: firstItem,
                remainingItems: Array(items.dropFirst())
            )
        }
        guard complete.count == 1 else { return nil }
        return complete[0]
    }

    private func menuCommand(
        character: String,
        modifiers: Int,
        application: AXUIElement
    ) throws -> AXPath? {
        guard let menuBar = try AXClient.element(
            kAXMenuBarAttribute as CFString,
            of: application
        ) else {
            return nil
        }
        return try AXTree.paths(below: menuBar).first { path in
            guard try AXClient.string(
                kAXRoleAttribute as CFString,
                of: path.element
            ) == kAXMenuItemRole as String else {
                return false
            }
            let commandCharacter = try AXClient.string(
                kAXMenuItemCmdCharAttribute as CFString,
                of: path.element
            )?.lowercased()
            let commandModifiers = try AXClient.integer(
                kAXMenuItemCmdModifiersAttribute as CFString,
                of: path.element
            )
            return commandCharacter == character
                && commandModifiers == modifiers
        }
    }

    private func waitForFinder() throws -> NSRunningApplication {
        let deadline = Date().addingTimeInterval(AutomationTiming.finder)
        while Date() < deadline {
            if let finder = runningFinder() { return finder }
            runLoopSlice(AutomationTiming.poll)
        }
        throw AutomationFailure.finderUnavailable
    }

    private func waitForFinderFrontmost(
        finder: NSRunningApplication,
        application: AXUIElement
    ) throws {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == "com.apple.loginwindow" {
            throw AutomationFailure.interactiveSessionUnavailable
        }
        if finder.isActive { return }

        let helper = NSRunningApplication.current
        let appKitApplication = NSApplication.shared
        appKitApplication.activate()

        let helperDeadline = Date().addingTimeInterval(1)
        while !helper.isActive, Date() < helperDeadline {
            runLoopSlice(AutomationTiming.poll)
        }
        var activationRequested = false
        if helper.isActive {
            appKitApplication.yieldActivation(to: finder)
            activationRequested = finder.activate(from: helper, options: [])
        }
        if !activationRequested {
            _ = finder.activate(options: [])
        }
        if try AXClient.isSettable(
            kAXFrontmostAttribute as CFString,
            on: application
        ) {
            try AXClient.setValue(
                kCFBooleanTrue,
                for: kAXFrontmostAttribute as CFString,
                on: application
            )
        }

        let deadline = Date().addingTimeInterval(AutomationTiming.finder)
        while Date() < deadline {
            if finder.isActive { return }
            runLoopSlice(AutomationTiming.poll)
        }
        throw AutomationFailure.finderActivationTimeout(
            frontmostBundleIdentifier: NSWorkspace.shared
                .frontmostApplication?
                .bundleIdentifier
        )
    }

    private func createdFinderWindow(
        from elements: [AXUIElement],
        application: AXUIElement
    ) throws -> AXUIElement? {
        var candidates: [AXUIElement] = []
        var hasPendingCandidate = false

        for element in uniqueElements(elements) {
            switch try finderWindowCandidateStatus(element) {
            case .pending:
                hasPendingCandidate = true
            case .unrelated:
                continue
            case .finderWindow:
                candidates.append(element)
            }
        }
        guard candidates.count <= 1 else {
            throw AutomationFailure.finderWindowOwnershipAmbiguous
        }
        guard !hasPendingCandidate, let candidate = candidates.first else {
            return nil
        }

        do {
            let windows = try AXClient.elements(
                kAXWindowsAttribute as CFString,
                of: application
            )
            guard windows.contains(where: { AXClient.same($0, candidate) }) else {
                return nil
            }
        } catch AutomationFailure.accessibility(_, .cannotComplete) {
            return nil
        } catch AutomationFailure.accessibility(_, .invalidUIElement) {
            return nil
        }
        return candidate
    }

    private func finderWindowIsFocused(
        _ window: AXUIElement,
        application: AXUIElement
    ) throws -> Bool {
        do {
            guard try AXClient.bool(
                kAXFrontmostAttribute as CFString,
                of: application
            ) == true,
                  let focusedWindow = try AXClient.element(
                      kAXFocusedWindowAttribute as CFString,
                      of: application
                  ),
                  let mainWindow = try AXClient.element(
                      kAXMainWindowAttribute as CFString,
                      of: application
                  ) else {
                return false
            }
            return AXClient.same(focusedWindow, window)
                && AXClient.same(mainWindow, window)
        } catch AutomationFailure.accessibility(_, .cannotComplete) {
            return false
        } catch AutomationFailure.accessibility(_, .invalidUIElement) {
            return false
        }
    }

    private func finderWindowCandidateStatus(
        _ element: AXUIElement
    ) throws -> FinderWindowCandidateStatus {
        do {
            guard let role = try AXClient.string(
                kAXRoleAttribute as CFString,
                of: element
            ) else {
                return .pending
            }
            guard role == kAXWindowRole as String else { return .unrelated }
            guard let identifier = try AXClient.string(
                kAXIdentifierAttribute as CFString,
                of: element
            ) else {
                return .pending
            }
            return identifier == "FinderWindow" ? .finderWindow : .unrelated
        } catch AutomationFailure.accessibility(_, .cannotComplete) {
            return .pending
        } catch AutomationFailure.accessibility(_, .invalidUIElement) {
            return .unrelated
        }
    }

    private func firstElement(
        withRole expectedRole: String,
        in elements: [AXUIElement],
        attachedTo expectedWindow: AXUIElement? = nil
    ) throws -> AXUIElement? {
        var matches: [AXUIElement] = []

        for element in uniqueElements(elements) {
            do {
                guard try AXClient.string(
                    kAXRoleAttribute as CFString,
                    of: element
                ) == expectedRole else {
                    continue
                }
                if let expectedWindow {
                    guard let window = try AXClient.element(
                        kAXWindowAttribute as CFString,
                        of: element
                    ), AXClient.same(window, expectedWindow) else {
                        continue
                    }
                }
                matches.append(element)
            } catch AutomationFailure.accessibility(_, .cannotComplete) {
                continue
            } catch AutomationFailure.accessibility(_, .invalidUIElement) {
                continue
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func uniqueElements(_ elements: [AXUIElement]) -> [AXUIElement] {
        var unique: [AXUIElement] = []
        for element in elements where !unique.contains(where: {
            AXClient.same($0, element)
        }) {
            unique.append(element)
        }
        return unique
    }

    private func applySelection(
        in resolved: ResolvedContext,
        application: AXUIElement
    ) throws -> VerifiedSelection {
        switch context {
        case .container:
            try AXClient.setValue(
                [] as CFArray,
                for: kAXSelectedChildrenAttribute as CFString,
                on: resolved.selectionOwner
            )
        case let .items(selection):
            if resolved.remainingItems.isEmpty {
                try click(
                    resolved.firstItem,
                    in: resolved,
                    application: application
                )
            } else {
                try click(
                    resolved.firstItem,
                    in: resolved,
                    application: application
                )
                try waitForSelection(
                    [selection.first],
                    on: resolved.selectionOwner
                )
                var selected = [selection.first]
                for (index, item) in resolved.remainingItems.enumerated() {
                    try click(item, in: resolved, application: application, flags: .maskCommand)
                    selected.append(selection.remaining[index])
                    try waitForSelection(selected, on: resolved.selectionOwner)
                }
            }
        }

        try waitForSelection(context.selectedURLs, on: resolved.selectionOwner)
        return VerifiedSelection(
            owner: resolved.selectionOwner,
            urls: context.selectedURLs
        )
    }

    private func waitForSelection(
        _ expectedURLs: [URL],
        on owner: AXUIElement
    ) throws {
        let deadline = Date().addingTimeInterval(AutomationTiming.target)
        while Date() < deadline {
            let actual = try selectedURLs(on: owner)
            if actual.count == expectedURLs.count && Set(actual.map(\.path)) == Set(expectedURLs.map(\.path)) { return }
            runLoopSlice(AutomationTiming.poll)
        }
        let actualChildren = try AXClient.elements(kAXSelectedChildrenAttribute as CFString, of: owner)
        func facts(_ children: [AXUIElement]) throws -> [[String: String]] {
            try children.map { child in
                let urls = try ([child] + AXTree.paths(below: child).map(\.element)).compactMap { try AXClient.url(of: $0)?.path }
                return ["role": try AXClient.string(kAXRoleAttribute as CFString, of: child) ?? "",
                        "title": try AXClient.string(kAXTitleAttribute as CFString, of: child) ?? "",
                        "urls": urls.joined(separator: "\n")]
            }
        }
        let evidence = try JSONSerialization.data(withJSONObject: ["expectedURLs": expectedURLs.map(\.path), "actual": facts(actualChildren)])
        FileHandle.standardOutput.write(Data("SELECTION_FAILURE\t\(evidence.base64EncodedString())\n".utf8))
        throw AutomationFailure.finderSelectionTimeout
    }

    private func click(
        _ item: ResolvedItem,
        in resolved: ResolvedContext,
        application: AXUIElement,
        flags: CGEventFlags = []
    ) throws {
        try verifySelectionFocus(in: resolved, application: application)

        let location = try FinderPointer.location(of: item.menuElement)
        let hitElement = try AXClient.element(
            at: location,
            in: AXUIElementCreateSystemWide()
        )
        guard try isDescendant(hitElement, of: item.itemScope) else {
            FinderNavigationEvidence.record(stage: .selectionHitMismatch, window: resolved.window,
                application: application, context: context, hit: hitElement,
                itemScope: item.itemScope, menuTarget: item.menuElement)
            throw AutomationFailure.focusLost(
                "The Finder item was obscured before selection."
            )
        }
        try FinderPointer.click(at: location, flags: flags)
    }

    private func verifySelectionFocus(
        in resolved: ResolvedContext,
        application: AXUIElement
    ) throws {
        guard try AXClient.bool(
            kAXFrontmostAttribute as CFString,
            of: application
        ) == true,
              let focusedWindow = try AXClient.element(
                  kAXFocusedWindowAttribute as CFString,
                  of: application
              ), AXClient.same(focusedWindow, resolved.window) else {
            throw AutomationFailure.focusLost(
                "The owned Finder window lost focus before selection."
            )
        }
    }

    private func isDescendant(
        _ element: AXUIElement,
        of ancestor: AXUIElement
    ) throws -> Bool {
        var current: AXUIElement? = element
        while let candidate = current {
            if AXClient.same(candidate, ancestor) { return true }
            current = try AXClient.element(
                kAXParentAttribute as CFString,
                of: candidate
            )
        }
        return false
    }

    private func verifySelection(_ selection: VerifiedSelection) throws {
        let actual = try selectedURLs(on: selection.owner)
        guard actual.count == selection.urls.count && Set(actual.map(\.path)) == Set(selection.urls.map(\.path)) else {
            throw AutomationFailure.finderSelectionTimeout
        }
    }

    private func selectedURLs(on owner: AXUIElement) throws -> [URL] {
        try AXClient.elements(kAXSelectedChildrenAttribute as CFString, of: owner).map { child in
            let urls = Set(try ([child] + AXTree.paths(below: child).map(\.element)).compactMap { try AXClient.url(of: $0) })
            guard urls.count == 1, let url = urls.first else {
                throw AutomationFailure.invalidAccessibilityValue("Selected Finder item URL")
            }
            return url
        }
    }

    private func menuTarget(in resolved: ResolvedContext) throws -> AXUIElement {
        switch context {
        case .container:
            guard try AXClient.supports(
                kAXShowMenuAction as CFString,
                on: resolved.selectionOwner
            ) else {
                throw AutomationFailure.showMenuUnavailable
            }
            return resolved.selectionOwner
        case .items:
            return resolved.firstItem.menuElement
        }
    }

    private func showMenu(
        on target: AXUIElement,
        in resolved: ResolvedContext,
        application: AXUIElement
    ) throws {
        switch context {
        case .container:
            try AXClient.perform(kAXShowMenuAction as CFString, on: target)
        case .items:
            try verifySelectionFocus(
                in: resolved,
                application: application
            )
            let location = try FinderPointer.location(of: target)
            let hitElement = try AXClient.element(
                at: location,
                in: AXUIElementCreateSystemWide()
            )
            guard try isDescendant(
                hitElement,
                of: resolved.firstItem.itemScope
            ) else {
                throw AutomationFailure.focusLost(
                    "The Finder item was obscured before opening its menu."
                )
            }
            try FinderPointer.rightClick(at: location)
        }
    }

    private func movePointerOutsideMenu(
        _ menu: AXUIElement,
        within window: AXUIElement
    ) throws {
        let menuFrame = try AXClient.frame(of: menu)
        let windowFrame = try AXClient.frame(of: window)
        let menuCenter = CGPoint(x: menuFrame.midX, y: menuFrame.midY)
        let inset: CGFloat = 16
        let candidates = [
            CGPoint(x: windowFrame.minX + inset, y: windowFrame.minY + inset),
            CGPoint(x: windowFrame.maxX - inset, y: windowFrame.minY + inset),
            CGPoint(x: windowFrame.minX + inset, y: windowFrame.maxY - inset),
            CGPoint(x: windowFrame.maxX - inset, y: windowFrame.maxY - inset),
        ]
        guard let location = candidates.max(by: {
            distanceSquared(from: $0, to: menuCenter)
                < distanceSquared(from: $1, to: menuCenter)
        }), !menuFrame.contains(location) else {
            throw AutomationFailure.pointerEventUnavailable
        }
        try FinderPointer.move(to: location)
    }

    private func distanceSquared(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let deltaX = lhs.x - rhs.x
        let deltaY = lhs.y - rhs.y
        return deltaX * deltaX + deltaY * deltaY
    }

    private func waitForStableMenu(_ menu: AXUIElement, requiredTitles: Set<String> = [], before limit: Date? = nil) throws -> MenuSnapshot {
        let deadline = min(limit ?? .distantFuture,
                           Date().addingTimeInterval(requiredTitles.isEmpty ? AutomationTiming.stability : AutomationTiming.target))
        var previous: MenuSnapshot?
        while Date() < deadline {
            switch try observeMenu(menu) {
            case let .ready(current):
                let items = try AXClient.elements(kAXChildrenAttribute as CFString, of: menu)
                let available = try requiredTitles.allSatisfy { title in
                    let matches = try items.filter {
                        try AXClient.string(kAXRoleAttribute as CFString, of: $0) == kAXMenuItemRole as String
                            && AXClient.string(kAXTitleAttribute as CFString, of: $0) == title
                            && AXClient.bool(kAXEnabledAttribute as CFString, of: $0) == true
                    }
                    return matches.count == 1
                }
                guard available else {
                    previous = nil
                    runLoopSlice(AutomationTiming.poll)
                    continue
                }
                if current == previous { return current }
                previous = current
            case .notReady:
                previous = nil
            case .gone:
                throw AutomationFailure.menuStabilityTimeout
            }
            runLoopSlice(AutomationTiming.poll)
        }
        throw AutomationFailure.menuStabilityTimeout
    }

    private func observeMenu(_ menu: AXUIElement) throws -> MenuObservation {
        do {
            guard let role = try AXClient.string(
                kAXRoleAttribute as CFString,
                of: menu
            ) else {
                return .notReady
            }
            guard role == kAXMenuRole as String else {
                throw AutomationFailure.invalidAccessibilityValue(
                    kAXRoleAttribute as String
                )
            }
            let frame = try AXClient.frame(of: menu)
            let titles = try AXClient.elements(
                kAXChildrenAttribute as CFString,
                of: menu
            ).compactMap { item -> String? in
                guard try AXClient.string(
                    kAXRoleAttribute as CFString,
                    of: item
                ) == kAXMenuItemRole as String else { return nil }
                return try AXClient.string(
                    kAXTitleAttribute as CFString,
                    of: item
                ) ?? ""
            }
            guard frame.width > 0, frame.height > 0, !titles.isEmpty else {
                return .notReady
            }
            guard let finder else {
                preconditionFailure("An open Finder menu requires a Finder process.")
            }
            return .ready(MenuSnapshot(
                processIdentifier: finder.processIdentifier,
                rect: MenuRect(frame),
                titles: titles
            ))
        } catch AutomationFailure.accessibility(_, .invalidUIElement) {
            return .gone
        } catch AutomationFailure.accessibility(_, .noValue) {
            return .notReady
        }
    }

    private func closeMenu(
        _ menu: AXUIElement,
        application: AXUIElement
    ) throws {
        switch try observeMenu(menu) {
        case .gone:
            return
        case .ready, .notReady:
            break
        }
        guard try AXClient.supports(kAXCancelAction as CFString, on: menu) else {
            throw AutomationFailure.menuCancelUnavailable
        }
        guard let finder else {
            preconditionFailure("Owned Finder UI requires a Finder process.")
        }
        let closeWaiter = try AXElementNotificationWaiter(
            processIdentifier: finder.processIdentifier,
            application: application,
            notification: kAXMenuClosedNotification as CFString
        )
        try AXClient.perform(kAXCancelAction as CFString, on: menu)
        guard try closeWaiter.wait(
            timeout: AutomationTiming.cleanup,
            resolve: { elements in
                if elements.contains(where: { AXClient.same($0, menu) }) {
                    return true
                }
                do {
                    if case .gone = try self.observeMenu(menu) {
                        return true
                    }
                } catch AutomationFailure.accessibility(_, .cannotComplete) {
                    return nil
                }
                return nil
            }
        ) != nil else {
            throw AutomationFailure.menuCloseTimeout
        }
    }

    private func sheetIsAttached(
        _ sheet: AXUIElement,
        to window: AXUIElement
    ) throws -> Bool {
        do {
            guard let sheetWindow = try AXClient.element(
                kAXWindowAttribute as CFString,
                of: sheet
            ) else { return false }
            return AXClient.same(sheetWindow, window)
        } catch AutomationFailure.accessibility(_, .invalidUIElement) {
            return false
        }
    }

    private func closeSheet(
        _ sheet: AXUIElement,
        in window: AXUIElement,
        application: AXUIElement
    ) throws {
        guard try sheetIsAttached(sheet, to: window) else { return }
        guard try AXClient.bool(
            kAXFrontmostAttribute as CFString,
            of: application
        ) == true,
              let focusedElement = try AXClient.element(
                  kAXFocusedWindowAttribute as CFString,
                  of: application
              ) else {
            throw AutomationFailure.sheetCancelUnavailable
        }
        let focusBelongsToOwnedUI: Bool
        if AXClient.same(focusedElement, window) {
            focusBelongsToOwnedUI = true
        } else {
            focusBelongsToOwnedUI = try isOwnedSheetFocus(
                focusedElement,
                sheet: sheet,
                window: window
            )
        }
        guard focusBelongsToOwnedUI else {
            throw AutomationFailure.sheetCancelUnavailable
        }
        try FinderKeyboard.press(.escape)

        let deadline = Date().addingTimeInterval(AutomationTiming.cleanup)
        while Date() < deadline {
            if try !sheetIsAttached(sheet, to: window) { return }
            runLoopSlice(AutomationTiming.poll)
        }
        throw AutomationFailure.sheetCloseTimeout
    }

    private func closeWindow(_ window: AXUIElement, application: AXUIElement) throws {
        let windows = try AXClient.elements(kAXWindowsAttribute as CFString, of: application)
        guard windows.contains(where: { AXClient.same($0, window) }) else { return }
        guard let closeButton = try AXClient.element(
            kAXCloseButtonAttribute as CFString,
            of: window
        ), try AXClient.supports(kAXPressAction as CFString, on: closeButton) else {
            throw AutomationFailure.windowCloseTimeout
        }
        try AXClient.perform(kAXPressAction as CFString, on: closeButton)

        let deadline = Date().addingTimeInterval(AutomationTiming.cleanup)
        while Date() < deadline {
            let remaining = try AXClient.elements(
                kAXWindowsAttribute as CFString,
                of: application
            )
            if !remaining.contains(where: { AXClient.same($0, window) }) { return }
            runLoopSlice(AutomationTiming.poll)
        }
        throw AutomationFailure.windowCloseTimeout
    }
}

private func runningFinder() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
        .first(where: { !$0.isTerminated })
}
