/**
 以 actor 串行持有模板记录，协调首次初始化、索引恢复与清单变更提交。
 通过存储边界操作副本和索引，明确区分提交前失败与提交后的清理问题。
 */

import Foundation

/// 主应用唯一拥有的已提交索引；同步存储操作在 actor 内串行执行。
actor FileTemplateLibrary {
    private let storage: FileTemplateStorage
    private var records: [FileTemplateRecord]?

    init() {
        storage = FileTemplateStorage()
    }

    /// 恢复索引或执行唯一一次初始化；空索引保留用户已删除全部模板的状态。
    func load() throws -> FileTemplateLoadResult {
        if let records {
            return FileTemplateLoadResult(templates: records.map(\.template), origin: .cached)
        }

        guard let data = try storage.readIndex() else {
            let templates = try initialize()
            return FileTemplateLoadResult(templates: templates, origin: .initialized)
        }

        let index: FileTemplateIndex
        do {
            index = try JSONDecoder().decode(FileTemplateIndex.self, from: data)
        } catch let error as FileTemplateLibraryError {
            throw error
        } catch {
            throw FileTemplateLibraryError.invalidIndex(SystemErrorSnapshot(capturing: error))
        }

        records = index.templates
        storage.cleanUnreferencedFiles(referencedBy: index.templates)
        return FileTemplateLoadResult(templates: index.templates.map(\.template), origin: .restored)
    }

    /// 完整保存普通源文件的内容后，再把新模板追加到索引。
    func importFile(at sourceURL: URL) throws -> FileTemplateCommit {
        var current = try currentRecords()
        let data = try storage.readContent(at: sourceURL)
        let template = try FileTemplateImportNaming.template(
            id: FileTemplateID(), from: sourceURL, existing: current.map(\.template)
        )
        let file = try storage.saveContent(data, named: sourceURL.lastPathComponent)
        current.append(FileTemplateRecord(template: template, file: file))
        do {
            try commit(current)
        } catch {
            storage.cleanContent(at: storage.directoryURL(for: file))
            throw error
        }
        return .committed(current.map(\.template))
    }

    /// 名称修改只提交元数据，保留稳定身份、内容和列表顺序。
    private func update(_ template: FileTemplate) throws -> FileTemplateCommit {
        var current = try currentRecords()
        guard let position = current.firstIndex(where: { $0.template.id == template.id }) else {
            throw FileTemplateLibraryError.templateNotFound(template.id)
        }
        current[position] = FileTemplateRecord(template: template, file: current[position].file)
        try commit(current)
        return .committed(current.map(\.template))
    }

    /// 单字段修改从 actor 当前记录构造，读取另一字段与提交之间不引入异步交接。
    func updateName(
        for id: FileTemplateID,
        field: FileTemplateNameField,
        value: String
    ) throws -> FileTemplateCommit {
        let template = try record(for: id).template
        return try update(field.updating(template, to: value))
    }

    /// 按稳定身份移动当前记录；nil 目标表示末尾，位置未改变时不写索引。
    func move(id: FileTemplateID, before destinationID: FileTemplateID?) throws -> FileTemplateCommit? {
        var current = try currentRecords()
        guard let source = current.firstIndex(where: { $0.template.id == id }) else {
            throw FileTemplateLibraryError.templateNotFound(id)
        }
        let destination: Int
        if let destinationID {
            guard let target = current.firstIndex(where: { $0.template.id == destinationID }) else {
                throw FileTemplateLibraryError.templateNotFound(destinationID)
            }
            destination = target > source ? target - 1 : target
        } else {
            destination = current.count - 1
        }
        guard source != destination else { return nil }

        current.insert(current.remove(at: source), at: destination)
        try commit(current)
        return .committed(current.map(\.template))
    }

    /// 完整复制选定文件后原子发布新引用；提交后的清理问题随权威清单返回。
    func replaceFile(for id: FileTemplateID, at sourceURL: URL) throws -> FileTemplateCommit {
        var current = try currentRecords()
        guard let position = current.firstIndex(where: { $0.template.id == id }) else {
            throw FileTemplateLibraryError.templateNotFound(id)
        }
        let original = current[position]
        let file = try storage.saveContent(storage.readContent(at: sourceURL), named: sourceURL.lastPathComponent)
        current[position] = FileTemplateRecord(template: original.template, file: file)
        do {
            try commit(current)
        } catch {
            storage.cleanContent(at: storage.directoryURL(for: file))
            throw error
        }
        return cleanAfterCommit(original.file, committed: current)
    }

    /// 先提交元数据删除，再清理副本；返回值明确区分清理问题与提交失败。
    func remove(id: FileTemplateID) throws -> FileTemplateCommit {
        var current = try currentRecords()
        guard let position = current.firstIndex(where: { $0.template.id == id }) else {
            throw FileTemplateLibraryError.templateNotFound(id)
        }
        let removed = current.remove(at: position)
        try commit(current)
        return cleanAfterCommit(removed.file, committed: current)
    }

    /// 每次从实际文件取得独立字节快照，使默认应用保存的编辑用于下一次创建。
    func content(for id: FileTemplateID) throws -> FileTemplateContent {
        let record = try record(for: id)
        return FileTemplateContent(
            template: record.template,
            data: try storage.readContent(at: storage.contentURL(for: record.file))
        )
    }

    /// 提供已保存的内部副本；只检查普通文件，不为系统打开操作读取全部内容。
    func fileURL(for id: FileTemplateID) throws -> URL {
        let record = try record(for: id)
        let url = storage.contentURL(for: record.file)
        try storage.validateRegularFile(at: url)
        return url
    }

    private func currentRecords() throws -> [FileTemplateRecord] {
        if let records { return records }
        _ = try load()
        return records!
    }

    private func record(for id: FileTemplateID) throws -> FileTemplateRecord {
        guard let record = try currentRecords().first(where: { $0.template.id == id }) else {
            throw FileTemplateLibraryError.templateNotFound(id)
        }
        return record
    }

    private func initialize() throws -> [FileTemplate] {
        let template = try FileTemplate(displayName: "TXT", defaultFileName: "untitled.txt")
        let file = try storage.saveContent(Data(), named: "untitled.txt")
        let initial = [FileTemplateRecord(template: template, file: file)]
        try commit(initial)
        storage.cleanUnreferencedFiles(referencedBy: initial)
        return [template]
    }

    private func commit(_ updated: [FileTemplateRecord]) throws {
        try storage.commit(updated)
        records = updated
    }

    private func cleanAfterCommit(
        _ file: FileTemplateFileReference,
        committed records: [FileTemplateRecord]
    ) -> FileTemplateCommit {
        let templates = records.map(\.template)
        do {
            try storage.removeContent(at: storage.directoryURL(for: file))
            return .committed(templates)
        } catch {
            return .committedWithCleanupIssue(templates, error)
        }
    }
}
